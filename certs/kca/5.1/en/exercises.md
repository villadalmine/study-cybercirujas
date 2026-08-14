# KCA Topic 5.1 — Validation Rules: Guided Exercises

> **Certification:** Kyverno Certified Associate (KCA) · **Domain 5.1 — Validation Rules** (exam weight 2.91)
> **Reference syllabus:** [CNCF KCA Curriculum](https://github.com/cncf/curriculum) · **Authoritative docs:** [kyverno.io/docs/writing-policies/validate](https://kyverno.io/docs/writing-policies/validate/)

Validation is the most heavily used Kyverno rule type. A `validate` rule inspects an incoming (or existing) resource and either **allows**, **blocks**, or **reports** it. These exercises take you from a first pattern rule through anchors, `deny` conditions, `foreach`, CEL, and `podSecurity`, plus offline testing with the Kyverno CLI. Run each block against a live cluster (kind/minikube is fine) and answer the checkpoint questions before moving on.

**Prerequisites:** a running cluster + `kubectl`, and the `kyverno` CLI (`brew install kyverno` or download from the [releases page](https://github.com/kyverno/kyverno/releases)).

---

## Exercise 1 — Install Kyverno and write your first `pattern` rule

**Goal:** understand the admission flow, `Audit` vs `Enforce`, and the `pattern` overlay.

1. Install Kyverno via Helm and wait for it to become ready:

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm repo update
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller
   ```

   Expected:

   ```
   deployment "kyverno-admission-controller" successfully rolled out
   ```

2. Create a `ClusterPolicy` that requires every Pod to carry a non-empty `team` label. Save as `require-labels.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-labels
   spec:
     background: true
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Enforce      # block at admission (1.10+ per-rule field)
           message: "The label 'team' is required and must not be empty."
           pattern:
             metadata:
               labels:
                 team: "?*"            # ? = exactly one char, * = zero or more → "non-empty"
   ```

3. Apply it and confirm it loaded:

   ```bash
   kubectl apply -f require-labels.yaml
   kubectl get clusterpolicy require-labels
   ```

   Expected:

   ```
   NAME             ADMISSION   BACKGROUND   READY   AGE   MESSAGE
   require-labels   true        true         True    8s    Ready
   ```

4. Try a **non-compliant** Pod:

   ```bash
   kubectl run nginx-bad --image=nginx:1.27
   ```

   Expected (request blocked):

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/default/nginx-bad was blocked due to the following policies

   require-labels:
     check-team-label: 'validation error: The label ''team'' is required and must
       not be empty. rule check-team-label failed at path /metadata/labels/team/'
   ```

5. Now a **compliant** Pod:

   ```bash
   kubectl run nginx-good --image=nginx:1.27 --labels team=payments
   ```

   Expected:

   ```
   pod/nginx-good created
   ```

6. Inspect the machine-readable result Kyverno records:

   ```bash
   kubectl get policyreport -n default
   ```

   Expected (a report accumulating pass/fail counts for the namespace):

   ```
   NAME                                   KIND   NAME         PASS   FAIL   WARN   ERROR   SKIP   AGE
   e1a2...                                Pod    nginx-good   1      0      0      0       0      20s
   ```

**Checkpoint 1**

- **1a.** What does the pattern value `"?*"` assert, and why is it preferred over `"*"` for a required label?
- **1b.** If you change `failureAction` from `Enforce` to `Audit`, what happens when `nginx-bad` is submitted — is it created, and where does the violation show up?
- **1c.** The policy matches `kinds: [Pod]`. If you now `kubectl create deployment` with a bad template, is it blocked? What Kyverno feature explains your answer?
- **1d.** Which Kyverno component actually rejected the request in step 4, and what is the significance of the `-fail` suffix in the webhook name?

---

## Exercise 2 — Operators, `anyPattern`, and anchors

**Goal:** control *which parts* of a resource a pattern applies to using operators (`* ? > < ! |`) and the four anchors.

1. **Operators + list semantics.** Require CPU/memory requests and a memory limit on **every** container. Save as `require-resources.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-resources
   spec:
     background: true
     rules:
       - name: validate-resources
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Enforce
           message: "Every container must set CPU/memory requests and a memory limit."
           pattern:
             spec:
               containers:
                 - resources:                # single overlay element → applied to ALL containers
                     requests:
                       memory: "?*"
                       cpu: "?*"
                     limits:
                       memory: "?*"
   ```

2. Apply it, then submit a Pod with no resources set and observe the failure. Note the path in the message points at the first offending container index (`/spec/containers/0/resources/...`).

3. **Conditional anchor `()`.** Enforce that *only* containers pinned to the `:latest` tag must use `imagePullPolicy: Always`. Save as `latest-pull.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: latest-requires-always
   spec:
     background: true
     rules:
       - name: latest-pull-policy
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Enforce
           message: "Containers using the ':latest' tag must set imagePullPolicy: Always."
           pattern:
             spec:
               containers:
                 - (image): "*:latest"        # conditional anchor: evaluate the peer ONLY when this matches
                   imagePullPolicy: "Always"
   ```

4. Test both branches:

   ```bash
   # Skipped by the anchor → allowed (pinned digest/tag, not :latest)
   kubectl run pinned --image=nginx:1.27 --labels team=web \
     --overrides='{"spec":{"containers":[{"name":"pinned","image":"nginx:1.27","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"memory":"32Mi"}}}]}}'

   # Matches the anchor, wrong pull policy → blocked
   kubectl run latest --image=nginx:latest --labels team=web \
     --overrides='{"spec":{"containers":[{"name":"latest","image":"nginx:latest","imagePullPolicy":"IfNotPresent","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"memory":"32Mi"}}}]}}'
   ```

5. **Existence anchor `^()` and `anyPattern` (logical OR).** Require that the Pod runs as non-root *either* at the pod level *or* at the container level, and that at least one container declares a memory limit. Save as `nonroot-or.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-nonroot
   spec:
     background: true
     rules:
       - name: run-as-non-root
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Enforce
           message: "runAsNonRoot must be true at the pod or container level."
           anyPattern:                          # OR: the resource must satisfy at least one branch
             - spec:
                 securityContext:
                   runAsNonRoot: true
             - spec:
                 containers:
                   - securityContext:
                       runAsNonRoot: true
       - name: at-least-one-limit
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Audit
           message: "At least one container should declare a memory limit."
           pattern:
             spec:
               ^(containers):                    # existence anchor: AT LEAST ONE element must match
                 - resources:
                     limits:
                       memory: "?*"
   ```

**Checkpoint 2**

- **2a.** In step 1 the `containers` list has a single element, yet the rule constrains *all* containers. Why? How would you instead require that **only one** container match — which anchor?
- **2b.** Explain the difference between the **conditional anchor `()`** and the **equality anchor `=()`**. Rewrite the step-3 rule so it reads "if `securityContext` is present, then `runAsNonRoot` must be `true`" using the correct anchor.
- **2c.** With `anyPattern`, does the resource have to satisfy *all* branches or *any* branch? What is the corresponding `message` behavior when it fails all of them?
- **2d.** Name the four Kyverno anchors and give the negation anchor's job in one sentence.

---

## Exercise 3 — `deny` rules, `conditions`, and `preconditions`

**Goal:** validate on *request context and JMESPath expressions* rather than static structure. Use `deny` for "block when a condition is true."

1. **`deny` with `conditions`.** Constrain production Deployment replica counts to the range 2–5. Save as `replica-range.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: replica-range
   spec:
     background: false
     rules:
       - name: prod-replica-bounds
         match:
           any:
             - resources:
                 kinds:
                   - Deployment
                 namespaces:
                   - production
         validate:
           failureAction: Enforce
           message: "Production Deployments must run between 2 and 5 replicas (got {{ request.object.spec.replicas }})."
           deny:
             conditions:
               any:                                   # deny if ANY condition is true
                 - key: "{{ request.object.spec.replicas }}"
                   operator: LessThan
                   value: 2
                 - key: "{{ request.object.spec.replicas }}"
                   operator: GreaterThan
                   value: 5
   ```

2. Create the namespace and test the boundaries:

   ```bash
   kubectl create ns production
   kubectl -n production create deployment web --image=nginx:1.27 --replicas=1   # blocked (< 2)
   kubectl -n production create deployment web --image=nginx:1.27 --replicas=3   # allowed
   ```

   The first fails with your interpolated message; the second succeeds.

3. **`preconditions` + unconditional `deny`.** Prevent deletion of any ConfigMap labelled `protected=true`. `preconditions` gate whether the rule body even runs. Save as `protect-configmaps.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: protect-configmaps
   spec:
     background: false
     rules:
       - name: block-protected-deletes
         match:
           any:
             - resources:
                 kinds:
                   - ConfigMap
         preconditions:
           all:
             - key: "{{ request.operation || 'BACKGROUND' }}"
               operator: AnyIn
               value:
                 - DELETE
             - key: "{{ request.oldObject.metadata.labels.protected || '' }}"
               operator: Equals
               value: "true"
         validate:
           failureAction: Enforce
           message: "ConfigMaps labelled protected=true cannot be deleted."
           deny: {}                                   # empty deny → block whenever match + preconditions pass
   ```

4. Verify:

   ```bash
   kubectl create configmap app-conf --from-literal=k=v
   kubectl label configmap app-conf protected=true
   kubectl delete configmap app-conf         # blocked
   ```

   Expected:

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource ConfigMap/default/app-conf was blocked due to the following policies

   protect-configmaps:
     block-protected-deletes: ConfigMaps labelled protected=true cannot be deleted.
   ```

**Checkpoint 3**

- **3a.** What is the semantic difference between putting a check under `preconditions` versus under `deny.conditions`? When does each one execute?
- **3b.** In step 3, why do we read the label from `request.oldObject` rather than `request.object`?
- **3c.** Why is `background: false` required on a policy that references `request.operation` / `request.userInfo`? What would happen to background scans otherwise?
- **3d.** Under `conditions`, what is the difference between `all:` and `any:`? And between the operators `In` and `AnyIn` when the `key` resolves to a **list**?

---

## Exercise 4 — `foreach`: validating every element of a list

**Goal:** apply per-element logic (patterns or deny conditions) across a collection.

1. Restrict container images to two approved registries using `foreach` with a `pattern` and the `|` (OR) operator. Save as `restrict-registries.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: restrict-registries
   spec:
     background: true
     rules:
       - name: validate-registries
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Enforce
           message: "Images may only come from registry.corp.local or ghcr.io/corp."
           foreach:
             - list: "request.object.spec.containers"       # iterate; each item is bound to `element`
               pattern:
                 image: "registry.corp.local/* | ghcr.io/corp/*"
   ```

2. Apply, then submit a multi-container Pod where one image is off-registry:

   ```bash
   kubectl apply -f restrict-registries.yaml
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: mixed
     labels: { team: data }
   spec:
     containers:
       - name: app
         image: registry.corp.local/app:1.0
       - name: sidecar
         image: docker.io/library/busybox:1.36   # violates
   EOF
   ```

   Expected: blocked, with the message pointing at the `sidecar` element's image.

3. Extend coverage to `initContainers` and `ephemeralContainers` by adding two more `list` entries under `foreach` (each is validated independently):

   ```yaml
           foreach:
             - list: "request.object.spec.containers"
               pattern: { image: "registry.corp.local/* | ghcr.io/corp/*" }
             - list: "request.object.spec.initContainers"
               pattern: { image: "registry.corp.local/* | ghcr.io/corp/*" }
             - list: "request.object.spec.ephemeralContainers"
               pattern: { image: "registry.corp.local/* | ghcr.io/corp/*" }
   ```

**Checkpoint 4**

- **4a.** Inside a `foreach` block, what variable name refers to the current list item? How would you reference a sub-field of it in a `deny.conditions` key?
- **4b.** Why do we need three separate `list` entries instead of one? What happens if `spec.initContainers` is absent on a given Pod — does the rule error out?
- **4c.** Rewrite the step-1 registry check using `foreach` + `deny.conditions` with the `AnyNotIn` operator instead of a `pattern`. When would you prefer `deny` over `pattern` inside `foreach`?

---

## Exercise 5 — CEL-based validation (`validate.cel`)

**Goal:** use Common Expression Language for richer, self-documenting validation (aligns with Kubernetes `ValidatingAdmissionPolicy`). Requires **Kyverno 1.11+**.

1. Cap Deployment replicas with a single CEL expression. Save as `max-replicas-cel.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: max-replicas-cel
   spec:
     background: true
     rules:
       - name: check-replicas
         match:
           any:
             - resources:
                 kinds:
                   - Deployment
         validate:
           failureAction: Enforce
           cel:
             expressions:
               - expression: "object.spec.replicas <= 5"
                 message: "Deployments may not exceed 5 replicas."
   ```

2. Apply and test:

   ```bash
   kubectl create deployment big --image=nginx:1.27 --replicas=8   # blocked by the CEL expression
   ```

3. **CEL variables + macros.** Enforce approved registries across all containers of a Deployment template, using a `variables` block and the `all`/`exists` macros. Save as `registries-cel.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: registries-cel
   spec:
     background: true
     rules:
       - name: approved-registries
         match:
           any:
             - resources:
                 kinds:
                   - Deployment
         validate:
           failureAction: Enforce
           cel:
             variables:
               - name: allowed
                 expression: "['registry.corp.local/', 'ghcr.io/corp/']"
             expressions:
               - expression: >-
                   object.spec.template.spec.containers.all(c,
                     variables.allowed.exists(p, c.image.startsWith(p)))
                 messageExpression: >-
                   "All images must start with one of: " + variables.allowed.join(", ")
   ```

4. Apply and submit a Deployment whose image is `docker.io/library/redis` — observe the block and note that `messageExpression` produced a **computed** message listing the allowed prefixes.

**Checkpoint 5**

- **5a.** In a Kyverno CEL rule, what do `object`, `oldObject`, and `request` bind to? Which one is `null` on a CREATE?
- **5b.** What is the difference between the `message` field and the `messageExpression` field on a CEL expression, and what type must `messageExpression` return?
- **5c.** The step-3 expression walks `object.spec.template.spec.containers`. Why doesn't Kyverno's Pod **autogen** save us from having to write `.spec.template.spec` here, unlike the `pattern`-based rules in Exercise 1?
- **5d.** Give one capability CEL validation offers that JMESPath `pattern`/`deny` cannot express cleanly.

---

## Exercise 6 — `podSecurity` subrule, `failureActionOverrides`, and offline CLI testing

**Goal:** enforce the Pod Security Standards with one rule, scope enforcement per-namespace, and gate everything in CI *before* it reaches the cluster.

1. **`podSecurity` subrule + overrides.** Enforce the `baseline` profile cluster-wide but downgrade to `Audit` for system/dev namespaces. Save as `psa-baseline.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: psa-baseline
   spec:
     background: true
     rules:
       - name: baseline
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Enforce
           failureActionOverrides:
             - action: Audit
               namespaces:
                 - kube-system
                 - dev
           podSecurity:
             level: baseline
             version: latest
             exclude:                              # granular exemptions per control + image
               - controlName: "HostPath Volumes"
                 images:
                   - "registry.corp.local/legacy/*"
   ```

2. Apply, then try a Pod that violates baseline (e.g. `hostNetwork: true`) in `default` (blocked) vs `dev` (allowed but reported):

   ```bash
   kubectl create ns dev
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata: { name: hostnet, namespace: default, labels: { team: infra } }
   spec:
     hostNetwork: true
     containers: [{ name: c, image: registry.corp.local/app:1.0 }]
   EOF
   ```

   Expected in `default`: blocked with a PodSecurity baseline violation message. Recreate it in `-n dev`: it is **created**, and a `PolicyReport` entry records the `fail`.

3. **Offline validation with `kyverno apply`.** No cluster round-trip — evaluate the policy against local manifests:

   ```bash
   kyverno apply psa-baseline.yaml --resource hostnet.yaml
   ```

   Expected:

   ```
   Applying 1 policy rule(s) to 1 resource(s)...

   policy psa-baseline -> resource default/Pod/hostnet failed:
   1. baseline: Validation rule 'baseline' failed. It violates PodSecurity "baseline:latest": ...

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   ```

4. **Declarative test suite with `kyverno test`.** Create `kyverno-test.yaml`:

   ```yaml
   apiVersion: cli.kyverno.io/v1alpha1
   kind: Test
   metadata:
     name: require-labels-test
   policies:
     - require-labels.yaml
   resources:
     - resources.yaml
   results:
     - policy: require-labels
       rule: check-team-label
       kind: Pod
       resource: nginx-good
       result: pass
     - policy: require-labels
       rule: check-team-label
       kind: Pod
       resource: nginx-bad
       result: fail
   ```

   With `resources.yaml` holding both Pods, run:

   ```bash
   kyverno test .
   ```

   Expected (all rows `Pass` means observed matched expected):

   ```
   │───│────────────────│──────────────────│──────────────│────────│
   │ # │ POLICY         │ RULE             │ RESOURCE     │ RESULT │
   │───│────────────────│──────────────────│──────────────│────────│
   │ 1 │ require-labels │ check-team-label │ .../nginx-good │ Pass │
   │ 2 │ require-labels │ check-team-label │ .../nginx-bad  │ Pass │
   │───│────────────────│──────────────────│──────────────│────────│

   Test Summary: 2 tests passed and 0 tests failed
   ```

**Checkpoint 6**

- **6a.** What are the two Pod Security Standard levels the `podSecurity` subrule accepts, and what does `version: latest` pin?
- **6b.** With `failureActionOverrides` set to `Audit` for `dev`, is the violating Pod in `dev` created? Where is the violation visible?
- **6c.** Distinguish `kyverno apply` from `kyverno test`. In a `Test` manifest, what does a `RESULT: Pass` row actually assert about the policy?
- **6d.** Why is running `kyverno apply`/`kyverno test` in CI valuable even though the cluster already enforces the same policies at admission?

---

<details>
<summary><strong>Answers — check your understanding</strong></summary>

**Checkpoint 1**

- **1a.** `?` matches exactly one character and `*` matches zero or more, so `"?*"` means "at least one character" — i.e. the label must exist **and** be non-empty. A bare `"*"` also matches the empty string `""`, so `team: ""` would incorrectly pass. See [Validate → pattern anchors/operators](https://kyverno.io/docs/writing-policies/validate/).
- **1b.** With `Audit`, admission is **not** blocked: `nginx-bad` is created. The violation is recorded in a `PolicyReport` (`kubectl get polr -n default`) with `result: fail`, and (if `emitWarning` is enabled) surfaced as an admission warning. `Audit` is the default `failureAction`. ([Policy reports](https://kyverno.io/docs/policy-reports/))
- **1c.** Yes, it is effectively blocked. Kyverno **autogen** automatically derives equivalent rules for Pod controllers (Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet, ReplicationController) from a Pod-matching rule, applying the check to `spec.template.metadata.labels`. ([Auto-Gen Rules](https://kyverno.io/docs/writing-policies/autogen/))
- **1d.** The **Kyverno admission (validating webhook) controller** rejected it. The `-fail` suffix identifies the webhook registered with `failurePolicy: Fail`, meaning if Kyverno is unreachable the API request is refused (fail-closed) rather than admitted; the companion `-ignore` webhook is fail-open.

**Checkpoint 2**

- **2a.** A `pattern` overlay with a single list element is applied to **every** element of the target array by default, so all containers must match. To require that **at least one** container match instead, use the **existence anchor** `^(containers)`.
- **2b.** The **conditional anchor `()`** controls *whether the sibling block is evaluated*: if the anchored key's value matches, the peers must validate; if it doesn't match, that subtree is skipped. The **equality anchor `=()`** asserts that *if the key is present its value must equal the pattern* (it does not force the key to exist). Rewrite: `spec.containers[].=(securityContext).=(runAsNonRoot): true` — "if `securityContext` and `runAsNonRoot` exist, `runAsNonRoot` must be `true`." ([Anchors](https://kyverno.io/docs/writing-policies/validate/))
- **2c.** `anyPattern` is a logical **OR** — the resource must satisfy **at least one** branch. When it satisfies none, Kyverno reports the failure of every branch so the author can see all the ways it fell short.
- **2d.** Conditional `()`, equality `=()`, existence `^()`, negation `X()` (plus the global anchor `<()`). The **negation anchor** asserts that the tagged key/field must **not** be present.

**Checkpoint 3**

- **3a.** `preconditions` are a **gate**: they are evaluated first and, if they don't pass, the rule is skipped entirely (counts as `skip`, not `fail`). `deny.conditions` are the **assertion**: when they evaluate true the request is **denied** (`fail`). Precondition false → rule doesn't run; deny condition true → request blocked. ([Preconditions](https://kyverno.io/docs/writing-policies/preconditions/))
- **3b.** On a DELETE, `request.object` is `null`; the resource being removed is available only in `request.oldObject`. Reading the `protected` label therefore must come from `oldObject`.
- **3c.** Rules that reference admission-only context (`request.operation`, `request.userInfo`, `request.roles`, etc.) cannot be evaluated during background scans of already-stored resources, because that context doesn't exist offline. Setting `background: false` prevents Kyverno from trying (and erroring). ([Background scanning](https://kyverno.io/docs/writing-policies/background/))
- **3d.** `all:` requires **every** condition true (AND); `any:` requires **at least one** true (OR). For a `key` that resolves to a **list**, `In` requires the *whole list* to be a subset of `value`, whereas `AnyIn` passes if **any** element of the key list is in `value` (`AllIn` requires all elements). ([Operators](https://kyverno.io/docs/writing-policies/preconditions/))

**Checkpoint 4**

- **4a.** The current item is bound to `element` (and its index to `elementIndex`). In `deny.conditions` you reference sub-fields as e.g. `key: "{{ element.image }}"`. ([foreach](https://kyverno.io/docs/writing-policies/validate/))
- **4b.** `containers`, `initContainers`, and `ephemeralContainers` are **distinct** list fields, so each needs its own `list` entry. If a Pod has no `initContainers`, the referenced list resolves to empty and that `foreach` entry simply validates zero elements — it does **not** error.
- **4c.** Example: `list: "request.object.spec.containers"` with `deny.conditions.all: [{ key: "{{ element.image }}", operator: AnyNotIn, value: ["registry.corp.local/*","ghcr.io/corp/*"] }]`. Prefer `deny` when the logic is comparative/expression-based or needs request context; prefer `pattern` for simple structural shape checks. ([foreach](https://kyverno.io/docs/writing-policies/validate/))

**Checkpoint 5**

- **5a.** `object` = the incoming resource, `oldObject` = the prior state, `request` = the `AdmissionRequest`. On a **CREATE**, `oldObject` is `null`. ([CEL validation](https://kyverno.io/docs/writing-policies/validate/))
- **5b.** `message` is a **static string**; `messageExpression` is a **CEL expression** evaluated at failure time and must return a **string**, letting you build dynamic messages (e.g. listing allowed values).
- **5c.** Kyverno's autogen rewrites JMESPath `pattern`/`deny` rules for controllers automatically, but for CEL you write the expression against the actual object graph, so for a Deployment you must traverse `spec.template.spec.containers` yourself (matching on `Deployment` rather than `Pod`).
- **5d.** CEL cleanly expresses quantifiers and cross-field arithmetic/relationships — e.g. `containers.all(c, ...)`, comparing two fields, set membership with `exists`, or ratio checks — that are awkward or impossible in a static overlay.

**Checkpoint 6**

- **6a.** `baseline` and `restricted`. `version: latest` pins the check to the newest Pod Security Standard version Kyverno ships (you can pin a specific one like `v1.24` for reproducibility). ([Pod Security](https://kyverno.io/docs/writing-policies/pod-security/))
- **6b.** Yes — because `failureActionOverrides` sets `Audit` for `dev`, the violating Pod is **created**; the violation appears as a `fail` in the namespace's `PolicyReport` (`kubectl get polr -n dev`).
- **6c.** `kyverno apply` evaluates policies against resources and prints pass/fail; `kyverno test` runs a declarative `Test` manifest that compares **observed** results to **expected** ones. A `RESULT: Pass` row means "the policy produced the outcome the test asserted" (which may itself be an expected `fail` on a bad resource) — it validates the *policy's behavior*, not the resource. ([CLI apply](https://kyverno.io/docs/kyverno-cli/usage/apply/), [CLI test](https://kyverno.io/docs/kyverno-cli/usage/test/))
- **6d.** It shifts enforcement **left**: authors catch policy regressions and non-compliant manifests in CI/PR review before merge/deploy, without a cluster, giving fast deterministic feedback and preventing a broken policy or manifest from ever reaching admission.

</details>

---

### Sources

- Kyverno — *Validate rules* (patterns, anchors, `anyPattern`, `deny`, `foreach`, CEL, `podSecurity`, failure actions): https://kyverno.io/docs/writing-policies/validate/
- Kyverno — *Preconditions & operators*: https://kyverno.io/docs/writing-policies/preconditions/
- Kyverno — *Auto-generation of Pod controller rules*: https://kyverno.io/docs/writing-policies/autogen/
- Kyverno — *Pod Security*: https://kyverno.io/docs/writing-policies/pod-security/
- Kyverno — *Policy Reports*: https://kyverno.io/docs/policy-reports/
- Kyverno — *CLI `apply`*: https://kyverno.io/docs/kyverno-cli/usage/apply/ · *CLI `test`*: https://kyverno.io/docs/kyverno-cli/usage/test/
- CNCF — *KCA Curriculum*: https://github.com/cncf/curriculum