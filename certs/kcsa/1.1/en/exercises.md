# Guided Exercises — Topic 1.1: The 4Cs of Cloud Native Security

> **Exam:** KCSA (Kubernetes and Cloud Native Security Associate)
> **Domain:** Overview of Cloud Native Security · **Weight:** 2.33
>
> The **4Cs** are the concentric defense-in-depth layers of a cloud native system: **Cloud → Cluster → Container → Code**. Each outer layer is the trust boundary for the one inside it: **you cannot secure an inner layer if the layer around it is weak**, because a compromise of the outer layer bypasses every control you placed further in. These exercises make that dependency concrete by having you probe each layer, break it, and observe the blast radius.

---

## Prerequisites

You need a throwaway single-node cluster and a few CLIs. Everything below is reproducible on a laptop with `kind`; no paid cloud account is required.

```bash
# Versions used when authoring these exercises (newer is fine)
kind version         # kind v0.23.0
kubectl version --client --output=yaml | grep gitVersion   # v1.30.x
docker --version     # Docker 26.x
```

### Step 0 — Create the lab cluster

1. Create a `kind` cluster with the API server bound only to localhost (a Cloud-layer control we will revisit):

```bash
cat <<'EOF' > kind-4cs.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "127.0.0.1"   # do NOT expose the control plane on 0.0.0.0
nodes:
  - role: control-plane
EOF

kind create cluster --name kcsa-4cs --config kind-4cs.yaml
```

2. Confirm the node and control-plane components are healthy:

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods
```

Expected (abridged):

```
NAME                      STATUS   ROLES           AGE   VERSION
kcsa-4cs-control-plane    Ready    control-plane   40s   v1.30.0

NAME                                             READY   STATUS    RESTARTS   AGE
kube-apiserver-kcsa-4cs-control-plane            1/1     Running   0          35s
etcd-kcsa-4cs-control-plane                      1/1     Running   0          35s
...
```

> **Comprehension check 0**
> 1. In the 4Cs model, name each of the four layers from outermost to innermost.
> 2. The `apiServerAddress: "127.0.0.1"` setting is a control at which of the 4Cs? Justify the answer.
> 3. Why does the phrase *"defense in depth"* apply to the 4Cs even though each layer has its own distinct controls?

---

## Exercise 1 — The **Cloud** (Infrastructure) layer

The Cloud layer is everything Kubernetes runs *on*: the provider's control plane, the VMs/nodes, the network fabric, and the **instance metadata service (IMDS)**. It is the outermost trust boundary — if an attacker owns the infrastructure, no cluster control matters. The classic Cloud-layer attack from *inside* a workload is **SSRF against the metadata endpoint** to steal the node's cloud IAM credentials.

### Step 1.1 — Reach the metadata endpoint from a Pod

1. Launch an ephemeral debug Pod:

```bash
kubectl run imds-probe --image=curlimages/curl:8.8.0 --restart=Never -it --rm -- sh
```

2. Inside the Pod, attempt to read the well-known link-local metadata address (this is `169.254.169.254` on AWS/GCP/Azure/OpenStack):

```sh
# AWS IMDSv1-style probe (unauthenticated GET)
curl -s --max-time 5 http://169.254.169.254/latest/meta-data/iam/security-credentials/ ; echo
```

3. On this `kind` cluster there is **no** cloud metadata service, so you get a timeout — the *safe* outcome:

```
command terminated with exit code 28   # curl: (28) Connection timed out
```

4. Now read what the same request would return on a **real, misconfigured** managed node (annotated example — do not expect this on kind):

```
# On a real EKS node with IMDSv1 enabled and a node role attached:
$ curl http://169.254.169.254/latest/meta-data/iam/security-credentials/
eks-node-role
$ curl http://169.254.169.254/latest/meta-data/iam/security-credentials/eks-node-role
{
  "AccessKeyId": "ASIA...",
  "SecretAccessKey": "wJalr...",
  "Token": "IQoJb3JpZ2lu...",     # <-- usable AWS STS credentials for the NODE role
  "Expiration": "2026-08-06T18:00:00Z"
}
```

5. Exit the Pod (`exit`). It is deleted automatically by `--rm`.

> **Comprehension check 1.1**
> 1. Explain, in terms of trust boundaries, why leaked *node* IAM credentials are dangerous even when your Pod's own ServiceAccount has minimal permissions.
> 2. Name the two Cloud-layer mitigations that stop this specific attack (hint: one is an IMDS setting, one is a network control at the node).
> 3. Is IMDS SSRF a Cloud-layer or Cluster-layer problem? Defend your answer — and explain why the *fix* can live in more than one layer.

### Step 1.2 — Inspect the node's trust into the cluster

1. Look at how the kubelet authenticates to the API server — this is the Cloud↔Cluster seam:

```bash
kubectl -n kube-system get cm kubeadm-config -o yaml | grep -iA2 anonymous || true
docker exec kcsa-4cs-control-plane cat /var/lib/kubelet/config.yaml | grep -iA3 authentication
```

Expected (abridged — anonymous auth disabled, webhook authz on):

```
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
authorization:
  mode: Webhook
```

> **Comprehension check 1.2**
> 1. What would `anonymous: enabled: true` on the kubelet allow an attacker who can reach port `10250` to do?
> 2. Which 4C layer owns the responsibility for restricting *who can reach the node's ports* in the first place?

---

## Exercise 2 — The **Cluster** layer

The Cluster layer covers everything Kubernetes itself controls: **authentication, authorization (RBAC), admission control, network policy, and secrets handling**. Here the trust boundary is the API server.

### Step 2.1 — RBAC least privilege with `kubectl auth can-i`

1. Create a namespace and a ServiceAccount to represent a workload identity:

```bash
kubectl create namespace app-prod
kubectl create serviceaccount reporter -n app-prod
```

2. Grant it a deliberately **narrow** Role (read-only Pods) and bind it:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: app-prod
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: reporter-pod-reader
  namespace: app-prod
subjects:
  - kind: ServiceAccount
    name: reporter
    namespace: app-prod
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF
```

3. Impersonate the ServiceAccount and test its effective permissions:

```bash
# Allowed: reading pods in its own namespace
kubectl auth can-i list pods \
  --as=system:serviceaccount:app-prod:reporter -n app-prod

# Denied: reading secrets, and anything cluster-wide
kubectl auth can-i get secrets \
  --as=system:serviceaccount:app-prod:reporter -n app-prod
kubectl auth can-i list pods \
  --as=system:serviceaccount:app-prod:reporter -n kube-system
```

Expected:

```
yes
no
no
```

4. Enumerate the full effective permission set (the exact command an auditor runs):

```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:app-prod:reporter -n app-prod
```

Expected (abridged — note it can only `get/list/watch pods`, plus the self-review verbs every identity has):

```
Resources                                       Non-Resource URLs   Resource Names   Verbs
pods                                            []                  []               [get list watch]
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
...
```

> **Comprehension check 2.1**
> 1. Why is `kubectl auth can-i --list --as=...` a more reliable audit than reading the `Role`/`RoleBinding` YAML by hand?
> 2. A teammate proposes binding `cluster-admin` "temporarily" to fix a broken deploy. In 4Cs terms, what boundary does that violate and what is the blast radius?
> 3. What is the difference between a `Role`+`RoleBinding` and a `ClusterRole`+`ClusterRoleBinding`, and which did we use to enforce namespace isolation?

### Step 2.2 — Default-deny network policy

1. Deploy a victim and a client in `app-prod`:

```bash
kubectl -n app-prod run web --image=nginx:1.27-alpine --port=80
kubectl -n app-prod expose pod web --port=80
kubectl -n app-prod run client --image=curlimages/curl:8.8.0 --restart=Never -- sleep 3600
kubectl -n app-prod wait --for=condition=Ready pod/web pod/client --timeout=60s
```

2. Confirm that, **by default, all Pod-to-Pod traffic is allowed** (Kubernetes is not zero-trust out of the box):

```bash
kubectl -n app-prod exec client -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 web
```

Expected:

```
200
```

3. Apply a **default-deny ingress** policy for the namespace:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: app-prod
spec:
  podSelector: {}          # selects every Pod in the namespace
  policyTypes:
    - Ingress              # no ingress rules => deny all inbound
EOF
```

4. Re-test. **Note:** `kind`'s default CNI (`kindnet`) does **not** enforce NetworkPolicy. If your cluster uses Calico/Cilium, the request now times out:

```bash
kubectl -n app-prod exec client -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 web
```

Expected on an enforcing CNI:

```
000        # curl: (28) timed out — connection blocked
```

Expected on plain `kind`/`kindnet`:

```
200        # policy accepted by the API server but NOT enforced by the CNI
```

> **Comprehension check 2.2**
> 1. The API server *accepted* the NetworkPolicy on `kindnet`, yet traffic still flowed. What does this teach you about the difference between a policy being **admitted** and being **enforced**?
> 2. Why is "default allow" the out-of-the-box behavior a security-conscious operator must actively override?
> 3. Our policy only set `policyTypes: [Ingress]`. Does it restrict *outbound* (egress) traffic from these Pods? What would you add to also block egress?

---

## Exercise 3 — The **Container** layer

The Container layer is about the images you run and the runtime restrictions you place on them: **provenance/scanning, running as non-root, dropping Linux capabilities, read-only root filesystem, and blocking privilege escalation**. Pod Security Standards (`restricted`) codify most of these.

### Step 3.1 — Scan an image for known vulnerabilities

1. Scan a deliberately old image with `trivy` (install per https://trivy.dev if needed):

```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed nginx:1.14.0
```

Expected (abridged — an old base image has many fixable CVEs):

```
nginx:1.14.0 (debian 9.4)
Total: 180 (HIGH: 150, CRITICAL: 30)

┌───────────────┬────────────────┬──────────┬───────────────────┬───────────────┐
│    Library    │ Vulnerability  │ Severity │ Installed Version  │ Fixed Version │
├───────────────┼────────────────┼──────────┼───────────────────┼───────────────┤
│ openssl       │ CVE-2021-3711  │ CRITICAL │ 1.1.0f-3+deb9u2   │ 1.1.0l-...    │
│ ...           │ ...            │ ...      │ ...               │ ...           │
└───────────────┴────────────────┴──────────┴───────────────────┴───────────────┘
```

> **Comprehension check 3.1**
> 1. Which 4C layer does image scanning belong to, and why is `--ignore-unfixed` a deliberate policy choice rather than laziness?
> 2. Scanning happens both in CI (Code layer) and at admission/runtime (Container/Cluster layer). Why run it in more than one place?

### Step 3.2 — Harden the runtime with `securityContext`

1. First observe an **unhardened** Pod running as root:

```bash
kubectl -n app-prod run rooted --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl -n app-prod exec rooted -- id
```

Expected:

```
uid=0(root) gid=0(root) groups=0(root),10(wheel)
```

2. Now deploy a **hardened** Pod applying the `restricted` Pod Security Standard controls:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: hardened
  namespace: app-prod
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
kubectl -n app-prod wait --for=condition=Ready pod/hardened --timeout=60s
```

3. Verify the restrictions actually took effect at runtime:

```bash
# Running as the non-root UID we specified
kubectl -n app-prod exec hardened -- id

# Root filesystem is read-only: this write MUST fail
kubectl -n app-prod exec hardened -- sh -c 'echo test > /evil 2>&1 || echo "WRITE BLOCKED"'

# All capabilities dropped: this MUST fail with EPERM
kubectl -n app-prod exec hardened -- sh -c 'chown 0:0 /tmp 2>&1 || echo "CAP BLOCKED"'
```

Expected:

```
uid=10001 gid=10001 groups=10001
/evil: Read-only file system
WRITE BLOCKED
chown: /tmp: Operation not permitted
CAP BLOCKED
```

4. Enforce these controls namespace-wide with **Pod Security Admission** so a non-compliant Pod is rejected at admission time:

```bash
kubectl label namespace app-prod \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted --overwrite

# The old rooted Pod would now be rejected; prove it:
kubectl -n app-prod run rooted2 --image=busybox:1.36 --restart=Never -- sleep 3600
```

Expected (admission denial):

```
Error from server (Forbidden): pods "rooted2" is forbidden: violates PodSecurity "restricted:latest":
allowPrivilegeEscalation != false (container "rooted2" must set securityContext.allowPrivilegeEscalation=false),
unrestricted capabilities (container "rooted2" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true, seccompProfile ...
```

> **Comprehension check 3.2**
> 1. `runAsNonRoot: true` and `runAsUser: 10001` overlap. What does each one *actually* do, and what happens if the image's default user is root but you set only `runAsNonRoot: true` without a `runAsUser`?
> 2. Why is `allowPrivilegeEscalation: false` necessary even after you drop `ALL` capabilities? (Hint: think about setuid binaries.)
> 3. Pod Security Admission (Step 4) is a Cluster-layer control that enforces Container-layer settings. Explain how this illustrates the 4Cs working *together* rather than in isolation.

---

## Exercise 4 — The **Code** layer

The Code layer is the innermost and the only one fully under the developer's control: **no hardcoded secrets, dependency management, TLS for all traffic, input validation, and static/dynamic analysis (SAST/DAST)**. A perfectly hardened outer three Cs cannot save you from a credential committed to git.

### Step 4.1 — Detect a hardcoded secret

1. Simulate application source with an embedded credential:

```bash
mkdir -p /tmp/code-layer && cd /tmp/code-layer
cat <<'EOF' > config.py
# BAD: secret hardcoded in source — a Code-layer failure
DB_PASSWORD = "S3cr3t-Pr0d-Pass!"
AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
EOF
```

2. Scan it with a secret detector (`gitleaks`, or fall back to `grep`):

```bash
gitleaks detect --source /tmp/code-layer --no-git -v 2>/dev/null \
  || grep -rnE 'PASSWORD|SECRET|API_?KEY' /tmp/code-layer
```

Expected (gitleaks abridged):

```
Finding:     AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
Secret:      wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
RuleID:      aws-access-token
File:        config.py
2 leaks found
```

3. Demonstrate the correct pattern — inject the secret at runtime from a Kubernetes Secret instead of baking it into the image:

```bash
kubectl -n app-prod create secret generic db-cred \
  --from-literal=password='S3cr3t-Pr0d-Pass!'

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: uses-secret
  namespace: app-prod
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo secret is $DB_PASSWORD; sleep 3600"]
      env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-cred
              key: password
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
EOF
```

> **Comprehension check 4.1**
> 1. Moving the password into a Kubernetes `Secret` fixed the Code layer, but Kubernetes Secrets are only **base64-encoded**, not encrypted, in etcd by default. Which layer must you harden to protect the secret *at rest*, and how?
> 2. Why is a secret committed to git dangerous even *after* you delete it in a later commit?
> 3. Rank the 4Cs by how much of the responsibility sits with the application developer versus the platform/provider.

### Step 4.2 — Reason about TLS and the code you ship

1. Confirm the API server serves over TLS and inspect its certificate (traffic encryption is a shared Code/Cluster responsibility):

```bash
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}'; echo
docker exec kcsa-4cs-control-plane \
  openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -subject -issuer -dates
```

Expected (abridged):

```
https://127.0.0.1:6443
subject=CN = kube-apiserver
issuer=CN = kubernetes
notBefore=... notAfter=...
```

> **Comprehension check 4.2**
> 1. The 4Cs guidance says "encrypt traffic between services." Which layer(s) implement that, and name one Kubernetes-native way to get mutual TLS between workloads without changing application code.
> 2. Give one Code-layer defense that no outer C can provide for you.

---

## Cleanup

```bash
kind delete cluster --name kcsa-4cs
rm -rf /tmp/code-layer kind-4cs.yaml
```

---

## Sources (official)

- Kubernetes docs — *Overview of Cloud Native Security / The 4C's of Cloud Native security*: https://kubernetes.io/docs/concepts/security/overview/
- CNCF TAG-Security — *Cloud Native Security Whitepaper v2*: https://github.com/cncf/tag-security/blob/main/community/resources/security-whitepaper/v2/cloud-native-security-whitepaper.md
- KCSA Curriculum: https://github.com/cncf/curriculum
- Kubernetes docs — *Pod Security Standards*: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes docs — *Pod Security Admission*: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes docs — *RBAC Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes docs — *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes docs — *Encrypting Confidential Data at Rest*: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes docs — *Configure a Security Context for a Pod or Container*: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/

---

## Answers

<details>
<summary>Click to reveal the answers to all comprehension checks</summary>

### Check 0
1. **Cloud → Cluster → Container → Code** (outermost to innermost).
2. It is a **Cloud (infrastructure) layer** control: it dictates the network exposure of the machine/endpoint hosting the control plane. Binding the API server to `127.0.0.1` limits *who can reach it on the network* — a property of the underlying host/network, not of Kubernetes authorization.
3. Because the layers are **concentric and nested**: an attacker must defeat the outer layer to reach the inner one, so each layer is an independent barrier. Multiple independent barriers of differing kinds (network, authz, runtime, source) = defense in depth. A failure in one layer is contained by the others rather than being fatal.

### Check 1.1
1. Node IAM credentials belong to the **node's role**, which is typically far broader than any single Pod's ServiceAccount (it can pull images, attach volumes, describe/modify cloud resources, sometimes assume other roles). Stealing them **bypasses your Pod-level least privilege entirely** by operating at the infrastructure layer, outside Kubernetes RBAC.
2. (a) **Require IMDSv2** (session-token/`PUT`-based, hop-limit = 1) so the address can't be reached through simple SSRF from a container; (b) **block egress to `169.254.169.254`** from Pods (a `NetworkPolicy`/host firewall/iptables rule on the node), so workloads can't reach the metadata endpoint at all. On EKS specifically, also set the instance metadata **hop limit to 1** and prefer **IRSA / Pod Identity** over node roles.
3. It is fundamentally a **Cloud-layer** exposure (the metadata service and node IAM live in the infrastructure). But because the *fix* can be a `NetworkPolicy` (Cluster layer) or IMDSv2/hop-limit (Cloud layer), it shows that a single risk is often mitigable at more than one C — you defend it wherever you can, and preferably at multiple layers.

### Check 1.2
1. Anonymous kubelet access on `10250` lets an unauthenticated attacker who can reach the port hit the kubelet API directly: `exec` into containers, read logs, list Pods, and run commands on the node — a full node/workload compromise that **bypasses the API server and RBAC**.
2. The **Cloud (infrastructure)** layer — node/host firewalling and network segmentation decide who can even reach port `10250`. (The kubelet's `anonymous: false` + webhook authz is the Cluster-layer complement.)

### Check 2.1
1. `kubectl auth can-i --list --as=...` evaluates the **effective, aggregated** permissions the way the API server's authorizer actually does — merging every `RoleBinding`/`ClusterRoleBinding`, aggregated ClusterRoles, and group memberships. Reading YAML by hand misses transitive grants, aggregation, and bindings you didn't know existed.
2. It violates the **Cluster-layer** least-privilege boundary. `cluster-admin` is cluster-wide `*/*/*`; the blast radius is the **entire cluster and every namespace** (read all Secrets, modify any workload, escalate to the nodes) — and "temporary" bindings are routinely forgotten.
3. A `Role`+`RoleBinding` is **namespace-scoped**; a `ClusterRole`+`ClusterRoleBinding` is **cluster-wide**. We used `Role`+`RoleBinding` so the ServiceAccount's rights are confined to `app-prod` — that namespace scoping is what enforces isolation.

### Check 2.2
1. **Admission ≠ enforcement.** The API server validated and stored the object (it's a syntactically valid resource), but the *data-plane component that must act on it* — the CNI — has to implement NetworkPolicy. `kindnet` doesn't, so nothing enforced it. A stored policy is worthless without an enforcing CNI (Calico, Cilium, etc.).
2. Kubernetes networking is **flat and default-allow**: every Pod can reach every other Pod across namespaces unless a policy says otherwise. A single compromised Pod can therefore pivot laterally to the whole cluster, so an operator must actively impose default-deny.
3. No — it only restricts **Ingress** (`policyTypes: [Ingress]`). To block outbound as well, add `Egress` to `policyTypes` (an empty egress rule set then denies all egress), typically followed by explicit allow rules for DNS and required destinations.

### Check 3.1
1. **Container layer** (image provenance/vulnerability management). `--ignore-unfixed` is a policy choice: it filters to vulnerabilities that have an available fix, so the report is **actionable** (things you can remediate by upgrading) rather than noise you cannot act on — you triage fixable HIGH/CRITICAL first.
2. **Shift-left + defense-in-depth.** CI scanning (Code layer) catches issues before build/merge; admission- or runtime-scanning (Cluster/Container layer) catches images that were built elsewhere, drifted, or gained newly disclosed CVEs after the build. New CVEs appear against images that never change, so a one-time CI scan is insufficient.

### Check 3.2
1. `runAsNonRoot: true` is an **assertion checked at container start** — it refuses to start the container if the effective user resolves to UID 0. `runAsUser: 10001` **sets** the UID. If the image defaults to root and you set only `runAsNonRoot: true` **without** a numeric `runAsUser`, the container **fails to start** (`CreateContainerError`: "container has runAsNonRoot and image will run as root") — because the kubelet can't prove a non-numeric/root user is non-root. Best practice: set both (or bake a non-root user into the image).
2. `allowPrivilegeEscalation: false` sets the `no_new_privs` process flag, which prevents a process from **gaining** privileges it didn't start with — most importantly via **setuid/setgid binaries** (e.g. `sudo`, `ping`). Even with no capabilities in the bounding set, a setuid-root binary could otherwise re-acquire privileges; `no_new_privs` closes that path.
3. Pod Security Admission is a **Cluster-layer** admission controller that *enforces* **Container-layer** `securityContext` requirements at the API boundary — a workload that doesn't harden itself is rejected before it ever runs. That's the 4Cs cooperating: an outer layer guarantees an inner layer's controls are present, so security doesn't depend on every developer remembering to set them.

### Check 4.1
1. The **Cloud/Cluster layer** — enable **encryption at rest for Secrets in etcd** (an `EncryptionConfiguration` with a KMS or `aescbc`/`secretbox` provider), and restrict etcd/node access. Base64 is encoding, not encryption; anyone with etcd or broad `get secrets` RBAC can read them otherwise.
2. Git history is immutable by default: the secret persists in **prior commits, reflogs, forks, clones, and CI caches** even after a "delete" commit. The only safe response is to **rotate/revoke the credential**, not just remove the line.
3. From most developer-owned to least: **Code** (fully the developer's) → **Container** (developer + platform: image contents vs. runtime policy) → **Cluster** (platform/operator) → **Cloud** (provider + platform). Responsibility shifts outward from developer to platform/provider.

### Check 4.2
1. **Cluster and Code layers.** A **service mesh (e.g. Istio, Linkerd)** provides **mutual TLS between workloads transparently** via sidecar/ambient proxies, encrypting service-to-service traffic without changing application code. (Application-level TLS is the Code-layer alternative when no mesh is present.)
2. Examples: **input validation / preventing injection**, correct **authorization logic** inside the app, safe handling of untrusted data, and secure use of dependencies. No network policy, runtime restriction, or infrastructure control can compensate for an application that mishandles its own inputs or logic.

</details>