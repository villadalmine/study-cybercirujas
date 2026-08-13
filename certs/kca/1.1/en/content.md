# Kyverno Policies & Rules

> KCA · Domain 1 · Topic 1.1 · Exam weight **4.51%**
> Policy-as-code for Kubernetes admission control, mutation, and resource generation — authored as native Kubernetes CRDs.

---

## 1. Motivation: the admission-control gap in production clusters

A Kubernetes API server accepts any manifest that is *structurally* valid and passes RBAC. It does not care whether your `Deployment` sets resource limits, whether the image tag is `:latest`, whether `runAsNonRoot` is set, or whether a new namespace has a default-deny `NetworkPolicy`. In a multi-tenant production cluster, that permissiveness is the problem: the gap between "the API accepts it" and "the platform team considers it safe to run" is exactly where incidents live — a memory-limitless pod that OOM-kills its node's neighbours, a mutable `:latest` tag that silently drifts between rollouts, a namespace with no network isolation.

You can close that gap in three places:

- **Left, in CI** — `kubeconform`, `conftest`, `kyverno apply` in a pipeline. Fast feedback, but bypassable: anyone with `kubectl apply` credentials skips CI entirely.
- **At the door, in admission control** — a webhook that the API server calls *synchronously* before persisting the object. Unbypassable for anything going through the API. This is where Kyverno's `validate`/`mutate` rules live.
- **After the fact, in reporting** — background scans of what is already running, surfaced as reports. Catches drift and pre-existing violations that predate the policy.

Kyverno's architectural bet is that policy should be expressed as **Kubernetes resources in YAML**, using the same pattern-matching and overlay idioms operators already know from `kubectl` and strategic-merge patches — not as a separate language (Rego) with its own mental model. The trade-off is expressiveness vs. approachability, and it is the central comparison of this topic.

Kyverno runs as a set of in-cluster controllers and registers itself as dynamic **`ValidatingWebhookConfiguration`** and **`MutatingWebhookConfiguration`** objects. Critically, it **only registers webhooks for the resource kinds your installed policies actually reference** — install a policy that matches only `Pods` and the API server is only called for pods, not for every `ConfigMap` and `Secret`. This is what keeps admission latency and API-server blast radius bounded.

---

## 2. The object model: Policy, ClusterPolicy, and Rule

Two policy kinds and one rule shape. Everything in this topic is a composition of these.

```
ClusterPolicy (cluster-scoped)  ─┐
Policy       (namespace-scoped) ─┴─▶ spec.rules[]  ─▶  each rule has exactly ONE action:
                                                        validate | mutate | generate | verifyImages
```

### 2.1 Policy vs. ClusterPolicy

| | `ClusterPolicy` | `Policy` |
|---|---|---|
| API kind | `kyverno.io/v1 · ClusterPolicy` | `kyverno.io/v1 · Policy` |
| Scope | Whole cluster, all namespaces | Single namespace |
| `kubectl` short name | `cpol` | `pol` |
| Can match cluster-scoped resources (Namespace, Node, PV) | Yes | No — only namespaced resources in its namespace |
| Typical owner | Platform / security team | Application team, self-service guardrails |
| Precedence | Both apply; a resource is evaluated against every matching policy of either kind | |

**Rule of thumb:** platform baselines are `ClusterPolicy`; delegated, namespace-local exceptions or team-specific rules are `Policy`.

### 2.2 The four rule types — decision table

| Rule type | What it does | Runs at admission | Runs in background | Mutates the request? | Canonical use |
|---|---|---|---|---|---|
| `validate` | Accept/reject or report based on a pattern or conditions | ✅ | ✅ (report only) | ❌ | Require limits, forbid `:latest`, enforce PSA |
| `mutate` | Inject/overlay/remove fields | ✅ | ✅ (mutate-existing) | ✅ | Add default `securityContext`, inject sidecar labels |
| `generate` | Create *other* resources when a trigger appears | ✅ (trigger) | ✅ (sync) | ❌ (creates new objects) | Default `NetworkPolicy`, sync `ConfigMap`/`Secret` |
| `verifyImages` | Verify image signatures/attestations (Cosign/Notary) | ✅ | ✅ | ✅ (can add digest) | Supply-chain: only signed images |

A single policy may carry multiple rules, but **each rule holds exactly one** of these blocks. Mixing `validate` and `mutate` in one rule is a validation error.

### 2.3 Anatomy of a rule

```yaml
rules:
  - name: <unique-within-policy>          # required
    match:                                # which resources this rule applies to
      any: | all: [...]
    exclude:                              # carve-outs from the match set
      any: | all: [...]
    preconditions:                        # extra JMESPath gates before the action
      any: | all: [...]
    context: [...]                        # external data: ConfigMap, API call, image data
    validate: {...}  # ─┐
    mutate:   {...}  #  ├─ exactly ONE of these
    generate: {...}  #  │
    verifyImages: [] # ─┘
```

**`match`/`exclude` selectors** use `any` (logical OR across blocks) or `all` (logical AND), each block filtering on:

- `resources` — `kinds`, `names`, `namespaces`, `selector` (label), `operations` (`CREATE`/`UPDATE`/`DELETE`/`CONNECT`)
- `subjects`, `roles`, `clusterRoles` — the *identity* making the request (from the `AdmissionReview.userInfo`)

---

## 3. `validate` — the core of admission enforcement

### 3.1 `Enforce` vs. `Audit`

This is the single most consequential knob in the topic.

| | `Enforce` | `Audit` |
|---|---|---|
| Behaviour on violation | **Blocks** the admission request | **Allows**, records a failing entry in a `PolicyReport` |
| Student-facing effect | `kubectl apply` returns an error | apply succeeds, violation visible in reports |
| Production rollout use | Final state, after soak | Always the *first* state for a new policy — measure blast radius before blocking |
| Where set | `spec.validationFailureAction` (v1) **or** per-rule `validate.failureAction` (v2beta1+) | same |

> **Version note.** In `kyverno.io/v1` the field is `spec.validationFailureAction` and since Kyverno **1.10** its values are capitalized `Enforce`/`Audit` (older lowercase `enforce`/`audit` still parse with a deprecation warning). In `kyverno.io/v2beta1`+ the recommended location is **per rule** under `validate.failureAction`, so different rules in one policy can enforce or audit independently. Prefer the per-rule form for new policies.

**Standard production pattern:** ship every new policy as `Audit`, watch the `PolicyReport` fail count for a release cycle, fix or exempt the offenders, then flip to `Enforce`.

### 3.2 Validation styles

Kyverno gives you three ways to express "is this resource acceptable":

1. **`pattern`** — an overlay the resource must match (strategic-merge style, with anchors).
2. **`anyPattern`** — a list of patterns; the resource must match *at least one* (logical OR).
3. **`deny.conditions`** — imperative JMESPath conditions; if they evaluate true, deny.
4. **`foreach`** — iterate a list (e.g. `spec.containers`) and apply `pattern`/`deny` per element.
5. **`cel`** — CEL expressions (Kyverno 1.11+), for parity with native `ValidatingAdmissionPolicy`.

#### Pattern anchors — the grammar you must know for the exam

| Anchor | Name | Meaning |
|---|---|---|
| *(none)* | Default | Field must exist and match |
| `()` | Conditional | *If* the anchored field matches, the sibling pattern must match; otherwise skip |
| `=()` | Equality | Field **must** exist and equal the value |
| `X()` | Negation | Field must **not** exist |
| `^()` | Existence | For arrays: **at least one** element must match |
| `<()` | Global | If the anchor matches *anywhere*, apply the pattern to *all* elements |
| `+()` | Add-if-absent | (mutate only) add the value if the field is missing |

Wildcards inside string values: `*` (zero-or-more chars), `?` (exactly one char), `?*` (one-or-more = "non-empty"), and a leading `!` for negation (`"!*:latest"` = "must not end in `:latest`").

### 3.3 Complete manifest — require resource requests and limits

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-requests-limits
  annotations:
    policies.kyverno.io/title: Require Requests and Limits
    policies.kyverno.io/category: Resource Management
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
spec:
  validationFailureAction: Audit        # start in Audit; flip to Enforce after soak
  background: true                      # also evaluate pre-existing pods in reports
  rules:
    - name: validate-resources
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          CPU and memory resource requests and limits are required
          for every container.
        pattern:
          spec:
            containers:
              - name: "*"               # applies to every container
                resources:
                  requests:
                    memory: "?*"        # must be non-empty
                    cpu: "?*"
                  limits:
                    memory: "?*"
```

Because the rule matches `Pod`, Kyverno's **autogen** silently expands it to matching rules for `Deployment`, `StatefulSet`, `DaemonSet`, `Job`, `CronJob`, `ReplicaSet`, and `ReplicationController` — so you write the pod rule once and it enforces on the controllers that create pods. (More on autogen in §7.)

### 3.4 Complete manifest — disallow the `:latest` tag (and untagged images)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "An explicit image tag is required (no untagged images)."
        pattern:
          spec:
            containers:
              - image: "*:*"            # must contain a tag separator
    - name: forbid-latest-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Using the mutable ':latest' tag is not allowed."
        pattern:
          spec:
            containers:
              - image: "!*:latest"      # negation: must NOT end in :latest
```

### 3.5 Complete manifest — deny root with `foreach` + `deny.conditions`

`pattern` is declarative and clean for shape checks; `deny.conditions` with JMESPath is the tool when you need boolean logic, defaults, or to reason about *missing* fields.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-non-root
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
        message: "Containers must set securityContext.runAsNonRoot=true."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  # element.securityContext.runAsNonRoot, defaulting to false if absent
                  - key: "{{ element.securityContext.runAsNonRoot || `false` }}"
                    operator: NotEquals
                    value: true
```

The `|| `false`` idiom is the JMESPath way to treat "field absent" as "insecure default" — a classic source of policy bypasses if you forget it. A `pattern` alone cannot express "field is missing → fail" without the negation anchor; `deny.conditions` makes it explicit.

#### JMESPath operators available in `conditions`/`preconditions`

`Equals`, `NotEquals`, `In`, `NotIn`, `AnyIn`, `AllIn`, `AnyNotIn`, `AllNotIn`, `GreaterThan`, `GreaterThanOrEquals`, `LessThan`, `LessThanOrEquals`, `DurationGreaterThan(OrEquals)`, `DurationLessThan(OrEquals)`.

---

## 4. `mutate` — defaulting and normalization at admission

Mutation runs **before** validation in the admission chain, so a `mutate` rule can supply a compliant default that a sibling `validate` rule then confirms. Three engines:

| Engine | Field | Best for |
|---|---|---|
| Strategic-merge | `patchStrategicMerge` | Adding/overlaying fields on known Kubernetes types (uses `+()` anchor) |
| JSON Patch (RFC 6902) | `patchesJson6902` | Precise `add`/`replace`/`remove` at explicit JSON paths |
| Iteration | `foreach` | Per-element mutation of a list |

### 4.1 Complete manifest — add a default `securityContext` (add-if-absent)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-securitycontext
spec:
  rules:
    - name: set-runasnonroot
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"                  # conditional anchor: select every container
                securityContext:
                  +(runAsNonRoot): true      # add-if-absent: never overwrite an explicit value
                  +(allowPrivilegeEscalation): false
```

The `+()` anchor is what makes mutation **non-destructive**: if a workload already sets `runAsNonRoot: false` deliberately (and is exempted elsewhere), the mutation leaves it alone rather than silently flipping it.

### 4.2 `patchesJson6902` for precise edits

```yaml
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/metadata/labels/team"
            value: "platform"
          - op: replace
            path: "/spec/containers/0/imagePullPolicy"
            value: "Always"
```

**Trade-off:** JSON6902 targets exact indices (`/containers/0/...`) — brittle if the array order changes; use `foreach` when you need "every container" semantics with JSON-patch precision.

---

## 5. `generate` — companion resources and drift correction

`generate` creates *new* resources triggered by another resource's admission. The killer feature is **`synchronize: true`**: the generated resource is owned and reconciled by Kyverno's background controller — edit or delete it out-of-band and it is restored; update the source and downstream copies follow.

### 5.1 Complete manifest — default-deny `NetworkPolicy` for every new namespace

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-deny-networkpolicy
spec:
  rules:
    - name: create-default-deny
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true                 # reconcile if edited/deleted
        data:
          spec:
            podSelector: {}               # all pods in the namespace
            policyTypes:
              - Ingress
              - Egress
```

### 5.2 `clone` instead of `data` — sync a Secret from a source of truth

```yaml
      generate:
        apiVersion: v1
        kind: Secret
        name: regcred
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        clone:
          namespace: platform-system
          name: regcred                   # master copy; updates propagate to all clones
```

`background: true` is **required** for synchronization — the background controller is what reconciles clones after the initial admission-time creation.

---

## 6. CLI workflow — install, apply, test, inspect

### 6.1 Install and confirm the controllers

```console
$ helm repo add kyverno https://kyverno.github.io/kyverno/
$ helm install kyverno kyverno/kyverno -n kyverno --create-namespace

$ kubectl -n kyverno get pods
NAME                                             READY   STATUS    RESTARTS   AGE
kyverno-admission-controller-7d9f8c6b4-2xqzt     1/1     Running   0          48s
kyverno-background-controller-5c7b9d8f6-l9k2m    1/1     Running   0          48s
kyverno-cleanup-controller-6b8c7d9e4-p4rzn       1/1     Running   0          48s
kyverno-reports-controller-8d6f5c7b9-w7t3q       1/1     Running   0          48s
```

Four controllers, each with a distinct job: **admission** (webhooks), **background** (generate + mutate-existing + scans), **reports** (PolicyReports), **cleanup** (CleanupPolicy TTL).

### 6.2 Apply a policy and watch webhook registration

```console
$ kubectl apply -f require-requests-limits.yaml
clusterpolicy.kyverno.io/require-requests-limits created

$ kubectl get cpol
NAME                      ADMISSION   BACKGROUND   READY   AGE
require-requests-limits   true        true         True    12s

$ kubectl get validatingwebhookconfigurations | grep kyverno
kyverno-resource-validating-webhook-cfg   2   18s
kyverno-policy-validating-webhook-cfg     1   6m
```

Note the resource webhook only appears **after** a matching policy exists — dynamic registration in action. `READY: True` means the policy compiled and its webhook is live; `False` means a compile or webhook error you must inspect with `kubectl describe cpol`.

### 6.3 Test enforcement against a bad pod

```console
$ cat pod-bad.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-bad
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      # no resources block

$ kubectl apply -f pod-bad.yaml
Error from server: error when creating "pod-bad.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource Pod/default/nginx-bad was blocked due to the following policies

require-requests-limits:
  validate-resources: 'validation error: CPU and memory resource requests and
    limits are required for every container. rule validate-resources failed at path
    /spec/containers/0/resources/'
```

That denial message — policy name, rule name, the `message`, and the failing JSON path — is the exact format Kyverno emits and worth recognizing on the exam.

### 6.4 Offline evaluation with `kyverno apply` (CI / no cluster needed)

```console
$ kyverno apply require-requests-limits.yaml --resource pod-bad.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy require-requests-limits -> resource default/Pod/nginx-bad failed:
1. validate-resources: validation error: CPU and memory resource requests and
   limits are required for every container. rule validate-resources failed at
   path /spec/containers/0/resources/

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

### 6.5 The `kyverno test` framework — assert expected outcomes

`kyverno-test.yaml` binds policies + resources + expected results into a regression suite:

```yaml
# kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-requests-limits
policies:
  - require-requests-limits.yaml
resources:
  - resources.yaml
results:
  - policy: require-requests-limits
    rule: validate-resources
    resource: nginx-bad
    kind: Pod
    result: fail
  - policy: require-requests-limits
    rule: validate-resources
    resource: nginx-good
    kind: Pod
    result: pass
```

```console
$ kyverno test .

Executing require-requests-limits...
│───│──────────────────────────│───────────────────│──────────│────────│
│ ID│ POLICY                   │ RULE              │ RESOURCE │ RESULT │
│───│──────────────────────────│───────────────────│──────────│────────│
│ 1 │ require-requests-limits  │ validate-resources│ nginx-bad│ Pass   │
│ 2 │ require-requests-limits  │ validate-resources│ nginx-good│ Pass  │
│───│──────────────────────────│───────────────────│──────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

(`RESULT: Pass` here means "the actual outcome matched the *expected* outcome in `results:`", not that the resource passed the policy.)

---

## 7. Autogen: the pod-controller expansion you must not fight

When a rule matches `Pod`, Kyverno auto-generates parallel rules for the controllers that produce pods, prefixing them `autogen-`. This is why a single Pod-scoped policy also blocks a bad `Deployment`.

```console
$ kubectl get cpol require-requests-limits -o yaml | grep -A2 'autogen'
    pod-policies.kyverno.io/autogen-controllers: DaemonSet,Deployment,Job,StatefulSet,CronFlow...
```

Control it with the annotation:

```yaml
metadata:
  annotations:
    pod-policies.kyverno.io/autogen-controllers: none   # disable entirely
    # or restrict: "Deployment,StatefulSet"
```

**Diagnostic gotcha:** when a Deployment is rejected, the denial names the rule `autogen-<yourrule>`, not `<yourrule>`. Students who wrote a Pod rule and see `autogen-` in the error are looking at the *same* rule expanded — not a second policy.

---

## 8. Verification & failure diagnosis

### 8.1 Is the policy healthy?

```console
$ kubectl get cpol
NAME                      ADMISSION   BACKGROUND   READY   AGE
require-requests-limits   true        true         True    5m

$ kubectl describe cpol require-requests-limits | tail -n 8
Status:
  Conditions:
    Type:    Ready
    Status:  True
  Rule Count:
    Validate:  1
  Autogen:
    Rules:  ...
Events:  <none>
```

`READY: False` → run `kubectl describe` and read `Status.Conditions` for the compile error (bad JMESPath, invalid anchor, unknown kind).

### 8.2 What did it decide? — Policy Reports

Reports are the authoritative record for `Audit` policies and background scans, stored as `wgpolicyk8s.io/v1alpha2` CRDs (Policy WG standard, shared with other engines).

```console
$ kubectl get polr -A
NAMESPACE   NAME                                   PASS   FAIL   WARN   ERROR   SKIP   AGE
default     e8f3c2a1-4b5d-6e7f-8a9b-0c1d2e3f4a5b   2      1      0       0      0      9m

$ kubectl get clusterpolicyreport
NAME                      PASS   FAIL   WARN   ERROR   SKIP   AGE
clusterpolicyreport       14     2      0       0      0      9m

$ kubectl describe polr e8f3c2a1-4b5d-6e7f-8a9b-0c1d2e3f4a5b | grep -A6 'Results'
Results:
  Message:   validation error: CPU and memory resource requests and limits are required
  Policy:    require-requests-limits
  Rule:      validate-resources
  Result:    fail
  Scored:    true
  Severity:  medium
```

Since Kyverno 1.10 reports are **one per resource, named by the resource UID** — aggregate views come from `kubectl get polr -A` or the Policy Reporter UI.

### 8.3 When the webhook itself misbehaves

The webhook's `failurePolicy` decides what happens when Kyverno is *unreachable* (crashed, evicted, network-partitioned):

| `failurePolicy` | If Kyverno is down | Risk |
|---|---|---|
| `Fail` (default for enforce) | API server **rejects** the request | A Kyverno outage can freeze all cluster writes — self-inflicted DoS |
| `Ignore` | API server **allows** the request | Policies silently bypassed during the outage — a security gap |

```console
$ kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[0].failurePolicy}{"\n"}'
Fail

# Symptom of a Fail-mode outage: EVERY apply times out
$ kubectl apply -f any-pod.yaml
Error from server (InternalError): Internal error occurred: failed calling webhook
"validate.kyverno.svc-fail": failed to call webhook: Post
"https://kyverno-svc.kyverno.svc:443/validate/fail?timeout=10s":
context deadline exceeded
```

Diagnosis ladder for that error: (1) `kubectl -n kyverno get pods` — is the admission controller Running? (2) check the service/endpoints `kubectl -n kyverno get ep kyverno-svc`; (3) tail logs; (4) if the controller is truly wedged and blocking the cluster, `kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg` is the emergency break-glass (Kyverno recreates it on recovery).

### 8.4 Reading the controller logs

```console
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=20 | grep -i error
E1213 ... "failed to load context" err="JMESPath query failed" \
  policy="require-run-as-non-root" rule="run-as-non-root"
```

A JMESPath error in the logs but `READY: True` on the policy means the rule compiled but fails *at evaluation time* on specific inputs — usually a null-dereference the `|| `default`` idiom would fix.

### 8.5 Diagnostic quick-reference

| Symptom | Likely cause | First command |
|---|---|---|
| Policy created but nothing is enforced | `validationFailureAction: Audit` | `kubectl get cpol -o yaml \| grep FailureAction` |
| `cpol` shows `READY: False` | Compile error (anchor/JMESPath/kind) | `kubectl describe cpol <name>` |
| Deployment blocked, error says `autogen-…` | Autogen expansion of your Pod rule | expected — it's the same rule |
| All applies time out | `failurePolicy: Fail` + Kyverno down | `kubectl -n kyverno get pods` |
| Mutation not applied to existing pods | mutate-existing needs `background` + RBAC | check background-controller logs |
| Generated resource keeps disappearing | `synchronize: false` and something deletes it | set `synchronize: true` |

---

## 9. Where Kyverno fits: engine comparison

| | **Kyverno** | **OPA / Gatekeeper** | **ValidatingAdmissionPolicy (native)** |
|---|---|---|---|
| Language | YAML patterns + JMESPath/CEL | Rego | CEL |
| Install | CRDs + controllers | CRDs + controllers | Built into API server (GA 1.30) |
| Validate | ✅ | ✅ | ✅ |
| Mutate | ✅ (native) | ⚠️ separate mutation CRD | ✅ (MutatingAdmissionPolicy, newer) |
| Generate side-effect resources | ✅ | ❌ | ❌ |
| Image verification | ✅ (`verifyImages`) | ⚠️ via external data | ❌ |
| Policy reports | ✅ (Policy WG CRDs) | ✅ (constraint status) | ⚠️ limited |
| Extra runtime to operate | Yes (Kyverno pods) | Yes (Gatekeeper pods) | **No** — zero extra components |
| Learning curve | Low (Kubernetes-native idioms) | High (Rego) | Medium (CEL) |
| Best when | You want mutate+generate+verify in one Kubernetes-native tool | You need arbitrary logic / already invested in Rego | You want validation with no add-on and are on ≥1.30 |

**Positioning:** Kyverno wins where you need the *full lifecycle* — validate, mutate, generate, and supply-chain verification — expressed the way Kubernetes already expresses things, at the cost of running its controllers. Native `ValidatingAdmissionPolicy` is the right call for pure validation with no operational footprint; Gatekeeper is the choice when your policies need Turing-complete logic you can only express in Rego.

---

## 10. References

- Kyverno — Policies & Rules (concepts): https://kyverno.io/docs/policy-types/cluster-policy/
- Kyverno — Validate rules: https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Mutate rules: https://kyverno.io/docs/writing-policies/mutate/
- Kyverno — Generate rules: https://kyverno.io/docs/writing-policies/generate/
- Kyverno — Match / exclude selectors: https://kyverno.io/docs/writing-policies/match-exclude/
- Kyverno — Preconditions & JMESPath operators: https://kyverno.io/docs/writing-policies/preconditions/
- Kyverno — Autogen for pod controllers: https://kyverno.io/docs/writing-policies/autogen/
- Kyverno — Policy Reports: https://kyverno.io/docs/policy-reports/
- Kyverno — Kyverno CLI (`apply` / `test`): https://kyverno.io/docs/kyverno-cli/
- Kyverno — Installation & controllers: https://kyverno.io/docs/installation/
- Kubernetes — Dynamic admission control (webhooks, `failurePolicy`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes Policy WG — PolicyReport CRDs (`wgpolicyk8s.io`): https://github.com/kubernetes-sigs/wg-policy-prototypes
- CNCF — KCA (Kyverno Certified Associate) curriculum: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf