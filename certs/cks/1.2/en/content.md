# 1.2 Use CIS Benchmark to Review the Security Configuration of Kubernetes Components (etcd, kubelet, kubedns, kubeapi)

## Why this topic matters

A default Kubernetes cluster is *functional*, not *hardened*. `kubeadm` makes reasonable choices, but distributions, cloud providers, and hand-rolled installers all differ, and many of them leave dangerous defaults in place: an anonymously-reachable kubelet, an unauthenticated etcd peer port, profiling endpoints exposed on the API server, world-readable PKI material.

The **CIS Kubernetes Benchmark** (Center for Internet Security) is the industry-standard checklist that tells you, control by control, what "hardened" means for each component. In the CKS exam you are not asked to memorize the benchmark — you are asked to **run it, read its output, and fix what it flags**, usually with `kube-bench`.

---

## 1. What the CIS Kubernetes Benchmark is

The benchmark is a versioned PDF/spreadsheet published by CIS, developed by a community of practitioners. It is **versioned independently of Kubernetes**: CIS Kubernetes Benchmark v1.9, v1.10, v1.11… each targets a range of Kubernetes releases. There are separate benchmarks for managed distributions (EKS, GKE, AKS, OpenShift, RKE), because on those you cannot see or edit the control plane.

### Structure

Every control has:

| Field | Meaning |
|---|---|
| **ID** | Hierarchical number, e.g. `1.2.15` |
| **Title** | e.g. *Ensure that the `--profiling` argument is set to `false`* |
| **Assessment** | **Automated** (a tool can verify it) or **Manual** (a human must judge) |
| **Profile Level** | **Level 1** = practical, low operational impact. **Level 2** = defense-in-depth, may break things |
| **Audit** | The command that proves compliance |
| **Remediation** | The exact change to make |
| **Impact** | What breaks if you apply it |

### Sections

```
1  Control Plane Components
   1.1  Control Plane Node Configuration Files   (file permissions & ownership)
   1.2  API Server                               (kube-apiserver flags)
   1.3  Controller Manager
   1.4  Scheduler
2  etcd                                          (etcd TLS & peer auth)
3  Control Plane Configuration
   3.1  Authentication and Authorization
   3.2  Logging                                  (audit policy)
4  Worker Nodes
   4.1  Worker Node Configuration Files
   4.2  Kubelet
5  Policies
   5.1  RBAC and Service Accounts
   5.2  Pod Security Standards
   5.3  Network Policies and CNI
   5.4  Secrets Management
   5.5  Extensible Admission Control
   5.7  General Policies
```

> **Exam-critical caveat:** the *numbering shifts between benchmark revisions*. `--protect-kernel-defaults` may be `4.2.6` in one release and `4.2.7` in another. **Never trust an ID you memorized — read the ID out of your own `kube-bench` output.**

---

## 2. kube-bench: the tool that automates the benchmark

`kube-bench` (Aqua Security, Go, Apache-2.0) implements the Automated controls as YAML rule files and runs them against the node it is executing on.

### 2.1 Running it

**A. As a container on a control plane node (most common in the exam):**

```bash
docker run --rm --pid=host \
  -v /etc:/etc:ro \
  -v /var:/var:ro \
  -t docker.io/aquasec/kube-bench:latest \
  run --targets=master
```

**B. As a Job inside the cluster:**

```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs -f job/kube-bench
```

The upstream repo also ships `job-master.yaml` and `job-node.yaml`, which pin the pod to a control-plane or worker node respectively. All of them need `hostPID: true` (to inspect running processes) and read-only `hostPath` mounts of `/etc` and `/var`.

**C. As a binary already installed on the node:**

```bash
kube-bench run --targets master,node,etcd,policies
```

### 2.2 Targets

| Target | Covers | Run it on |
|---|---|---|
| `master` | sections 1 and 3 | control plane node |
| `etcd` | section 2 | node running etcd |
| `node` | section 4 | worker node |
| `policies` | section 5 | anywhere with kubeconfig |
| `controlplane` | section 3 | control plane node |

If you omit `--targets`, kube-bench auto-detects what is running locally.

### 2.3 Selecting the benchmark version

```bash
# Let kube-bench auto-detect the cluster version:
kube-bench run --targets master

# Pin explicitly, when auto-detection guesses wrong:
kube-bench run --benchmark cis-1.10 --targets master

# Managed clusters:
kube-bench run --benchmark eks-1.5.0
kube-bench run --benchmark gke-1.6.0

# What does my binary actually ship?
ls /etc/kube-bench/cfg/
# cis-1.8  cis-1.9  cis-1.10  cis-1.11  eks-1.5.0  gke-1.6.0  aks-1.7  rh-1.6 ...
```

If kube-bench errors with `unable to determine benchmark version`, pin it manually — that is the intended fix, not a bug.

### 2.4 Useful flags

```bash
kube-bench run --targets master --check 1.2.15        # one control
kube-bench run --targets master --check 1.2.15,1.2.16 # several
kube-bench run --targets node   --skip 4.2.6          # ignore a control
kube-bench run --targets master --json | jq .          # machine-readable
kube-bench run --targets master --outputfile /tmp/r.txt
kube-bench run --targets master --noremediations       # terse
kube-bench run --targets master --exit-code 1          # non-zero exit if FAIL → CI gate
```

### 2.5 Reading the output

```text
[INFO] 1 Control Plane Security Configuration
[INFO] 1.2 API Server
[PASS] 1.2.1 Ensure that the --anonymous-auth argument is set to false (Manual)
[FAIL] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
[WARN] 1.2.9 Ensure that the admission control plugin EventRateLimit is set (Manual)
[PASS] 1.2.24 Ensure that the --tls-cert-file and --tls-private-key-file arguments are set

== Remediations master ==
1.2.15 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and set the below parameter.
--profiling=false

== Summary master ==
44 checks PASS
8 checks FAIL
11 checks WARN
0 checks INFO
```

| Status | Meaning | What you do |
|---|---|---|
| `PASS` | Automated check satisfied | Nothing |
| `FAIL` | Automated check violated | **Fix it** — remediation text is printed below |
| `WARN` | Manual control, or a check kube-bench could not evaluate | Read it and decide; the exam usually only grades `FAIL` |
| `INFO` | Informational | Nothing |

**Exam workflow:** run → note the failing IDs → apply the printed remediation → re-run with `--check <id>` to confirm `PASS`.

---

## 3. kube-apiserver (section 1.2)

The API server is the single front door to the cluster. All flags live in the static pod manifest:

```
/etc/kubernetes/manifests/kube-apiserver.yaml
```

Editing that file causes the kubelet to restart the static pod automatically — no `systemctl` needed.

### Controls you must be able to fix on sight

| Control | Correct setting | Why |
|---|---|---|
| `--anonymous-auth` | `false` | Otherwise unauthenticated requests get the `system:anonymous` identity |
| `--token-auth-file` | **not set** | Static token file = plaintext, non-revocable credentials |
| `--authorization-mode` | contains `Node,RBAC`, never `AlwaysAllow` | `AlwaysAllow` disables authorization entirely |
| `--enable-admission-plugins` | includes `NodeRestriction`, `ServiceAccount`, `NamespaceLifecycle` | `NodeRestriction` stops a compromised kubelet from editing other nodes/pods |
| `--enable-admission-plugins` | does **not** include `AlwaysAdmit` | Bypasses all admission control |
| `--profiling` | `false` | `/debug/pprof` leaks system detail and is a DoS vector |
| `--audit-log-path` | set (e.g. `/var/log/kubernetes/audit.log`) | No audit log = no forensics |
| `--audit-log-maxage` / `-maxbackup` / `-maxsize` | `30` / `10` / `100` | Retention without filling the disk |
| `--service-account-lookup` | `true` | Validates the token still exists in etcd (honours revocation) |
| `--kubelet-certificate-authority` | set | Prevents API-server→kubelet MITM |
| `--client-ca-file`, `--tls-cert-file`, `--tls-private-key-file` | set | Mutual TLS |
| `--etcd-cafile`, `--etcd-certfile`, `--etcd-keyfile` | set | Authenticated TLS to etcd |
| `--encryption-provider-config` | set, with a real provider (`aescbc`/`secretbox`/`kms`), never `identity` first | Encrypts Secrets at rest |
| `--request-timeout` | sane value (default `60s`) | Slowloris-style DoS |
| `--tls-cipher-suites` | strong suites only | Level 2 |

### Worked remediation

kube-bench reports:

```text
[FAIL] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
[FAIL] 1.2.21 Ensure that the --service-account-lookup argument is set to true (Automated)
```

Fix:

```bash
ssh controlplane
cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=10.0.0.10
    - --authorization-mode=Node,RBAC
    - --enable-admission-plugins=NodeRestriction
    - --profiling=false                 # <-- 1.2.15
    - --service-account-lookup=true     # <-- 1.2.21
    - --audit-log-path=/var/log/kubernetes/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    ...
```

Watch it come back:

```bash
# The kubelet notices the file change and recreates the static pod.
crictl ps | grep kube-apiserver
# 3f9a1c...  2 seconds ago  Running  kube-apiserver  0

kubectl get pods -n kube-system kube-apiserver-controlplane
# NAME                         READY   STATUS    RESTARTS   AGE
# kube-apiserver-controlplane  1/1     Running   0          31s
```

Re-verify:

```bash
kube-bench run --targets master --check 1.2.15,1.2.21
# [PASS] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
# [PASS] 1.2.21 Ensure that the --service-account-lookup argument is set to true (Automated)
```

> **Trap:** a typo in the manifest makes the API server never start, and `kubectl` stops working with `The connection to the server ... was refused`. Debug with `crictl ps -a`, `crictl logs <id>`, and `journalctl -u kubelet`. Always keep a backup copy **outside** `/etc/kubernetes/manifests/` — a `.bak` file left inside that directory is parsed as a manifest and creates a duplicate pod.

---

## 4. etcd (section 2)

etcd holds every Secret, ConfigMap and object in the cluster **in plaintext by default**. Read access to etcd is equivalent to cluster-admin. Manifest:

```
/etc/kubernetes/manifests/etcd.yaml
```

| Control | Correct setting |
|---|---|
| 2.1 | `--cert-file` and `--key-file` set (client TLS) |
| 2.2 | `--client-cert-auth=true` — clients must present a valid cert |
| 2.3 | `--auto-tls` **not** `true` — self-signed certs accept anyone |
| 2.4 | `--peer-cert-file` and `--peer-key-file` set |
| 2.5 | `--peer-client-cert-auth=true` |
| 2.6 | `--peer-auto-tls` **not** `true` |
| 2.7 | etcd uses a **unique CA**, not the cluster CA |

Hardened fragment:

```yaml
spec:
  containers:
  - command:
    - etcd
    - --advertise-client-urls=https://10.0.0.10:2379
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --client-cert-auth=true
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --peer-client-cert-auth=true
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --data-dir=/var/lib/etcd
```

Prove the client port really demands a certificate:

```bash
# Without credentials — must fail:
curl -k https://127.0.0.1:2379/version
# curl: (56) OpenSSL SSL_read: error:0A00045C:SSL routines::tlsv13 alert certificate required

# With credentials — succeeds:
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
# https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 4.2ms
```

Data directory permissions (control 1.1.11/1.1.12 depending on revision):

```bash
stat -c "%a %U:%G" /var/lib/etcd
# 700 etcd:etcd

# Remediation if wrong:
chmod 700 /var/lib/etcd
chown etcd:etcd /var/lib/etcd
```

Demonstrate why encryption-at-rest matters:

```bash
kubectl create secret generic demo --from-literal=password=S3cr3t
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/demo | hexdump -C | head
# ... 70 61 73 73 77 6f 72 64  ... 53 33 63 72 33 74   |password ... S3cr3t|
```

With `--encryption-provider-config` set to an `aescbc` or `kms` provider, that same dump starts with `k8s:enc:aescbc:v1:` and the value is unreadable.

---

## 5. kubelet (section 4)

The kubelet exposes an API on port `10250` that can **exec into any pod on the node**. It is the single most attractive lateral-movement target in a cluster.

Configuration comes from two places, and the config file wins for anything not overridden on the command line:

```
/var/lib/kubelet/config.yaml            # KubeletConfiguration object
/etc/systemd/system/kubelet.service.d/10-kubeadm.conf   # CLI flags
```

| Control | Setting | Config-file key |
|---|---|---|
| 4.2.1 | `--anonymous-auth=false` | `authentication.anonymous.enabled: false` |
| 4.2.2 | `--authorization-mode=Webhook` (never `AlwaysAllow`) | `authorization.mode: Webhook` |
| 4.2.3 | `--client-ca-file` set | `authentication.x509.clientCAFile` |
| 4.2.4 | `--read-only-port=0` | `readOnlyPort: 0` |
| 4.2.5 | `--streaming-connection-idle-timeout` ≠ `0` | `streamingConnectionIdleTimeout: 5m` |
| 4.2.x | `--protect-kernel-defaults=true` | `protectKernelDefaults: true` |
| 4.2.x | `--make-iptables-util-chains=true` | `makeIPTablesUtilChains: true` |
| 4.2.x | `--hostname-override` not set | — |
| 4.2.x | `eventRecordQPS` set (rate-limit event flooding) | `eventRecordQPS: 5` |
| 4.2.x | `--rotate-certificates=true` | `rotateCertificates: true` |
| 4.2.x | `RotateKubeletServerCertificate=true` | `serverTLSBootstrap: true` |
| 4.2.x | strong `tlsCipherSuites` | `tlsCipherSuites: [...]` |

Hardened `config.yaml`:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false                 # 4.2.1
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt   # 4.2.3
authorization:
  mode: Webhook                    # 4.2.2
readOnlyPort: 0                    # 4.2.4
streamingConnectionIdleTimeout: 5m # 4.2.5
protectKernelDefaults: true
makeIPTablesUtilChains: true
eventRecordQPS: 5
rotateCertificates: true
serverTLSBootstrap: true
tlsCipherSuites:
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
```

Unlike static pods, the kubelet needs an explicit restart:

```bash
systemctl daemon-reload
systemctl restart kubelet
systemctl status kubelet --no-pager
journalctl -u kubelet -n 30 --no-pager
```

Verify the attack surface is actually closed:

```bash
# Read-only port (10255) must be gone:
curl -s http://localhost:10255/pods
# curl: (7) Failed to connect to localhost port 10255: Connection refused

# Anonymous access to the authenticated port must be rejected:
curl -sk https://localhost:10250/pods
# Unauthorized
```

> **Trap:** `protectKernelDefaults: true` makes the kubelet **refuse to start** if sysctls such as `vm.overcommit_memory` or `kernel.panic` do not match its expectations. Check `journalctl -u kubelet` for `Failed to start ContainerManager ... sysctl ...` and set the values in `/etc/sysctl.d/` before enabling it.

> **Trap:** on some distributions the effective value comes from the systemd drop-in, not from `config.yaml`. Always confirm what the process is really running with:
> ```bash
> ps -ef | grep '[k]ubelet' | tr ' ' '\n' | grep -E 'anonymous|read-only|authorization|config'
> ```

---

## 6. kubedns / CoreDNS

The exam objective names `kubedns`, which is historical — modern clusters run **CoreDNS**. The CIS Kubernetes Benchmark does **not** have a dedicated CoreDNS section; it is covered indirectly by section 5 (RBAC, Pod Security Standards, network policy). You harden it as a workload:

**1. Audit its RBAC.** CoreDNS only needs to *read* endpoints, services, pods and namespaces:

```bash
kubectl get clusterrole system:coredns -o yaml
```

```yaml
rules:
- apiGroups: [""]
  resources: ["endpoints", "services", "pods", "namespaces"]
  verbs: ["list", "watch"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["list", "watch"]
```

Anything beyond `list`/`watch` on those resources — especially `secrets`, or any `create`/`update` — is a finding.

**2. Check the pod's security context.** CoreDNS should run as non-root with a minimal capability set:

```bash
kubectl get deploy coredns -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | jq .
```

```json
{
  "allowPrivilegeEscalation": false,
  "capabilities": { "add": ["NET_BIND_SERVICE"], "drop": ["ALL"] },
  "readOnlyRootFilesystem": true
}
```

**3. Review the Corefile** for dangerous plugins. Verify no unexpected `forward` to an untrusted resolver, and that the metrics/health endpoints are not exposed beyond the cluster:

```bash
kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}'
```

```
.:53 {
    errors
    health { lameduck 5s }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
    }
    prometheus :9153
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
}
```

`pods insecure` allows resolving *any* pod IP as `<ip>.<ns>.pod.cluster.local` without verifying the pod actually lives in that namespace — a reconnaissance aid. `pods verified` is the hardened alternative.

**4. Restrict who can talk to it.** A NetworkPolicy in `kube-system` that only permits UDP/TCP 53 ingress prevents a compromised pod from using the DNS service as a pivot:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: coredns-allow-dns-only
  namespace: kube-system
spec:
  podSelector:
    matchLabels:
      k8s-app: kube-dns
  policyTypes: ["Ingress"]
  ingress:
  - ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

---

## 7. File permissions and ownership (sections 1.1 and 4.1)

These are the easiest `FAIL`s to fix and appear constantly in kube-bench output.

| Path | Permissions | Owner |
|---|---|---|
| `/etc/kubernetes/manifests/*.yaml` | `600` | `root:root` |
| `/etc/kubernetes/admin.conf` | `600` | `root:root` |
| `/etc/kubernetes/scheduler.conf`, `controller-manager.conf` | `600` | `root:root` |
| `/etc/kubernetes/pki/*.crt` | `644` | `root:root` |
| `/etc/kubernetes/pki/*.key` | `600` | `root:root` |
| `/var/lib/etcd` | `700` | `etcd:etcd` |
| `/var/lib/kubelet/config.yaml` | `600` | `root:root` |
| `/etc/kubernetes/kubelet.conf` | `600` | `root:root` |
| CNI config files under `/etc/cni/net.d/` | `600` | `root:root` |

> Older benchmark revisions asked for `644` on manifests and kubeconfigs; current ones require `600`. Apply what **your** output says.

Bulk remediation:

```bash
chmod 600 /etc/kubernetes/manifests/*.yaml
chmod 600 /etc/kubernetes/admin.conf /etc/kubernetes/scheduler.conf \
          /etc/kubernetes/controller-manager.conf /etc/kubernetes/kubelet.conf
chmod 600 /etc/kubernetes/pki/*.key /etc/kubernetes/pki/etcd/*.key
chmod 644 /etc/kubernetes/pki/*.crt
chown -R root:root /etc/kubernetes/pki

# Verify:
find /etc/kubernetes/pki -name '*.key' -exec stat -c "%a %U:%G %n" {} \;
# 600 root:root /etc/kubernetes/pki/apiserver.key
# 600 root:root /etc/kubernetes/pki/ca.key
```

---

## 8. Controller manager and scheduler (sections 1.3 and 1.4)

Smaller surface, but they show up in kube-bench output:

| Component | Control | Setting |
|---|---|---|
| controller-manager | `--profiling` | `false` |
| controller-manager | `--use-service-account-credentials` | `true` (each controller gets its own least-privilege SA) |
| controller-manager | `--service-account-private-key-file` | set |
| controller-manager | `--root-ca-file` | set |
| controller-manager | `RotateKubeletServerCertificate` | `true` |
| controller-manager | `--bind-address` | `127.0.0.1` |
| scheduler | `--profiling` | `false` |
| scheduler | `--bind-address` | `127.0.0.1` |

---

## 9. Practical exam workflow

1. **Baseline.** Run kube-bench on the control plane node and save the output.
   ```bash
   kube-bench run --targets master,etcd --outputfile /tmp/cp.txt
   grep '\[FAIL\]' /tmp/cp.txt
   ```
2. **Back up** every manifest you touch, to a directory *outside* `/etc/kubernetes/manifests/`.
3. **Apply** the remediation kube-bench printed — verbatim. Don't invent your own flag name.
4. **Restart correctly:** static pods (apiserver, controller-manager, scheduler, etcd) restart on their own; kubelet needs `systemctl restart kubelet`.
5. **Confirm the cluster is alive:** `kubectl get nodes`, `kubectl -n kube-system get pods`.
6. **Re-run scoped** to what you fixed: `kube-bench run --targets master --check 1.2.15,1.2.21`.
7. **Repeat on workers:** `kube-bench run --targets node`.

Handy one-liner to list only failures with their titles:

```bash
kube-bench run --targets master --json \
  | jq -r '.Controls[].tests[].results[] | select(.status=="FAIL") | "\(.test_number)  \(.test_desc)"'
```

```text
1.2.15  Ensure that the --profiling argument is set to false
1.2.21  Ensure that the --service-account-lookup argument is set to true
1.1.12  Ensure that the etcd data directory ownership is set to etcd:etcd
```

---

## 10. Limits and pitfalls

- **The benchmark is a baseline, not a security program.** Full CIS compliance does not stop a malicious container image, a leaked service-account token, or an over-permissive RBAC binding.
- **Not every FAIL should be fixed blindly.** Some controls break specific workloads (`AlwaysPullImages` on an air-gapped registry, `EventRateLimit` without a tuned config). CIS documents this under *Impact*. Justify and document exceptions rather than pretending they pass.
- **kube-bench only sees the node it runs on.** In a multi-node control plane you must run it on every node — configuration drift between control plane nodes is a real and common finding.
- **On managed clusters** (EKS/GKE/AKS) you cannot edit the control plane at all; use the provider-specific benchmark, which only tests worker nodes and policies.
- **`WARN` is not "safe".** Manual controls are the ones a tool cannot verify — often the most important ones (audit policy content, encryption provider correctness, RBAC design).

---

## Exercises

**1.** Run kube-bench against the control plane and produce a list of only the failing check IDs for the API server section.

<details><summary>Solution</summary>

```bash
kube-bench run --targets master --json \
  | jq -r '.Controls[].tests[] | select(.section=="1.2") | .results[]
           | select(.status=="FAIL") | .test_number'
```
</details>

**2.** kube-bench reports `[FAIL] 1.2.15 Ensure that the --profiling argument is set to false`. Fix it and prove the fix.

<details><summary>Solution</summary>

```bash
cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/backup/
# add `- --profiling=false` to the command list
vi /etc/kubernetes/manifests/kube-apiserver.yaml
# wait for the static pod to be recreated
watch crictl ps | grep kube-apiserver
kube-bench run --targets master --check 1.2.15
# [PASS] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
```
</details>

**3.** Close the kubelet read-only port and disable anonymous authentication on a worker node, then verify both from the shell.

<details><summary>Solution</summary>

In `/var/lib/kubelet/config.yaml`: set `readOnlyPort: 0`, `authentication.anonymous.enabled: false`, `authorization.mode: Webhook`.

```bash
systemctl restart kubelet
curl -s http://localhost:10255/pods          # connection refused
curl -sk https://localhost:10250/pods        # Unauthorized
kube-bench run --targets node --check 4.2.1,4.2.2,4.2.4
```
</details>

**4.** Confirm that etcd rejects clients that do not present a certificate.

<details><summary>Solution</summary>

Ensure `--client-cert-auth=true` and `--auto-tls` is absent in `/etc/kubernetes/manifests/etcd.yaml`, then:

```bash
curl -k https://127.0.0.1:2379/version
# tlsv13 alert certificate required
```
</details>

**5.** Show that a Secret is stored in plaintext in etcd, then explain which CIS control addresses it.

<details><summary>Solution</summary>

Use `etcdctl get /registry/secrets/<ns>/<name> | hexdump -C` and observe the readable value. The relevant controls are the API server's `--encryption-provider-config` being set (1.2.27 in recent revisions) and the providers being correctly configured, i.e. `identity` must not be the first provider.
</details>

---

## References

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CIS Kubernetes Benchmark (free download) — https://www.cisecurity.org/benchmark/kubernetes
- CIS Benchmarks overview — https://www.cisecurity.org/cis-benchmarks
- kube-bench repository — https://github.com/aquasecurity/kube-bench
- kube-bench documentation — https://aquasecurity.github.io/kube-bench/
- Kubernetes — Securing a Cluster — https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Kubernetes — kube-apiserver reference — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes — kubelet reference — https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
- Kubernetes — KubeletConfiguration (v1beta1) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Kubernetes — kube-controller-manager reference — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
- Kubernetes — kube-scheduler reference — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-scheduler/
- Kubernetes — Encrypting Secret Data at Rest — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes — Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — Operating etcd clusters for Kubernetes — https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Kubernetes — Kubelet authentication/authorization — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes — Using NodeRestriction admission plugin — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
- Kubernetes — Customizing DNS Service (CoreDNS) — https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/
- CoreDNS Kubernetes plugin — https://coredns.io/plugins/kubernetes/
- etcd — Transport security model — https://etcd.io/docs/latest/op-guide/security/