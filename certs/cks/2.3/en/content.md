# Understand and implement isolation techniques (multi-tenancy, sandboxed containers, etc.)

## 1. Why isolation is a security control

A Kubernetes cluster is, by default, a **shared-everything** system:

- Every Pod can reach every other Pod on the network (flat L3 network, no filtering).
- Every Pod on a node **shares the host kernel** with every other Pod on that node.
- Every ServiceAccount can talk to the API server (even if it can barely read anything).
- Every Service in the cluster is resolvable through cluster DNS, from any namespace.

Isolation is the discipline of deliberately removing those defaults so that a compromise stays small. The mental model for the exam — and for real clusters — is **blast radius**:

> If an attacker gets arbitrary code execution inside one container, what else can they touch?

Isolation techniques answer that question at four different layers, and a serious design uses several of them together (defense in depth):

| Layer | Boundary | Primary tools |
|---|---|---|
| API / logical | Namespace | RBAC, ServiceAccounts, ResourceQuota, LimitRange, Pod Security Admission |
| Network | Pod-to-Pod traffic | NetworkPolicy, CNI-level policy (Cilium), mTLS / service mesh |
| Node | Which workload lands on which machine | taints/tolerations, nodeSelector/affinity, dedicated node pools, admission control |
| Kernel | Syscall surface of the container | seccomp, AppArmor, capabilities, user namespaces, **sandboxed runtimes (gVisor, Kata)** |

Nothing above is a substitute for the layer below it. A namespace does **not** stop a container escape; a seccomp profile does **not** stop a Pod from reading another namespace's Secret over the API.

---

## 2. Multi-tenancy: soft vs hard

A *tenant* is whatever unit you need to keep apart: a team, a customer, an environment, a CI job. The critical design question is how much you trust that tenant.

### 2.1 Soft multi-tenancy

Tenants are **mutually non-malicious but potentially careless** — typical for teams inside one company. The threat model is *accident*: a bad label selector, a runaway Deployment, a Secret read by the wrong team.

Soft multi-tenancy is implemented with namespaces plus policy:

- one namespace per tenant,
- RBAC scoped with `Role` / `RoleBinding` (never `ClusterRoleBinding`),
- `ResourceQuota` + `LimitRange` so one tenant can't starve the others,
- default-deny `NetworkPolicy` per namespace,
- Pod Security Admission at `restricted`.

### 2.2 Hard multi-tenancy

Tenants are **assumed hostile** — SaaS customers, untrusted user-submitted code, public CI runners. Namespaces are not sufficient, because a namespace is only an API-level scope. The threat model now includes container escape and kernel exploitation, so you must add:

- **sandboxed runtimes** (gVisor / Kata) or dedicated nodes per tenant,
- node-level separation so a successful escape lands the attacker on a node that only hosts that tenant's workloads,
- often a **separate control plane per tenant** (separate cluster, or a virtual cluster such as vcluster / Capsule).

The honest CKS answer: **true hard multi-tenancy on a single shared kernel is not achievable with namespaces alone.** The strongest single-cluster answer is *sandboxed runtime + dedicated nodes + strict network policy*.

### 2.3 What a namespace does NOT isolate

Memorize this list; it is the source of most exam distractors and most real-world mistakes:

- **Nodes and the kernel** — Pods from different namespaces share the same machine and the same kernel by default.
- **Network** — namespaces have zero effect on connectivity without NetworkPolicy.
- **DNS** — any Pod can resolve and query `svc.other-tenant.svc.cluster.local`.
- **Cluster-scoped objects** — Nodes, PersistentVolumes, StorageClasses, CRDs, ClusterRoles, IngressClasses, PriorityClasses, `RuntimeClass`, and (namespaced but cluster-wide-reaching) `NodePort` allocations.
- **CRDs** — a CRD is cluster-scoped; one tenant defining or deleting a CRD affects everyone.
- **The kubelet and node metadata** — a Pod with host access reaches the node regardless of its namespace.

---

## 3. Logical isolation with namespaces

### 3.1 Create the tenant namespace and lock down the API surface

```bash
kubectl create namespace tenant-a
kubectl label namespace tenant-a tenant=a
```

Every namespace automatically carries an immutable label with its own name — extremely useful for NetworkPolicy and PSA selectors:

```bash
kubectl get ns tenant-a --show-labels
```

```
NAME       STATUS   AGE   LABELS
tenant-a   Active   12s   kubernetes.io/metadata.name=tenant-a,tenant=a
```

Apply Pod Security Admission at the namespace level so the tenant cannot create host-privileged Pods:

```bash
kubectl label namespace tenant-a \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.34 \
  pod-security.kubernetes.io/warn=restricted
```

This single step blocks `hostPID`, `hostNetwork`, `hostPath`, `privileged: true`, and unconfined seccomp — i.e. the most common paths from "inside a container" to "on the node".

### 3.2 Scope RBAC to the namespace

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: tenant-a
  name: tenant-admin
rules:
- apiGroups: ["", "apps", "batch"]
  resources: ["pods", "deployments", "services", "configmaps", "jobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: tenant-a
  name: tenant-a-admins
subjects:
- kind: Group
  name: tenant-a-devs
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: tenant-admin
  apiGroup: rbac.authorization.k8s.io
```

Verify the boundary from the tenant's point of view:

```bash
kubectl auth can-i list secrets --namespace tenant-a --as-group tenant-a-devs --as dev1
kubectl auth can-i list pods    --namespace tenant-b --as-group tenant-a-devs --as dev1
kubectl auth can-i list nodes   --as-group tenant-a-devs --as dev1
```

```
no
no
no
```

Two extra hardening rules for tenant workloads:

```yaml
# Stop the default token from being mounted into every Pod
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: tenant-a
automountServiceAccountToken: false
```

Never grant a tenant `escalate`, `bind`, `impersonate`, `nodes/proxy`, `pods/exec` on other namespaces, or `create` on `pods` in `kube-system` — each of those turns a namespace-scoped identity into a cluster-scoped one.

### 3.3 Resource isolation: quotas and limits

Isolation includes availability. Without quotas, one tenant is a denial-of-service vector for the whole cluster.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-a-quota
  namespace: tenant-a
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.cpu: "16"
    limits.memory: 32Gi
    pods: "50"
    count/services.nodeports: "0"     # tenants must not expose NodePorts
    count/services.loadbalancers: "2"
    persistentvolumeclaims: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-a-defaults
  namespace: tenant-a
spec:
  limits:
  - type: Container
    default:            { cpu: 500m, memory: 512Mi }
    defaultRequest:     { cpu: 100m, memory: 128Mi }
    max:                { cpu: "4",  memory: 8Gi }
```

```bash
kubectl describe quota tenant-a-quota -n tenant-a
```

```
Name:                         tenant-a-quota
Namespace:                    tenant-a
Resource                      Used  Hard
--------                      ----  ----
count/services.nodeports      0     0
limits.cpu                    2     16
limits.memory                 2Gi   32Gi
pods                          4     50
requests.cpu                  400m  8
requests.memory               512Mi 16Gi
```

Note `count/services.nodeports: "0"` — a NodePort punches a hole in every node in the cluster, so it is a cross-tenant concern, not a tenant-local one.

---

## 4. Network isolation

Namespaces give you *names*, not *walls*. Start each tenant namespace with default deny for both directions, then open only what is needed.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-a
spec:
  podSelector: {}                 # every Pod in the namespace
  policyTypes: ["Ingress", "Egress"]
```

An empty `podSelector` with no `ingress`/`egress` rules denies everything. This immediately breaks DNS, so add it back explicitly:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: tenant-a
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - { protocol: UDP, port: 53 }
    - { protocol: TCP, port: 53 }
```

Allow traffic *within* the tenant, and only from an explicitly named peer namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-tenant-and-ingress-ns
  namespace: tenant-a
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector: {}                       # same namespace
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

Verify from another tenant — this is the check that proves isolation:

```bash
kubectl run probe -n tenant-b --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c 'wget -qO- --timeout=3 http://web.tenant-a.svc.cluster.local || echo BLOCKED'
```

```
wget: download timed out
BLOCKED
pod "probe" deleted
```

Two important subtleties:

- `namespaceSelector` + `podSelector` in the **same list item** (no `-` before `podSelector`) means "that Pod *in* that namespace" (AND). As **separate list items** it means OR. This distinction is a classic exam trap.
- NetworkPolicy is enforced by the CNI. On a CNI without policy support the objects are accepted and silently ignored. Confirm your CNI (Calico, Cilium, Antrea, …) actually enforces them.
- For confidentiality *on the wire* between tenants, NetworkPolicy is not enough — add Pod-to-Pod encryption (Cilium WireGuard/IPsec, or a mesh providing mTLS).

---

## 5. Node isolation

If two tenants share a node, a container escape in one is a compromise of the other. Node isolation makes the escape land somewhere harmless.

### 5.1 Dedicate nodes with taints + nodeSelector

```bash
kubectl label node worker-3 tenant=a
kubectl taint node worker-3 tenant=a:NoSchedule
```

```
node/worker-3 labeled
node/worker-3 tainted
```

The tenant's Pods then need both a toleration (to be *allowed* on the node) and a selector (to be *forced* onto it):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
  namespace: tenant-a
spec:
  nodeSelector:
    tenant: a
  tolerations:
  - key: tenant
    operator: Equal
    value: a
    effect: NoSchedule
  containers:
  - name: web
    image: nginx:1.27
```

**Taint ≠ security boundary by itself.** A toleration is self-service: any tenant that can create a Pod can write any toleration and land on any tainted node. To make node isolation enforceable you need admission control:

- **`PodNodeSelector`** admission plugin — forces a nodeSelector per namespace, and restricts which selectors are allowed:

  ```bash
  # kube-apiserver flag
  --enable-admission-plugins=NodeRestriction,PodNodeSelector,PodTolerationRestriction
  ```

  ```yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: tenant-a
    annotations:
      scheduler.alpha.kubernetes.io/node-selector: "tenant=a"
  ```

- **`PodTolerationRestriction`** admission plugin — sets default tolerations and a whitelist per namespace, so a tenant cannot invent a toleration for another tenant's nodes:

  ```yaml
  metadata:
    annotations:
      scheduler.alpha.kubernetes.io/defaultTolerations: '[{"key":"tenant","operator":"Equal","value":"a","effect":"NoSchedule"}]'
      scheduler.alpha.kubernetes.io/tolerationsWhitelist: '[{"key":"tenant","operator":"Equal","value":"a","effect":"NoSchedule"}]'
  ```

- Or a policy engine (Kyverno / OPA Gatekeeper / a ValidatingAdmissionPolicy) that mutates and validates `nodeSelector`/`tolerations` based on the request's namespace.

### 5.2 Keep the control plane off tenant nodes

Control-plane nodes carry `node-role.kubernetes.io/control-plane:NoSchedule`. Never remove that taint to "get more capacity" — it puts tenant workloads next to etcd and the API server certificates.

---

## 6. Kernel isolation: sandboxed containers

### 6.1 The problem

A normal container is a process on the host, constrained by namespaces, cgroups, capabilities, seccomp and LSMs — but it calls **the host kernel directly**, through roughly 300+ syscalls. Any exploitable kernel bug reachable from that surface is a path to full node compromise, and from the node to every Pod on it (including their service account tokens and mounted Secrets).

A **sandboxed container** shrinks or removes that direct kernel contact. Two production approaches:

| | **gVisor** (`runsc`) | **Kata Containers** |
|---|---|---|
| Technique | User-space kernel intercepts syscalls and re-implements them | Each Pod runs inside a lightweight VM (QEMU / Cloud Hypervisor / Firecracker) |
| Boundary | Syscall interception (`Sentry`) + tightly restricted host syscall set | Hardware virtualization (VT-x/AMD-V), separate guest kernel |
| Startup | Milliseconds–tens of ms | Slower (VM boot), ~100s of ms |
| Syscall compatibility | Partial — some syscalls unimplemented; unusual workloads may fail | High — real Linux kernel in the guest |
| I/O performance | Noticeable overhead on syscall-heavy / network-heavy work | Overhead on I/O, better CPU-bound parity |
| Nested virt needed | No | Yes, if nodes are themselves VMs |
| Typical use | Untrusted user code, functions, CI jobs | Stronger guarantee, workloads needing full kernel features |

Both are **CRI-level runtimes** selected per Pod. Neither is enabled by default.

### 6.2 Step 1 — install the runtime on the node and register it with containerd

gVisor ships `runsc` plus a containerd shim:

```bash
runsc --version
```

```
runsc version release-20250401.0
spec: 1.1.0
```

containerd (config version 2) — add a runtime handler:

```toml
# /etc/containerd/config.toml
version = 2

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
```

> On containerd 2.x with config `version = 3`, the CRI plugin key is `io.containerd.cri.v1.runtime` instead of `io.containerd.grpc.v1.cri`. Check `containerd config dump` on the node rather than guessing.

```bash
systemctl restart containerd
systemctl is-active containerd
```

```
active
```

The key name at the end of that TOML path (`runsc`, `kata`) is the **handler** name — that is exactly the string a RuntimeClass must reference.

### 6.3 Step 2 — create the RuntimeClass

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor          # what Pod authors write
handler: runsc          # must match the containerd runtime key
```

A more realistic version also pins the class to nodes that actually have the runtime installed, and accounts for the sandbox's own resource cost:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
scheduling:
  nodeSelector:
    sandbox.example.com/runtime: kata
  tolerations:
  - key: sandbox
    operator: Equal
    value: kata
    effect: NoSchedule
overhead:
  podFixed:
    cpu: 250m
    memory: 160Mi
```

```bash
kubectl get runtimeclass
```

```
NAME     HANDLER   AGE
gvisor   runsc     30s
kata     kata      12s
```

RuntimeClass is **cluster-scoped**: only cluster admins create it; tenants only reference it. Restrict who may reference which class with RBAC (`resourceNames`) or an admission policy if that matters.

### 6.4 Step 3 — run a Pod in the sandbox

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: untrusted
  namespace: tenant-a
spec:
  runtimeClassName: gvisor
  containers:
  - name: app
    image: nginx:1.27
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 10001
      capabilities:
        drop: ["ALL"]
      seccompProfile:
        type: RuntimeDefault
```

```bash
kubectl apply -f untrusted.yaml
kubectl get pod untrusted -n tenant-a -o jsonpath='{.spec.runtimeClassName}{"\n"}'
```

```
pod/untrusted created
gvisor
```

### 6.5 Step 4 — prove the sandbox is real

This verification step is worth practising; "I set `runtimeClassName`" is not proof.

**gVisor** announces itself in the guest `dmesg`:

```bash
kubectl exec -n tenant-a untrusted -- dmesg | head -5
```

```
[    0.000000] Starting gVisor...
[    0.284728] Checking naughty and nice process list...
[    0.508201] Rewriting operating system in Javascript...
[    0.762211] Creating cloned children...
[    0.913860] Ready!
```

If the Pod is **not** sandboxed you get the host's ring buffer or a permission error instead:

```bash
kubectl exec -n tenant-a normal-pod -- dmesg | head -3
```

```
dmesg: read kernel buffer failed: Operation not permitted
command terminated with exit code 1
```

**Kata**: the guest kernel differs from the node kernel.

```bash
kubectl exec -n tenant-a kata-pod -- uname -r     # guest kernel
ssh worker-3 uname -r                             # host kernel
```

```
6.1.62
5.15.0-119-generic
```

And on the node you can see the VMM process backing the Pod:

```bash
ssh worker-3 'ps -ef | grep -c "[q]emu"'
```

```
1
```

### 6.6 Sandbox limitations to expect

- Pods requiring `privileged`, `hostPID`, `hostNetwork`, most `hostPath` mounts, or direct device access generally **won't work** under gVisor — which is largely the point.
- Some syscalls / `/proc` and `/sys` entries are unimplemented or emulated; software that probes deep kernel interfaces (some debuggers, `perf`, certain databases, eBPF tooling) may fail.
- Kata needs virtualization available on the node; nested virtualization must be enabled if nodes are VMs.
- Node-level tooling that inspects containers via the host kernel (some runtime-security agents) sees less inside a sandbox.
- Sandboxes cost CPU/memory/latency — declare it via `overhead` so the scheduler accounts for it.

### 6.7 A lighter middle ground: user namespaces

Instead of a full sandbox, you can map container UIDs to unprivileged host UIDs, so root in the Pod is a nobody on the host:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: userns-demo
spec:
  hostUsers: false          # run the Pod in its own user namespace
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
```

```bash
kubectl exec userns-demo -- id -u        # inside the Pod
```

```
0
```

```bash
ssh worker-1 'ps -o uid,cmd -C sleep'    # on the host
```

```
  UID CMD
65538 sleep 3600
```

This mitigates a large class of "root in container → root on host" escapes at almost no performance cost. It is a beta feature (enabled by default from v1.30) and requires a supporting runtime/kernel (idmap mounts), so verify feature gates and node versions before relying on it.

---

## 7. Control-plane isolation for stronger tenancy

When tenants need their own CRDs, webhooks, or cluster-scoped objects, a shared control plane is the bottleneck. Options, from weakest to strongest:

1. **Namespaces + policy** — soft multi-tenancy (sections 3–4).
2. **Namespace hierarchy / tenant operators** — Hierarchical Namespace Controller, Capsule: policies and RBAC propagate to tenant subtrees; still one control plane and one kernel per node.
3. **Virtual clusters** (vcluster) — each tenant gets its own API server and etcd (as Pods), while workloads are synced down to the host cluster. Tenants can create CRDs and cluster-scoped objects safely; the *kernel* is still shared unless you add sandboxing.
4. **Separate clusters** — the strongest and simplest-to-reason-about boundary; the highest operational cost.

For the exam, know the trade-off statement: *namespaces isolate the API, virtual clusters isolate the control plane, sandboxes/VMs isolate the kernel, separate clusters isolate everything.*

---

## 8. Putting it together: a hard-multi-tenant namespace

A complete, layered isolation setup for one untrusted tenant:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-x
  labels:
    tenant: x
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
  annotations:
    scheduler.alpha.kubernetes.io/node-selector: "tenant=x"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota
  namespace: tenant-x
spec:
  hard:
    pods: "20"
    requests.cpu: "4"
    requests.memory: 8Gi
    count/services.nodeports: "0"
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-x
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workload
  namespace: tenant-x
spec:
  replicas: 2
  selector:
    matchLabels: { app: workload }
  template:
    metadata:
      labels: { app: workload }
    spec:
      runtimeClassName: gvisor            # kernel isolation
      automountServiceAccountToken: false # API isolation
      nodeSelector: { tenant: x }         # node isolation
      tolerations:
      - { key: tenant, operator: Equal, value: x, effect: NoSchedule }
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: app
        image: registry.example.com/app@sha256:6b6e...c41f
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: ["ALL"] }
```

Each line maps to one layer of section 1. Removing any one of them re-opens a specific attack path — that mapping is exactly what the exam tests.

---

## 9. Verification checklist

Run these against any cluster you claim is isolated:

```bash
# 1. Does the namespace enforce a Pod Security Standard?
kubectl get ns tenant-a -o jsonpath='{.metadata.labels}' | tr ',' '\n'

# 2. Is there a default-deny NetworkPolicy?
kubectl get netpol -n tenant-a

# 3. Can a tenant identity reach outside its namespace?
kubectl auth can-i --list --namespace tenant-b --as-group tenant-a-devs --as dev1

# 4. Which runtime is each Pod actually using?
kubectl get pods -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,RC:.spec.runtimeClassName'

# 5. Are tenants sharing nodes?
kubectl get pods -A -o wide --sort-by='.spec.nodeName' \
  | awk '{print $8, $1}' | sort -u

# 6. Any Pod with host access left?
kubectl get pods -A -o json | jq -r '.items[]
  | select(.spec.hostNetwork or .spec.hostPID or .spec.hostIPC
      or (.spec.containers[].securityContext.privileged // false))
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

---

## 10. Common pitfalls

- **Assuming namespaces are a security boundary.** They are an API scope. Without NetworkPolicy, PSA, quotas and node separation, they isolate names only.
- **Default-deny without allowing DNS.** Everything "works" but every name resolution fails; symptoms look like application bugs.
- **`namespaceSelector` with unlabeled namespaces.** Use the built-in `kubernetes.io/metadata.name` label instead of hand-maintained ones.
- **Trusting taints alone.** Tolerations are attacker-controlled unless admission control constrains them.
- **RuntimeClass without the runtime installed.** The Pod stays `ContainerCreating`; `kubectl describe pod` shows a CreateContainerError mentioning an unknown runtime handler — always check `Events` and the node's containerd config.
- **Handler name mismatch.** `handler:` must equal the containerd runtime key exactly (`runsc`, not `gvisor`).
- **Forgetting `overhead`.** Sandbox VMs consume real memory the scheduler otherwise doesn't see, leading to node pressure and evictions.
- **Sandbox as a replacement for the other layers.** gVisor does not stop a Pod from reading Secrets it is authorized to read, nor from scanning the Pod network.
- **Leaving `automountServiceAccountToken` on.** A sandbox is pointless if the escape target is simply the API server via a mounted token.

---

## Referencias

- CKS Curriculum v1.34 (CNCF): https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes — Multi-tenancy: https://kubernetes.io/docs/concepts/security/multi-tenancy/
- Kubernetes — Namespaces: https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — Enforcing Pod Security Standards with namespace labels: https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Kubernetes — Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes — Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-ranges/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Taints and Tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Kubernetes — Assigning Pods to Nodes: https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Kubernetes — Admission Controllers (`PodNodeSelector`, `PodTolerationRestriction`, `NodeRestriction`): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — RuntimeClass: https://kubernetes.io/docs/concepts/containers/runtime-class/
- Kubernetes — Pod Overhead: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-overhead/
- Kubernetes — User Namespaces: https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/
- Kubernetes — RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — Configure Service Accounts for Pods: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- gVisor — Kubernetes / containerd quick start: https://gvisor.dev/docs/user_guide/quick_start/kubernetes/
- gVisor — Architecture guide: https://gvisor.dev/docs/architecture_guide/
- Kata Containers — Documentation: https://katacontainers.io/docs/
- Kata Containers — Kubernetes integration: https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/run-kata-with-k8s.md
- containerd — CRI plugin configuration: https://github.com/containerd/containerd/blob/main/docs/cri/config.md
- Cilium — Transparent encryption (WireGuard/IPsec): https://docs.cilium.io/en/stable/security/network/encryption/
- vcluster — Virtual Kubernetes clusters: https://www.vcluster.com/docs/
- Kubernetes Hierarchical Namespace Controller: https://github.com/kubernetes-sigs/hierarchical-namespaces