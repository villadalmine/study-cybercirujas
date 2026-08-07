# 2.4 Kubernetes Security Essentials and Hardening

> **Certification:** CNPA (Cloud Native Platform Engineering Associate) — exam version 2025-04-01
> **Domain 2 topic weight:** 4.0
> **Profile:** Principal Platform Architect / Senior SRE
> **Prerequisite mental model:** you already understand Pods, Deployments, Services, RBAC subjects, and the control-plane component split (`kube-apiserver`, `etcd`, `kube-scheduler`, `kube-controller-manager`, `kubelet`).

---

## 1. Motivation: why a Kubernetes cluster is insecure by default

The single most important fact for a platform engineer to internalize is this: **an out-of-the-box Kubernetes cluster is optimized for developer velocity, not for containment.** Every default is permissive:

- A Pod with no `securityContext` runs as **UID 0 (root)** inside its container, sharing the host kernel.
- Every namespace, unless you add a `NetworkPolicy`, is a **flat L3 network** — any Pod can reach any other Pod, any Service, and the cloud metadata endpoint `169.254.169.254`.
- The `default` ServiceAccount is **auto-mounted** into every Pod, and its token is a valid credential against the API server.
- `Secret` objects are stored in `etcd` **base64-encoded, not encrypted** (base64 is an encoding, not a cipher).
- Before Pod Security Admission, nothing stopped a Pod from requesting `privileged: true`, `hostPID: true`, or mounting `/` from the node.

### 1.1 The architectural problem: the shared kernel and the blast radius

A container is not a VM. It is a set of Linux namespaces (`pid`, `net`, `mnt`, `uts`, `ipc`, `user`) plus cgroups and a set of capabilities — **all backed by a single, shared host kernel.** The security boundary of a container is therefore only as strong as the kernel's namespace isolation plus the syscall surface you allow it to reach.

This creates a specific production failure mode: **container escape → node compromise → cluster compromise → cloud account compromise.** The chain is real and each link is a defensive control you are responsible for:

```
                     ┌─────────────────────────────────────────────┐
                     │  CLOUD  (IAM, VPC, KMS, metadata service)    │
                     │  ┌───────────────────────────────────────┐  │
   escape the        │  │  CLUSTER (API server, etcd, RBAC)     │  │
   cloud IAM   ◄─────┼──┤  ┌─────────────────────────────────┐  │  │
   boundary          │  │  │  NODE (kernel, kubelet, runtime)│  │  │
                     │  │  │  ┌───────────────────────────┐  │  │  │
   escape the        │  │  │  │ CONTAINER (namespaces,    │  │  │  │
   container   ◄─────┼──┼──┼──┤ cgroups, caps, seccomp)   │  │  │  │
   boundary          │  │  │  │  ┌─────────────────────┐  │  │  │  │
                     │  │  │  │  │  CODE (your app)    │  │  │  │  │
                     │  │  │  │  └─────────────────────┘  │  │  │  │
                     │  │  │  └───────────────────────────┘  │  │  │
                     │  │  └─────────────────────────────────┘  │  │
                     │  └───────────────────────────────────────┘  │
                     └─────────────────────────────────────────────┘
```

This is the **4C model of Cloud Native Security** (Cloud → Cluster → Container → Code). Each outer layer is the trust anchor of the layer inside it; a control at an inner layer cannot compensate for a broken outer layer (a hardened container on a compromised node is still owned). Source: [Kubernetes — Overview of Cloud Native Security](https://kubernetes.io/docs/concepts/security/overview/).

### 1.2 Defense in depth: the controls map to the 4Cs

The reason Kubernetes security "essentials" is a broad topic is that no single control is sufficient — you compose them. The mental map every platform team needs:

| Layer | Threat you are containing | Primary controls |
|---|---|---|
| **Cloud** | Metadata-service credential theft, over-broad node IAM | IMDSv2, workload identity, private endpoints, network egress control |
| **Cluster** | Over-privileged identities, unauthenticated API access, secret exfiltration from etcd | RBAC least-privilege, encryption-at-rest with KMS, audit logging, API server hardening |
| **Container** | Container escape, privilege escalation, lateral movement | Pod Security Standards, `securityContext`, seccomp/AppArmor, NetworkPolicy, admission control |
| **Code** | Vulnerable dependencies, malicious images, secrets in images | Image scanning, signing/verification (Sigstore), SBOM, minimal base images |

The rest of this topic is a production-grade tour of the **Cluster** and **Container** controls, because those are what a platform engineer configures on the cluster itself and what the CNPA exam weights.

---

## 2. Authentication and authorization: RBAC done for production

### 2.1 The request pipeline

Every request to `kube-apiserver` passes through three gates, in order. If you do not understand this pipeline you will misdiagnose every 403 you ever see:

```
Request ──► [ Authentication ] ──► [ Authorization ] ──► [ Admission ] ──► etcd
             who are you?           are you allowed?       is it valid/mutated?
             (certs, tokens,        (RBAC, Node, Webhook)  (PSA, webhooks,
              OIDC, SA tokens)                               ResourceQuota…)
```

- **Authentication** establishes *identity* (a username + groups, or a ServiceAccount). Kubernetes has **no `User` object** — users are external (an x509 CN, an OIDC `sub`, a bearer token). ServiceAccounts *are* first-class objects.
- **Authorization** is almost always **RBAC** in production. RBAC is *additive and deny-by-default*: with zero bindings, a subject can do nothing. There is no "deny" rule — you never subtract, you only grant.
- **Admission** runs after authz and can mutate or reject (section 5).

Source: [Controlling Access to the Kubernetes API](https://kubernetes.io/docs/concepts/security/controlling-access/).

### 2.2 RBAC object model and the least-privilege discipline

Four objects, two axes (namespaced vs cluster-wide):

| Object | Scope | Grants permission… | Binds…|
|---|---|---|---|
| `Role` | Namespaced | within one namespace | via `RoleBinding` |
| `ClusterRole` | Cluster | cluster-wide, OR reusable in any ns | via `RoleBinding` (one ns) or `ClusterRoleBinding` (all ns) |
| `RoleBinding` | Namespaced | binds a Role **or** ClusterRole into one namespace | subjects |
| `ClusterRoleBinding` | Cluster | binds a ClusterRole cluster-wide | subjects |

**The single most common production RBAC mistake:** binding the built-in `cluster-admin` ClusterRole via a ClusterRoleBinding to a ServiceAccount "to make the CI pipeline work." That grants `*` on `*` in `*` — total cluster takeover if the SA token leaks.

Here is a **least-privilege, complete, production-grade** grant: a CI ServiceAccount that may only manage `Deployments` and read `Pods`/logs in the `web` namespace, and nothing else anywhere.

```yaml
# rbac-ci-deployer.yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-deployer
  namespace: web
automountServiceAccountToken: false   # tokens are minted explicitly, not auto-injected
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployment-manager
  namespace: web
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
    # note: NO "delete" — deletions go through a separate reviewed workflow
  - apiGroups: ["apps"]
    resources: ["deployments/scale"]     # subresource, granted independently
    verbs: ["update", "patch"]
  - apiGroups: [""]                        # core API group
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-deployer-binds-deployment-manager
  namespace: web
subjects:
  - kind: ServiceAccount
    name: ci-deployer
    namespace: web
roleRef:
  kind: Role
  name: deployment-manager
  apiGroup: rbac.authorization.k8s.io
```

Minting a short-lived, audience-scoped token for that SA (the modern, bound-token way — no long-lived Secret):

```console
$ kubectl create token ci-deployer -n web --duration=30m --audience=https://kubernetes.default.svc
eyJhbGciOiJSUzI1NiIsImtpZCI6 Imd4...<snip>...Q2Zw
```

Verifying the grant is exactly what you intended — **`kubectl auth can-i` is the RBAC diagnostic tool**, use it before shipping and in CI:

```console
$ kubectl auth can-i update deployments -n web \
    --as=system:serviceaccount:web:ci-deployer
yes

$ kubectl auth can-i delete deployments -n web \
    --as=system:serviceaccount:web:ci-deployer
no

$ kubectl auth can-i get secrets -n web \
    --as=system:serviceaccount:web:ci-deployer
no

$ kubectl auth can-i '*' '*' -A \
    --as=system:serviceaccount:web:ci-deployer
no
```

Auditing what a subject can do across the whole cluster (list every rule that resolves for it):

```console
$ kubectl auth can-i --list -n web \
    --as=system:serviceaccount:web:ci-deployer
Resources                                       Non-Resource URLs   Resource Names   Verbs
deployments.apps                                []                  []               [get list watch create update patch]
deployments.apps/scale                          []                  []               [update patch]
pods                                             []                  []               [get list watch]
pods/log                                         []                  []               [get list watch]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
```

### 2.3 RBAC trade-offs

| Approach | Pros | Cons | When to use |
|---|---|---|---|
| Built-in `cluster-admin` binding | Zero friction | Total blast radius; token leak = cluster loss | **Never** for workloads; humans only, break-glass |
| Built-in aggregated roles (`admin`, `edit`, `view`) | Curated, maintained by upstream | `edit`/`admin` can read Secrets and create workloads that escalate | Namespace-scoped human roles |
| Hand-written least-privilege `Role` | Exact blast radius | Verbose, drifts, needs review | Workloads, CI/CD identities |
| `ClusterRole` + per-ns `RoleBinding` | Define once, reuse per team | Wrong binding scope leaks cluster-wide | Multi-tenant platform teams |

**Escalation footgun to know for the exam:** the built-in `edit` and `admin` ClusterRoles can `create` Pods, and a Pod can mount any ServiceAccount in its namespace. If a more privileged SA exists in that namespace, an `edit` user can launch a Pod as that SA and escalate. Least privilege must therefore consider *what identities live in the namespace*, not just the verbs granted.

Source: [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/).

---

## 3. Pod Security: SecurityContext and Pod Security Standards

### 3.1 The removal of PodSecurityPolicy and what replaced it

**PodSecurityPolicy (PSP) was deprecated in v1.21 and removed in v1.25.** If you read older material telling you to write PSP objects, it is dead code — `kubectl apply` of a PSP on a modern cluster silently does nothing (the API type no longer exists). Its replacement is a two-part system:

1. **Pod Security Standards (PSS)** — three named, versioned *policies*: `privileged`, `baseline`, `restricted`. These are specifications, not objects.
2. **Pod Security Admission (PSA)** — a built-in admission controller (GA since v1.25, enabled by default) that *enforces* a PSS level per namespace via labels.

| PSS level | Intent | Key allowances / restrictions |
|---|---|---|
| `privileged` | Unrestricted | Anything, including `privileged: true`, hostPath, host namespaces. Reserve for system/infra workloads. |
| `baseline` | Prevent known privilege escalations | Blocks `privileged`, host namespaces, most `hostPath`, adding dangerous capabilities. Allows running as root. |
| `restricted` | Hardened best practice | Requires `runAsNonRoot`, `allowPrivilegeEscalation: false`, seccomp `RuntimeDefault`, drop **ALL** capabilities, no `hostPath`. |

Source: [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/).

### 3.2 Pod Security Admission — the three modes

PSA applies a level in up to three modes simultaneously, so you can roll out safely:

| Mode | Effect on a violating Pod | Use in rollout |
|---|---|---|
| `enforce` | **Rejected** at admission | Final state |
| `audit` | Allowed, but records an annotation in the audit log | Observe impact before enforcing |
| `warn` | Allowed, but returns a `Warning:` to the client (e.g. `kubectl`) | Give developers immediate feedback |

You configure it with **namespace labels**. The production pattern is: enforce `baseline`, but `warn` and `audit` at `restricted`, so teams see what they'd need to change before you tighten enforcement:

```yaml
# namespace-hardened.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: web
  labels:
    # Enforce the baseline: hard-reject privileged/host-namespace pods now.
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.31
    # Surface restricted violations without blocking, to plan the next step.
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.31
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.31
```

Pinning `*-version` is not optional in production: it freezes the *definition* of the level so a cluster upgrade cannot silently tighten (or loosen) what "restricted" means and break admission for existing workloads.

Watch PSA reject a bad Pod at apply time:

```console
$ kubectl label ns web pod-security.kubernetes.io/enforce=restricted --overwrite
namespace/web labeled

$ cat <<'EOF' | kubectl apply -n web -f -
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
spec:
  containers:
    - name: app
      image: nginx:1.27
EOF
Error from server (Forbidden): error when creating "STDIN": pods "bad-pod" is forbidden:
violates PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false
(container "app" must set securityContext.allowPrivilegeEscalation=false),
unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true),
seccompProfile (pod or container "app" must set securityContext.seccompProfile.type
to "RuntimeDefault" or "Localhost")
```

That error message is a *specification*: it lists precisely what a `restricted` Pod must set.

### 3.3 A fully-hardened, `restricted`-compliant workload

This is the reference manifest. Every field below is load-bearing; the comments explain the mechanism it engages in the kernel/runtime.

```yaml
# deploy-hardened.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: web
spec:
  replicas: 3
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      # Do NOT auto-mount the SA token unless the app calls the API server.
      automountServiceAccountToken: false
      # Pod-level context: applies to all containers unless overridden.
      securityContext:
        runAsNonRoot: true          # kubelet refuses to start a container whose image runs as UID 0
        runAsUser: 10001            # explicit non-root UID
        runAsGroup: 10001
        fsGroup: 10001              # group that owns mounted volumes (for writable emptyDir)
        seccompProfile:
          type: RuntimeDefault      # apply the container runtime's default seccomp filter (blocks ~44 dangerous syscalls)
      containers:
        - name: app
          image: nginx:1.27.2       # pin by tag+digest in prod: nginx@sha256:...
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false   # sets no_new_privs bit; blocks setuid binaries from gaining privs
            readOnlyRootFilesystem: true      # container root FS is immutable; tampering/webshell drops fail
            capabilities:
              drop: ["ALL"]                   # drop every Linux capability, then add back only what is needed
              # add: ["NET_BIND_SERVICE"]     # ONLY if you must bind a port <1024
          resources:                          # limits are a security control: they bound a noisy-neighbor / DoS blast radius
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/nginx
            - name: run
              mountPath: /var/run
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /ready, port: 8080 }
            periodSeconds: 5
      # readOnlyRootFilesystem forces you to declare every writable path explicitly.
      volumes:
        - name: tmp
          emptyDir: {}
        - name: cache
          emptyDir: {}
        - name: run
          emptyDir: {}
```

### 3.4 `securityContext` field reference and trade-offs

| Field | Mechanism | If you skip it |
|---|---|---|
| `runAsNonRoot: true` | kubelet checks the image's effective UID at start | Container may run as root; escape = root on node |
| `allowPrivilegeEscalation: false` | Sets `PR_SET_NO_NEW_PRIVS` | setuid binaries can regain privileges |
| `readOnlyRootFilesystem: true` | Mounts `/` read-only | Attacker can write webshells, tamper binaries |
| `capabilities.drop: ["ALL"]` | Clears the bounding capability set | Retains ~14 default caps incl. `CHOWN`, `SETUID`, `NET_RAW` |
| `seccompProfile.type: RuntimeDefault` | Applies runtime's seccomp BPF filter | Full ~300+ syscall surface exposed to the container |
| `privileged: true` | Grants all caps + device access | **Full node compromise on escape — never in app workloads** |

**Trade-off you must be able to articulate:** `readOnlyRootFilesystem: true` is the single highest-value/lowest-effort hardening for stateless services, but it breaks any app that writes to `/`, `/tmp`, or a framework cache. The fix is not to disable it — it is to mount `emptyDir` volumes at exactly the paths the app writes to (as shown above). This is a *diagnosis-and-declare* exercise, not a reason to weaken the control.

Sources: [Configure a Security Context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/), [Seccomp tutorial](https://kubernetes.io/docs/tutorials/security/seccomp/).

---

## 4. Network policy: from a flat network to default-deny segmentation

### 4.1 The problem

Without NetworkPolicy, cluster networking is **allow-all**. A compromised frontend Pod can open a TCP connection to your database, to the Kubernetes API, and to `169.254.169.254` (cloud metadata → IAM credentials). Microsegmentation is how you stop **lateral movement** — the step between "one Pod is popped" and "the cluster is popped."

Critical caveat: **NetworkPolicy is enforced by the CNI plugin, not by Kubernetes itself.** Calico, Cilium, and Antrea enforce it; the default `kubenet` and some managed CNIs *do not*. Applying a NetworkPolicy on a non-enforcing CNI creates the object and returns no error — and enforces nothing. This is a classic silent-failure blind spot; verify your CNI supports it.

### 4.2 The foundational pattern: default-deny, then allow explicitly

NetworkPolicies are *additive*: a Pod selected by any policy becomes default-deny for the covered direction, and every allowed flow must be granted by some policy. Start every namespace with a deny-all baseline:

```yaml
# netpol-default-deny.yaml — deny all ingress AND egress in the namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: web
spec:
  podSelector: {}              # empty selector = every Pod in the namespace
  policyTypes:
    - Ingress
    - Egress
  # no ingress/egress rules => nothing is allowed
```

Then punch precise holes. This allows the `web` tier to receive traffic only from an ingress controller, talk only to the `api` tier, and resolve DNS — nothing else, including no metadata-service access:

```yaml
# netpol-web-allow.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow
  namespace: web
spec:
  podSelector:
    matchLabels: { app: web }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
          podSelector:
            matchLabels: { app.kubernetes.io/name: ingress-nginx }
      ports:
        - port: 8080
          protocol: TCP
  egress:
    # 1) Allow DNS to kube-dns (UDP+TCP 53) — forgetting this breaks name resolution.
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
          podSelector:
            matchLabels: { k8s-app: kube-dns }
      ports:
        - { port: 53, protocol: UDP }
        - { port: 53, protocol: TCP }
    # 2) Allow egress to the api tier only.
    - to:
        - podSelector:
            matchLabels: { app: api }
      ports:
        - { port: 8443, protocol: TCP }
```

### 4.3 The DNS footgun (the #1 NetworkPolicy support ticket)

The moment you apply `default-deny-all` with `Egress`, **DNS resolution stops** because port 53 to `kube-dns` is now denied. Every "my app can't reach anything after I added a NetworkPolicy" incident is this. The symptom and diagnosis:

```console
$ kubectl exec -n web deploy/web -- curl -sS --max-time 3 http://api:8443/health
curl: (6) Could not resolve host: api

$ kubectl exec -n web deploy/web -- nslookup api
;; connection timed out; no servers could be reached
command terminated with exit code 1
```

The fix is the explicit DNS egress rule shown in `netpol-web-allow.yaml`. **Always ship the DNS allow rule in the same commit as the default-deny.**

### 4.4 Trade-offs and what NetworkPolicy cannot do

| Capability | NetworkPolicy (v1) | Needs a CNI extension (Cilium/Calico) |
|---|---|---|
| L3/L4 Pod-to-Pod segmentation | ✅ | — |
| Namespace/label selectors | ✅ | — |
| Egress to external CIDRs | ✅ via `ipBlock` | — |
| **L7 (HTTP path/method, gRPC) rules** | ❌ | ✅ (CiliumNetworkPolicy, etc.) |
| **FQDN-based egress** (`api.stripe.com`) | ❌ (IPs churn) | ✅ |
| **Deny/priority ordering** | ❌ (additive-only) | ✅ (Calico `GlobalNetworkPolicy` tiers) |
| Cluster-wide default policy | ❌ (per-namespace) | ✅ |

Source: [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/).

---

## 5. Admission control: enforcing policy the API-native way

### 5.1 Why admission control is the real control plane for security policy

RBAC answers "*who* can touch *what resource verb*." It cannot answer "*is the content of this object safe*" — RBAC has no idea whether a Pod is `privileged`. Admission controllers run **after** authz and can inspect and **mutate or reject** the full object. This is where you enforce organization-wide rules like "no `:latest` tags," "every workload has resource limits," "images must come from our registry," and "every Deployment has an owner label."

There are two dynamic-admission webhook types:

| Type | Runs | Can | Order |
|---|---|---|---|
| `MutatingAdmissionWebhook` | first | patch the object (inject sidecars, defaults, labels) | before validation |
| `ValidatingAdmissionWebhook` | second | accept/reject only (no mutation) | after all mutation |

### 5.2 The policy-engine landscape: Gatekeeper vs Kyverno vs ValidatingAdmissionPolicy

| Engine | Policy language | Mutation | In-tree | Best for |
|---|---|---|---|---|
| **OPA Gatekeeper** | Rego (via ConstraintTemplates) | limited (assign mutators) | No (CNCF project) | Orgs already invested in OPA/Rego; complex logic |
| **Kyverno** | YAML (Kubernetes-native) | ✅ strong | No (CNCF project) | Kubernetes-native teams; readable policies, generate/mutate |
| **ValidatingAdmissionPolicy (VAP)** | CEL | ❌ (validate only; MutatingAdmissionPolicy is newer) | **Yes, built-in (GA v1.30)** | No extra controller, no webhook latency, simple in-cluster rules |

**The architectural trade-off:** external webhooks (Gatekeeper/Kyverno) are powerful but insert a **network hop into the critical path of every API write** — if the webhook Pod is down and its `failurePolicy: Fail`, you can wedge the whole cluster (you cannot create Pods, including the webhook's own replacement). In-tree `ValidatingAdmissionPolicy` (CEL, evaluated inside the API server) removes that failure mode for the rules it can express. Modern platforms use VAP for simple invariants and a webhook engine only for logic CEL can't express.

### 5.3 A built-in ValidatingAdmissionPolicy (no external controller)

Reject any Deployment whose Pod template requests `privileged` — enforced inside the API server, zero extra components:

```yaml
# vap-deny-privileged.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: deny-privileged-containers
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  validations:
    - expression: >-
        object.spec.template.spec.containers.all(c,
          !has(c.securityContext) ||
          !has(c.securityContext.privileged) ||
          c.securityContext.privileged == false)
      message: "privileged containers are not allowed by platform policy"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: deny-privileged-containers-binding
spec:
  policyName: deny-privileged-containers
  validationActions: [Deny]     # could also be Warn, Audit
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system"]   # exempt the control plane's own namespace
```

The equivalent guardrail expressed as a **Kyverno** policy (more readable, and Kyverno can also *mutate* to add defaults):

```yaml
# kyverno-require-nonroot.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-nonroot
spec:
  validationFailureAction: Enforce   # Enforce = reject; Audit = report only
  background: true                    # also scan existing resources
  rules:
    - name: check-runasnonroot
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Every container must set runAsNonRoot=true."
        pattern:
          spec:
            =(securityContext):
              =(runAsNonRoot): "true"
            containers:
              - =(securityContext):
                  =(runAsNonRoot): "true"
```

Sources: [Admission Controllers Reference](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/), [Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/), [Kyverno docs](https://kyverno.io/docs/).

---

## 6. Secrets: encryption at rest and getting them out of etcd cleartext

### 6.1 The default is not encryption

By default a `Secret` is stored in `etcd` as **base64** — a reversible encoding. Anyone with read access to etcd (an etcd backup file, a node with etcd on it, a `get secrets` RBAC grant) reads it in cleartext:

```console
$ kubectl create secret generic db-cred -n web \
    --from-literal=password='S3cr3t-pw'
secret/db-cred created

# On a control-plane node, read the raw etcd value — base64 is trivially decoded:
$ ETCDCTL_API=3 etcdctl --endpoints=127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/web/db-cred | hexdump -C | head
00000000  2f 72 65 67 69 73 74 72  65 74 73 2f 77 65 62 2f  |/registry/secrets/web/|
...
000000a0  53 33 63 72 33 74 2d 70  77 0a                    |S3cr3t-pw.|      # <-- cleartext!
```

### 6.2 Encryption at rest with a KMS provider

The fix is an `EncryptionConfiguration` passed to the API server via `--encryption-provider-config`. Production uses the **KMS v2 provider**, which envelope-encrypts with a key held in an external HSM/KMS (AWS KMS, GCP KMS, Vault) so the DEK never lives in cleartext on disk and key rotation doesn't require re-encrypting everything:

```yaml
# /etc/kubernetes/enc/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps                    # optionally protect ConfigMaps too
    providers:
      # First provider is used to WRITE (encrypt). Order matters.
      - kms:
          apiVersion: v2
          name: cloud-kms
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      # identity must be LAST so previously-unencrypted data can still be READ
      # during the migration window. Remove it once migration completes.
      - identity: {}
```

Reference to the API server (kubeadm-managed static Pod manifest):

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml (excerpt)
spec:
  containers:
    - command:
        - kube-apiserver
        - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
        - --encryption-provider-config-automatic-reload=true
```

**Enabling encryption does not encrypt existing Secrets** — encryption applies on write. You must force-rewrite every Secret to encrypt the backlog:

```console
$ kubectl get secrets --all-namespaces -o json | kubectl replace -f -
secret/db-cred replaced
secret/default-token-... replaced
...
```

Verify a Secret is now encrypted at rest — the etcd value must be prefixed with the provider name and be unreadable:

```console
$ ETCDCTL_API=3 etcdctl get /registry/secrets/web/db-cred \
    --endpoints=127.0.0.1:2379 --cacert=... --cert=... --key=... \
    | hexdump -C | head -2
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 77 65 62 2f 64 62  2d 63 72 65 64 0a 6b 38  |s/web/db-cred.k8|
00000020  73 3a 65 6e 63 3a 6b 6d  73 3a 76 32 3a 63 6c 6f  |s:enc:kms:v2:clo|  # k8s:enc:kms:v2 prefix
# The password string no longer appears anywhere in the blob.
```

### 6.3 Secret-handling trade-offs

| Approach | Secret at rest | Rotation | Blast radius | Notes |
|---|---|---|---|---|
| Default (base64) | Cleartext in etcd | Manual | Whole cluster on etcd read | **Not acceptable in prod** |
| `aescbc`/`aesgcm` local key | Encrypted, key on disk | Manual, edit config | Node with the key file | Better than nothing; key is local |
| **KMS v2 provider** | Envelope-encrypted, key in HSM/KMS | KMS-side, no re-encrypt | Requires KMS access | **Production standard** |
| External Secrets Operator + Vault/cloud SM | Not in etcd at all (synced or injected) | Central, automatic | Depends on operator RBAC | Best for large orgs; secrets sourced externally |

Additional hardening regardless of backend: set `automountServiceAccountToken: false` (SA tokens *are* secrets), and never bake secrets into images or `env` values checked into Git.

Source: [Encrypting Confidential Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/).

---

## 7. Node, runtime, and control-plane hardening

### 7.1 CIS Benchmark and kube-bench

The industry baseline is the **CIS Kubernetes Benchmark**. You don't grade against it by hand — you run **`kube-bench`**, which maps each check to a benchmark ID and gives a PASS/FAIL/WARN with the exact remediation. Run it as a Job on each node role:

```console
$ kubectl run kube-bench --rm -it --restart=Never \
    --image=aquasec/kube-bench:latest -- run --targets master
[INFO] 1 Control Plane Security Configuration
[INFO] 1.2 API Server
[PASS] 1.2.1 Ensure that the --anonymous-auth argument is set to false
[FAIL] 1.2.5 Ensure that the --kubelet-certificate-authority argument is set as appropriate
[WARN] 1.2.10 Ensure that the admission control plugin EventRateLimit is set
[PASS] 1.2.20 Ensure that the --profiling argument is set to false
...
== Remediations master ==
1.2.5 Follow the Kubernetes documentation and setup the TLS connection between
      the apiserver and kubelets. Then, edit the API server pod specification file
      /etc/kubernetes/manifests/kube-apiserver.yaml and set:
      --kubelet-certificate-authority=<ca-string>

== Summary ==
42 checks PASS
6 checks FAIL
9 checks WARN
```

### 7.2 The high-value control-plane flags

| Flag | Set to | Why |
|---|---|---|
| `--anonymous-auth` (apiserver, kubelet) | `false` | Anonymous requests are unauthenticated; a source of unauth API access |
| `--authorization-mode` (apiserver) | `Node,RBAC` | Never `AlwaysAllow`; `Node` authorizer scopes kubelet access |
| `--profiling` | `false` | pprof endpoints leak internals / are a DoS vector |
| kubelet `--read-only-port` | `0` | The read-only port 10255 exposes Pod data unauthenticated |
| kubelet `authorization.mode` | `Webhook` | Otherwise the kubelet API authorizes everything |
| apiserver `--audit-log-path` | set + policy | No audit log = no forensics after an incident |

### 7.3 Runtime security with Falco

Everything above is *preventive*. **Falco** is *detective*: it taps kernel syscalls (via eBPF) and alerts on anomalous runtime behavior that policy didn't stop — a shell spawned in a container, a write to `/etc`, an outbound connection to a new IP, a read of `/etc/shadow`. A representative alert:

```console
$ kubectl logs -n falco -l app.kubernetes.io/name=falco | grep Warning
17:42:11.902 Warning A shell was spawned in a container with an attached terminal
  (user=root user_uid=0 container_id=9f3c1a2b container_name=web
   image=nginx:1.27.2 shell=bash parent=runc
   cmdline=bash terminal=34816 k8s.ns=web k8s.pod=web-7d9c-abcde)
```

Falco closes the loop on the honest gap in prevention: an attacker who found a path *through* your admission and RBAC controls still trips a runtime rule.

Sources: [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes), [kube-bench](https://github.com/aquasecurity/kube-bench), [Falco docs](https://falco.org/docs/).

---

## 8. Supply chain: image provenance and admission-time verification

The **Code** layer of the 4Cs: an attacker who cannot escape a container may instead poison the image before it ever runs. Two controls belong on the platform:

1. **Sign images** with Sigstore `cosign` (keyless signing binds the signature to an OIDC identity via the public Rekor transparency log).
2. **Verify at admission** — a policy engine (Kyverno / Sigstore policy-controller / Gatekeeper) rejects any image lacking a valid signature from a trusted identity.

```console
$ cosign sign --yes registry.example.com/web@sha256:1a2b3c...
Generating ephemeral keys...
Retrieving signed certificate from Fulcio...
tlog entry created with index: 8871234
Pushing signature to: registry.example.com/web

$ cosign verify \
    --certificate-identity=ci@example.com \
    --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
    registry.example.com/web@sha256:1a2b3c...
Verification for registry.example.com/web@sha256:1a2b3c... --
The following checks were performed on the signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The signatures were verified against the specified public key
```

The admission-time gate as a Kyverno policy (reject unsigned images cluster-wide):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
      verifyImages:
        - imageReferences:
            - "registry.example.com/*"
          attestors:
            - entries:
                - keyless:
                    subject: "ci@example.com"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

Also pin images by **digest, not tag** (`nginx@sha256:...` not `nginx:1.27`) so admission verifies the exact bytes and a mutable tag can't be swapped under you.

Source: [Sigstore / cosign](https://docs.sigstore.dev/), [Kyverno image verification](https://kyverno.io/docs/writing-policies/verify-images/).

---

## 9. Verification and failure-diagnosis playbook

Security controls fail *closed* (they block things), so the platform engineer's job is distinguishing "correctly blocked a bad thing" from "wrongly blocked a good thing." Master this table.

| Symptom | Likely cause | Diagnostic command | Fix |
|---|---|---|---|
| `403 Forbidden` on API call | Missing RBAC rule | `kubectl auth can-i <verb> <res> -n <ns> --as=<subject>` | Add the specific verb/resource to the Role |
| `pods ... is forbidden: violates PodSecurity "restricted"` | Pod not compliant with namespace PSA level | read the error — it lists each missing field | Add the `securityContext` fields it names |
| App can't resolve DNS after adding NetworkPolicy | default-deny egress blocks port 53 | `kubectl exec <pod> -- nslookup kubernetes.default` | Add egress allow to `kube-dns` :53 UDP+TCP |
| App can't reach another service | no NetworkPolicy allow rule for that flow | `kubectl exec <pod> -- nc -zv <svc> <port>` | Add matching egress + ingress rules |
| Container `CrashLoopBackOff` after hardening | `readOnlyRootFilesystem` blocks a write | `kubectl logs <pod>` → `read-only file system` | Mount an `emptyDir` at that path |
| Container won't start: `container has runAsNonRoot and image will run as root` | image's `USER` is root, `runAsNonRoot: true` set | `docker inspect <img> --format '{{.Config.User}}'` | Set `runAsUser: <nonzero>` or rebuild image with `USER` |
| NetworkPolicy has no effect at all | CNI doesn't enforce NetworkPolicy | check CNI: `kubectl get pods -n kube-system` | Use Calico/Cilium/Antrea |
| Webhook makes all creates fail cluster-wide | webhook Pod down + `failurePolicy: Fail` | `kubectl get validatingwebhookconfigurations` | Scope `namespaceSelector`, add control-plane exemptions, consider `Ignore` for non-critical |

### 9.1 A repeatable pre-flight verification script pattern

Before declaring a namespace "hardened," prove each control positively and negatively:

```console
# 1. PSA is enforcing what you think:
$ kubectl get ns web -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep pod-security
"pod-security.kubernetes.io/enforce":"restricted"
"pod-security.kubernetes.io/enforce-version":"v1.31"

# 2. A privileged pod is rejected (negative test):
$ kubectl apply -n web -f bad-privileged-pod.yaml
Error from server (Forbidden): ... violates PodSecurity "restricted:v1.31" ...   # GOOD

# 3. The hardened workload is admitted and Running (positive test):
$ kubectl rollout status -n web deploy/web
deployment "web" successfully rolled out

# 4. Default-deny is in place and DNS still works:
$ kubectl get netpol -n web
NAME               POD-SELECTOR   AGE
default-deny-all   <none>         10m
web-allow          app=web        10m
$ kubectl exec -n web deploy/web -- nslookup api.web.svc.cluster.local
Name:   api.web.svc.cluster.local
Address: 10.96.4.7                                                              # GOOD

# 5. Egress to the metadata service is denied (negative test):
$ kubectl exec -n web deploy/web -- curl -sS --max-time 3 http://169.254.169.254/
curl: (28) Connection timed out after 3001 ms                                  # GOOD — blocked

# 6. Secrets are encrypted at rest (spot-check one on a control-plane node):
$ sudo ETCDCTL_API=3 etcdctl get /registry/secrets/web/db-cred ... | grep -a 'k8s:enc:kms:v2'
k8s:enc:kms:v2:cloud-kms:...                                                    # GOOD

# 7. No workload is running as root anywhere:
$ kubectl get pods -A -o jsonpath=\
'{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" runAsNonRoot="}{.spec.securityContext.runAsNonRoot}{"\n"}{end}' \
  | grep -v 'runAsNonRoot=true'
# (empty output = every pod sets runAsNonRoot: true)
```

The discipline: **every control gets a positive test (the good thing still works) and a negative test (the bad thing is blocked).** A control you only tested positively might be inert (e.g. a NetworkPolicy on a non-enforcing CNI returns no error and blocks nothing).

---

## 10. References

- Kubernetes — Overview of Cloud Native Security (the 4C model): https://kubernetes.io/docs/concepts/security/overview/
- Kubernetes — Controlling Access to the Kubernetes API: https://kubernetes.io/docs/concepts/security/controlling-access/
- Kubernetes — Using RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes — Enforce Pod Security Standards with Namespace Labels: https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Kubernetes — Configure a Security Context for a Pod or Container: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes — Restrict a Container's Syscalls with seccomp: https://kubernetes.io/docs/tutorials/security/seccomp/
- Kubernetes — Restrict a Container's Access to Resources with AppArmor: https://kubernetes.io/docs/tutorials/security/apparmor/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Admission Controllers Reference: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — Dynamic Admission Control (webhooks): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — Validating Admission Policy (CEL): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — Encrypting Confidential Data at Rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes — Managing Service Accounts / Bound tokens: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubernetes — Securing a Cluster: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- kube-bench (Aqua Security): https://github.com/aquasecurity/kube-bench
- NSA/CISA Kubernetes Hardening Guidance v1.2: https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- Falco — Runtime security documentation: https://falco.org/docs/
- OPA Gatekeeper documentation: https://open-policy-agent.github.io/gatekeeper/website/docs/
- Kyverno documentation: https://kyverno.io/docs/
- Kyverno — Verifying Image Signatures: https://kyverno.io/docs/writing-policies/verify-images/
- Sigstore / cosign documentation: https://docs.sigstore.dev/
- CNCF CNPA Curriculum: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf