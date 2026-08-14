# Topic 5.11 — Common Expression Language (CEL): Guided Exercises

> **Persona of the exercises:** you are operating a real cluster as a platform engineer who is codifying policy *inside the API server* instead of shipping external webhooks. CEL is the shared expression engine behind four Kubernetes surfaces: CRD **validation rules** (`x-kubernetes-validations`), **ValidatingAdmissionPolicy** (VAP), admission-webhook **`matchConditions`**, and the **authorizer** CEL library. These labs walk all four.

**Prerequisites**

- A cluster running **Kubernetes v1.30+** (the release where `ValidatingAdmissionPolicy` and webhook `matchConditions` reached GA; CRD validation rules are GA since v1.29). `kind create cluster --image kindest/node:v1.30.0` or `minikube start --kubernetes-version=v1.30.0` both work.
- `kubectl` matching the server minor version.
- Cluster-admin rights (you will create CRDs and cluster-scoped policy objects).

**Reference sources (official)**

- CEL in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- CRD validation rules — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- ValidatingAdmissionPolicy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Webhook `matchConditions` — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#matching-requests-matchconditions
- CEL language definition — https://github.com/google/cel-spec/blob/master/doc/langdef.md
- CEL playground (offline expression testing) — https://playcel.undistro.io/

Create a scratch namespace so cleanup is trivial:

```bash
kubectl create namespace cel-lab
```

---

## Exercise 1 — CEL inside a CRD: `x-kubernetes-validations`

**Goal:** enforce cross-field and per-element invariants that plain OpenAPI (`minimum`, `pattern`, `required`) cannot express, using `self`, the `has()` guard, and the `all()` macro.

1. Write the CRD. Note the two rules are attached to the **`spec` object node**, so inside them `self` is the `spec` object.

```yaml
# scalingpolicy-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: scalingpolicies.training.example.com
spec:
  group: training.example.com
  scope: Namespaced
  names:
    plural: scalingpolicies
    singular: scalingpolicy
    kind: ScalingPolicy
    shortNames: ["sp"]
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
              required: ["minReplicas", "maxReplicas"]
              properties:
                minReplicas:
                  type: integer
                  minimum: 0
                maxReplicas:
                  type: integer
                  minimum: 1
                tiers:
                  type: array
                  maxItems: 16          # bounds the cost estimator — see Exercise 5
                  items:
                    type: string
              x-kubernetes-validations:
                - rule: "self.minReplicas <= self.maxReplicas"
                  message: "minReplicas cannot be larger than maxReplicas"
                - rule: "!has(self.tiers) || self.tiers.all(t, t.startsWith('tier-'))"
                  message: "every tier must be prefixed with 'tier-'"
                  fieldPath: ".tiers"
```

```bash
kubectl apply -f scalingpolicy-crd.yaml
```

```text
customresourcedefinition.apiextensions.k8s.io/scalingpolicies.training.example.com created
```

2. Apply a **valid** object:

```bash
kubectl apply -n cel-lab -f - <<'EOF'
apiVersion: training.example.com/v1
kind: ScalingPolicy
metadata:
  name: good
spec:
  minReplicas: 2
  maxReplicas: 10
  tiers: ["tier-a", "tier-b"]
EOF
```

```text
scalingpolicy.training.example.com/good created
```

3. Break the cross-field rule:

```bash
kubectl apply -n cel-lab -f - <<'EOF'
apiVersion: training.example.com/v1
kind: ScalingPolicy
metadata: { name: bad-range }
spec: { minReplicas: 10, maxReplicas: 3 }
EOF
```

```text
The ScalingPolicy "bad-range" is invalid: spec: Invalid value: "object": minReplicas cannot be larger than maxReplicas
```

4. Break the per-element rule (watch how `fieldPath` moves the error onto `spec.tiers`):

```bash
kubectl apply -n cel-lab -f - <<'EOF'
apiVersion: training.example.com/v1
kind: ScalingPolicy
metadata: { name: bad-tier }
spec:
  minReplicas: 1
  maxReplicas: 3
  tiers: ["tier-a", "gold"]
EOF
```

```text
The ScalingPolicy "bad-tier" is invalid: spec.tiers: Invalid value: "array": every tier must be prefixed with 'tier-'
```

**Check your understanding**

- **1a.** In rule `self.minReplicas <= self.maxReplicas`, what exactly does `self` bind to, and what would it bind to if the same rule were placed under the `minReplicas` node instead?
- **1b.** Why is the second rule written `!has(self.tiers) || self.tiers.all(...)` rather than just `self.tiers.all(...)`? What runtime error appears if you drop the `has()` guard and submit an object with no `tiers`?
- **1c.** What is the effect of `fieldPath: ".tiers"` on the error a user sees, and why does that matter for large objects?

---

## Exercise 2 — Transition rules and immutability with `oldSelf`

**Goal:** make a field write-once. A rule that references `oldSelf` is a **transition rule**: the API server only evaluates it on `UPDATE`, when a previous value exists.

1. Add an immutable `storageClass` field. Edit the CRD to insert this property under `spec.properties` and re-apply:

```yaml
                storageClass:
                  type: string
                  x-kubernetes-validations:
                    - rule: "self == oldSelf"
                      message: "storageClass is immutable once set"
```

```bash
kubectl apply -f scalingpolicy-crd.yaml
```

2. Create an object with the field set, then try to change it:

```bash
kubectl apply -n cel-lab -f - <<'EOF'
apiVersion: training.example.com/v1
kind: ScalingPolicy
metadata: { name: locked }
spec: { minReplicas: 1, maxReplicas: 5, storageClass: "fast-ssd" }
EOF

kubectl patch -n cel-lab scalingpolicy locked --type merge -p '{"spec":{"storageClass":"slow-hdd"}}'
```

```text
scalingpolicy.training.example.com/locked created
The ScalingPolicy "locked" is invalid: spec.storageClass: Invalid value: "string": storageClass is immutable once set
```

3. Confirm the create in step 2 succeeded even though `self == oldSelf` looks like it should have fired. It did not fire on CREATE — there was no `oldSelf`.

**Check your understanding**

- **2a.** Why did the initial `CREATE` succeed instead of failing the `self == oldSelf` rule?
- **2b.** A colleague wants to make an *already existing* optional field immutable from now on, but current objects may not have it set. Which CEL construct lets a transition rule tolerate "old value was absent", and roughly how is it written? (Hint: `optionalOldSelf`.)
- **2c.** Immutability could also be done with a mutating webhook that rejects changes. Give one concrete operational advantage of expressing it as a CEL transition rule instead.

---

## Exercise 3 — `ValidatingAdmissionPolicy` on built-in resources

**Goal:** enforce a cluster rule on `Deployments` — resources you do **not** own — without deploying any webhook server. This is the VAP + `ValidatingAdmissionPolicyBinding` split: the **policy** holds the logic; the **binding** decides *where* it applies and *what action* it takes.

1. Create the policy (logic only — it does nothing until bound):

```yaml
# replica-policy.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: replica-limit.policy.example.com
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  validations:
    - expression: "!has(object.spec.replicas) || object.spec.replicas <= 5"
      message: "Deployment replicas must not exceed 5 in this cluster"
      reason: Invalid
```

2. Create the binding, scoped to any namespace carrying the label `cel-demo=true`, and set the enforcement action to **Deny**:

```yaml
# replica-binding.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: replica-limit.binding.example.com
spec:
  policyName: replica-limit.policy.example.com
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        cel-demo: "true"
```

```bash
kubectl apply -f replica-policy.yaml
kubectl apply -f replica-binding.yaml
kubectl label namespace cel-lab cel-demo=true
```

3. Test the boundary. A compliant Deployment is admitted; an over-provisioned one is denied:

```bash
kubectl create deployment ok  -n cel-lab --image=nginx --replicas=3
kubectl create deployment nope -n cel-lab --image=nginx --replicas=8
```

```text
deployment.apps/ok created
error: failed to create deployment: deployments.apps "nope" is forbidden: ValidatingAdmissionPolicy 'replica-limit.policy.example.com' with binding 'replica-limit.binding.example.com' denied request: Deployment replicas must not exceed 5 in this cluster
```

4. Prove the scope. Create the same object in a namespace **without** the label and watch it pass:

```bash
kubectl create deployment nope -n default --image=nginx --replicas=8
```

```text
deployment.apps/nope created
```

**Check your understanding**

- **3a.** Two objects are needed (`ValidatingAdmissionPolicy` and `...Binding`). What responsibility does each own, and why is that separation useful when the same policy must apply differently to `prod` vs `dev`?
- **3b.** `validationActions` accepts `Deny`, `Warn`, and `Audit`. Describe a safe rollout sequence for a brand-new policy across a busy cluster using those values.
- **3c.** The expression guards with `!has(object.spec.replicas)`. Given that `replicas` has a default of `1`, is that guard strictly necessary here? What variable would be `null` for a `DELETE` request, and why does that make defensive guarding a habit worth keeping?

---

## Exercise 4 — Variables, `matchConditions`, `messageExpression`, and the `authorizer`

**Goal:** build a realistic image-provenance policy on Pods that (a) skips system namespaces cheaply, (b) factors logic into reusable **variables**, (c) builds a dynamic message, and (d) grants an exemption based on the caller's RBAC via the **authorizer** library.

1. Create the policy:

```yaml
# image-policy.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: image-registry.policy.example.com
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  matchConditions:
    - name: skip-system-namespaces
      expression: "!(namespaceObject.metadata.name in ['kube-system', 'kube-node-lease'])"
  variables:
    - name: registry
      expression: "'registry.example.com/'"
    - name: containers
      expression: "object.spec.containers"
    - name: fromApprovedRegistry
      expression: "variables.containers.all(c, c.image.startsWith(variables.registry))"
    - name: callerMayBypass
      expression: >
        authorizer.group('policy.example.com').resource('imagebypass')
          .namespace(request.namespace).check('use').allowed()
  validations:
    - expression: "variables.fromApprovedRegistry || variables.callerMayBypass"
      messageExpression: >
        'all Pod images must come from ' + variables.registry +
        ' (or the caller must be granted use on imagebypass)'
      reason: Forbidden
```

```bash
kubectl apply -f image-policy.yaml
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: { name: image-registry.binding.example.com }
spec:
  policyName: image-registry.policy.example.com
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels: { cel-demo: "true" }
EOF
```

2. A Pod from the wrong registry is denied; the message is built at evaluation time:

```bash
kubectl run bad --image=docker.io/library/nginx -n cel-lab
```

```text
Error from server (Forbidden): pods "bad" is forbidden: ValidatingAdmissionPolicy 'image-registry.policy.example.com' with binding 'image-registry.binding.example.com' denied request: all Pod images must come from registry.example.com/ (or the caller must be granted use on imagebypass)
```

3. Prove the `matchCondition` short-circuits. Create the same offending Pod in `kube-system` — the policy never even evaluates its `validations`:

```bash
kubectl run bad --image=docker.io/library/nginx -n kube-system
```

```text
pod/bad created
```

**Check your understanding**

- **4a.** A request that matches `matchConstraints` can still be excluded by a `matchCondition`. What is the semantic difference between failing a `matchCondition` and failing a `validation`? Which one can *deny* a request?
- **4b.** Variables are declared as an ordered list and referenced as `variables.<name>`. Give two reasons (one about readability, one about **cost/performance**) to move `object.spec.containers.all(...)` into a variable instead of inlining it in every validation.
- **4c.** The `authorizer` call performs a SubjectAccessReview-style check inside the expression. What real-world escape hatch does `callerMayBypass` implement, and what RBAC object would you create to actually grant `use` on `imagebypass`?
- **4d.** When would you prefer `messageExpression` over the static `message` field, and what type must `messageExpression` evaluate to?

---

## Exercise 5 — Diagnostics: type checking, the cost budget, and parameterization

**Goal:** exercise the three things that most often surprise engineers writing CEL in production — the **non-blocking type checker**, the **cost estimator** that rejects unbounded iteration at write time, and **parameterized** policies via `paramKind`/`paramRef`.

1. **Type checking is a warning, not a gate.** Introduce a deliberate type error and observe that the object is still *created*, with a warning stamped into `status`:

```bash
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: { name: typecheck-demo.example.com }
spec:
  matchConstraints:
    resourceRules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["deployments"]
  validations:
    - expression: "object.spec.replicas <= '5'"   # int <= string — nonsense
      message: "bogus"
EOF

kubectl get validatingadmissionpolicy typecheck-demo.example.com \
  -o jsonpath='{.status.typeChecking}{"\n"}'
```

```text
validatingadmissionpolicy.admissionregistration.k8s.io/typecheck-demo.example.com created
{"expressionWarnings":[{"fieldRef":"spec.validations[0].expression","warning":"apps/v1, Kind=Deployment: ERROR: <input>:1:20: found no matching overload for '_<=_' applied to '(int, string)'\n"}]}
```

2. **The cost estimator rejects unbounded iteration at CRD registration.** Try to register a CRD that iterates a list with **no `maxItems`** — the estimator has to assume the list could be enormous and refuses:

```bash
kubectl apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: { name: costbombs.training.example.com }
spec:
  group: training.example.com
  scope: Namespaced
  names: { plural: costbombs, singular: costbomb, kind: CostBomb }
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
              properties:
                items:
                  type: array          # NOTE: no maxItems
                  items: { type: string }
              x-kubernetes-validations:
                - rule: "self.items.all(x, x.size() < 100)"
EOF
```

```text
The CustomResourceDefinition "costbombs.training.example.com" is invalid: spec.versions[0].schema.openAPIV3Schema.properties[spec].x-kubernetes-validations[0].rule: Forbidden: contributed to estimated rule & messageExpression cost total exceeding cost limit for entire OpenAPIv3 schema
```

3. Fix it by adding `maxItems: 100` and a `maxLength` on the string items, then re-apply — it now registers, because the estimator can bound the work.

4. **Parameterize a policy.** Externalize the replica ceiling into a ConfigMap so it can change without editing the policy. `params` is bound to the referenced object:

```bash
kubectl create namespace policy-config
kubectl create configmap replica-limits -n policy-config --from-literal=maxReplicas=3

kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: { name: param-replica.policy.example.com }
spec:
  paramKind: { apiVersion: v1, kind: ConfigMap }
  matchConstraints:
    resourceRules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]
  validations:
    - expression: "object.spec.replicas <= int(params.data.maxReplicas)"
      messageExpression: "'replicas exceed the configured limit of ' + params.data.maxReplicas"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: { name: param-replica.binding.example.com }
spec:
  policyName: param-replica.policy.example.com
  validationActions: ["Deny"]
  paramRef:
    name: replica-limits
    namespace: policy-config
    parameterNotFoundAction: Deny
  matchResources:
    namespaceSelector:
      matchLabels: { cel-demo: "true" }
EOF

kubectl create deployment big -n cel-lab --image=nginx --replicas=4
```

```text
error: failed to create deployment: deployments.apps "big" is forbidden: ValidatingAdmissionPolicy 'param-replica.policy.example.com' with binding 'param-replica.binding.example.com' denied request: replicas exceed the configured limit of 3
```

5. Before shipping a raw expression, test it offline in the CEL playground (https://playcel.undistro.io/) or with `kubectl apply --dry-run=server`, which runs the full admission chain without persisting.

**Check your understanding**

- **5a.** Is CEL type checking blocking or advisory? Why can it only ever be *best-effort*, given a policy may match many Kinds via wildcards?
- **5b.** Explain, in terms of the cost **estimator** vs the runtime cost **budget**, why omitting `maxItems`/`maxLength` causes a *write-time* rejection rather than a *runtime* failure. What is the practical rule of thumb for any schema field a CEL rule iterates or measures?
- **5c.** In the parameterized binding, what does `parameterNotFoundAction: Deny` do, and how does that choice change the failure mode if someone deletes the `replica-limits` ConfigMap?
- **5d.** `params.data.maxReplicas` is wrapped in `int(...)`. Why — what is the CEL type of a ConfigMap `data` value?

---

## Cleanup

```bash
kubectl delete validatingadmissionpolicybinding \
  replica-limit.binding.example.com image-registry.binding.example.com param-replica.binding.example.com --ignore-not-found
kubectl delete validatingadmissionpolicy \
  replica-limit.policy.example.com image-registry.policy.example.com \
  param-replica.policy.example.com typecheck-demo.example.com --ignore-not-found
kubectl delete crd scalingpolicies.training.example.com costbombs.training.example.com --ignore-not-found
kubectl delete namespace cel-lab policy-config --ignore-not-found
```

---

## Answers

<details>
<summary>Reveal answers for all exercises</summary>

### Exercise 1

- **1a.** `self` binds to the **`spec` object** (a map with keys `minReplicas`, `maxReplicas`, `tiers`), because the rule is attached to the `spec` schema node. If the rule were placed under the `minReplicas` node, `self` would bind to the scalar **integer value** of `minReplicas` — and you could no longer reach `maxReplicas`, since CEL rules only see *down* from where they are anchored. Cross-field rules must therefore live at the common ancestor node.
- **1b.** `tiers` is optional. Accessing `self.tiers` when the field is absent raises `no such key: tiers` and the rule fails as an evaluation error. `has(self.tiers)` tests presence; `!has(self.tiers) || …` short-circuits so the `all()` macro only runs when the field exists. Without the guard, an object with no `tiers` is rejected with an error like `... rule ... failed: no such key: tiers`. (Equivalent optional-chaining form: `self.?tiers.orValue([]).all(...)`.)
- **1c.** `fieldPath: ".tiers"` relocates the API error from the anchor node (`spec`) onto `spec.tiers`, so the returned `Invalid value` points at the offending sub-field. On large objects this is the difference between a user seeing "something in spec is wrong" and "your `tiers` list is wrong," which matters for UX and for tools that parse field-level errors.

### Exercise 2

- **2a.** `self == oldSelf` is a **transition rule** — it references `oldSelf`, which only exists on `UPDATE`. On the initial `CREATE` there is no prior object, so the rule is **not evaluated** and the create succeeds. Transition rules never fire on create.
- **2b.** Use **`optionalOldSelf`**: mark the rule with `optionalOldSelf: true` and reference `oldSelf` as an `Optional` value, e.g. `oldSelf.hasValue() ? self == oldSelf.value() : true`. This lets the rule tolerate objects that predate the field (`oldSelf` is absent) while still locking it once set.
- **2c.** It runs **in-process in the API server** — no external webhook to deploy, scale, secure with TLS, or keep highly available; there is no network hop that can time out or fail-open, and immutability is enforced identically during API-server self-checks and upgrades. (It also cannot be bypassed by a webhook outage under `failurePolicy: Ignore`.)

### Exercise 3

- **3a.** The `ValidatingAdmissionPolicy` holds the **reusable logic** (`matchConstraints`, `validations`, `variables`). The `ValidatingAdmissionPolicyBinding` holds the **deployment decision**: which resources/namespaces it applies to (`matchResources`), what action to take (`validationActions`), and which params to feed. One policy can have many bindings — e.g. a `Deny` binding on `prod` namespaces and a `Warn` binding on `dev` — without duplicating the expression.
- **3b.** Roll out as `Audit` first (records to the audit log, denies nothing), inspect the audit annotations for how often it *would* have fired and on which workloads; promote to `Warn` (surfaces a warning to `kubectl`/clients but still admits) to give owners notice; only then switch to `Deny`. You may list several actions at once, e.g. `["Deny","Audit"]`.
- **3c.** Strictly, `replicas` is defaulted to `1` before validating admission runs, so the guard is not required for `Deployments` here. But the habit matters: for a `DELETE` request **`object` is `null`** (and for `CREATE`, `oldObject` is `null`). Reaching into a `null` object raises an evaluation error, so guarding with `has()`/optional chaining keeps a policy from failing on operations you didn't intend to constrain.

### Exercise 4

- **4a.** A failed `matchCondition` means the request is **excluded from the policy entirely** — the `validations` never run and the request proceeds (subject to other policies). A failed `validation` (under a `Deny` binding) **rejects** the request. `matchConditions` filter; only `validations` deny. `matchConditions` are also evaluated first and are the cheap place to short-circuit high-volume or system traffic.
- **4b.** *Readability:* one named `fromApprovedRegistry` expresses intent, and the `validation` reads as `fromApprovedRegistry || callerMayBypass`. *Cost/performance:* variables are **lazily evaluated and memoized** — the container scan runs at most once per request even if referenced in several validations or in `messageExpression`, instead of re-iterating the list each time. This keeps you comfortably under the per-request runtime cost budget.
- **4c.** `callerMayBypass` is a **break-glass exemption**: any identity that RBAC allows to `use` the virtual resource `imagebypass` (group `policy.example.com`) skips the registry check. You grant it with a `ClusterRole` containing a rule `{apiGroups: ["policy.example.com"], resources: ["imagebypass"], verbs: ["use"]}` and a `RoleBinding`/`ClusterRoleBinding` to the trusted subject. `imagebypass` need not be a real API object — the authorizer performs an access review against the RBAC graph, not a GET.
- **4d.** Use `messageExpression` when the message must include **runtime data** (the offending value, the configured limit, the registry). It must evaluate to a **`string`**; if it errors or returns a non-string, Kubernetes falls back to the static `message`.

### Exercise 5

- **5a.** Type checking is **advisory (non-blocking)** — the policy is created with warnings recorded in `status.typeChecking.expressionWarnings`. It can only be best-effort because a policy's `matchConstraints` may match many Kinds (including wildcards or CRDs the checker can't fully resolve); the checker type-checks against each discoverable matched type and reports mismatches, but cannot guarantee coverage, so it warns rather than blocks.
- **5b.** The **estimator** computes a *worst-case* cost statically at write time using the schema's declared bounds (`maxItems`, `maxLength`, `maxProperties`). With no bound, it assumes a very large maximum, the estimate blows past the per-schema cost limit, and the CRD/policy is **rejected on write**. The **runtime budget** is a separate ceiling enforced *during* each evaluation that halts an expression that actually gets too expensive. Rule of thumb: **put an explicit `maxItems`/`maxLength`/`maxProperties` on every field a CEL rule iterates or measures**, so the estimator can bound the work and admit your policy.
- **5c.** `parameterNotFoundAction: Deny` means that if the `paramRef` resolves to **no object**, the request is denied instead of silently admitted (`Allow` is the other choice). So deleting the `replica-limits` ConfigMap flips the policy to **fail-closed** — all matched Deployment writes are denied until the param is restored — which is usually the safe default for a security control.
- **5d.** ConfigMap `data` values are always **`string`** in CEL (the ConfigMap schema types `data` as `map[string]string`). Comparing a string to an integer is a type error, so you convert with `int(params.data.maxReplicas)` before the numeric comparison.

</details>