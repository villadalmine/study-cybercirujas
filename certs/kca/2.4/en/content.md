# 2.4 Configuring Kyverno RBAC, Roles, and Permissions

## 1. The production problem: least privilege meets policy automation

Kyverno is often introduced as "the admission controller you write in YAML," and for pure `validate` rules that mental model holds — the work happens in-flight on the `AdmissionReview` object and Kyverno never touches the API server on your behalf. The moment a policy does anything *outside* the admission request, the picture changes completely, and this is where most production incidents originate.

Three rule types act on cluster state that is not the resource under admission:

- **`generate`** — Kyverno *creates* a companion resource (a default `NetworkPolicy` per namespace, a pull-secret in every tenant namespace, a `ResourceQuota`, etc.).
- **`mutate` with `targets:` (mutate-existing)** — Kyverno *patches* resources that already exist and are not the trigger.
- **`ClusterCleanupPolicy` / `CleanupPolicy`** — Kyverno *deletes* resources on a schedule.

Every one of these is executed by a Kyverno controller acting as its own `ServiceAccount`, not as the user who triggered it. And since **Kyverno 1.10 the project deliberately ships with least-privilege ServiceAccounts** — the historical `cluster-admin`-adjacent grant was removed because it turned every policy author into a de-facto cluster admin. The consequence, which the KCA exam tests directly and which bites every new operator, is:

> A `generate` or `mutate-existing` rule for a resource kind the controller has **no RBAC for** does not error at admission time. The triggering resource is admitted normally, the policy shows `Ready: true`, and the side-effect silently never happens. The failure lives in an `UpdateRequest` status and a controller log line — nowhere a casual `kubectl get cpol` will show it.

Configuring RBAC correctly is therefore not optional hardening; it is the difference between a policy that works and a policy that lies about working. This topic is the mechanics of that configuration: which controller needs which permission, how Kyverno extends its own roles through native Kubernetes ClusterRole aggregation, how to scope grants to the smallest blast radius, and how to diagnose the silent failure.

---

## 2. The controller model and where permissions live

Since 1.10 Kyverno runs as **four independent controllers**, each a separate `Deployment` with its own `ServiceAccount` in the `kyverno` namespace. Splitting them is what makes least privilege possible — the admission path does not carry delete power, the cleanup path does not carry admission power.

| Controller | ServiceAccount (`ns: kyverno`) | Aggregation label key | Responsible for | Typically needs *extra* RBAC to… |
|---|---|---|---|---|
| Admission | `kyverno-admission-controller` | `rbac.kyverno.io/aggregate-to-admission-controller` | Validating/mutating webhooks, evaluating `context` | `get`/`list` resources referenced by `apiCall` / `configMap` / `globalReference` context |
| Background | `kyverno-background-controller` | `rbac.kyverno.io/aggregate-to-background-controller` | `generate` and `mutate-existing`, background reconciliation | `create`/`update`/`delete`/`get`/`list`/`watch` on every **generated or mutated target kind** |
| Reports | `kyverno-reports-controller` | `rbac.kyverno.io/aggregate-to-reports-controller` | Building `PolicyReport` / `ClusterPolicyReport` | `get`/`list`/`watch` on kinds it must scan (ships broad by default) |
| Cleanup | `kyverno-cleanup-controller` | `rbac.kyverno.io/aggregate-to-cleanup-controller` | Executing `CleanupPolicy` schedules | `list`/`watch`/`delete` on every **cleanup target kind** |

### 2.1 How Kyverno extends its own permissions: native ClusterRole aggregation

Kyverno does not use a custom permission system. It leans entirely on **Kubernetes aggregated ClusterRoles** (`kube-controller-manager`'s `clusterrole-aggregation-controller`). For each controller it ships a *pair* of ClusterRoles:

- `kyverno:<controller>` — an **aggregation shell**. Its `rules:` are empty in the manifest; it carries an `aggregationRule` that selects other ClusterRoles by label.
- `kyverno:<controller>:core` — the baseline rules Kyverno itself needs, carrying the aggregation label so the controller-manager folds it into the shell.

```console
$ kubectl get clusterroles | grep '^kyverno:'
kyverno:admission-controller             2024-06-11T09:20:14Z
kyverno:admission-controller:core        2024-06-11T09:20:14Z
kyverno:background-controller            2024-06-11T09:20:14Z
kyverno:background-controller:core       2024-06-11T09:20:14Z
kyverno:cleanup-controller               2024-06-11T09:20:14Z
kyverno:cleanup-controller:core          2024-06-11T09:20:14Z
kyverno:reports-controller               2024-06-11T09:20:14Z
kyverno:reports-controller:core          2024-06-11T09:20:14Z
kyverno:rbac:admin:policies              2024-06-11T09:20:14Z
kyverno:rbac:admin:policyreports         2024-06-11T09:20:14Z
kyverno:rbac:admin:reports               2024-06-11T09:20:14Z
kyverno:rbac:view:policies               2024-06-11T09:20:14Z
kyverno:rbac:view:policyreports          2024-06-11T09:20:14Z
```

Inspecting the shell shows the aggregation selector and the *populated* rules that the controller-manager copied in from every matching role:

```console
$ kubectl get clusterrole kyverno:background-controller -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:background-controller
  labels:
    app.kubernetes.io/part-of: kyverno
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:                       # <-- filled in by kube-controller-manager, do not edit
- apiGroups: ["kyverno.io"]
  resources: ["updaterequests","updaterequests/status","policies","clusterpolicies"]
  verbs: ["create","delete","get","list","patch","update","watch","deletecollection"]
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get","list","watch"]
# ...core rules only; note: no networkpolicies, no secrets, no configmaps update
```

**The pattern you will use all the time:** to grant a controller a new permission, you never edit `kyverno:<controller>` (the controller-manager overwrites its `rules`) and you never edit `:core` (the next Helm upgrade overwrites it). You create a **new** ClusterRole carrying the right aggregation label. The controller-manager notices the label and folds your rules into the shell automatically within seconds. This is the single most important operational fact in this topic.

### 2.2 The other aggregation: exposing Kyverno CRDs to human roles

Separately, Kyverno aggregates its CRDs into the **built-in Kubernetes `admin`/`edit`/`view` ClusterRoles** using the standard `rbac.authorization.k8s.io/aggregate-to-*` labels, so a namespace `admin` can manage namespaced `Policy` objects and reports without a bespoke grant:

```console
$ kubectl get clusterrole kyverno:rbac:admin:policies -o yaml | yq '.metadata.labels'
app.kubernetes.io/part-of: kyverno
rbac.authorization.k8s.io/aggregate-to-admin: "true"
rbac.authorization.k8s.io/aggregate-to-edit: "true"
```

Keep the two aggregation namespaces straight — they answer different questions:

| Label prefix | Aggregates into | Answers |
|---|---|---|
| `rbac.kyverno.io/aggregate-to-*` | Kyverno controller ClusterRoles | "What can Kyverno's ServiceAccounts do to the cluster?" |
| `rbac.authorization.k8s.io/aggregate-to-*` | Built-in `admin`/`edit`/`view` | "What can *humans* do to Kyverno objects?" |

---

## 3. Comparative approaches to granting a controller a permission

There is more than one way to give the background controller `create networkpolicies`. They are not equivalent in blast radius or upgrade-safety.

| Approach | How | Blast radius | Upgrade-safe? | When to use |
|---|---|---|---|---|
| **Aggregated ClusterRole** (recommended) | New ClusterRole with `rbac.kyverno.io/aggregate-to-background-controller: "true"` | Cluster-wide for that kind | ✅ survives Helm upgrades | Default choice; policy applies to many/all namespaces |
| **Namespaced Role + RoleBinding** | `Role` in one namespace bound to the controller SA | Single namespace | ✅ | Generate/mutate confined to one or a few tenant namespaces; tightest scope |
| **Patch the `:core` role** | Edit `kyverno:background-controller:core` in place | Cluster-wide | ❌ overwritten by next `helm upgrade` | Never in production |
| **Patch the aggregation shell** | Edit `kyverno:background-controller` `rules` | — | ❌ overwritten by controller-manager within seconds | Never — it does not even persist |
| **Wildcard grant** (`*/*`) | ClusterRole with `apiGroups/resources/verbs: ["*"]` + label | Everything | ✅ (technically) | Never — reintroduces the pre-1.10 privilege-escalation surface |

**Trade-off summary.** Prefer the *namespaced Role/RoleBinding* whenever the policy's targets live in a known set of namespaces — it is the only option that bounds the controller's power to where the policy actually acts, which matters enormously for sensitive kinds like `secrets`, `roles`, and `serviceaccounts`. Reach for the *aggregated ClusterRole* when the policy is genuinely cluster-wide (e.g. a default `NetworkPolicy` in every namespace). Everything else is either non-persistent or an upgrade landmine.

---

## 4. Complete manifests

### 4.1 A `generate` policy and the RBAC it requires

The classic case: enforce a default-deny `NetworkPolicy` in every namespace.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-networkpolicy
spec:
  # generate rules are inherently background work; they must be able to run
  background: true
  # also reconcile namespaces that already existed when the policy was created
  generateExisting: true
  rules:
  - name: default-deny-per-namespace
    match:
      any:
      - resources:
          kinds:
          - Namespace
    exclude:
      any:
      - resources:
          namespaces:
          - kube-system
          - kube-node-lease
          - kyverno
    generate:
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      name: default-deny
      namespace: "{{ request.object.metadata.name }}"
      synchronize: true         # keep the generated object in lock-step with the source
      data:
        spec:
          podSelector: {}
          policyTypes:
          - Ingress
          - Egress
```

Applied on a fresh Kyverno install, this does **nothing** — the background controller cannot create `NetworkPolicy`. The required grant, as an aggregated ClusterRole:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:generate-networkpolicies
  labels:
    app.kubernetes.io/part-of: kyverno
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
- apiGroups:
  - networking.k8s.io
  resources:
  - networkpolicies
  # synchronize:true means the controller must also reconcile & tear down,
  # so update/delete are mandatory, not just create
  verbs:
  - create
  - update
  - delete
  - get
  - list
  - watch
```

> **Verb rule of thumb.** `create` alone is enough only for a one-shot generate with `synchronize: false`. With `synchronize: true` (the usual choice) you must add `update`, `delete`, `get`, `list`, `watch`, because the controller now owns the lifecycle of the generated object.

### 4.2 A `mutate-existing` policy and its RBAC

Trigger on a namespace and stamp a management label onto every `ConfigMap` already inside it.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: label-existing-configmaps
spec:
  background: true
  # re-run against existing targets whenever this policy is created/updated
  mutateExistingOnPolicyUpdate: true
  rules:
  - name: stamp-managed-by
    match:
      any:
      - resources:
          kinds:
          - Namespace
    mutate:
      targets:
      - apiVersion: v1
        kind: ConfigMap
        namespace: "{{ request.object.metadata.name }}"
      patchStrategicMerge:
        metadata:
          labels:
            managed-by: kyverno
```

Required grant (background controller — mutate-existing runs there, *not* in the admission controller):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:mutate-configmaps
  labels:
    app.kubernetes.io/part-of: kyverno
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "update"]   # no create/delete needed for a patch
```

### 4.3 Scoping the grant to a single namespace (least-privilege pattern)

If a policy only ever generates `Secret`s into `team-a`, do **not** hand the background controller cluster-wide secret creation. Bind a namespaced `Role` instead — this is the tightest option and the one to reach for on sensitive kinds.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kyverno:generate-secrets
  namespace: team-a
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["create", "update", "delete", "get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kyverno:generate-secrets
  namespace: team-a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kyverno:generate-secrets
subjects:
- kind: ServiceAccount
  name: kyverno-background-controller
  namespace: kyverno
```

Because a `RoleBinding` grants only within its own namespace, the controller can now write secrets in `team-a` and nowhere else — even though the `ClusterPolicy` object itself is cluster-scoped. Aggregation labels have **no effect** here; namespace scoping is achieved purely through the `RoleBinding` subject.

### 4.4 A `CleanupPolicy` and the cleanup controller's RBAC

```yaml
apiVersion: kyverno.io/v2beta1
kind: ClusterCleanupPolicy
metadata:
  name: remove-empty-configmaps
spec:
  match:
    any:
    - resources:
        kinds:
        - ConfigMap
  conditions:
    all:
    - key: "{{ target.data | length(@) || `0` }}"
      operator: Equals
      value: 0
  schedule: "*/10 * * * *"
```

The cleanup controller must be able to *find* and *delete* the target kind:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:cleanup-configmaps
  labels:
    app.kubernetes.io/part-of: kyverno
    rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "delete"]
```

### 4.5 An admission-time `context` that needs read RBAC

A `validate` rule that consults live cluster state via `apiCall` runs in the **admission controller**, so the grant goes to that controller — a frequently-missed detail because the policy "feels" like pure validation.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-unique-ingress-host
spec:
  validationFailureAction: Enforce
  rules:
  - name: no-duplicate-host
    match:
      any:
      - resources:
          kinds: ["Ingress"]
    context:
    - name: existingIngresses
      apiCall:
        urlPath: "/apis/networking.k8s.io/v1/ingresses"
        jmesPath: "items[].spec.rules[].host"
    validate:
      message: "Ingress host must be unique across the cluster."
      deny:
        conditions:
          any:
          - key: "{{ request.object.spec.rules[].host }}"
            operator: AnyIn
            value: "{{ existingIngresses }}"
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:read-ingresses
  labels:
    app.kubernetes.io/part-of: kyverno
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
rules:
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list"]
```

Without this grant the `apiCall` fails, and depending on `failurePolicy` the webhook either **blocks all Ingress admissions** (`Fail`) or silently skips the check (`Ignore`) — both are production incidents with the same root cause.

---

## 5. Verification and failure diagnosis

### 5.1 The primary tool: impersonation with `kubectl auth can-i`

This is the fastest, most decisive check. Ask the exact question the controller will ask, *as* the controller's ServiceAccount, in the target namespace.

```console
# Before applying the aggregated ClusterRole from 4.1:
$ kubectl auth can-i create networkpolicies \
    --as=system:serviceaccount:kyverno:kyverno-background-controller \
    -n default
no

# After applying it (aggregation propagates in a few seconds):
$ kubectl auth can-i create networkpolicies \
    --as=system:serviceaccount:kyverno:kyverno-background-controller \
    -n default
yes
```

The impersonation subject is always `system:serviceaccount:<namespace>:<sa-name>`. Audit the *full* effective permission set of a controller with:

```console
$ kubectl auth can-i --list \
    --as=system:serviceaccount:kyverno:kyverno-background-controller | head
Resources                                Non-Resource URLs   Resource Names   Verbs
updaterequests.kyverno.io                []                  []               [create delete get list ...]
networkpolicies.networking.k8s.io        []                  []               [create update delete get ...]
namespaces                               []                  []               [get list watch]
...
```

### 5.2 Confirm aggregation actually took effect

A common mistake is a typo in the label key or a value of `true` (bool) instead of `"true"` (string). Verify the controller-manager folded your rules in:

```console
$ kubectl get clusterrole kyverno:background-controller -o yaml \
    | yq '.rules[] | select(.resources[] == "networkpolicies")'
apiGroups: ["networking.k8s.io"]
resources: ["networkpolicies"]
verbs: ["create","update","delete","get","list","watch"]
```

If this returns nothing but your standalone role clearly has the rule, the label is wrong. Compare directly:

```console
$ kubectl get clusterrole kyverno:generate-networkpolicies \
    -o jsonpath='{.metadata.labels}' | jq
{
  "app.kubernetes.io/part-of": "kyverno",
  "rbac.kyverno.io/aggregate-to-background-controller": "true"
}
```

### 5.3 Read the failure where it actually lives

Generate and mutate-existing operations flow through `UpdateRequest` custom resources in the `kyverno` namespace. A failed RBAC check surfaces there and in the controller log — not in the policy status.

```console
$ kubectl -n kyverno get updaterequests
NAME          POLICY                       RULETYPE   RESOURCEKIND   RESOURCENAME   STATE
ur-7bkq2      add-default-networkpolicy    generate   Namespace      default        Failed

$ kubectl -n kyverno get updaterequest ur-7bkq2 -o jsonpath='{.status.state}: {.status.message}{"\n"}'
Failed: networkpolicies.networking.k8s.io is forbidden: User "system:serviceaccount:kyverno:kyverno-background-controller" cannot create resource "networkpolicies" in API group "networking.k8s.io" in the namespace "default"
```

```console
$ kubectl -n kyverno logs deploy/kyverno-background-controller | grep -i forbidden
E0611 ... "failed to process update request" err="networkpolicies.networking.k8s.io is forbidden: User \"system:serviceaccount:kyverno:kyverno-background-controller\" cannot create resource \"networkpolicies\" in API group \"networking.k8s.io\" in the namespace \"default\"" policy="add-default-networkpolicy"
```

For an admission-time `context` (§4.5) failure, look at the admission controller and, if `failurePolicy: Fail`, the webhook rejection the user sees:

```console
$ kubectl -n kyverno logs deploy/kyverno-admission-controller | grep -i "apiCall\|forbidden"
ERROR ... failed to execute APICall ... ingresses.networking.k8s.io is forbidden: ... cannot list resource "ingresses"

$ kubectl apply -f new-ingress.yaml
Error from server: error when creating "new-ingress.yaml": admission webhook "validate.kyverno.svc-fail"
denied the request: failed to load context: failed to execute APICall for context entry existingIngresses
```

### 5.4 Failure-mode reference table

| Symptom | Root cause | Where it surfaces | Fix |
|---|---|---|---|
| `generate` rule creates nothing, policy `Ready` | Background controller lacks `create` (and/or lifecycle verbs) on target kind | `UpdateRequest` `Failed`; background-controller log `forbidden` | Aggregate a ClusterRole to **background** (§4.1) or namespaced Role (§4.3) |
| `mutate-existing` is a no-op | Background controller lacks `update`/`get`/`list` on target | Same as above | Aggregate to **background** (§4.2) |
| Generated object drifts / isn't cleaned up | `synchronize: true` but missing `update`/`delete` | background-controller log | Add lifecycle verbs to the role |
| `CleanupPolicy` leaves resources behind | Cleanup controller lacks `delete`/`list` on target | cleanup-controller log | Aggregate to **cleanup** (§4.4) |
| Ingress/Pod admission suddenly blocked | `apiCall` context fails, `failurePolicy: Fail` | admission-controller log; webhook denial to user | Aggregate read verbs to **admission** (§4.5) |
| Aggregated role rules never appear | Wrong label key, or `true` bool vs `"true"` string, or missing `part-of` | `kubectl get clusterrole kyverno:<c>` shows no new rules | Fix the label exactly (§5.2) |
| Human can't edit namespaced `Policy` | CRD-to-`admin` aggregation removed/overridden | `kubectl auth can-i` as the user | Restore `rbac.authorization.k8s.io/aggregate-to-admin` label |

---

## 6. Security hardening: RBAC is the privilege-escalation surface

Kyverno's controllers run continuously with whatever you aggregate onto them, and their actions are triggered by *ordinary resource events*. That makes over-permissioning a real escalation path, not a theoretical one:

- **Never** grant the background controller broad `create`/`update` on `secrets`, `serviceaccounts`, `roles`, `rolebindings`, `clusterroles`, or `clusterrolebindings` in a multi-tenant cluster. If a policy that generates such objects can be triggered by a low-privilege user's action (e.g. creating a namespace or a `ConfigMap`), that user has effectively borrowed the controller's power. Scope these with **namespaced `RoleBinding`s** (§4.3) and audit them explicitly.
- **Never** aggregate a `*/*/*` wildcard role. It reverses the entire point of the 1.10 split-controller least-privilege redesign and turns Kyverno back into a cluster-admin-equivalent daemon. Audit for it: `kubectl auth can-i --list --as=system:serviceaccount:kyverno:kyverno-background-controller` should never read like `cluster-admin`.
- **Control who may author policies.** Because `kyverno:rbac:admin:policies` aggregates namespaced `Policy` management into the built-in `admin` role, any namespace admin can write a `Policy`. Combined with a generous controller grant, that is an escalation vector. Review which humans hold `admin` and whether the controller's permissions on sensitive kinds are namespace-bounded.
- **Match `failurePolicy` to the context grant.** A `context` that needs RBAC plus `failurePolicy: Fail` means a missing grant is a cluster-wide outage for that resource kind; a missing grant plus `Ignore` means a silent security bypass. Decide deliberately, and verify the admission SA has the read permission before shipping.
- **Diff the shipped roles after every upgrade.** `helm upgrade` re-renders `:core` and the shells; your *aggregated add-on* roles are untouched (that's the point), but confirm the label contract hasn't changed by re-running the §5.2 check post-upgrade.

---

## 7. References

- Kyverno — Installation, *Roles and Permissions / Customizing Permissions*: <https://kyverno.io/docs/installation/customization/>
- Kyverno — *Generate Rules* (background controller RBAC, `synchronize`, `generateExisting`): <https://kyverno.io/docs/writing-policies/generate/>
- Kyverno — *Mutate Existing Resources* (`targets`, `mutateExistingOnPolicyUpdate`): <https://kyverno.io/docs/writing-policies/mutate/#mutate-existing-resources>
- Kyverno — *Cleanup Policies* (`ClusterCleanupPolicy`, cleanup controller): <https://kyverno.io/docs/writing-policies/cleanup/>
- Kyverno — *High Availability & Architecture* (the four controllers and their ServiceAccounts): <https://kyverno.io/docs/high-availability/>
- Kyverno — *Troubleshooting* (`UpdateRequest` states, controller logs): <https://kyverno.io/docs/troubleshooting/>
- Kubernetes — *Using RBAC Authorization → Aggregated ClusterRoles*: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles>
- Kubernetes — *Authenticating → ServiceAccount user names & impersonation* (`system:serviceaccount:<ns>:<name>`): <https://kubernetes.io/docs/reference/access-authn-authz/authentication/#service-account-tokens>
- CNCF — *Kyverno Certified Associate (KCA) Curriculum*: <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>