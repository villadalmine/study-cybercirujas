# Common Policy Settings for Kyverno Rules

> **KCA Exam Domain 4 — Applying Kyverno Policies · Topic 4.3 (weight 3.33)**
> Target Kyverno line: **1.11 → 1.13**. Where a field moved or was deprecated across that range, it is flagged inline. If your exam image pins an older build, prefer the policy-level location; the modern per-rule location is the strategic default going forward.

---

## 1. The production problem: a policy is a webhook, and its *settings* are the blast-radius controls

A Kyverno `ClusterPolicy` / `Policy` is not a passive linter. When you `kubectl apply` a policy, Kyverno's controller **reconfigures the cluster's admission path** by writing entries into `ValidatingWebhookConfiguration` and `MutatingWebhookConfiguration` objects. From that instant, a slice of every `CREATE`/`UPDATE`/`DELETE` on the matched kinds is round-tripped through the Kyverno admission controller Pod *before* the object is persisted to etcd.

That is the architectural stakes of "common policy settings." They are the knobs that decide:

- **Does a Kyverno outage take the API server down with it?** → `failurePolicy` + `webhookTimeoutSeconds`
- **Does the policy block deployments, or just report on them?** → `validationFailureAction` / `validate.failureAction`
- **Does the policy scan the 40,000 objects already in etcd, or only new admissions?** → `background`
- **Do you evaluate all rules or short-circuit on the first?** → `applyRules`
- **Does a `Deployment` author need to know Kyverno inspects `Pods`?** → autogen (`pod-policies.kyverno.io/autogen-controllers`)

An SRE who ships a policy with `failurePolicy: Fail` (the default), a tight webhook timeout, and a single-replica Kyverno install has coupled the availability of *every workload create* to the availability of one Pod. This topic is fundamentally about **decoupling correctness from availability**, and about scoping a policy tightly enough that it never fires where it shouldn't.

These settings split into two altitudes, and the exam expects you to know which lives where:

| Altitude | Where | Examples |
|---|---|---|
| **Policy-wide** (`spec.*`) | Applies to all rules in the policy | `background`, `admission`, `applyRules`, `failurePolicy`, `webhookTimeoutSeconds`, `schemaValidation`, `webhookConfiguration`, `generateExisting`, `mutateExistingOnPolicyUpdate` |
| **Per-rule** (`spec.rules[].*`) | Scopes / tunes one rule | `match`, `exclude`, `preconditions`, `context`, and (modern) `validate.failureAction`, `validate.failureActionOverrides`, `validate.allowExistingViolations` |

---

## 2. The settings, one by one — mechanics and trade-offs

### 2.1 `validationFailureAction` — Audit vs Enforce

The single most consequential setting on a validate policy. It decides whether a violation **blocks** the request or is merely **recorded** in a policy report.

> **Version note.** Through Kyverno 1.10 this lived at `spec.validationFailureAction` (values `audit`/`enforce`, later capitalized `Audit`/`Enforce`). Since **1.11** it is deprecated at the spec level and moved **per-rule** to `spec.rules[].validate.failureAction`, with per-namespace overrides at `spec.rules[].validate.failureActionOverrides`. Both forms still parse in 1.11–1.13; the CRD emits a deprecation warning for the spec-level form.

| | `Audit` (default) | `Enforce` |
|---|---|---|
| Request on violation | **Admitted**, violation written to `PolicyReport` | **Denied** at admission |
| Webhook wired for validate | Yes (still on the admission path) | Yes |
| Blast radius of a bad policy | Low — nothing is blocked | High — can wedge all deploys |
| Right for | New policies, measuring drift, canary/soak | Hard requirements after soak |
| Observability | `kubectl get polr,cpolr -A` | Denial message returned to `kubectl` |

**Production pattern:** ship every new hard requirement as `Audit`, watch `PolicyReport` `fail` counts across a full deploy cycle, *then* promote to `Enforce`. Use `failureActionOverrides` to keep `dev`/`sandbox` namespaces in `Audit` permanently while `prod` enforces.

### 2.2 `failurePolicy` — Fail vs Ignore (the availability knob)

`failurePolicy` is passed straight through to the Kubernetes webhook object. It governs what the **API server** does when the Kyverno webhook errors, times out, or is unreachable.

| | `Fail` (default) | `Ignore` |
|---|---|---|
| Kyverno down / timing out | Matched requests are **rejected** by the API server | Matched requests are **admitted** un-checked |
| Guarantees | Policy is fail-closed (no bypass) | Availability of the workload path |
| Risk | Kyverno outage ⇒ cluster-wide admission outage | Silent policy bypass during outages |
| Pairs with | Enforce security invariants, HA Kyverno (≥3 replicas) | Best-effort / audit policies |

**Trade-off in one sentence:** `Fail` protects the *invariant*; `Ignore` protects the *cluster's ability to deploy*. For a genuinely security-critical `Enforce` policy you generally want `Fail` **plus** a highly-available Kyverno (`replicaCount: 3`, PDB, anti-affinity) so the fail-closed posture doesn't become a self-inflicted outage.

### 2.3 `webhookTimeoutSeconds`

Range **1–30**, default **10**. This is the API server's patience for a single Kyverno response. Combined with `failurePolicy: Fail`, a too-tight timeout under load turns latency into outright request rejections. Raise it for policies that do expensive work (`context` API calls, image verification), but never above what your API-server request budget tolerates — a slow webhook adds latency to *every* matched admission.

### 2.4 `background`

Default **true**. Controls whether the policy participates in **background scans** — Kyverno's periodic reconciliation of resources *already in etcd*, independent of admission.

| | `background: true` (default) | `background: false` |
|---|---|---|
| Evaluates pre-existing resources | Yes (reports on the whole cluster) | No — admission only |
| May use admission-only context | **No** | Yes |
| Reports reflect current state of old objects | Yes | Only newly admitted objects appear |

**The gotcha the exam loves:** background scans have **no admission request**, so any rule that references admission-only variables — `request.userInfo`, `request.roles`, `request.clusterRoles`, `serviceAccountName`, `request.operation` — is **incompatible with `background: true`**. Kyverno rejects such a policy at creation with a validation error. The fix is `background: false`.

### 2.5 `admission`

Default **true**. Whether the policy is evaluated on the admission path at all. Set `false` to build a **report-only / background-scan-only** policy that never touches the webhook (zero admission latency, pure drift reporting). Setting both `admission: false` and `background: false` produces a policy that does nothing.

### 2.6 `applyRules` — All vs One

| | `All` (default) | `One` |
|---|---|---|
| Rules evaluated | Every matching rule in `spec.rules` | Stops after the **first** matching rule succeeds |
| Use case | Independent checks | Ordered fallbacks / mutual-exclusion (e.g. first matching mutate wins) |

### 2.7 `schemaValidation`

Default **true**. Kyverno validates your `pattern`/`overlay` against the target's OpenAPI schema at policy-apply time, catching typo'd field paths early. Disable only for CRDs whose schema Kyverno can't resolve.

### 2.8 `webhookConfiguration` (unified, 1.12+)

Newer Kyverno consolidates the webhook knobs — and adds **CEL `matchConditions`** so the API server itself can pre-filter requests *before* they ever reach Kyverno (cutting load and avoiding self-loops like the kubelet or Kyverno's own SA):

```yaml
spec:
  webhookConfiguration:
    failurePolicy: Ignore
    timeoutSeconds: 15
    matchConditions:
      - name: exclude-kubelet-updates
        expression: "request.userInfo.username != 'system:node:*'"
```

> Prefer `spec.webhookConfiguration.failurePolicy`/`timeoutSeconds` on 1.12+; the top-level `spec.failurePolicy`/`spec.webhookTimeoutSeconds` remain for compatibility.

### 2.9 `generateExisting` / `mutateExistingOnPolicyUpdate`

By default `generate` and `mutate` rules act only on **future** admissions. These two booleans opt the policy into acting on resources that **already exist** at policy apply/update time — e.g. injecting a label into every existing Namespace, or cloning a ConfigMap into all current namespaces. Powerful and dangerous: a `mutateExistingOnPolicyUpdate: true` policy patches live production objects the moment you apply it. Related: `validate.allowExistingViolations` (default `true`) decides whether pre-existing violators are tolerated rather than reported as blocking errors during background/mutate-existing.

---

## 3. Per-rule common settings: `match`, `exclude`, `preconditions`, autogen

### 3.1 `match` / `exclude` — the resource selector

Every rule needs a `match`; `exclude` narrows it. Both take `any` (logical OR across blocks) or `all` (logical AND). This is where you scope the blast radius precisely.

```yaml
match:
  any:
    - resources:
        kinds: [Pod]
        namespaceSelector:
          matchExpressions:
            - key: kubernetes.io/metadata.name
              operator: NotIn
              values: [kube-system, kyverno]
exclude:
  any:
    - subjects:
        - kind: ServiceAccount
          name: system:serviceaccount:kyverno:kyverno-admission-controller
    - clusterRoles: [cluster-admin]
```

**Always exclude system namespaces** (`kube-system`, `kube-node-lease`, Kyverno's own namespace) from `Enforce` policies. A policy that blocks Pods in `kube-system` can prevent control-plane components from scheduling — a classic self-inflicted cluster wedge.

### 3.2 `preconditions`

Fine-grained gating *after* `match`, evaluated against JMESPath (or CEL) over the admission request. Use them for conditions the coarse selector can't express — "only when `spec.hostNetwork == true`", "only on `CREATE`".

```yaml
preconditions:
  all:
    - key: "{{ request.operation || 'BACKGROUND' }}"
      operator: AnyIn
      value: [CREATE, UPDATE]
```

> The `|| 'BACKGROUND'` idiom is essential when `background: true`: `request.operation` is empty during scans, so this default keeps the precondition evaluable in both contexts.

### 3.3 Autogen for Pod controllers

When a rule matches `Pod`, Kyverno **auto-generates** equivalent rules for `Deployment`, `StatefulSet`, `DaemonSet`, `Job`, `CronJob`, `ReplicaSet`, `ReplicationController` — so the check fires at the *controller* level, where the author actually gets the feedback. Control it with the annotation:

```yaml
metadata:
  annotations:
    pod-policies.kyverno.io/autogen-controllers: "Deployment,StatefulSet,Job"   # subset
    # pod-policies.kyverno.io/autogen-controllers: "none"                        # disable
```

Autogen is why a `Pod`-matching `Enforce` policy blocks a bad `Deployment` at apply time rather than silently failing later at Pod creation.

---

## 4. A complete, production-grade ClusterPolicy exercising the common settings

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
  annotations:
    policies.kyverno.io/title: Require Team Label
    policies.kyverno.io/category: Governance
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet,DaemonSet,Job,CronJob
spec:
  # ---- policy-wide common settings ----
  admission: true                 # evaluate on the admission path
  background: true                # also scan pre-existing resources
  applyRules: All                 # evaluate every matching rule
  schemaValidation: true          # validate patterns against target schema
  webhookConfiguration:
    failurePolicy: Fail           # fail-closed: no bypass on Kyverno outage
    timeoutSeconds: 10            # API server patience for the webhook
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-node-lease
                - kyverno
      preconditions:
        all:
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
      validate:
        failureAction: Enforce                     # per-rule (1.11+) action
        failureActionOverrides:
          - action: Audit                          # keep non-prod in report mode
            namespaces:
              - "dev-*"
              - "sandbox-*"
        allowExistingViolations: true              # don't error on legacy Pods
        message: >-
          The label 'team' is required on all Pods so ownership and cost
          allocation can be attributed. Found: {{ request.object.metadata.labels || '{}' }}
        pattern:
          metadata:
            labels:
              team: "?*"                            # must be present and non-empty
```

**Namespaced equivalent** (same spec, scoped to one namespace — note `kind: Policy`):

```yaml
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: require-team-label
  namespace: payments
spec:
  background: true
  webhookConfiguration:
    failurePolicy: Fail
    timeoutSeconds: 10
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        failureAction: Enforce
        message: "The label 'team' is required."
        pattern:
          metadata:
            labels:
              team: "?*"
```

---

## 5. CLI: apply, inspect, and prove the settings took effect

```console
$ kubectl apply -f require-team-label.yaml
clusterpolicy.kyverno.io/require-team-label created

$ kubectl get cpol
NAME                 ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
require-team-label   true        true         Enforce           True    9s    Ready
```

The `READY=True` / `MESSAGE=Ready` columns confirm the controller finished wiring the webhook. Verify the webhook object Kyverno actually wrote:

```console
$ kubectl get validatingwebhookconfigurations | grep kyverno
kyverno-resource-validating-webhook-cfg    2    41s

$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{range .webhooks[*]}{.name}{"  failurePolicy="}{.failurePolicy}{"  timeout="}{.timeoutSeconds}{"\n"}{end}'
validate.kyverno.svc-fail    failurePolicy=Fail    timeout=10
validate.kyverno.svc-ignore  failurePolicy=Ignore  timeout=10
```

> Kyverno maintains **two** webhook entries — `...svc-fail` and `...svc-ignore` — and routes each rule to the one matching its `failurePolicy`. Seeing your kind under `svc-fail` proves `failurePolicy: Fail` is live.

**Enforce fires** — the denial message is returned straight to the client:

```console
$ kubectl run nginx --image=nginx -n payments
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/payments/nginx was blocked due to the following policies

require-team-label:
  check-team-label: 'validation error: The label ''team'' is required on all Pods
    so ownership and cost allocation can be attributed. Found: {}. rule check-team-label
    failed at path /metadata/labels/team/'
```

**Autogen proves itself** — the same policy blocks a `Deployment`, because Kyverno auto-generated a Deployment rule:

```console
$ kubectl create deployment web --image=nginx -n payments
error: failed to create deployment: admission webhook "validate.kyverno.svc-fail"
denied the request:

resource Deployment/payments/web was blocked due to the following policies

require-team-label:
  autogen-check-team-label: 'validation error: The label ''team'' is required ...'
```

**The override works** — the same object in a `dev-*` namespace is admitted and only *reported*:

```console
$ kubectl run nginx --image=nginx -n dev-alice
pod/nginx created

$ kubectl get polr -n dev-alice
NAME                                   KIND   NAME    PASS   FAIL   WARN   ERROR   SKIP   AGE
5f0b...-require-team-label             Pod    nginx   0      1      0      0       0      6s
```

**Inspect the generated report entry:**

```console
$ kubectl get polr -n dev-alice -o jsonpath='{.items[0].results[0]}' | jq
{
  "message": "validation error: The label 'team' is required ...",
  "policy": "require-team-label",
  "rule": "check-team-label",
  "result": "fail",
  "scored": true,
  "severity": "medium",
  "source": "kyverno"
}
```

**Kyverno CLI — validate settings offline, before they ever touch the cluster** (this is the fail-fast the exam rewards):

```console
$ kyverno apply require-team-label.yaml --resource bad-pod.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy require-team-label -> resource default/Pod/nginx failed:
1. check-team-label: validation error: The label 'team' is required ...

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

---

## 6. Verification & failure diagnosis

**A) "My policy applied but nothing is blocked."** Walk the settings ladder:

```console
# 1) Is the action actually Enforce (not the Audit default)?
$ kubectl get cpol require-team-label -o jsonpath='{.spec.rules[0].validate.failureAction}{"\n"}'
Enforce

# 2) Is the webhook wired for the right kind?
$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[0].rules[*].resources}{"\n"}'
["pods","deployments","statefulsets", ... ]

# 3) Is the target namespace being excluded/overridden?
$ kubectl get cpol require-team-label -o jsonpath='{.spec.rules[0].validate.failureActionOverrides}{"\n"}'
```

Most common cause: the rule is still at the `Audit` default, or the namespace matches a `failureActionOverrides`/`exclude` block.

**B) "Policy won't create — admission-only variable error."**

```console
$ kubectl apply -f uses-userinfo.yaml
The ClusterPolicy "check-creator" is invalid: spec.rules[0]: variable
'request.userInfo.username' is not allowed in background mode; set spec.background=false
```

Fix: `spec.background: false` (that rule can only run at admission anyway).

**C) "Kyverno pods are down and now no Pods can be created."** This is `failurePolicy: Fail` doing exactly what you told it. Confirm and, if it's an emergency, flip to `Ignore` (or scale Kyverno back up):

```console
$ kubectl get pods -n kyverno
NAME                                         READY   STATUS             RESTARTS   AGE
kyverno-admission-controller-7d8...          0/1     CrashLoopBackOff   6          4m

$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[*].failurePolicy}{"\n"}'
Fail Ignore
```

Lesson: pair `Fail` with **HA Kyverno** (`replicaCount: 3`, PodDisruptionBudget, node anti-affinity) so fail-closed never means fail-cluster.

**D) "Slow admissions / intermittent denials under load."** The webhook is timing out; with `Fail`, timeouts become rejections. Inspect and raise the budget:

```console
$ kubectl get cpol require-team-label -o jsonpath='{.spec.webhookConfiguration.timeoutSeconds}{"\n"}'
10
$ kubectl logs -n kyverno deploy/kyverno-admission-controller | grep -i "webhook.*timeout"
```

**E) Confirm background scans are running** (for `Audit`/report policies):

```console
$ kubectl get cpolr,polr -A
NAMESPACE   NAME                              PASS   FAIL   WARN   ERROR   SKIP   AGE
default     polr-ns-default                   118    3      0      0       2      12m
            cpolr                              402    9      0      0       5      12m
```

Stale or absent reports for old objects ⇒ check `spec.background` is `true` and the rule doesn't reference admission-only context.

---

## 7. Quick reference — the common settings at a glance

| Setting | Location | Default | Controls |
|---|---|---|---|
| `validationFailureAction` / `validate.failureAction` | `spec` (dep.) → `rules[].validate` (1.11+) | `Audit` | Block vs report on violation |
| `validationFailureActionOverrides` / `validate.failureActionOverrides` | same | – | Per-namespace action overrides |
| `failurePolicy` | `spec` / `spec.webhookConfiguration` | `Fail` | API-server behavior on webhook error/timeout |
| `webhookTimeoutSeconds` / `webhookConfiguration.timeoutSeconds` | `spec` | `10` (1–30) | Webhook response budget |
| `background` | `spec` | `true` | Participate in background scans of existing resources |
| `admission` | `spec` | `true` | Evaluate on the admission path |
| `applyRules` | `spec` | `All` | Evaluate all rules vs stop after first match |
| `schemaValidation` | `spec` | `true` | Validate patterns against target schema |
| `generateExisting` | `spec` | `false` | Apply generate rules to pre-existing resources |
| `mutateExistingOnPolicyUpdate` | `spec` | `false` | Mutate existing resources on policy update |
| `match` / `exclude` | `rules[]` | – | Resource selection (`any`/`all`) |
| `preconditions` | `rules[]` | – | Fine-grained JMESPath/CEL gating |
| `pod-policies.kyverno.io/autogen-controllers` | `metadata.annotations` | all controllers | Autogen scope for Pod-matching rules |

---

## Referencias

- Kyverno — Common / Policy Settings: https://kyverno.io/docs/writing-policies/policy-settings/
- Kyverno — Writing Policies (overview): https://kyverno.io/docs/writing-policies/
- Kyverno — Selecting Resources (`match`/`exclude`): https://kyverno.io/docs/writing-policies/match-exclude/
- Kyverno — Preconditions: https://kyverno.io/docs/writing-policies/preconditions/
- Kyverno — Auto-Gen Rules for Pod Controllers: https://kyverno.io/docs/writing-policies/autogen/
- Kyverno — Validate rules (`failureAction`, patterns): https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Mutate / Generate existing resources: https://kyverno.io/docs/writing-policies/mutate/ · https://kyverno.io/docs/writing-policies/generate/
- Kyverno CLI (`apply`, `test`): https://kyverno.io/docs/kyverno-cli/
- Kubernetes — Dynamic Admission Control (`failurePolicy`, `timeoutSeconds`, `matchConditions`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- CNCF KCA Curriculum: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf