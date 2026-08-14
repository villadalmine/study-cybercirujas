# 5.1 Validation Rules

> **Domain 5 — Validation · Exam weight ≈ 2.91**
> Kyverno Certified Associate (KCA). Reference syllabus: CNCF *KCA_Curriculum.pdf*.

Validation is the discipline of asserting that a Kubernetes resource *conforms to policy* before it is persisted to `etcd`. In Kyverno this is expressed with the `validate` rule — the single most examined and most operationally consequential rule type, because it is the one that can *reject* a request and therefore the one that can take an entire delivery pipeline offline if you get its availability semantics wrong.

---

## 1. Motivation and the production architectural problem

### 1.1 What validation actually enforces, and where RBAC stops

RBAC answers *"who may perform which verb on which resource"*. It says nothing about the **shape** of the object. A user with `create pods` permission can legitimately submit a Pod that:

- runs as UID 0 with `privileged: true` and `hostPID: true`,
- pulls `nginx:latest` from an untrusted public registry,
- omits the `team`/`cost-center` labels your chargeback system depends on,
- requests no CPU/memory limits and starves a node.

None of that is an RBAC violation — the verb was `create`, the resource was `pods`, and the user was authorized. The missing control plane is **admission control**: a synchronous decision point, *inside the API request path*, that inspects the fully-formed object and either admits or rejects it. That is precisely the seam Kyverno's `validate` rule occupies.

### 1.2 The request path — where a validate rule runs

Every mutating write to the API server passes through this pipeline:

```
kubectl / controller
      │  (1) AuthN
      ▼
kube-apiserver ──► (2) AuthZ (RBAC) ──► (3) Mutating admission webhooks ──► (4) Schema/OpenAPI validation
                                                        │                              │
                                              (Kyverno mutate rules)                   ▼
                                                                        (5) Validating admission webhooks
                                                                                │
                                                                   ┌────────────┴────────────┐
                                                                   │  Kyverno validating      │
                                                                   │  webhook (this rule)     │
                                                                   └────────────┬────────────┘
                                                                        allowed: true / false
                                                                                │
                                                                          (6) etcd persist
```

Kyverno registers a **`ValidatingWebhookConfiguration`** with the API server. When a `validate` rule with `Enforce` action fails, the webhook returns `allowed: false` and **the API server rejects the request synchronously** — the object never reaches `etcd`. This is *shift-left enforced at runtime*: the guardrail is not a linter that a developer can ignore, it is a hard gate every controller and human must pass.

### 1.3 The architectural trade-off nobody escapes: fail-open vs fail-closed

Because the validate rule sits *in the critical write path*, the Kyverno admission controller becomes a **dependency of every write to the cluster** for the resource kinds it matches. This creates the central production tension of Domain 5:

- If Kyverno is unreachable and the webhook `failurePolicy` is **`Fail`** (fail-closed, the Kubernetes default), then *all matching writes across the cluster are rejected* until Kyverno recovers — including writes from core controllers that reconcile Deployments into Pods. A crashlooping Kyverno with `Fail` can wedge the cluster.
- If `failurePolicy` is **`Ignore`** (fail-open), an outage of Kyverno silently lets *non-compliant objects through unvalidated* — a security and compliance gap that leaves no admission record.

There is no free choice here; this is the reason production Kyverno is run **highly available (≥3 admission-controller replicas)**, with a bounded `webhookTimeoutSeconds`, and with `namespaceSelector`/`objectSelector` scoping so the blast radius of a webhook outage is as small as the policy set allows. Sections 7 and 8 return to this.

---

## 2. Anatomy of a `validate` rule

A validation policy is a `ClusterPolicy` (cluster-scoped) or `Policy` (namespaced). Its `spec.rules[]` each declare a `match`/`exclude` selector, optional `preconditions`, and exactly one action block — here, `validate`.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy          # or kind: Policy (namespaced)
metadata:
  name: require-labels
spec:
  # Cluster-wide default action for this policy's validate rules.
  # Values: Enforce | Audit.  (Deprecated at spec-level in favour of the
  # per-rule validate.failureAction in Kyverno 1.12+, still widely used.)
  validationFailureAction: Enforce
  # Enables periodic background scanning of PRE-EXISTING resources into reports.
  background: true
  # Webhook behaviour if Kyverno itself is unreachable: Fail (default) | Ignore.
  failurePolicy: Fail
  rules:
  - name: check-team
    match:
      any:
      - resources:
          kinds:
          - Pod
    # Optional gate evaluated BEFORE validate. If false, the rule is SKIPPED
    # (not failed). Uses JMESPath conditions.
    preconditions:
      all:
      - key: "{{ request.operation || 'BACKGROUND' }}"
        operator: In
        value: [CREATE, UPDATE]
    validate:
      # Shown to the user on rejection and recorded in the policy report.
      message: "The label 'team' is required on all Pods."
      # Exactly ONE validation method per validate block:
      pattern:                 # overlay pattern (this example)
        metadata:
          labels:
            team: "?*"
```

### The validation methods (choose exactly one per `validate` block)

| Method | Field | What it does |
|---|---|---|
| **Overlay pattern** | `pattern` | Resource must structurally match a declarative overlay (with anchors, wildcards, operators). |
| **Any-of patterns** | `anyPattern` | Resource must match **at least one** overlay in a list — models "either shape A or shape B". |
| **Deny with conditions** | `deny.conditions` | Imperative boolean logic over `request`/computed values with typed operators (`GreaterThan`, `In`, …). |
| **CEL expressions** | `cel.expressions` | Common Expression Language, aligned with Kubernetes `ValidatingAdmissionPolicy`. |
| **Pod Security** | `podSecurity` | Applies Pod Security Standards (`baseline`/`restricted`) with per-control, per-image exclusions. |
| **Foreach** | `foreach` | Iterates a list (e.g. containers) and applies `pattern`/`deny` to each element. |
| **Manifest integrity** | `manifests` | Verifies a resource's YAML signature (`cosign`/`sigstore`) — integrity of the manifest itself. |

---

## 3. Choosing a validation method — technical trade-offs

| Method | Cross-field / list logic | External data (API/ConfigMap) | Readability | Best when… | Weakness |
|---|---|---|---|---|---|
| `pattern` | Limited (anchors express *conditional* logic) | No | **High** — reads like the target YAML | Structural shape assertions ("this field must exist / equal X") | Awkward for arithmetic or "count > N" |
| `anyPattern` | Yes (disjunction of shapes) | No | Medium | Multiple valid configurations ("A **or** B is acceptable") | Verbose; failure message must enumerate all shapes |
| `deny` + conditions | **Yes** — full boolean `any`/`all` | **Yes** (via `context`) | Medium | Imperative rules: thresholds, set membership, request metadata | Logic scattered across `key/operator/value` triples |
| `cel` | **Yes** — expressions, `has()`, macros | Yes (`variables`, params) | Medium-High | Portability with native VAP, terse numeric/logical checks | Requires CEL fluency; some Kyverno context differs from VAP |
| `podSecurity` | N/A (PSS-defined) | No | **High** | Enforcing baseline/restricted with **granular exclusions** PSA can't express | Scoped to the PSS control set only |
| `foreach` | **Yes** — per-element | Yes | Medium | Per-container/volume checks with a clear message per element | More verbose than a single pattern |

### 3.1 Kyverno `validate` vs. the alternatives (the architectural comparison)

| Dimension | Kyverno `validate` | OPA Gatekeeper (Rego) | Native `ValidatingAdmissionPolicy` (VAP) | Pod Security Admission (PSA) |
|---|---|---|---|---|
| Policy language | YAML overlays + CEL + JMESPath | Rego (separate DSL) | CEL only | Fixed 3 levels (privileged/baseline/restricted) |
| Runs as | External webhook | External webhook | **In-process** in kube-apiserver | In-process |
| Learning curve | Low (YAML) → medium (CEL) | High (Rego) | Medium (CEL) | Trivial |
| Availability risk | Webhook is a write-path dependency | Same | **None** (no external hop) | None |
| Reporting | PolicyReport CRDs, background scan | Constraint status, audit | Limited | Warnings/audit annotations |
| Granularity | Per-control exclusions, wildcards, external data | Very high | Expression-scoped | Namespace-label scoped, all-or-nothing per level |
| CNCF status | Graduated (Kyverno) | Graduated (OPA) | Kubernetes core (GA 1.30) | Kubernetes core |

**Reading of the table:** VAP is cheapest for pure-CEL, single-cluster field checks because it runs *inside* the API server (no availability tax). Kyverno wins when you need external data, granular Pod Security exclusions, unified reporting, and the *same* engine that also mutates and generates. PSA is the floor you should always enable; Kyverno's `podSecurity` subrule is how you keep PSS while carving out narrow, auditable exceptions PSA cannot express.

---

## 4. Pattern anchors — the declarative logic of `pattern`

Anchors are the mechanism that turns a static overlay into conditional logic. This table is high-yield for the exam.

| Anchor | Syntax | Semantics |
|---|---|---|
| **Conditional** | `(field)` | *If* the anchored field matches its value, *then* the sibling non-anchored fields must also match. If it doesn't match, the block is **skipped (pass)**. → "if-then". |
| **Equality** | `=(field)` | If the field **is present**, it must equal the value. (Asserts value on that specific tag.) |
| **Existence** | `^(field)` | On a **list**: at least **one** element must satisfy the pattern. |
| **Negation** | `X(field)` | The field **must not be present** at all (regardless of value). |
| **Global** | `<(field)` | Global condition — if it matches anywhere, the pattern is applied. |

**Wildcards & operators inside pattern values:** `*` = zero-or-more chars, `?` = exactly one char (so `"?*"` = "non-empty / at least one char"). Value operators: `>`, `<`, `>=`, `<=` (numeric), `!` (not), `|` (OR), `&` (AND). Example: `runAsUser: ">0"`, `image: "!*:latest"`.

**Worked conditional-anchor example** — "containers using the `:latest` tag must set `imagePullPolicy: Always`":

```yaml
    validate:
      message: "Containers pinned to ':latest' must set imagePullPolicy: Always."
      pattern:
        spec:
          containers:
          - (image): "*:latest"        # conditional: only for latest-tagged images…
            imagePullPolicy: Always    # …this sibling is enforced
```

**Equality-anchor example** — the canonical host-namespace guard:

```yaml
    validate:
      message: >-
        Sharing host namespaces is disallowed:
        hostNetwork, hostIPC and hostPID must be unset or false.
      pattern:
        spec:
          =(hostNetwork): "false"   # if present, must be false
          =(hostIPC): "false"
          =(hostPID): "false"
```

---

## 5. Complete, unabridged manifests

### 5.1 Required labels (pattern + `?*` wildcard)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
  annotations:
    policies.kyverno.io/title: Require team label
    policies.kyverno.io/category: Best Practices
    policies.kyverno.io/severity: medium
spec:
  validationFailureAction: Enforce
  background: true
  failurePolicy: Fail
  rules:
  - name: check-team
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "The label 'team' is required on all Pods."
      pattern:
        metadata:
          labels:
            team: "?*"          # must exist and be non-empty
```

### 5.2 `anyPattern` — "runAsNonRoot true OR non-zero runAsUser"

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-non-root
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: run-as-non-root
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: >-
        Pods must run as non-root: set securityContext.runAsNonRoot=true
        or a runAsUser greater than 0.
      anyPattern:
      - spec:
          securityContext:
            runAsNonRoot: true
      - spec:
          securityContext:
            =(runAsUser): ">0"    # if runAsUser is set, it must be > 0
```

### 5.3 `deny` with typed conditions — replica ceiling

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: deny-large-deployments
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: max-ten-replicas
    match:
      any:
      - resources:
          kinds:
          - Deployment
          - StatefulSet
    validate:
      message: "Workloads may not exceed 10 replicas in this cluster."
      deny:
        conditions:
          any:
          - key: "{{ request.object.spec.replicas }}"
            operator: GreaterThan
            value: 10
```

> **Operators available to `deny.conditions`:** `Equals`, `NotEquals`, `In`, `AnyIn`, `AllIn`, `NotIn`, `AnyNotIn`, `AllNotIn`, `GreaterThan`, `GreaterThanOrEquals`, `LessThan`, `LessThanOrEquals`, `DurationGreaterThan`, `DurationLessThan`.

### 5.4 CEL expressions (portable with native VAP)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: cel-replica-limit
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: max-replicas-cel
    match:
      any:
      - resources:
          kinds:
          - Deployment
    validate:
      cel:
        expressions:
          - expression: "object.spec.replicas <= 10"
            message: "Deployments may not exceed 10 replicas."
          - expression: >-
              has(object.spec.template.spec.containers) &&
              object.spec.template.spec.containers.all(c,
                has(c.resources) && has(c.resources.limits))
            message: "Every container must declare resource limits."
```

> CEL root variables mirror Kubernetes VAP: `object`, `oldObject`, `request`, `params`, `namespaceObject`, `variables`, `authorizer`.

### 5.5 `foreach` — per-container registry allow-list

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: validate-registries
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "Images must be pulled from registry.corp.example.com."
      foreach:
      - list: "request.object.spec.containers"
        pattern:
          image: "registry.corp.example.com/*"   # applied to each {{ element }}
      - list: "request.object.spec.initContainers"
        pattern:
          image: "registry.corp.example.com/*"
```

### 5.6 `podSecurity` subrule — PSS restricted with a scoped exclusion

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: psa-restricted-with-exceptions
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: restricted-with-legacy-exception
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      podSecurity:
        level: restricted
        version: latest
        exclude:
        - controlName: "Seccomp"                      # relax ONE control…
          images:
          - "registry.corp.example.com/legacy/*"      # …for ONE image prefix only
```

### 5.7 Progressive rollout — `validationFailureActionOverrides`

Audit everywhere, but **Enforce** in production namespaces. This is the standard safe-rollout pattern: observe fail counts in reports, then flip namespaces to Enforce.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels-progressive
spec:
  validationFailureAction: Audit          # default: report only
  validationFailureActionOverrides:
    - action: Enforce
      namespaces: ["prod-*"]              # hard-block in prod
    - action: Audit
      namespaces: ["dev-*", "staging-*"]  # report-only elsewhere
  background: true
  rules:
  - name: check-team
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "The label 'team' is required."
      pattern:
        metadata:
          labels:
            team: "?*"
```

---

## 6. CLI commands and real terminal output

### 6.1 Confirm the controller and policy are Ready

```console
$ kubectl -n kyverno get deploy
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller   3/3     3            3           14d
kyverno-background-controller  1/1     1            1           14d
kyverno-reports-controller     1/1     1            1           14d

$ kubectl apply -f require-labels.yaml
clusterpolicy.kyverno.io/require-labels created

$ kubectl get clusterpolicy
NAME             ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE    MESSAGE
require-labels   true        true         Enforce           True    2m3s   Ready
```

### 6.2 A violation is rejected synchronously (Enforce)

```console
$ cat nginx-bad.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: registry.corp.example.com/nginx:1.27

$ kubectl apply -f nginx-bad.yaml
Error from server: error when creating "nginx-bad.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource Pod/default/nginx was blocked due to the following policies

require-labels:
  check-team: 'validation error: The label ''team'' is required on all Pods.
    rule check-team failed at path /metadata/labels/team/'
```

> Note the webhook name suffix: `-fail` corresponds to `failurePolicy: Fail`; you would see `validate.kyverno.svc-ignore` for `Ignore`.

### 6.3 A conforming resource is admitted

```console
$ kubectl label --local -f nginx-bad.yaml team=payments -o yaml \
    | kubectl apply -f -
pod/nginx created
```

### 6.4 Inspect policy reports (Audit action & background scan)

```console
$ kubectl get policyreport -A
NAMESPACE   NAME                                   PASS   FAIL   WARN   ERROR   SKIP   AGE
default     e3b0c442-98fc-1c14-9afb-4c8996fb9242   0      1      0      0       0      3m

$ kubectl get policyreport -n default -o yaml | yq '.items[0].results[0]'
message: 'validation error: The label ''team'' is required on all Pods. ...'
policy: require-labels
rule: check-team
result: fail
scored: true
severity: medium
source: kyverno
```

### 6.5 Offline evaluation with the Kyverno CLI (no cluster needed)

```console
$ kyverno apply require-labels.yaml --resource nginx-bad.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy require-labels -> resource default/Pod/nginx failed:
1. check-team: validation error: The label 'team' is required on all Pods.
   rule check-team failed at path /metadata/labels/team/

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

### 6.6 Regression testing with `kyverno test`

```console
$ kyverno test .

Loading test  ( ./kyverno-test.yaml ) ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│───│────────────────│────────────│──────────────────────│────────│
│ ID│ POLICY         │ RULE       │ RESOURCE             │ RESULT │
│───│────────────────│────────────│──────────────────────│────────│
│ 1 │ require-labels │ check-team │ default/Pod/good     │ Pass   │
│ 2 │ require-labels │ check-team │ default/Pod/bad      │ Pass   │
│───│────────────────│────────────│──────────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

---

## 7. Enforce vs Audit and failurePolicy — the operational trade-off table

| Setting | Value | Admission behaviour on violation | Availability impact | Use when |
|---|---|---|---|---|
| `validationFailureAction` | `Audit` | Object **admitted**; violation written to PolicyReport | None | Rolling out a new policy; measuring blast radius |
| `validationFailureAction` | `Enforce` | Object **rejected** at admission | Webhook is now a hard write dependency | Policy proven safe; compliance gate |
| `failurePolicy` | `Fail` (default) | If Kyverno is **unreachable**, request is **rejected** | Fail-closed: Kyverno outage can wedge writes | Security-critical clusters with HA Kyverno |
| `failurePolicy` | `Ignore` | If Kyverno is unreachable, request is **admitted** unvalidated | Fail-open: silent policy gap during outage | Non-critical policies where availability > enforcement |
| `background` | `true` | Enables periodic report generation over existing resources | Extra controller load | You want drift visibility, not just admission-time |
| `webhookTimeoutSeconds` | 1–30 (default 10) | Bounds how long the API server waits on Kyverno | Lower = faster fail decision | Tuning tail latency of the write path |

**SRE guidance:** the safe production path is **Audit → observe reports → Enforce**, per-namespace via `validationFailureActionOverrides`, with **≥3 admission-controller replicas**, a **`namespaceSelector` excluding `kube-system`/`kyverno`**, and a deliberate, documented choice of `failurePolicy`. `Fail` + non-HA Kyverno is the classic self-inflicted outage.

---

## 8. Verification and failure diagnosis guide

When a validate rule "doesn't work," walk this ladder top-to-bottom — most incidents are resolved in the first four rungs.

**1. Is the policy loaded and Ready?**
```console
$ kubectl get cpol require-labels -o jsonpath='{.status.conditions}'
```
`READY=False` with a message means the policy failed schema/type-check; it is **not enforcing at all**.

**2. Does `match` actually select the resource?** The most common false conclusion is "the policy passed" when it was simply **skipped**. Check with the CLI, which prints `skip`:
```console
$ kyverno apply policy.yaml --resource obj.yaml
pass: 0, fail: 0, warn: 0, error: 0, skip: 1   # ← skipped, not enforced
```

**3. Autogen — the #1 "why is my Deployment ignored?" gotcha.** A rule matching **Pods** is *auto-expanded* by Kyverno to also cover Pod controllers (Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet). Confirm the generated rules exist:
```console
$ kubectl get cpol require-labels -o yaml | yq '.spec.rules[].name'
check-team
autogen-check-team
autogen-cronjob-check-team
```
If they are missing (e.g. you used `request.object.spec.containers` with a path that only exists on a bare Pod), autogen may have been suppressed — check the `pod-policies.kyverno.io/autogen-controllers` annotation.

**4. Is the action `Enforce` or `Audit` for *this* namespace?** A `validationFailureActionOverrides` entry may have downgraded the namespace to Audit — it will *report* a fail but *admit* the object. Verify the effective action:
```console
$ kubectl get cpol require-labels -o jsonpath='{.spec.validationFailureActionOverrides}'
```

**5. Did a `precondition` skip the rule?** Preconditions failing → skip (pass), silently. Background scans have **no `request.operation`**; the `{{ request.operation || 'BACKGROUND' }}` idiom is what keeps a rule from being skipped during background evaluation.

**6. Variable substitution / context failures.** A malformed `{{ ... }}` JMESPath, or an unreachable `context` API call, surfaces as `error` (not `fail`). Inspect controller logs and events:
```console
$ kubectl -n kyverno logs deploy/kyverno-admission-controller | grep -i "require-labels"
$ kubectl describe cpol require-labels | sed -n '/Events/,$p'
```

**7. Wildcard semantics.** `team: "*"` matches *even an empty or absent* value; you almost always want `"?*"` (≥1 char). This silently passes when you expected a fail.

**8. Is the webhook even being called?** If violations aren't blocked at all, the `ValidatingWebhookConfiguration` may be scoped away from the namespace:
```console
$ kubectl get validatingwebhookconfigurations | grep kyverno
$ kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
    -o yaml | yq '.webhooks[].namespaceSelector'
```

**9. Metrics for fleet-wide truth.** Don't reason from a single apply — read the counters:
```console
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
$ curl -s localhost:8000/metrics | grep kyverno_policy_results_total
kyverno_policy_results_total{policy_name="require-labels",rule_result="fail", ...} 42
kyverno_policy_results_total{policy_name="require-labels",rule_result="pass", ...} 918
```

**Quick failure-mode reference:**

| Symptom | Likely cause | Fix |
|---|---|---|
| Deployment allowed, bare Pod blocked | Autogen didn't cover controllers | Check `autogen-*` rules / annotation; match a shape autogen understands |
| Violation reported but not blocked | Action is `Audit` (or override) | Set `Enforce` for that namespace |
| Rule "passes" for everything | `match` doesn't select, or precondition skips | Test with `kyverno apply`; look for `skip` |
| Empty label passes | Used `"*"` not `"?*"` | Use `"?*"` for non-empty |
| Reports empty | `background: false` | Enable `background: true` |
| `result: error` in report | Bad JMESPath / failed `context` call | Fix variable path; check API permissions in logs |

---

## 9. References

- Kyverno — Validate rules: <https://kyverno.io/docs/writing-policies/validate/>
- Kyverno — Anchors (conditional, equality, existence, negation, global): <https://kyverno.io/docs/writing-policies/validate/#anchors>
- Kyverno — CEL expressions in validate: <https://kyverno.io/docs/writing-policies/validate/#cel-expressions>
- Kyverno — Pod Security subrule: <https://kyverno.io/docs/writing-policies/validate/#pod-security>
- Kyverno — Preconditions: <https://kyverno.io/docs/writing-policies/preconditions/>
- Kyverno — Match/Exclude selectors: <https://kyverno.io/docs/writing-policies/match-exclude/>
- Kyverno — Auto-generating rules for Pod controllers: <https://kyverno.io/docs/writing-policies/autogen/>
- Kyverno — Foreach declarations: <https://kyverno.io/docs/writing-policies/validate/#foreach>
- Kyverno — Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Kyverno — CLI (`apply`, `test`): <https://kyverno.io/docs/kyverno-cli/>
- Kyverno — Policy library (production examples): <https://kyverno.io/policies/>
- Kyverno — High availability & webhook configuration: <https://kyverno.io/docs/installation/high-availability/>
- Kubernetes — Dynamic Admission Control (`ValidatingWebhookConfiguration`, `failurePolicy`): <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- Kubernetes — Validating Admission Policy (native CEL): <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/>
- Kubernetes — Pod Security Admission: <https://kubernetes.io/docs/concepts/security/pod-security-admission/>
- CNCF — KCA curriculum: <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>