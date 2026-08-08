# CNPE 3.2 — Applying RBAC and Security Controls Across Platform Resources

> **Domain:** Platform Security & Governance · **Exam weight:** 3
> **Profile:** Principal Platform Architect / Senior SRE · Production depth
> **Source syllabus:** [CNPE Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

---

## 1. The architectural problem: authorization as a platform capability, not a cluster afterthought

A platform is a **multi-tenant product**. The moment two teams share a control plane, "who can do what to which resource" stops being a security checkbox and becomes a *product surface*: it must be self-service, auditable, reproducible, and enforceable without a human gate in the request path. This is the distinction the CNPE syllabus draws — you are not configuring RBAC for *a* cluster, you are **provisioning authorization and security guardrails as a repeatable capability across every tenant, environment, and resource type the platform exposes.**

Three failure modes drive the design:

1. **The `cluster-admin` shortcut.** Under delivery pressure, teams get bound to `cluster-admin` "temporarily." RBAC is additive and has no deny rules, so a single over-broad `ClusterRoleBinding` silently defeats every namespace boundary. There is no CVE for this — it is a governance failure that looks like convenience.

2. **The authorization gap.** RBAC answers *"is this subject allowed to perform this verb on this resource kind?"* It **cannot** answer *"is the *content* of this object safe?"* — it cannot forbid a Pod that runs as root, mandate resource limits, or require a specific label. RBAC is coarse-grained on purpose; the field-level and value-level controls live in **admission control** (Pod Security Admission, OPA Gatekeeper, Kyverno, ValidatingAdmissionPolicy). A platform that ships RBAC without admission policy has locked the door and left the windows open.

3. **Ambient credentials.** Every Pod historically mounted a non-expiring ServiceAccount token. Exfiltrate one Pod and you hold a permanent cluster credential. The modern platform issues **short-lived, audience-scoped, projected tokens** and federates workload identity to cloud IAM (IRSA, GKE Workload Identity, Azure Workload Identity) so no long-lived secret ever touches a container.

The **request path** below is the mental model to hold. Every write to the API server passes through it in order; security is the *composition* of all stages, and RBAC is only the third.

```
                          Kubernetes API request lifecycle
  ┌────────────┐   ┌───────────────┐   ┌──────────────────┐   ┌──────────────────────┐
  │ 1. Authn   │──▶│ 2. Authz      │──▶│ 3. Mutating      │──▶│ 4. Validating        │
  │ who are    │   │ (RBAC / Node/ │   │    admission     │   │    admission         │
  │ you?       │   │  Webhook)     │   │ (defaults,       │   │ (PSA, Gatekeeper,    │
  │ OIDC, cert,│   │ verb×resource │   │  sidecars,       │   │  Kyverno, VAP,       │
  │ SA token   │   │ ALLOW/DENY    │   │  mutate objs)    │   │  schema) ALLOW/DENY  │
  └────────────┘   └───────────────┘   └──────────────────┘   └──────────────────────┘
        │                  │                     │                        │
    identity           coarse-grained        object rewrite        content policy
   (not authz)         (kind-level)          (least-priv defaults)  (value-level)  ──▶ etcd
```

RBAC gates the *verb×resource kind*. Admission gates the *object's contents*. You need both, and on a platform you deliver both **as code, per tenant, from a Git source of truth.**

---

## 2. Kubernetes RBAC mechanics — the four primitives and the rules that bind them

RBAC is defined entirely in the `rbac.authorization.k8s.io/v1` API group by four kinds:

| Kind | Scope | Grants permissions in | Typical platform use |
|---|---|---|---|
| `Role` | Namespaced | its own namespace | per-tenant developer/viewer roles |
| `ClusterRole` | Cluster | cluster-wide **or** reusable in any namespace via a `RoleBinding` | platform-defined role templates, node/PV access, aggregation |
| `RoleBinding` | Namespaced | binds subjects → `Role`/`ClusterRole`, effective only in its namespace | grant a team access inside its tenant namespace |
| `ClusterRoleBinding` | Cluster | binds subjects → `ClusterRole`, cluster-wide | platform operators, cluster-scoped controllers only |

Two rules carry most of the weight in production:

- **A `RoleBinding` may reference a `ClusterRole`.** This is the key platform pattern: define a role *template* once as a `ClusterRole`, then instantiate it per namespace with a `RoleBinding`. Grant is confined to the binding's namespace. You do **not** duplicate `Role` objects across 200 tenants.
- **RBAC is purely additive; there is no `deny`.** Effective permissions are the union of every binding that matches the subject. You subtract nothing. Restriction is achieved by *not granting*, plus admission control on top.

### 2.1 A production tenant role (namespaced `Role`)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-developer
  namespace: team-alpha
  labels:
    app.kubernetes.io/managed-by: platform
    platform.example.com/role-template: developer
rules:
# Core workload objects — full lifecycle.
- apiGroups: [""]
  resources: ["pods", "pods/log", "pods/exec", "services", "configmaps", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Workload controllers.
- apiGroups: ["apps", "batch"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets", "jobs", "cronjobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Read-only on Secrets by NAME — no blanket 'list' that would dump every secret.
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
  resourceNames: ["app-db-credentials", "app-tls"]
# Ingress, but not the IngressClass (cluster-scoped, platform-owned).
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "networkpolicies"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Explicitly NO access to ResourceQuota / LimitRange — platform-owned guardrails.
```

Two least-privilege techniques are load-bearing here:

- **`resourceNames`** narrows a rule to specific object names. It is the only way to grant `get` on *one* Secret without granting `list`/`watch` on *all* of them. Caveat: `resourceNames` does **not** work with `list`, `watch`, `create`, or `deletecollection` (the name is unknown at request time for those verbs).
- **Omission over restriction.** Quotas and LimitRanges are simply absent from the rules, so tenants cannot raise their own limits.

### 2.2 Reusable role templates with `ClusterRole` + `RoleBinding`

```yaml
# Platform-defined, defined ONCE, cluster-scoped as a template.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:viewer
  labels:
    platform.example.com/role-template: viewer
rules:
- apiGroups: ["", "apps", "batch", "networking.k8s.io"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
---
# Instantiated per tenant — grant is confined to team-alpha only.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alpha-oncall-viewer
  namespace: team-alpha
subjects:
- kind: Group
  name: "oidc:team-alpha-oncall"        # group asserted by the OIDC IdP
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole                       # references the template...
  name: platform:viewer
  apiGroup: rbac.authorization.k8s.io
```

Because the `roleRef` is a `ClusterRole` but the binding is a `RoleBinding`, `oidc:team-alpha-oncall` can read objects **only in `team-alpha`**. Bind subjects to **Groups**, never to individual users — user lifecycle (joiners/leavers) then lives in the IdP, and the cluster never needs a re-bind when someone changes teams.

### 2.3 Aggregated ClusterRoles — extensible without editing

Aggregation lets you *extend* a role by labeling new rules, without ever editing the aggregate. The built-in `admin`, `edit`, and `view` ClusterRoles use exactly this so CRDs can slot themselves in.

```yaml
# The aggregate — its rules[] is managed by the controller; leave it empty.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:monitoring
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      platform.example.com/aggregate-to-monitoring: "true"
rules: []   # DO NOT hand-edit — the aggregation controller overwrites this.
---
# A contributing role — add capabilities just by matching the label.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:monitoring-prometheus
  labels:
    platform.example.com/aggregate-to-monitoring: "true"
rules:
- apiGroups: ["monitoring.coreos.com"]
  resources: ["servicemonitors", "podmonitors", "prometheusrules"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

Ship a new observability CRD? Add a labeled `ClusterRole` in the same GitOps commit and every subject bound to `platform:monitoring` inherits it — no edit to the aggregate, no re-bind.

### 2.4 The three privilege-escalation verbs you must audit

RBAC contains three verbs that let a subject grant themselves *more* than they hold. A platform must treat these as break-glass-only:

| Verb | On resource | Danger |
|---|---|---|
| `escalate` | `roles`, `clusterroles` | create/update a Role with permissions the actor does not itself hold — bypasses the normal escalation-prevention check |
| `bind` | `rolebindings`, `clusterrolebindings` | bind a subject to a role more powerful than the actor's own |
| `impersonate` | `users`, `groups`, `serviceaccounts` | act *as* another identity via `--as` / `--as-group`, inheriting their rights |

By default the API server **prevents escalation**: a user can only create/edit a Role whose rules are a subset of what they already have. Granting `escalate` or `bind` removes that guardrail. `impersonate` is how a compromised service can pivot to `cluster-admin` if `system:masters` is impersonable. Alert on any binding that grants these outside the platform-operators group.

---

## 3. RBAC vs. the alternatives — and where RBAC stops

### 3.1 Authorization modes

| Mode | Granularity | State | Dynamic? | Platform verdict |
|---|---|---|---|---|
| **RBAC** | verb × resource kind (+ `resourceNames`) | declarative objects in etcd | yes, `kubectl apply` | **Default.** Auditable, GitOps-friendly, the ecosystem assumes it. |
| **ABAC** | attribute policy lines in a file | static file on every API server | no — requires apiserver restart | Legacy. Un-auditable at runtime, no self-service. Avoid. |
| **Node** | kubelet-scoped, auto | built-in | n/a | Always on for kubelets; not for humans. |
| **Webhook** | delegated to external service | external | yes | Escape hatch for org-specific logic; adds latency + a hard dependency in the auth path. |

Run RBAC as the primary authorizer. The apiserver flag is ordered — `--authorization-mode=Node,RBAC` — and the **first mode to return an explicit allow wins**; a deny falls through to the next. Webhook only if you have policy RBAC genuinely cannot express.

### 3.2 The RBAC ↔ admission boundary — memorize this table

| Requirement | RBAC can enforce it? | Correct control |
|---|---|---|
| "Team-alpha may create Deployments in team-alpha" | ✅ Yes | `Role` + `RoleBinding` |
| "Nobody may run a container as UID 0" | ❌ No | Pod Security Admission (`restricted`) or policy engine |
| "Every Pod must set CPU/memory limits" | ❌ No | Kyverno / Gatekeeper / VAP |
| "Images must come from `registry.internal/`" | ❌ No | Policy engine + signature verification |
| "Grant read on Secret `app-tls` only" | ✅ Yes (`resourceNames`) | `Role` with `resourceNames` |
| "Every namespace must carry a `cost-center` label" | ❌ No | Policy engine |
| "This SA may not be bound above its own privileges" | ✅ Yes (escalation prevention) | built-in, don't grant `escalate`/`bind` |

**RBAC gates the request; admission gates the payload.** Any control about the *values inside an object* is admission, not RBAC.

---

## 4. Pod Security Admission — the built-in baseline, applied per tenant

PodSecurityPolicy was removed in v1.25. Its replacement, **Pod Security Admission (PSA)**, is a built-in admission controller driven by **namespace labels**, enforcing the three **Pod Security Standards (PSS)** levels:

| Level | Intent | Blocks |
|---|---|---|
| `privileged` | unrestricted | nothing — for infra/trusted system namespaces only |
| `baseline` | prevent known escalations | hostNetwork, hostPID, privileged, most hostPath, added dangerous capabilities |
| `restricted` | hardened best practice | all of baseline + must `runAsNonRoot`, drop `ALL` caps, `seccompProfile: RuntimeDefault`, no privilege escalation |

Each level runs in three **modes** — independently settable:

- `enforce` — reject violating Pods (hard gate).
- `audit` — allow, but annotate the audit log.
- `warn` — allow, but return a `Warning:` header to the client (great for rollout).

A platform provisions every tenant namespace pre-labeled — start in `warn`+`audit`, then promote to `enforce`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-alpha
  labels:
    # HARD gate at 'restricted'.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    # Belt-and-braces telemetry at the same level.
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
```

Pinning `-version` freezes the policy semantics so a cluster upgrade cannot silently tighten enforcement and break running tenants. PSA is **namespace-granular and value-limited** (it only knows the built-in PSS levels) — for anything beyond the three standard levels (registry allow-lists, required labels, custom seccomp), you escalate to a policy engine.

---

## 5. Policy engines — value-level controls RBAC and PSA cannot express

Two dominant CNCF engines. Both are `ValidatingWebhookConfiguration`-based admission controllers with mutation support.

| Dimension | OPA Gatekeeper | Kyverno |
|---|---|---|
| Policy language | **Rego** (declarative logic language, learning curve) | **YAML** (native, no new language) |
| Model | `ConstraintTemplate` (CRD generator) + `Constraint` | `ClusterPolicy` / `Policy` |
| Mutation | yes (Assign/ModifySet) | yes, first-class |
| Image verification | via external data / providers | **built-in** `verifyImages` (cosign/Notation) |
| Generate resources | limited | **yes** (auto-create NetworkPolicy, defaults) |
| Audit/background scan | yes (periodic) | yes (`Reports`) |
| Best when | complex cross-object logic, existing Rego investment | fast adoption, YAML-native teams, image signing |

### 5.1 Kyverno — enforce, mutate, and generate in three policies

**Enforce** — require resource limits and forbid `:latest`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-limits-no-latest
spec:
  validationFailureAction: Enforce      # block on violation
  background: true                        # also scan existing objects
  rules:
  - name: require-resource-limits
    match:
      any:
      - resources:
          kinds: ["Pod"]
    validate:
      message: "CPU and memory limits are required."
      pattern:
        spec:
          containers:
          - resources:
              limits:
                memory: "?*"
                cpu: "?*"
  - name: disallow-latest-tag
    match:
      any:
      - resources:
          kinds: ["Pod"]
    validate:
      message: "Using ':latest' or an untagged image is not allowed."
      pattern:
        spec:
          containers:
          - image: "!*:latest & *:*"
```

**Generate** — every new tenant namespace gets a default-deny NetworkPolicy automatically:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-deny-per-namespace
spec:
  rules:
  - name: add-default-deny
    match:
      any:
      - resources:
          kinds: ["Namespace"]
    generate:
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      name: default-deny-ingress
      namespace: "{{request.object.metadata.name}}"
      synchronize: true                   # keep in sync if the source changes
      data:
        spec:
          podSelector: {}
          policyTypes: ["Ingress"]
```

### 5.2 Gatekeeper — a ConstraintTemplate + Constraint pair

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedrepos
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRepos
      validation:
        openAPIV3Schema:
          type: object
          properties:
            repos:
              type: array
              items:
                type: string
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package k8sallowedrepos
      violation[{"msg": msg}] {
        container := input.review.object.spec.containers[_]
        satisfied := [good | repo := input.parameters.repos[_]; good := startswith(container.image, repo)]
        not any(satisfied)
        msg := sprintf("container <%v> image <%v> not from an allowed repo %v", [container.name, container.image, input.parameters.repos])
      }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: only-internal-registry
spec:
  match:
    kinds:
    - apiGroups: [""]
      kinds: ["Pod"]
    namespaceSelector:
      matchExpressions:
      - key: platform.example.com/tenant
        operator: Exists
  parameters:
    repos: ["registry.internal.example.com/"]
```

### 5.3 The in-tree path — ValidatingAdmissionPolicy (CEL, no webhook)

Stable since v1.30, **VAP** runs policy *inside* the apiserver using **CEL** — no external webhook, no availability dependency, no network hop. For simple constraints it is now the default recommendation:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-replica-limit
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["deployments"]
  validations:
  - expression: "object.spec.replicas <= 20"
    message: "Deployment replicas must not exceed 20."
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-replica-limit-binding
spec:
  policyName: require-replica-limit
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        platform.example.com/tier: "standard"
```

**Trade-off:** VAP removes the webhook's latency and single-point-of-failure, but CEL is less expressive than Rego/Kyverno for cross-object lookups and cannot mutate. Use VAP for simple field checks, a policy engine for the complex or generative ones.

---

## 6. Workload identity — killing the long-lived token

### 6.1 Bound, projected ServiceAccount tokens

Legacy SA Secrets were permanent JWTs. Modern tokens are **bound** to a Pod, **time-limited**, and **audience-scoped**. Request one explicitly with a projected volume:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
  namespace: team-alpha
spec:
  serviceAccountName: app
  automountServiceAccountToken: false     # deny the default API token...
  containers:
  - name: app
    image: registry.internal.example.com/app:1.4.2
    volumeMounts:
    - name: vault-token
      mountPath: /var/run/secrets/tokens
      readOnly: true
    securityContext:
      runAsNonRoot: true
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      seccompProfile:
        type: RuntimeDefault
  volumes:
  - name: vault-token
    projected:
      sources:
      - serviceAccountToken:
          path: token
          audience: vault                 # token only valid AT vault
          expirationSeconds: 3600         # kubelet auto-rotates before expiry
```

`automountServiceAccountToken: false` is the default-deny; you then hand-mount *only* a token whose `audience` is the exact consumer. A stolen token is useless anywhere but that audience and expires within the hour.

### 6.2 Federating to cloud IAM (no static cloud keys)

The SA token is an OIDC JWT signed by the cluster; a cloud IAM trust policy accepts it and returns temporary cloud credentials. **Zero secrets stored.**

```yaml
# AWS IRSA — annotate the SA with the IAM role to assume.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app
  namespace: team-alpha
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/team-alpha-app
---
# GKE / GCP Workload Identity Federation.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app
  namespace: team-alpha
  annotations:
    iam.gke.io/gcp-service-account: team-alpha-app@project.iam.gserviceaccount.com
```

The trade line the platform draws: **a workload's Kubernetes identity (its SA) is federated to exactly one cloud identity**, scoped by the cloud IAM policy. RBAC governs what it can do *in* the cluster; the IAM role governs what it can do *outside*. Neither leaks a static credential.

---

## 7. Delivering it as a platform — tenant provisioning from Git

The point of CNPE 3.2 is that none of the above is hand-applied. A **Tenant** abstraction bundles namespace + quota + RBAC + PSA + NetworkPolicy, provisioned via GitOps. Two common approaches:

**Capsule** — a `Tenant` CR that self-services namespaces under guardrails:

```yaml
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata:
  name: alpha
spec:
  owners:
  - name: "oidc:team-alpha-leads"
    kind: Group
  namespaceOptions:
    quota: 5                              # team may self-create ≤5 namespaces
  limitRanges:
    items:
    - limits:
      - type: Container
        default: { cpu: "500m", memory: "512Mi" }
        defaultRequest: { cpu: "100m", memory: "128Mi" }
  networkPolicies:
    items:
    - policyTypes: ["Ingress"]
      podSelector: {}
      ingress:
      - from:
        - namespaceSelector:
            matchLabels: { capsule.clastix.io/tenant: alpha }
  imagePullPolicies: ["Always"]
  containerRegistries:
    allowed: ["registry.internal.example.com"]
```

The owner group can create namespaces freely, but every namespace is *born* with the quota, LimitRange, default-deny NetworkPolicy, and registry allow-list. Self-service **inside** guardrails — the platform-engineering pattern in one object.

| Multi-tenancy model | Isolation strength | Cost / overhead | RBAC blast radius | Use when |
|---|---|---|---|---|
| Namespace + RBAC + PSA (Capsule/HNC) | soft (shared control plane) | lowest | per-namespace | most internal teams, trusted tenants |
| Virtual cluster (**vcluster**) | medium (own apiserver, shared nodes) | medium | per-vcluster | teams needing CRDs/cluster-scoped objects |
| Separate clusters | hard | highest | per-cluster | untrusted tenants, strict compliance |

---

## 8. Verification & failure diagnosis

**RBAC never emits errors for *missing* grants — it silently denies.** Diagnosis is therefore active interrogation, not log-reading.

### 8.1 `kubectl auth can-i` — the primary tool

```bash
# Ask on your own behalf.
$ kubectl auth can-i create deployments -n team-alpha
yes

$ kubectl auth can-i delete nodes
no

# Impersonate a subject to test a binding BEFORE handing it out.
$ kubectl auth can-i get secrets -n team-alpha --as=system:serviceaccount:team-alpha:app
no

$ kubectl auth can-i get secret/app-tls -n team-alpha --as=system:serviceaccount:team-alpha:app
yes

# Test a group-based grant.
$ kubectl auth can-i list pods -n team-alpha --as-group=oidc:team-alpha-oncall --as=alice
yes

# Enumerate EVERYTHING a subject can do in a namespace — the audit workhorse.
$ kubectl auth can-i --list -n team-alpha --as=system:serviceaccount:team-alpha:app
Resources                                       Non-Resource URLs   Resource Names     Verbs
pods                                            []                  []                 [get list watch create update patch delete]
pods/log                                        []                  []                 [get list watch]
secrets                                         []                  [app-tls app-db-credentials]  [get]
deployments.apps                                []                  []                 [get list watch create update patch delete]
...
```

`--as` / `--as-group` require the caller to hold `impersonate` — restrict that to platform operators. This is the single most valuable habit: **test the grant by impersonation before you apply the binding.**

### 8.2 Finding *who* can do a dangerous thing

The built-in tools answer "can *this* subject...?" To answer "who can...?" reverse-lookup with `krew` plugins:

```bash
# rakkess — access matrix for the current or impersonated subject.
$ kubectl access-matrix --namespace team-alpha
NAME              LIST  CREATE  UPDATE  DELETE
configmaps          ✔       ✔       ✔       ✔
secrets             ✔       ✖       ✖       ✖
pods                ✔       ✔       ✔       ✔

# rbac-lookup — who is bound to what.
$ kubectl rbac-lookup alice --output wide
SUBJECT   SCOPE       ROLE                    SOURCE
alice     team-alpha  ClusterRole/platform:viewer   RoleBinding/alpha-oncall-viewer

# Who can escalate? Find every subject with the dangerous verbs.
$ kubectl who-can create clusterrolebindings
ROLEBINDING             NAMESPACE  SUBJECT
platform-operators      (cluster)  Group/oidc:platform-admins
```

### 8.3 Diagnosing an admission rejection

```bash
$ kubectl apply -f pod-as-root.yaml
Error from server (Forbidden): error when creating "pod-as-root.yaml": pods "web" is forbidden:
violates PodSecurity "restricted:v1.30": allowPrivilegeEscalation != false (container "web"
must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container
"web" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or
container "web" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container
"web" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")

# A Kyverno block names the policy and rule — trace it directly:
$ kubectl apply -f deploy-nolimits.yaml
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
resource Deployment/team-alpha/api was blocked due to the following policies:
  require-limits-no-latest:
    require-resource-limits: 'validation error: CPU and memory limits are required.'

# Inspect the policy report for background-scan violations on EXISTING objects:
$ kubectl get policyreport -n team-alpha
NAME                          PASS   FAIL   WARN   ERROR
polr-ns-team-alpha            42     3      0      0

$ kubectl describe policyreport polr-ns-team-alpha -n team-alpha | grep -A3 fail
```

### 8.4 The authoritative source — API server audit log

RBAC/admission decisions are recorded in the apiserver audit log. Enable an audit policy that captures authorization detail:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
# Full request+response on RBAC and admission-relevant writes.
- level: RequestResponse
  verbs: ["create", "update", "patch", "delete"]
  resources:
  - group: "rbac.authorization.k8s.io"
  - group: "" ; resources: ["serviceaccounts", "secrets"]
# Log every Forbidden — the silent denials become visible here.
- level: Metadata
  omitStages: ["RequestReceived"]
```

```bash
# Find every denied request for a subject (annotation set by the authorizer).
$ jq 'select(.annotations["authorization.k8s.io/decision"]=="forbid")
      | {who:.user.username, verb:.verb, res:.objectRef.resource, reason:.annotations["authorization.k8s.io/reason"]}' \
      /var/log/kubernetes/audit.log
{"who":"system:serviceaccount:team-alpha:app","verb":"list","res":"secrets","reason":""}
```

The `authorization.k8s.io/decision` and `authorization.k8s.io/reason` annotations are the ground truth: the reason string tells you *which rule* allowed a request, or that none did.

### 8.5 Diagnostic decision tree

| Symptom | Likely cause | First command |
|---|---|---|
| `Error ... is forbidden: User cannot <verb> <resource>` | no matching RBAC rule | `kubectl auth can-i <verb> <res> --as=<subject>` then `kubectl auth can-i --list` |
| Works for you, fails for a Pod | Pod's SA lacks the grant / wrong SA | check `.spec.serviceAccountName`; `--as=system:serviceaccount:ns:sa` |
| `forbidden: PodSecurity "restricted..."` | PSA namespace label | inspect namespace labels; fix `securityContext` |
| `admission webhook "...kyverno..." denied` | policy engine rule | read the named policy/rule in the error; check `policyreport` |
| Subject has *more* access than expected | over-broad `ClusterRoleBinding` | `kubectl rbac-lookup <subject> -o wide`; `who-can` |
| Cloud API 403 from a Pod | IRSA/WI trust misconfig, not RBAC | decode the projected token `aud`/`sub`; check IAM trust policy |

---

## 9. Production checklist

- [ ] No human or workload bound to `cluster-admin` outside a documented break-glass path; break-glass access is audited and time-boxed.
- [ ] Subjects are **Groups from the IdP**, never individual users; lifecycle lives in the IdP.
- [ ] Role *templates* are `ClusterRole`s; per-tenant grants are `RoleBinding`s — no per-tenant `Role` duplication.
- [ ] `escalate`, `bind`, `impersonate` granted only to platform operators; alert on any new binding that grants them.
- [ ] Every tenant namespace carries pinned `pod-security.kubernetes.io/*` labels at `restricted` (or a justified exception).
- [ ] A policy engine (Kyverno/Gatekeeper) or VAP enforces limits, registry allow-list, and required labels; background scan is on.
- [ ] `automountServiceAccountToken: false` by default; consumers get audience-scoped, expiring projected tokens.
- [ ] Cloud access is via workload-identity federation (IRSA/WI); **zero** static cloud keys in Secrets.
- [ ] Default-deny NetworkPolicy auto-generated per namespace.
- [ ] Every tenant provisioned from Git (Capsule/HNC/Crossplane); no hand-applied RBAC.
- [ ] RBAC changes gated by impersonation tests (`--as … can-i --list`) in CI before merge.

---

## Referencias

- Kubernetes — Using RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — Authorization Overview (modes, ordering): https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Kubernetes — Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — ServiceAccounts & bound/projected tokens: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes — Managing Service Accounts (admin): https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubernetes — Validating Admission Policy (CEL): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — Auditing: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — Multi-tenancy: https://kubernetes.io/docs/concepts/security/multi-tenancy/
- OPA Gatekeeper documentation: https://open-policy-agent.github.io/gatekeeper/website/docs/
- Kyverno documentation: https://kyverno.io/docs/
- Capsule (multi-tenancy operator): https://capsule.clastix.io/docs/
- Hierarchical Namespace Controller (HNC): https://github.com/kubernetes-sigs/hierarchical-namespaces
- vcluster (virtual clusters): https://www.vcluster.com/docs/
- AWS IAM Roles for Service Accounts (IRSA): https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- GKE Workload Identity Federation: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
- CNPE Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf