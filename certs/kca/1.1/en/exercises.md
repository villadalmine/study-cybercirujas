# Kyverno Policies & Rules — Guided Exercises

> **Certification:** Kyverno Certified Associate (KCA) · **Topic 1.1** (exam weight 4.51%)
> **Reference:** [CNCF KCA Curriculum](https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf) · [Kyverno docs — Policies & Rules](https://kyverno.io/docs/policy-types/) · [Writing Policies overview](https://kyverno.io/docs/writing-policies/)
>
> **What you will internalize:** the anatomy of a Kyverno policy object, the difference between `Policy` and `ClusterPolicy`, the four rule types (`validate`, `mutate`, `generate`, `verifyImages`), how `match`/`exclude` select resources, how `validationFailureAction` changes admission behavior, pattern anchors, and how results surface in `PolicyReport` objects.

## Prerequisites

- A throwaway Kubernetes cluster you can break. `kind create cluster --name kca` is ideal.
- `kubectl` v1.27+ on your `PATH`, context pointed at that cluster.
- Outbound internet to pull the Kyverno release manifest and container images.
- ~2 GB free RAM; Kyverno runs an admission controller plus a background/reports controller.

Everything below is idempotent-ish: re-applying a policy updates it in place, and deleting the namespaces at the end returns the cluster to a clean state.

---

## Exercise 1 — Install Kyverno and read the CRDs

**Goal:** get the engine running and understand what "a policy" *is* at the API level.

1. Install the Kyverno control plane (pinning a version — never `latest` in exam-style work):

   ```bash
   kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.13.0/install.yaml
   ```

2. Wait for the controllers to become ready:

   ```bash
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller
   kubectl -n kyverno get pods
   ```

   Expected (names carry a hash suffix):

   ```
   NAME                                             READY   STATUS    RESTARTS   AGE
   kyverno-admission-controller-6f8d9c7b5-4xk2n     1/1     Running   0          58s
   kyverno-background-controller-7c9f6d4b8-tq7m9    1/1     Running   0          58s
   kyverno-cleanup-controller-59b7c6d9f-l8w4z       1/1     Running   0          58s
   kyverno-reports-controller-6d8b7f5c4-r2n6p       1/1     Running   0          58s
   ```

3. Discover the Custom Resource Definitions Kyverno installed:

   ```bash
   kubectl api-resources --api-group=kyverno.io
   ```

   Expected (abridged):

   ```
   NAME              SHORTNAMES   APIVERSION      NAMESPACED   KIND
   clusterpolicies   cpol         kyverno.io/v1   false        ClusterPolicy
   policies          pol          kyverno.io/v1   true         Policy
   ```

4. Inspect the two policy kinds and note the `NAMESPACED` column above.

> **Check your understanding**
> 1. A `ClusterPolicy` and a `Policy` share the same schema. What single property differs between them, and what practical consequence does that have for which resources each can govern?
> 2. Kyverno ships as several separate deployments (admission, background, reports, cleanup). Why is the *admission* controller the one that must be healthy for `Enforce` policies to actually block a `kubectl apply`?

---

## Exercise 2 — Your first `validate` rule (Audit → Enforce)

**Goal:** author a validation policy, see the difference between `Audit` and `Enforce`, and read the result in a `PolicyReport`.

1. Create a policy that requires every Pod to carry a `team` label. Start in **Audit** so nothing is blocked:

   ```yaml
   # require-team-label.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
   spec:
     validationFailureAction: Audit
     background: true
     rules:
       - name: check-team-label
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
                 team: "?*"
   ```

   ```bash
   kubectl apply -f require-team-label.yaml
   ```

2. Create a non-compliant Pod. Because the action is `Audit`, it is **admitted**:

   ```bash
   kubectl run nginx --image=nginx:1.27
   ```

   ```
   pod/nginx created
   ```

3. Read the machine-generated report for that Pod:

   ```bash
   kubectl get policyreport -o wide
   ```

   Expected:

   ```
   NAME                                   KIND   NAME    PASS   FAIL   WARN   ERROR   SKIP   AGE
   e4f...   ...
   ```

   Then drill into the failing result:

   ```bash
   kubectl describe policyreport | grep -A6 "require-team-label"
   ```

   ```
   Result:   fail
   Rule:     check-team-label
   Message:  validation error: The label 'team' is required on all Pods.
             rule check-team-label failed at path /metadata/labels/team/
   ```

4. Flip the policy to **Enforce** and re-apply:

   ```bash
   kubectl patch clusterpolicy require-team-label \
     --type merge -p '{"spec":{"validationFailureAction":"Enforce"}}'
   ```

5. Try the non-compliant Pod again — now it is **rejected at admission time**:

   ```bash
   kubectl run nginx2 --image=nginx:1.27
   ```

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/default/nginx2 was blocked due to the following policies

   require-team-label:
     check-team-label: 'validation error: The label ''team'' is required on all
       Pods. rule check-team-label failed at path /metadata/labels/team/'
   ```

6. Prove the compliant path works:

   ```bash
   kubectl run nginx3 --image=nginx:1.27 --labels team=payments
   ```

   ```
   pod/nginx3 created
   ```

> **Check your understanding**
> 1. Under `Audit`, the Pod in step 2 was created *and* a failing report appeared. Which of the four Kyverno controllers produced that report, and why is `background: true` relevant to it?
> 2. In the `validate.pattern`, what does the value `"?*"` mean, and how does it differ from `"*"`?
> 3. Newer Kyverno versions deprecate `spec.validationFailureAction` in favor of a per-rule field. What is that field's path, and why is per-rule granularity useful in a single multi-rule policy?

---

## Exercise 3 — `match` and `exclude` scoping with `any` / `all`

**Goal:** control *which* resources a rule applies to, and understand the logical difference between `any` and `all`.

1. Create two namespaces to scope against:

   ```bash
   kubectl create ns prod
   kubectl create ns sandbox
   ```

2. Apply a policy that enforces the `team` label **only** for Pods in the `prod` namespace, and **excludes** anything created by the built-in `system:` service accounts:

   ```yaml
   # require-team-label-prod.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label-prod
   spec:
     validationFailureAction: Enforce
     rules:
       - name: check-team-label-in-prod
         match:
           all:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - prod
         exclude:
           any:
             - clusterRoles:
                 - system:node
         validate:
           message: "Pods in 'prod' must carry a 'team' label."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   ```bash
   kubectl apply -f require-team-label-prod.yaml
   ```

3. Confirm the rule is scoped: a bare Pod in `sandbox` is allowed, the same Pod in `prod` is blocked:

   ```bash
   kubectl -n sandbox run web --image=nginx:1.27      # allowed
   kubectl -n prod    run web --image=nginx:1.27      # blocked
   ```

   ```
   pod/web created
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
   resource Pod/prod/web was blocked due to the following policies
   require-team-label-prod:
     check-team-label-in-prod: 'validation error: Pods in ''prod'' must carry a
       ''team'' label. ...'
   ```

4. Compare the semantics: edit the `match` block temporarily so it lists **two** entries under `any` (`Pod` *or* `Deployment`) versus **two** entries under `all`. Apply, and observe how each behaves against a Pod.

> **Check your understanding**
> 1. Within `match`, what is the boolean relationship *between the list entries* under `any` versus under `all`? (Not the filters inside one entry — the entries themselves.)
> 2. The `exclude` block above filters on `clusterRoles`. Besides `kinds`, `names`, `namespaces`, and `selector`, name two identity-based filters (`subjects`, `roles`/`clusterRoles`) that `match`/`exclude` can key on and explain when identity-based matching is the *only* correct choice.
> 3. This policy matches on `kinds: [Pod]`, yet Kyverno's autogen feature will still guard Deployments. What is autogen doing, and what would you add to the policy to see the auto-generated Deployment/DaemonSet/CronJob rules?

---

## Exercise 4 — A `mutate` rule (`patchStrategicMerge` + anchors)

**Goal:** modify resources at admission time and learn the mutation anchors.

1. Apply a policy that adds a default `team=unassigned` label **only if the Pod does not already have one**:

   ```yaml
   # add-default-team.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-default-team
   spec:
     rules:
       - name: add-team-if-missing
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         mutate:
           patchStrategicMerge:
             metadata:
               labels:
                 +(team): unassigned
   ```

   ```bash
   kubectl apply -f add-default-team.yaml
   ```

2. Create a Pod with **no** `team` label and inspect the result:

   ```bash
   kubectl run cache --image=redis:7
   kubectl get pod cache -o jsonpath='{.metadata.labels}' ; echo
   ```

   ```
   {"run":"cache","team":"unassigned"}
   ```

3. Create a Pod that **already** has the label and confirm it is left untouched (the `+()` anchor does not overwrite):

   ```bash
   kubectl run api --image=redis:7 --labels team=payments
   kubectl get pod api -o jsonpath='{.metadata.labels}' ; echo
   ```

   ```
   {"run":"api","team":"payments"}
   ```

> **Check your understanding**
> 1. What does the `+()` (add-if-absent) anchor guarantee that a plain `team: unassigned` key would not?
> 2. Mutation and validation run in a defined order for the same admission request. Does Kyverno *mutate* before or after it *validates*, and why does that ordering let a mutate rule "fix" a resource so it passes a later validate rule?
> 3. Besides `patchStrategicMerge`, name the other mutation method Kyverno supports for surgical, position-based edits, and one situation where you'd reach for it instead.

---

## Exercise 5 — A `generate` rule with `synchronize`

**Goal:** have Kyverno create and keep-in-sync a downstream resource when a trigger resource appears.

1. Create a source `ConfigMap` in `default` that will be cloned into every new namespace:

   ```bash
   kubectl -n default create configmap org-defaults \
     --from-literal=cost-center=platform
   ```

2. Apply a policy that clones it into any newly created namespace and keeps it synchronized:

   ```yaml
   # sync-org-defaults.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: sync-org-defaults
   spec:
     rules:
       - name: clone-org-defaults
         match:
           any:
             - resources:
                 kinds:
                   - Namespace
         generate:
           apiVersion: v1
           kind: ConfigMap
           name: org-defaults
           namespace: "{{request.object.metadata.name}}"
           synchronize: true
           clone:
             namespace: default
             name: org-defaults
   ```

   ```bash
   kubectl apply -f sync-org-defaults.yaml
   ```

3. Create a fresh namespace and confirm the ConfigMap materialized:

   ```bash
   kubectl create ns team-alpha
   kubectl -n team-alpha get configmap org-defaults
   ```

   ```
   NAME           DATA   AGE
   org-defaults   1      3s
   ```

4. Test synchronization: edit the **source** and watch the clone reconcile:

   ```bash
   kubectl -n default patch configmap org-defaults \
     --type merge -p '{"data":{"cost-center":"shared-infra"}}'
   sleep 3
   kubectl -n team-alpha get configmap org-defaults -o jsonpath='{.data.cost-center}' ; echo
   ```

   ```
   shared-infra
   ```

> **Check your understanding**
> 1. Which Kyverno controller reconciles generated resources, and what does `synchronize: true` add compared to a one-shot generate?
> 2. The `namespace` field uses `{{request.object.metadata.name}}`. What is this expression called, and at what point in request handling is it resolved?
> 3. What is the difference between the `clone:` form used here and the `data:` form of a generate rule?

---

## Exercise 6 — Anchors, preconditions, and `deny`

**Goal:** move beyond simple presence checks into conditional logic — the part of rule authoring the exam probes hardest.

1. Apply a policy using a **conditional anchor** `()`: *if* a container's `image` uses the `:latest` tag, *then* its `imagePullPolicy` must be `Always`:

   ```yaml
   # latest-needs-always.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: latest-needs-always
   spec:
     validationFailureAction: Enforce
     rules:
       - name: latest-tag-pull-policy
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           message: "Containers on ':latest' must set imagePullPolicy: Always."
           pattern:
             spec:
               containers:
                 - (image): "*:latest"
                   imagePullPolicy: Always
   ```

   ```bash
   kubectl apply -f latest-needs-always.yaml
   kubectl run bad --image=nginx:latest --overrides='{"spec":{"containers":[{"name":"bad","image":"nginx:latest","imagePullPolicy":"IfNotPresent"}]}}'
   ```

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
   resource Pod/default/bad was blocked due to the following policies
   latest-needs-always:
     latest-tag-pull-policy: 'validation error: Containers on '':latest'' must set
       imagePullPolicy: Always. ...'
   ```

2. Apply a policy using **`preconditions`** + a **`deny`** block: reject Pods that run as UID 0, but *only* evaluate the rule for Pods whose name starts with `svc-`:

   ```yaml
   # no-root-for-svc.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: no-root-for-svc
   spec:
     validationFailureAction: Enforce
     rules:
       - name: block-uid-0
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         preconditions:
           all:
             - key: "{{ request.object.metadata.name }}"
               operator: AnyIn
               value: "svc-*"
         validate:
           message: "Service Pods (svc-*) must not run as UID 0."
           deny:
             conditions:
               any:
                 - key: "{{ request.object.spec.securityContext.runAsUser || `0` }}"
                   operator: Equals
                   value: 0
   ```

   ```bash
   kubectl apply -f no-root-for-svc.yaml
   kubectl run svc-billing --image=nginx:1.27   # blocked (defaults to UID 0)
   kubectl run tmp-debug   --image=nginx:1.27   # allowed (precondition not met)
   ```

> **Check your understanding**
> 1. In step 1, the `(image)` key is a *conditional anchor*. Describe the "if/then" evaluation it triggers, and what happens to the check when the `image` value does **not** match `*:latest`.
> 2. A `validate.pattern` and a `validate.deny` express the *opposite* polarity. When you write a `deny` block, does a matching condition mean the resource *passes* or *fails*? Contrast that with `pattern`.
> 3. In step 2, why is the JMESPath `|| \`0\`` fallback essential? What would break if a Pod simply omitted `spec.securityContext.runAsUser` and you had written `{{ request.object.spec.securityContext.runAsUser }}` alone?
> 4. What is the functional difference between putting a filter in `preconditions` versus expressing the same condition inside `match`?

---

## Exercise 7 — Verify with the Kyverno CLI (no cluster mutation)

**Goal:** test policies against candidate manifests offline — how you iterate safely and how CI gates policies.

1. Install the CLI and save a manifest + policy locally:

   ```bash
   # brew install kyverno   (or download from the release page)
   kyverno version
   ```

2. Run a policy against a resource file without touching the cluster:

   ```bash
   kyverno apply require-team-label.yaml --resource my-pod.yaml
   ```

   ```
   Applying 1 policy rule(s) to 1 resource(s)...

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   ```

3. (Optional) Explore the built-in policy tester with a `values.yaml` and `--policy-report`.

> **Check your understanding**
> 1. `kyverno apply` never contacts the admission webhook. What class of policy behavior can it therefore **not** fully reproduce, and why does that matter for `generate` rules specifically?
> 2. Why is offline CLI validation a better gate for pull requests than relying on `Enforce` mode in a live cluster?

---

## Cleanup

```bash
kubectl delete clusterpolicy \
  require-team-label require-team-label-prod add-default-team \
  sync-org-defaults latest-needs-always no-root-for-svc --ignore-not-found
kubectl delete ns prod sandbox team-alpha --ignore-not-found
kubectl delete pod nginx nginx3 cache api web --ignore-not-found
# Full teardown:  kind delete cluster --name kca
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
1. Only the **scope** differs. `ClusterPolicy` is cluster-scoped (no `metadata.namespace`) and can match resources in **any** namespace as well as cluster-scoped resources (Namespaces, ClusterRoles, PersistentVolumes, CRDs). `Policy` is namespaced and its rules apply **only** to resources in the same namespace as the `Policy` object. The schema (`spec.rules`, rule types, `match`/`exclude`) is otherwise identical.
2. `Enforce` blocking happens synchronously during the API server's admission phase: the API server calls Kyverno's `ValidatingWebhookConfiguration`, and the **admission controller** returns allow/deny. If that controller is down, the webhook either fails open or the request errors (depending on `failurePolicy`), so no real blocking occurs. The background and reports controllers only produce *after-the-fact* `PolicyReport` results and never sit in the admission path.

### Exercise 2
1. The **reports controller** (with help from the background scanner) generates `PolicyReport`/`ClusterPolicyReport` objects. `background: true` enables periodic re-evaluation of *already-existing* resources against the policy outside the admission path — that scan is what produces a failing result for a Pod that was admitted under `Audit`. Without background scanning, only newly admitted resources would generate results.
2. `"?*"` requires **at least one character** — `?` = exactly one character, `*` = zero or more — so it means "the `team` label must exist **and** be non-empty." Plain `"*"` matches zero-or-more characters and therefore also matches an empty string, so a label present but empty would still pass.
3. The per-rule field is `spec.rules[].validate.failureAction` (values `Enforce`/`Audit`). Per-rule granularity lets one policy `Enforce` a critical rule while keeping a newer or noisier rule in `Audit` during rollout, instead of forcing every rule in the policy to share one action. (Related: `validate.failureActionOverrides` can vary the action per namespace.)

### Exercise 3
1. Entries under **`any`** are OR-ed (the resource matches if it satisfies *any one* entry); entries under **`all`** are AND-ed (it must satisfy *every* entry). Inside a single entry, the individual filters (kinds + namespaces + selector …) are always AND-ed together.
2. Identity filters include **`subjects`** (users/groups/service accounts), **`roles`** (namespaced RBAC roles), and **`clusterRoles`**. They are the only correct choice when the rule must react to *who* is making the request rather than *what* the resource is — e.g., "block this action unless the requester holds a specific ClusterRole," which no resource field can express.
3. **Autogen** automatically synthesizes equivalent rules targeting the Pod-controller kinds (`Deployment`, `DaemonSet`, `StatefulSet`, `ReplicaSet`, `Job`, `CronJob`) so a Pod-level rule also guards the Pods those controllers *will create*. You can see them with `kubectl get cpol require-team-label-prod -o yaml` and reading the `metadata.annotations["pod-policies.kyverno.io/autogen-controllers"]` value plus the rendered rules, or control it via that annotation (e.g. set it to `none` to disable autogen).

### Exercise 4
1. `+(team): unassigned` **only adds the key if it is absent** and never overwrites an existing value. A plain `team: unassigned` under `patchStrategicMerge` would *set/overwrite* the label to `unassigned` even for Pods that already declared a real team.
2. Kyverno **mutates before it validates** for the same request. That ordering means a mutate rule can inject or correct fields (add a default label, set a `securityContext`) so that a subsequent validate rule — in the same or another policy — sees the already-corrected object and passes.
3. **`patchesJson6902`** (RFC 6902 JSON Patch): use it for precise, position/index-based operations — e.g. inserting an element at a specific array index, `remove` on a path, or `test`-guarded edits — where strategic-merge semantics can't express the change.

### Exercise 5
1. The **background controller** reconciles generated resources. `synchronize: true` makes the relationship *ongoing*: changes to the source (or deletion/drift of the clone) are continuously reconciled, and deleting the trigger removes the generated resource. A one-shot generate (`synchronize: false`) creates the downstream object once and never touches it again.
2. It is a **variable / JMESPath substitution** (`{{ ... }}`) referencing the admission request context. It is resolved at rule-execution time, when Kyverno processes the triggering admission request, before the generated resource spec is finalized.
3. **`clone:`** copies an existing source object (from a named namespace) and can keep it in sync with that live source; **`data:`** defines the generated resource's content **inline** in the policy itself, so there is no external source object to track.

### Exercise 6
1. The conditional anchor `(image): "*:latest"` means: **if** the sibling condition matches (the container image ends in `:latest`), **then** the rest of that map entry (`imagePullPolicy: Always`) must also hold. If `image` does **not** match `*:latest`, the anchor's condition is false, the whole block is **skipped** for that container, and it passes without checking `imagePullPolicy`.
2. `deny` is **inverted** relative to `pattern`. With `deny`, if the `conditions` evaluate **true**, the resource is **denied/failed**; if false, it passes. With `pattern`, the resource must **match** the pattern to pass — a mismatch is the failure. So `pattern` describes the *allowed* shape, `deny` describes the *forbidden* condition.
3. The `|| \`0\`` fallback supplies a default when `runAsUser` is unset. Without it, `{{ request.object.spec.securityContext.runAsUser }}` evaluates to `null`/undefined for a Pod that omits the field, so `operator: Equals value: 0` would **not** match — and a Pod that inherits root by *default* (no explicit `runAsUser`) would slip through the check it was meant to catch.
4. `preconditions` are evaluated **after** the resource has already matched the `match`/`exclude` scope and can use full JMESPath/variables over request context (values, operators like `AnyIn`, comparisons). `match` is the coarse resource selector (kinds/namespaces/selectors/identity). Use `match` to pick the resource population; use `preconditions` for richer per-request logic that `match` cannot express. A precondition that isn't met **skips** the rule rather than failing it.

### Exercise 7
1. `kyverno apply` cannot fully reproduce **admission-time side effects and controller reconciliation** — most notably `generate` (which is executed by the background controller against a live cluster) and anything depending on live cluster state (`context` with `apiCall`, image verification against a registry). It evaluates the policy logic against the given manifests but does not run the generation/sync loop.
2. Offline CLI validation is **deterministic, fast, and non-destructive**: it runs in CI against candidate manifests with no cluster access, catching violations *before* merge. Relying on live `Enforce` means the bad manifest has already reached a cluster (and blocks a real deploy), and it can't run on a pull request that hasn't been applied yet.

</details>