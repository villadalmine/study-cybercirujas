# Topic 5.11 — Common Expression Language (CEL)

> Exam weight: 2.91 · Domain 5 (Extensibility & Policy) · Profile: production SRE / Platform Architect

---

## 1. Motivation: the architectural problem CEL solves

Every Kubernetes control plane needs a way to say **"this object is not allowed"** or **"this field must satisfy this relationship"** *before* the object is persisted to etcd. Historically there were exactly two mechanisms, and both have structural costs:

1. **OpenAPI v3 schema validation** (`type`, `minimum`, `pattern`, `enum`, `required`). This validates *one field at a time* against a static constraint. It cannot express **cross-field invariants** (`minReplicas <= maxReplicas`), **transition rules** (`replicas can only grow`), or anything conditional. It is structurally incapable of relational logic.

2. **Admission webhooks** (`ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration`). These are arbitrarily powerful — you run Go (or anything) in a pod — but you pay for that power on every axis that matters in production:
   - **A network hop on the critical write path.** Every `CREATE`/`UPDATE` for matched resources becomes a synchronous HTTP call from `kube-apiserver` to your webhook Service. Latency, TLS handshakes, and timeouts now sit between the user and etcd.
   - **A new availability dependency.** With `failurePolicy: Fail`, if your webhook pod is down, *the API for that resource is down*. This is how a bad webhook takes out an entire cluster — including its own recovery path (you cannot `kubectl apply` the fix if the webhook blocks it).
   - **Operational surface.** Certificates (`caBundle` rotation), a Deployment, a Service, HPA, PodDisruptionBudgets, and an entire release lifecycle — for what is often a five-line `if` statement.
   - **No termination guarantee, no cost bound.** Arbitrary code can loop, allocate, or hang.

The **production architectural problem** is therefore: *how do you get relational, conditional, cross-field policy — the power of a webhook — without the latency, the availability dependency, the certificate machinery, and the unbounded execution?*

**CEL is the answer.** [Common Expression Language](https://github.com/google/cel-spec) is a small, **non-Turing-complete** expression language from Google. Its defining property is that it is **not a general-purpose language**: it has no loops, no unbounded recursion, and every program's execution cost can be **statically estimated before it runs**. That single property is what makes it safe to embed *inside* `kube-apiserver` and evaluate *in-process, per request*, with a guaranteed upper bound on cost and guaranteed termination.

Kubernetes embeds CEL in several subsystems:

| Subsystem | Field | GA in | What it validates |
|---|---|---|---|
| CRD schema | `x-kubernetes-validations` | v1.29 | Cross-field / transition rules on custom resources |
| `ValidatingAdmissionPolicy` (VAP) | `spec.validations[].expression` | v1.30 | In-process validating admission for *any* resource |
| `MutatingAdmissionPolicy` | `spec.mutations[]` | alpha (v1.32) | In-process mutation via CEL / JSON Patch |
| Admission webhooks | `webhooks[].matchConditions[].expression` | v1.30 | Narrow *which* requests reach a webhook (in-process pre-filter) |
| Structured auth | `AuthenticationConfiguration` claim mappings/validation | v1.30 (beta) | JWT claim → user mapping and validation |

The rest of this topic focuses on the two you will be examined on and will use daily: **CRD validation rules** and **`ValidatingAdmissionPolicy`**. They share the same CEL runtime, cost model, and diagnostic surface.

---

## 2. Technical comparisons and trade-offs

### 2.1 CEL admission (`ValidatingAdmissionPolicy`) vs. admission webhooks

| Dimension | `ValidatingAdmissionPolicy` (CEL) | `ValidatingWebhookConfiguration` |
|---|---|---|
| Execution location | **In-process** in `kube-apiserver` | Out-of-process HTTP `POST` to a Service |
| Added latency | Sub-millisecond (no network) | Network RTT + TLS + serialization; capped by `timeoutSeconds` |
| Availability impact | None — no extra component runs | Webhook pod becomes a SPOF; `failurePolicy: Fail` can brick the API |
| Language | CEL (bounded, guaranteed to terminate) | Arbitrary code (Go, Python, …) |
| Type safety | **Compile-time**, checked against the target schema | Runtime only — a typo fails on live traffic |
| Cost model | Statically estimated + runtime-budgeted | Unbounded; you own the timeout/scaling |
| External I/O (DBs, APIs) | **Impossible by design** | Allowed (and a common footgun) |
| Mutation | Only via `MutatingAdmissionPolicy` (alpha) | Yes (`MutatingWebhookConfiguration`) |
| Delivery | `kubectl apply` one object | Deployment + Service + TLS certs + CA rotation |
| Parameterization | Native `paramKind` / `paramRef` (a CRD as config) | Roll your own (ConfigMap, flags) |
| Reusable across clusters | Yes (pure declarative YAML) | Requires shipping an image |
| Ordering vs. webhooks | Runs **after** mutating webhooks, **before** validating webhooks (mutating→validating admission phase order applies) | — |

**Decision rule (SRE lens):** if the policy is a pure function of the object, the old object, the request, and static params — use a `ValidatingAdmissionPolicy`. Reach for a webhook **only** when you genuinely need to call out to the world (an external inventory system, an image signature service, a licensing API) or need mutation on a version older than the `MutatingAdmissionPolicy` alpha. Everything else is cheaper, safer, and more available as CEL.

### 2.2 CEL admission vs. external policy engines

| | VAP (CEL, in-tree) | OPA Gatekeeper (Rego) | Kyverno |
|---|---|---|---|
| Runtime | In `kube-apiserver` | Webhook pods | Webhook pods |
| Policy language | CEL | Rego | YAML (+ CEL, JMESPath) |
| Extra components to run | **None** | Gatekeeper controller + webhook | Kyverno controllers + webhook |
| Availability failure mode | Cannot take out the API | Webhook downtime → `failurePolicy` risk | Same |
| Mutation | Alpha (`MutatingAdmissionPolicy`) | Limited (assign/mutation CRDs) | Mature (mutate rules) |
| Generate/clone resources | No | No | Yes (generate rules) |
| Image verification / external data | No (no I/O) | Via external data providers | Yes (`verifyImages`, API calls) |
| Audit/background scanning of existing objects | Via audit action only | Yes (constraint status) | Yes (policy reports) |
| Learning cost | Low (CEL is small) | High (Rego is a paradigm shift) | Low–medium |

**Trade-off:** VAP is the correct *default* for validation because it removes an entire tier of infrastructure. Gatekeeper/Kyverno remain justified when you need **mutation, resource generation, image verification, external data, or org-wide policy reporting across pre-existing objects** — capabilities CEL admission deliberately does not have. Many platform teams now run a hybrid: VAP for the cheap validating cases, Kyverno for mutation/generation.

### 2.3 Where CEL runs, and what each surface can see

| Surface | Root variables available | Returns |
|---|---|---|
| CRD `x-kubernetes-validations` | `self`, `oldSelf` (transition rules only) | `bool` |
| VAP `validations[].expression` | `object`, `oldObject`, `request`, `params`, `namespaceObject`, `authorizer`, `variables` | `bool` |
| VAP `matchConditions[].expression` | same as above (minus `variables`) | `bool` |
| VAP `variables[].expression` | same (plus earlier `variables`) | `any` |
| VAP `messageExpression` | same | `string` |
| VAP `auditAnnotations[].valueExpression` | same | `string` or `null` |
| Webhook `matchConditions[].expression` | `object`, `oldObject`, `request`, `authorizer` | `bool` |

---

## 3. Complete manifests (uncut)

### 3.1 CRD with cross-field, format, and transition validation rules

Note the two subtleties SREs trip on: (a) a rule attached to a node binds `self` to *that node's value*, so cross-field logic lives on the **parent** node; (b) `oldSelf` is only available in **transition rules** and only when the old value exists.

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: crontabs.stable.example.com
spec:
  group: stable.example.com
  names:
    kind: CronTab
    plural: crontabs
    singular: crontab
    shortNames: [ct]
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [minReplicas, maxReplicas, replicas, schedule]
              # Cross-field invariants live on the parent object node,
              # because only here does `self` see all sibling fields.
              x-kubernetes-validations:
                - rule: "self.minReplicas <= self.maxReplicas"
                  message: "minReplicas must not exceed maxReplicas"
                - rule: "self.replicas >= self.minReplicas && self.replicas <= self.maxReplicas"
                  messageExpression: >-
                    'replicas (' + string(self.replicas) +
                    ') must be within [' + string(self.minReplicas) +
                    ', ' + string(self.maxReplicas) + ']'
                # Conditional rule: image pull policy required only for prod tier.
                - rule: "self.tier != 'prod' || has(self.image)"
                  message: "prod tier requires an explicit image"
              properties:
                minReplicas:
                  type: integer
                  minimum: 0
                maxReplicas:
                  type: integer
                tier:
                  type: string
                  enum: ["dev", "staging", "prod"]
                image:
                  type: string
                replicas:
                  type: integer
                  # Transition rule: scale-up only. `oldSelf` is the prior value.
                  x-kubernetes-validations:
                    - rule: "self >= oldSelf"
                      message: "replicas can only be scaled up, never down"
                schedule:
                  type: string
                  # RE2 POSIX class [[:space:]] avoids CEL/YAML backslash escaping.
                  x-kubernetes-validations:
                    - rule: "self.matches('^[0-9*/,-]+([[:space:]]+[0-9*/,-]+){4}$')"
                      message: "schedule must be a valid 5-field cron expression"
```

### 3.2 `ValidatingAdmissionPolicy` — full lifecycle (param CRD → policy → binding → param object)

This is the canonical production shape: the policy is written **once**, and per-environment thresholds are supplied by a **parameter object** (a CRD instance), selected by the binding. That separation is why VAP scales across many namespaces without editing the policy.

**Step A — the parameter CRD** (config-as-a-resource):

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: replicalimits.rules.example.com
spec:
  group: rules.example.com
  names:
    kind: ReplicaLimit
    plural: replicalimits
    singular: replicalimit
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            maxReplicas:
              type: integer
              minimum: 1
          required: [maxReplicas]
```

**Step B — the policy** (with `matchConditions`, `variables`, `messageExpression`, `auditAnnotations`):

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "replica-limit.policy.example.com"
spec:
  failurePolicy: Fail          # runtime eval error -> deny (not Ignore)
  paramKind:
    apiVersion: rules.example.com/v1
    kind: ReplicaLimit
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  # Cheap pre-filter, evaluated before validations; keeps kube-system exempt.
  matchConditions:
    - name: 'exclude-privileged-namespaces'
      expression: '!(object.metadata.namespace in ["kube-system", "kube-node-lease"])'
  # Named, reusable sub-expressions. Evaluated lazily, in order.
  variables:
    - name: replicas
      expression: "object.spec.replicas"
    - name: maxReplicas
      # Null-safe: fall back to 5 if the param omits the field.
      expression: "has(params.maxReplicas) ? params.maxReplicas : 5"
  validations:
    - expression: "variables.replicas <= variables.maxReplicas"
      reason: Forbidden
      # messageExpression must return a string; falls back to `message` on error.
      messageExpression: >-
        'Deployment ' + object.metadata.name + ' requests ' +
        string(variables.replicas) + ' replicas but the limit is ' +
        string(variables.maxReplicas)
  # Recorded into the API audit log regardless of allow/deny.
  auditAnnotations:
    - key: "observed-replicas"
      valueExpression: "'replicas=' + string(variables.replicas)"
```

**Step C — the binding** (couples policy to scope and to a param object):

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "replica-limit-binding.example.com"
spec:
  policyName: "replica-limit.policy.example.com"
  # Deny | Warn | Audit — can combine, e.g. [Deny] in prod, [Warn,Audit] to canary.
  validationActions: [Deny]
  paramRef:
    name: "replica-limit-prod"
    namespace: "policy-params"
    # If the referenced param object is missing at eval time:
    parameterNotFoundAction: Deny
  matchResources:
    namespaceSelector:
      matchLabels:
        environment: production
```

**Step D — the param object** (the actual threshold, per environment):

```yaml
apiVersion: rules.example.com/v1
kind: ReplicaLimit
metadata:
  name: replica-limit-prod
  namespace: policy-params
maxReplicas: 8
```

### 3.3 A pure, self-contained policy (no params) using the `authorizer` and IP libraries

Two production-grade patterns: an **RBAC check inside admission** (only users who could already `update` the `scale` subresource may set a high replica count), and the **IP/CIDR library** for validating a LoadBalancer source range.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "guardrails.policy.example.com"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  variables:
    - name: highScale
      expression: "has(object.spec.replicas) && object.spec.replicas > 20"
    - name: canScale
      # Ask the built-in authorizer: could this same user update deployments/scale?
      expression: >-
        authorizer.group('apps').resource('deployments').subresource('scale')
          .namespace(object.metadata.namespace).check('update').allowed()
  validations:
    - expression: "!variables.highScale || variables.canScale"
      reason: Forbidden
      messageExpression: >-
        '>20 replicas requires update permission on deployments/scale in namespace ' +
        object.metadata.namespace
    # Reject containers without resource limits (cross-list quantifier).
    - expression: >-
        object.spec.template.spec.containers.all(c,
          has(c.resources) && has(c.resources.limits) &&
          'memory' in c.resources.limits)
      message: "every container must set a memory limit"
```

---

## 4. CLI commands and real terminal output

### 4.1 Happy path — create policy, bind, observe a denial

```console
$ kubectl apply -f param-crd.yaml
customresourcedefinition.apiextensions.k8s.io/replicalimits.rules.example.com created

$ kubectl apply -f policy.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/replica-limit.policy.example.com created

$ kubectl apply -f binding.yaml
validatingadmissionpolicybinding.admissionregistration.k8s.io/replica-limit-binding.example.com created

$ kubectl -n policy-params apply -f param.yaml
replicalimit.rules.example.com/replica-limit-prod created

$ kubectl get validatingadmissionpolicy
NAME                                  VALIDATIONS   PARAMKIND                         AGE
replica-limit.policy.example.com      1             ReplicaLimit.rules.example.com    41s

$ kubectl label namespace app-prod environment=production
namespace/app-prod labeled

# Attempt a Deployment that violates the limit (maxReplicas=8, requesting 10):
$ kubectl -n app-prod apply -f nginx-10-replicas.yaml
Error from server (Forbidden): error when creating "nginx-10-replicas.yaml": deployments.apps "nginx" is forbidden: ValidatingAdmissionPolicy 'replica-limit.policy.example.com' with binding 'replica-limit-binding.example.com' denied request: Deployment nginx requests 10 replicas but the limit is 8
```

### 4.2 The compile-time safety net (this is the headline feature)

CEL expressions are **type-checked against the target schema when the policy is created**. A field typo fails *at `kubectl apply` time*, not on live production traffic — the exact failure mode a webhook cannot prevent.

```console
$ cat broken-policy.yaml
...
  validations:
    - expression: "object.spec.replica <= 5"   # 'replica' — typo, should be 'replicas'
...

$ kubectl apply -f broken-policy.yaml
The ValidatingAdmissionPolicy "broken.policy.example.com" is invalid:
spec.validations[0].expression: Invalid value: "object.spec.replica <= 5":
compilation failed: ERROR: <input>:1:13: undefined field 'replica'
 | object.spec.replica <= 5
 | ............^
```

For resources matched loosely (e.g., `resources: ["*"]`), the API server cannot always resolve the type at compile time, so instead of failing it **records warnings in `.status.typeChecking`** — surfacing likely bugs without blocking:

```console
$ kubectl get validatingadmissionpolicy replica-limit.policy.example.com -o yaml
...
status:
  observedGeneration: 1
  typeChecking:
    expressionWarnings:
      - fieldRef: spec.validations[0].expression
        warning: |-
          apps/v1, Kind=Deployment: ERROR: <input>:1:13: undefined field 'replica'
           | object.spec.replica <= 5
           | ............^
```

### 4.3 Cost estimation rejection

If an expression's **statically estimated worst-case cost** exceeds the per-expression limit (e.g., nested `all()` over unbounded lists), the policy is rejected at creation:

```console
$ kubectl apply -f expensive-policy.yaml
The ValidatingAdmissionPolicy "expensive.policy.example.com" is invalid:
spec.validations[0].expression: Forbidden: estimated cost of the expression
exceeds the cost limit for the resource
```

### 4.4 CRD validation in action

```console
$ kubectl apply -f crontab-crd.yaml
customresourcedefinition.apiextensions.k8s.io/crontabs.stable.example.com created

$ cat bad-crontab.yaml
apiVersion: stable.example.com/v1
kind: CronTab
metadata: {name: nightly}
spec:
  minReplicas: 5
  maxReplicas: 2         # violates minReplicas <= maxReplicas
  replicas: 3
  schedule: "0 0 * * *"

$ kubectl apply -f bad-crontab.yaml
The CronTab "nightly" is invalid: spec: Invalid value: "object": minReplicas must not exceed maxReplicas

# Transition rule: scale-down is blocked on UPDATE, not on CREATE.
$ kubectl patch crontab nightly --type merge -p '{"spec":{"replicas":1}}'
The CronTab "nightly" is invalid: spec.replicas: Invalid value: "integer": replicas can only be scaled up, never down
```

### 4.5 Canary a policy safely with `Warn` + `Audit` before `Deny`

```console
# Flip the binding to non-blocking to measure blast radius first.
$ kubectl patch validatingadmissionpolicybinding replica-limit-binding.example.com \
    --type merge -p '{"spec":{"validationActions":["Warn","Audit"]}}'
validatingadmissionpolicybinding.admissionregistration.k8s.io/replica-limit-binding.example.com patched

$ kubectl -n app-prod apply -f nginx-10-replicas.yaml
Warning: Deployment nginx requests 10 replicas but the limit is 8
deployment.apps/nginx created

# The Audit action lands structured annotations in the API audit log:
$ jq 'select(.annotations["validation.policy.admission.k8s.io/validation_failure"])' \
     /var/log/kube-apiserver/audit.log | head
{
  "annotations": {
    "validation.policy.admission.k8s.io/validation_failure":
      "[{\"message\":\"Deployment nginx requests 10 replicas but the limit is 8\",\"policy\":\"replica-limit.policy.example.com\",\"binding\":\"replica-limit-binding.example.com\",\"expressionIndex\":0,\"validationActions\":[\"Warn\",\"Audit\"]}]",
    "observed-replicas": "replicas=10"
  }
}
```

This canary path — `Warn`/`Audit` first, read the audit log to size the blast radius, then promote to `Deny` — is the safe rollout pattern and has no equivalent in plain schema validation.

---

## 5. Verification and failure diagnosis

### 5.1 The cost model — the source of the two most common rejections

CEL in Kubernetes is bounded at **two** independent stages. Knowing which stage rejected you tells you what to fix.

| Stage | Constant (apiserver default) | Enforced when | Symptom |
|---|---|---|---|
| **Static per-expression** estimate | `10,000,000` (`StaticEstimatedCostLimit`) | Policy/CRD is **created** | `Forbidden: estimated cost … exceeds the cost limit` |
| **Static per-CRD** aggregate | `100,000,000` (`StaticEstimatedCRDCostLimit`) | CRD is **created** | CRD rejected: total rule cost too high |
| **Runtime per-request** budget (VAP) | `10,000,000` (`RuntimeCELCostBudget`) | Each admission **evaluation** | Request denied: runtime cost budget exceeded |
| **Runtime matchConditions** budget | `1,000,000` (`RuntimeCELCostBudgetMatchConditions`) | Webhook/VAP match phase | Match-phase cost exceeded |

The estimator is **pessimistic**: it uses schema bounds (`maxItems`, `maxLength`) as the size of lists/strings. An expression like `object.spec.a.all(x, object.spec.b.exists(y, x == y))` costs roughly `len(a) × len(b)`. **If your list fields have no `maxItems`/`maxLength`, the estimator assumes the maximum and the cost explodes.** The fix is almost always *"bound the field in the schema,"* not *"rewrite the expression."*

```console
# Diagnose an unbounded field feeding an expensive quantifier:
$ kubectl explain crontab.spec.hosts
KIND:     CronTab
FIELD:    hosts <[]string>
    (no maxItems -> estimator assumes worst case)
```

Add `maxItems: 100` to `hosts` and the estimate drops by orders of magnitude.

### 5.2 Runtime evaluation errors and `failurePolicy`

At runtime a CEL expression can error — most commonly a **null dereference** (`object.spec.foo` when `foo` is absent) or a bad type conversion. What happens next is governed by `failurePolicy`:

- `failurePolicy: Fail` (default) → the request is **denied**.
- `failurePolicy: Ignore` → the failing validation is **skipped** (the object is admitted as far as that policy is concerned).

**This is the #1 production bug:** an expression that assumes an optional field exists silently starts denying (or ignoring) traffic the moment someone omits that field. Defend with:

| Technique | Example | Effect |
|---|---|---|
| `has()` macro | `has(object.spec.replicas) && object.spec.replicas > 3` | Guard presence before access |
| Optional chaining | `object.?spec.?replicas.orValue(1)` | Return a default instead of erroring |
| Short-circuit ordering | `has(x) && x.y == 1` | `&&` / `\|\|` stop at the first decisive operand |
| Default via `variables` | compute once, reuse | Centralize the null-safe logic |

```yaml
    # WRONG — errors (and, under Fail, denies) when replicas is unset:
    - expression: "object.spec.replicas <= 5"
    # RIGHT — presence-guarded, no runtime error:
    - expression: "!has(object.spec.replicas) || object.spec.replicas <= 5"
```

### 5.3 The regex / string-escaping trap

CEL string literals interpret backslash escapes, and YAML *also* processes backslashes in **double-quoted** scalars. A regex `\d` therefore needs escaping twice, which is a frequent source of silent mismatches:

| You want (RE2) | CEL source | YAML single-quoted | YAML double-quoted |
|---|---|---|---|
| `\d` | `\\d` | `'\\d'` | `"\\\\d"` |
| `\s` | `\\s` | `'\\s'` | `"\\\\s"` |

Rule of thumb: **use single-quoted YAML for CEL rules**, and prefer POSIX classes (`[[:digit:]]`, `[[:space:]]`) which need no backslashes at all. A rule that "never matches anything" is almost always this bug.

### 5.4 Type checking, warnings, and matching

```console
# Is the policy type-clean against every matched Kind?
$ kubectl get validatingadmissionpolicy replica-limit.policy.example.com \
    -o jsonpath='{.status.typeChecking.expressionWarnings}'
[]        # empty == clean

# Why did my policy not fire? Verify the binding scope actually matches.
$ kubectl get validatingadmissionpolicybinding replica-limit-binding.example.com \
    -o jsonpath='{.spec.matchResources.namespaceSelector}{"\n"}'
{"matchLabels":{"environment":"production"}}

$ kubectl get ns app-prod --show-labels
NAME       STATUS   AGE   LABELS
app-prod   Active   3h    environment=production,kubernetes.io/metadata.name=app-prod
```

A policy that "does nothing" almost always fails one of three checks, in this order: (1) a **binding exists** and names the policy; (2) `validationActions` includes `Deny` (a policy with **no binding**, or with only `Audit`, never blocks); (3) the request is actually **in scope** (`matchConstraints` on the policy *and* `matchResources` on the binding both apply, ANDed together).

### 5.5 Fast local iteration without a cluster

Test CEL logic against sample objects before ever touching the API server:

```console
$ go install github.com/google/cel-go/repl@latest
$ cel-repl
> object.spec.replicas <= 5
... (bind `object` to a sample and evaluate)
```

or with the community `cel-playground`, or `kubectl-validate` for offline CRD/manifest checking. Iterating here turns a "compile failed" round-trip through the API server into a sub-second local loop.

### 5.6 Diagnostic checklist

- **Denies unexpectedly on some objects** → a null deref under `failurePolicy: Fail`; add `has()` / `?.orValue()`.
- **Never matches / regex silently fails** → double-escaping; switch to single-quoted YAML or `[[:...]]` classes.
- **Rejected at create with "estimated cost exceeds limit"** → bound the offending list/string field with `maxItems`/`maxLength`; don't just rewrite the CEL.
- **Policy has no effect** → missing binding, `Deny` not in `validationActions`, or scope mismatch between `matchConstraints` and `matchResources`.
- **`params` is null at runtime** → set `paramRef.parameterNotFoundAction`, or guard with `has(params...)` / `variables` defaults.
- **Cross-field rule "can't see" a sibling in a CRD** → move the rule up to the parent object node where `self` sees both fields.
- **Transition rule errors on CREATE** → `oldSelf` only exists on UPDATE with a prior value; a rule referencing it is skipped on CREATE by design.

---

## 6. References

- CEL specification (Google): https://github.com/google/cel-spec
- CEL language definition: https://github.com/google/cel-spec/blob/master/doc/langdef.md
- Kubernetes — CEL overview & extended libraries: https://kubernetes.io/docs/reference/using-api/cel/
- Kubernetes — Validating Admission Policy: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — Mutating Admission Policy (alpha): https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/
- Kubernetes — CRD validation rules (`x-kubernetes-validations`): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- Kubernetes — Webhook `matchConditions` (CEL pre-filter): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#matching-requests-matchconditions
- Kubernetes — Structured authentication configuration (CEL claim mapping/validation): https://kubernetes.io/docs/reference/access-authn-authz/authentication/#using-authentication-configuration
- KEP-3488 — CEL for Admission Control (`ValidatingAdmissionPolicy`): https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/3488-cel-admission-control
- KEP-2876 — CRD Validation Expression Language: https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/2876-crd-validation-expression-language
- cel-go (embeddable runtime and REPL): https://github.com/google/cel-go
- CNCF Curriculum (source syllabus): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf