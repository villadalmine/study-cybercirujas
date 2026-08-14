# 5.2 Preconditions

**Domain 5 — Writing Kyverno Policies · Exam weight: 2.91**

---

## 1. The production problem: `match` is a coarse filter, and coarse filters are expensive

### 1.1 What `match`/`exclude` can and cannot express

A Kyverno rule's `match`/`exclude` blocks select resources by *metadata about the request*, not by *the content of the resource*. The complete selector vocabulary is:

| Selector | Field | Example |
|---|---|---|
| Group/Version/Kind | `resources.kinds` | `apps/v1/Deployment`, `Pod` |
| Name / glob | `resources.names` | `["web-*", "api-*"]` |
| Namespace / glob | `resources.namespaces` | `["prod-*"]` |
| Label selector on the object | `resources.selector` | `matchLabels: {tier: "1"}` |
| Label selector on the namespace | `resources.namespaceSelector` | `matchExpressions: [...]` |
| Annotations | `resources.annotations` | `{"kyverno.io/managed": "true"}` |
| Admission verb | `resources.operations` (Kyverno 1.10+) | `[CREATE, UPDATE]` |
| Requesting identity | `subjects`, `roles`, `clusterRoles` | `system:serviceaccount:ci:deployer` |

Everything a platform team actually wants to gate on is **absent from that list**:

- "only if the Pod actually mounts a `hostPath`"
- "only on `UPDATE`, and only when `spec.storageClassName` actually changed"
- "only if the memory request exceeds 8Gi"
- "only if the image is *not* from our internal registry"
- "only if this ConfigMap has not already been labelled" (idempotency)
- "only if the namespace is not in an allowlist stored in a ConfigMap"

`preconditions` is the field that closes that gap. It is a rule-level (and `foreach`-level, and mutate-`targets`-level) boolean gate, evaluated **after** match/exclude and **before** the rule body, expressed over fully-substituted Kyverno variables — `request.object`, `request.oldObject`, `request.userInfo`, `element`, `target`, and anything loaded into `context`.

### 1.2 Why "just match broadly and let the rule body decide" is the wrong answer

You can always match all Pods and encode the condition inside `validate.deny.conditions` or a pattern. Three concrete costs make that a production anti-pattern:

**Report noise destroys the signal.** A rule that is *not applicable* to a resource should record `skip`, not `pass`. With 4 000 Pods in a cluster and 40 policies, the difference between "3 800 skips / 200 passes / 0 fails" and "4 000 passes" is the difference between a report you can reason about and a wall of green. `PolicyReport` summaries are what compliance dashboards, Policy Reporter UI, and `kubectl get polr` aggregate on.

**Variable resolution failures become admission failures.** If your rule body dereferences `request.object.spec.template.spec.volumes[0].hostPath.path` on a resource that has no volumes, the rule errors. With `failurePolicy: Fail` and an enforcing rule, an *error* is not the same as a *pass* — it can block a deployment at 03:00. A precondition that short-circuits before the dereference converts a hard failure into a clean skip.

**Webhook and background-scan cost.** Every rule evaluated on every admission request adds latency to the critical path of the API server, and every rule evaluated in every background scan cycle adds CPU to the reports controller. Preconditions short-circuit before the rule body — and, in Kyverno 1.10+, before *deferred* `context` entries (API calls, ConfigMap lookups, image registry reads) are ever loaded, provided the precondition itself does not reference them.

### 1.3 Where preconditions sit in the evaluation pipeline

```
  kubectl apply
       │
       ▼
┌──────────────────────────────────────────────────────────────┐
│ kube-apiserver: admission chain                              │
│   ValidatingWebhookConfiguration / MutatingWebhookConfig     │
│   rules[] + namespaceSelector + objectSelector + matchConds  │  ← Kyverno auto-generates
│   (a non-match here means Kyverno is never called at all)    │     these from your policies
└───────────────────────┬──────────────────────────────────────┘
                        │ AdmissionReview
                        ▼
┌──────────────────────────────────────────────────────────────┐
│ kyverno-admission-controller                                 │
│                                                              │
│  1. resourceFilters  (ConfigMap "kyverno")   → drop early    │
│  2. policy selection: spec.rules[].match / .exclude          │
│  3. rule context[] resolution (lazy in 1.10+)                │
│  4. ►► preconditions ◄◄   ── false ──▶ result = skip ────┐   │
│  5. rule body: validate | mutate | generate | verifyImages│   │
│  6. result = pass | fail | warn | error                  │   │
│                                                          │   │
└──────────────────────────┬───────────────────────────────┴───┘
                           ▼
              AdmissionResponse (allow/deny/patch)
                           +
              (Cluster)PolicyReport / EphemeralReport
```

The same step 4 runs in the **background scan** path (reports-controller), where `request.operation` is empty, `request.oldObject` is null, and `request.userInfo` is absent. That asymmetry is the single largest source of precondition bugs in production and is covered in §6.

> **Version surface.** The `any`/`all` precondition structure has been stable since Kyverno 1.4/1.5; the operator set grew over subsequent minors (duration operators, quantity comparison), `operations` in `match` arrived in 1.10, and 1.13 began migrating `spec.validationFailureAction` to `spec.rules[].validate.failureAction`. Run `kyverno version` and `kubectl get crd clusterpolicies.kyverno.io -o jsonpath='{.spec.versions[*].name}'` against your cluster before assuming a field exists.

---

## 2. Syntax and semantics

### 2.1 Anatomy of a precondition block

```yaml
preconditions:
  all:                                   # logical AND over the list
    - key: "{{ request.operation || 'BACKGROUND' }}"   # left-hand operand (variable or literal)
      operator: AnyIn                                  # comparison
      value:                                           # right-hand operand (variable or literal)
        - CREATE
        - UPDATE
        - BACKGROUND
    - key: "{{ request.object.spec.replicas || `0` }}"
      operator: GreaterThan
      value: 1
  any:                                   # logical OR over the list
    - key: "{{ request.object.metadata.labels.\"app.kubernetes.io/tier\" || '' }}"
      operator: Equals
      value: "1"
    - key: "{{ request.object.metadata.namespace }}"
      operator: Equals
      value: "prod-*"                    # wildcards allowed with Equals/NotEquals
```

Three structural facts to memorise:

1. `key`, `operator`, `value` — no other fields. `message` is **not** a precondition field; a failed precondition is silent by design.
2. `key` and `value` may both contain variables. Comparing two variables (`request.object` vs `request.oldObject`) is the canonical UPDATE-diff idiom.
3. **If both `any` and `all` are present, both must be satisfied**: every entry under `all` is true **AND** at least one entry under `any` is true.

**Deprecated legacy form** — a bare list, with implicit AND, no `any`/`all` wrapper:

```yaml
      # Pre-1.4 syntax. Do not write new policies this way.
      preconditions:
        - key: "{{ request.operation }}"
          operator: Equals
          value: CREATE
```

Modern CRD schemas reject or warn on this. Convert to `all:`.

### 2.2 Truth table

| `all` entries | `any` entries | Rule executes? |
|---|---|---|
| (absent) | (absent) | Yes — no gate |
| all true | (absent) | Yes |
| any false | (absent) | **No → `skip`** |
| (absent) | ≥1 true | Yes |
| (absent) | all false | **No → `skip`** |
| all true | ≥1 true | Yes |
| all true | all false | **No → `skip`** |
| any false | ≥1 true | **No → `skip`** |
| `all: []` (empty list) | (absent) | Yes — vacuously true |

The empty-list case matters when preconditions are templated by Helm or Kustomize: an empty `all: []` is an open gate, not a closed one.

### 2.3 Operator reference

| Operator | Semantics | Accepts | Notes |
|---|---|---|---|
| `Equals` | Deep equality | string, number, bool, object, array | `*` and `?` wildcards when both sides are strings |
| `NotEquals` | Negation of `Equals` | same | same wildcard support |
| `AnyIn` | ≥1 element of `key` ∈ `value` | scalar or array | scalar `key` is treated as a 1-element set |
| `AllIn` | every element of `key` ∈ `value` | array (scalar works) | with a scalar `key`, identical to `AnyIn` |
| `AnyNotIn` | ≥1 element of `key` ∉ `value` | scalar or array | with a scalar `key`: "is not in the list" |
| `AllNotIn` | no element of `key` ∈ `value` | array | the correct "none of the user's groups is X" operator |
| `GreaterThan` | `key > value` | number, Kubernetes quantity (`1Gi`, `500m`), duration | quantity comparison is unit-aware: `1000m` == `1` |
| `GreaterThanOrEquals` | `key >= value` | same | |
| `LessThan` | `key < value` | same | |
| `LessThanOrEquals` | `key <= value` | same | |
| `DurationGreaterThan` | duration `key > value` | Go duration string (`1h`, `30m`, `168h`) or seconds as a number | `24h`, not `1d` — Go durations have no day unit |
| `DurationGreaterThanOrEquals` | | same | |
| `DurationLessThan` | | same | |
| `DurationLessThanOrEquals` | | same | |
| `In` / `NotIn` | **Deprecated** aliases of `AnyIn` / `AnyNotIn` | | Replace on sight; the ambiguity is exactly what caused the split |

Ordered comparison of **semantic versions** is not an operator — use the JMESPath function `semver_compare()` inside the `key`:

```yaml
        - key: "{{ semver_compare('{{ request.object.metadata.labels.version }}', '>=1.24.0') }}"
          operator: Equals
          value: true
```

### 2.4 Type handling: the two rules that cause most failures

**Rule 1 — whole-string substitution preserves the type; concatenation does not.**

```yaml
        # key resolves to the NUMBER 3
        - key: "{{ request.object.spec.replicas }}"
          operator: GreaterThan
          value: 1

        # key resolves to the STRING "replicas=3" — GreaterThan will error
        - key: "replicas={{ request.object.spec.replicas }}"
          operator: GreaterThan
          value: 1
```

Likewise on the right-hand side: `value: 3` is a number, `value: "3"` is a string, and `Equals` between them is **false**. YAML's implicit typing is load-bearing here.

**Rule 2 — every dereference must be null-safe, because an unresolved variable is a rule *error*, not a `false`.**

The `||` operator in JMESPath returns the right operand when the left is *falsy* (null, `false`, `""`, `[]`, `{}`). The idioms:

```yaml
        - key: "{{ request.object.metadata.labels.owner || '' }}"                 # string default
        - key: "{{ request.object.spec.volumes || `[]` | length(@) }}"            # list default, then count
        - key: "{{ request.object.spec.replicas || `0` }}"                        # number default (backticks = JSON literal)
        - key: "{{ request.operation || 'BACKGROUND' }}"                          # background-scan safety
```

Note the quoting discipline, which is the #1 syntax error in real policies:

| Need | JMESPath token | Inside a double-quoted YAML scalar |
|---|---|---|
| String literal | `'prod'` | `'prod'` — single quotes pass through |
| JSON literal (number, list, object, bool) | `` `0` ``, `` `[]` ``, `` `true` `` | backticks pass through |
| Identifier containing `.`, `/`, or `-` | `"app.kubernetes.io/tier"` | `\"app.kubernetes.io/tier\"` — **must be escaped** |

```yaml
      # Correct: YAML double quotes, escaped JMESPath quoted-identifier, single-quoted literal default
      - key: "{{ request.object.metadata.labels.\"app.kubernetes.io/name\" || '' }}"
        operator: NotEquals
        value: ""
```

### 2.5 The four places preconditions may appear

| Site | Path | Variables in scope | Effect when false |
|---|---|---|---|
| Rule | `spec.rules[].preconditions` | `request.*`, `context` entries, `serviceAccountName` | Whole rule skipped |
| `foreach` element | `spec.rules[].validate.foreach[].preconditions`<br>`spec.rules[].mutate.foreach[].preconditions` | above **+ `element`, `elementIndex`** | That element skipped; iteration continues |
| Mutate-existing target | `spec.rules[].mutate.targets[].preconditions` | above **+ `target`** (the existing object) | That target is not patched |
| — *(contrast)* Deny conditions | `spec.rules[].validate.deny.conditions` | same structure, opposite meaning | Same `any`/`all`/operator grammar, but **true ⇒ block** |

The last row is the distinction the exam probes: **identical syntax, inverted semantics, different report result.**

---

## 3. Comparative analysis and trade-offs

### 3.1 The filtering ladder — pick the cheapest rung that can express the condition

| Rung | Mechanism | Enforced by | Cost per non-matching request | Expressiveness | Recorded as |
|---|---|---|---|---|---|
| 0 | Webhook `namespaceSelector` / `objectSelector` (Kyverno derives these from `match`) | kube-apiserver | **zero** — no network call | Labels only | nothing |
| 1 | `resourceFilters` in the `kyverno` ConfigMap | Kyverno, pre-policy | one webhook round-trip, no policy eval | `[Kind,namespace,name]` globs | nothing |
| 2 | `match` / `exclude` — kinds, names, namespaces, selectors, `operations`, subjects | Kyverno engine | negligible | Request metadata only | nothing |
| 3 | **`preconditions`** | Kyverno engine | variable substitution + JMESPath eval | Arbitrary: object content, old object, user info, external context | **`skip`** |
| 4 | `validate.deny.conditions`, `pattern`, `anyPattern` | Kyverno engine | same as rung 3 + report write | Arbitrary | `pass` / `fail` |

**Architectural rule:** if a condition is expressible at rung 0–2, express it there. `operations: [CREATE, UPDATE]` in the `match` block is strictly better than a precondition on `request.operation`, because Kyverno propagates it into the generated `ValidatingWebhookConfiguration` `rules[].operations` — the API server then never calls Kyverno for `DELETE` or `CONNECT` at all. A precondition on `request.operation` still pays a full webhook round-trip before deciding to do nothing.

Preconditions are for what genuinely cannot be known until you read the object.

### 3.2 `preconditions` vs `deny.conditions` vs conditional anchors

Three mechanisms can express "only check X when Y". They are not interchangeable.

| | `preconditions` | `validate.deny.conditions` | Conditional anchor `()` in a pattern |
|---|---|---|---|
| Grammar | `any`/`all` + operators | `any`/`all` + operators (identical) | Strategic-merge pattern syntax |
| Meaning of *true* | Continue to rule body | **Block the request** | Sibling fields in the same object must also match |
| Meaning of *false* | Skip rule → `skip` | Allow → `pass` | Object is not evaluated → `pass` |
| Can read `request.oldObject` | Yes | Yes | No |
| Can read external `context` | Yes | Yes | Via variables only |
| Can read `element` (foreach) | Yes | Yes | Yes (inside foreach patterns) |
| Report result when inapplicable | **`skip`** | `pass` | `pass` |
| Blocks in Enforce mode | Never | Yes | Yes |
| Autogen-rewritten for pod controllers | Path prefixes only (see §6.6) | Path prefixes only | Yes (full pattern rewrite) |

The **conditional anchor** family, for completeness, since it competes for the same job inside `validate.pattern`:

| Anchor | Name | Meaning |
|---|---|---|
| `(field): value` | Conditional | If `field` == `value`, the sibling rules in this map must hold; otherwise skip this map |
| `+(field): value` | Add-if-absent (mutate) | Set `field` only if not already present |
| `^(field): [...]` | Global (validate) | At least one array element must match |
| `X(field): value` | Negation | The tag must **not** exist |
| `=(field): value` | Existence | If `field` exists, it must match |

**When to use which:** conditional anchors are local to one object in a strategic-merge pattern and cannot see `oldObject`, `userInfo`, or ConfigMap data. Preconditions can, and they are the only mechanism that produces a `skip`. Choose preconditions for *applicability*; choose deny conditions for *the violation itself*; choose anchors for structural "if this field, then that field" inside a single pattern.

### 3.3 Kyverno preconditions vs upstream Kubernetes CEL gating

| | Kyverno `preconditions` | Webhook `matchConditions` | `ValidatingAdmissionPolicy.spec.matchConditions` |
|---|---|---|---|
| Language | JMESPath + Kyverno functions | CEL | CEL |
| Evaluated by | Kyverno pod | **kube-apiserver**, before the webhook call | kube-apiserver, in-process |
| Availability | Kyverno 1.4+ | Kubernetes 1.28 beta, 1.30 GA | Kubernetes 1.30 GA |
| Can read `oldObject` | Yes | Yes | Yes |
| Can read user info | Yes (admission only) | Yes | Yes |
| Can read cluster state / ConfigMaps / registries | **Yes**, via `context` | No | Only via `paramKind` |
| Failure to evaluate | Rule `error` (may block if `failurePolicy: Fail`) | Governed by webhook `failurePolicy` | Governed by `failurePolicy` |
| Latency cost | Network round-trip already paid | **Zero round-trip when false** | Zero — no webhook at all |
| Result surfaced in policy reports | Yes (`skip`) | No | Via `ValidatingAdmissionPolicyBinding` audit annotations |

The production synthesis for a platform team: put *cheap, request-shaped* conditions in webhook `matchConditions`/VAP (or in Kyverno's `match`, which compiles down to webhook config), and keep preconditions for conditions that require external state or old/new diffing with report visibility. Kyverno's own CEL-based rule types (`validate.cel` in 1.11+, and the `ValidatingPolicy` CRD in later releases) do not remove the need to understand `preconditions` — the JMESPath form remains the syntax for `ClusterPolicy`/`Policy`, which is what the KCA exam is written against.

---

## 4. Production manifests

Everything below is a complete, apply-ready manifest. Namespace assumed: Kyverno installed in `kyverno`.

### 4.0 Supporting infrastructure

```yaml
---
# Cheapest rung of the ladder: never let Kyverno see traffic it can never act on.
# Applied to the Kyverno ConfigMap; requires an admission-controller restart to take effect.
apiVersion: v1
kind: ConfigMap
metadata:
  name: kyverno
  namespace: kyverno
data:
  resourceFilters: >-
    [*/*,kube-system,*]
    [*/*,kube-public,*]
    [*/*,kube-node-lease,*]
    [*/*,kyverno,*]
    [Event,*,*]
    [Node,*,*]
    [Node/*,*,*]
    [APIService,*,*]
    [APIService/*,*,*]
    [TokenReview,*,*]
    [SubjectAccessReview,*,*]
    [SelfSubjectAccessReview,*,*]
    [Binding,*,*]
    [ReplicaSet,*,*]
    [AdmissionReport,*,*]
    [ClusterAdmissionReport,*,*]
    [BackgroundScanReport,*,*]
    [ClusterBackgroundScanReport,*,*]
    [ClusterRole,*,kyverno:*]
    [ClusterRoleBinding,*,kyverno:*]
  webhooks: >-
    [{"namespaceSelector":{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["kyverno"]}]}}]
  enableDefaultRegistryMutation: "true"
---
# Allowlist consumed by preconditions in §4.3 and §4.6. Keeping the list in a
# ConfigMap rather than in the policy means an exception is a ConfigMap edit,
# not a policy rollout — different RBAC, different blast radius, different audit trail.
apiVersion: v1
kind: ConfigMap
metadata:
  name: hostpath-allowlist
  namespace: kyverno
data:
  paths: "/var/log,/var/lib/containerd,/run/containerd/containerd.sock"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: netpol-bootstrap
  namespace: kyverno
data:
  exempt-namespaces: "kube-system,kube-public,kube-node-lease,kyverno,istio-system,monitoring"
---
# Kyverno's background controller runs with least privilege. Any resource a
# mutate-existing or generate rule touches needs an aggregated ClusterRole.
# Without this, the rule's preconditions pass and the patch then fails with a
# 403 — a failure mode that looks nothing like a precondition bug.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:background-extra
  labels:
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
# The reports controller must be able to read the ConfigMaps referenced from
# rule `context` blocks during background scans.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:reports-extra
  labels:
    rbac.kyverno.io/aggregate-to-reports-controller: "true"
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
```

### 4.1 Applicability gate — label, exemption and workload-shape preconditions

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-readiness-probe-tier1
  annotations:
    policies.kyverno.io/title: Require readiness probes on tier-1 workloads
    policies.kyverno.io/category: Reliability
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Tier-1 workloads must declare a readiness probe so that rolling updates and
      Service endpoint programming reflect real application readiness rather than
      container start. Preconditions restrict the rule to tier-1, non-exempt,
      long-running Pods, so that everything else is reported as skip rather than
      inflating the pass count.
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet
spec:
  validationFailureAction: Enforce      # Kyverno 1.13+: prefer rules[].validate.failureAction
  background: true
  failurePolicy: Fail
  rules:
    - name: readiness-probe-required
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:               # rung 2 — narrows the generated webhook itself
                - CREATE
                - UPDATE
      preconditions:
        all:
          # 1. Applicability: only tier-1 workloads.
          - key: "{{ request.object.metadata.labels.\"app.kubernetes.io/tier\" || '' }}"
            operator: Equals
            value: "1"
          # 2. Documented, auditable break-glass that leaves a trace on the object.
          - key: "{{ request.object.metadata.labels.\"policy.example.com/exempt-probes\" || '' }}"
            operator: NotEquals
            value: "true"
          # 3. Workload shape: Job- and CronJob-spawned Pods use restartPolicy
          #    Never/OnFailure and have no meaningful readiness semantics.
          - key: "{{ request.object.spec.restartPolicy || 'Always' }}"
            operator: Equals
            value: Always
          # 4. Do not fight the platform: Pods already terminating are ignored.
          - key: "{{ request.object.metadata.deletionTimestamp || '' }}"
            operator: Equals
            value: ""
      validate:
        message: >-
          Tier-1 Pods must define a readinessProbe on every container.
          Add spec.containers[*].readinessProbe, or label the workload
          policy.example.com/exempt-probes=true with an approved exception ticket.
        foreach:
          - list: request.object.spec.containers
            deny:
              conditions:
                all:
                  - key: "{{ element.readinessProbe || '' }}"
                    operator: Equals
                    value: ""
```

### 4.2 UPDATE-diff gate — the immutability pattern with `deny: {}`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: pvc-storageclass-immutable
  annotations:
    policies.kyverno.io/title: PVC storageClassName is immutable
    policies.kyverno.io/category: Storage
    policies.kyverno.io/severity: medium
spec:
  validationFailureAction: Enforce
  # background MUST be false: this rule reads request.userInfo and request.oldObject,
  # neither of which exists during a background scan. Kyverno's policy webhook
  # rejects background: true here.
  background: false
  failurePolicy: Fail
  rules:
    - name: block-storageclass-change
      match:
        any:
          - resources:
              kinds:
                - PersistentVolumeClaim
              operations:
                - UPDATE
      preconditions:
        all:
          # The entire violation is expressed here: the field changed.
          # Both sides are null-guarded because storageClassName is optional
          # and "" (explicitly empty) is semantically distinct from unset.
          - key: "{{ request.object.spec.storageClassName || '<unset>' }}"
            operator: NotEquals
            value: "{{ request.oldObject.spec.storageClassName || '<unset>' }}"
          # Controller-driven updates are not user intent.
          - key: "{{ request.userInfo.username }}"
            operator: AnyNotIn
            value:
              - system:serviceaccount:kube-system:pv-protection-controller
              - system:serviceaccount:kube-system:persistent-volume-binder
          # Cluster admins performing a documented migration are not blocked,
          # but the attempt is still visible in the audit log.
          - key: "{{ request.userInfo.groups || `[]` }}"
            operator: AllNotIn
            value:
              - system:masters
      validate:
        message: >-
          spec.storageClassName is immutable
          ({{ request.oldObject.spec.storageClassName || 'unset' }} ->
          {{ request.object.spec.storageClassName || 'unset' }}).
          Create a new PVC on the target StorageClass and migrate the data.
        # An empty deny denies unconditionally: the preconditions ARE the condition.
        # Consequence: every UPDATE that does not change the field reports `skip`,
        # not `pass`. Reports stay quiet; only real attempts appear.
        deny: {}
```

The trade-off encoded above is worth stating explicitly, because it is a design decision, not a style choice:

| Placement of the condition | Non-violating UPDATE reports | Report volume | Auditability |
|---|---|---|---|
| In `preconditions`, with `deny: {}` | `skip` | Low — only genuine attempts surface | You cannot prove the rule ran on a given resource |
| In `deny.conditions`, no preconditions | `pass` | High — one entry per UPDATE per resource | Positive evidence the rule evaluated |

Use the first for high-churn resources; use the second when an auditor requires evidence of evaluation.

### 4.3 Content gate — JMESPath over arrays, plus ConfigMap-driven allowlist

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-hostpath-and-privileged
  annotations:
    policies.kyverno.io/title: Restrict hostPath volumes to an allowlist
    policies.kyverno.io/category: Pod Security
    policies.kyverno.io/severity: critical
spec:
  validationFailureAction: Audit
  background: true
  failurePolicy: Fail
  rules:
    - name: hostpath-allowlist
      match:
        any:
          - resources:
              kinds:
                - Pod
      # The whole rule — including the ConfigMap lookup below, which in
      # Kyverno 1.10+ is deferred until first reference — is skipped for the
      # ~99% of Pods that use no hostPath and are not privileged.
      preconditions:
        any:
          - key: "{{ request.object.spec.volumes[?hostPath] || `[]` | length(@) }}"
            operator: GreaterThan
            value: 0
          - key: "{{ request.object.spec.containers[?securityContext.privileged == `true`] || `[]` | length(@) }}"
            operator: GreaterThan
            value: 0
          - key: "{{ request.object.spec.initContainers[?securityContext.privileged == `true`] || `[]` | length(@) }}"
            operator: GreaterThan
            value: 0
      context:
        - name: allowlist
          configMap:
            name: hostpath-allowlist
            namespace: kyverno
      validate:
        message: >-
          hostPath volumes are limited to the paths declared in the
          kyverno/hostpath-allowlist ConfigMap, and privileged containers are
          not permitted outside the node-agent namespaces.
        foreach:
          - list: request.object.spec.volumes[?hostPath]
            deny:
              conditions:
                all:
                  - key: "{{ element.hostPath.path }}"
                    operator: AnyNotIn
                    value: "{{ split(allowlist.data.paths, ',') }}"
```

Note the precedence in `request.object.spec.volumes[?hostPath] || \`[]\` | length(@)`. JMESPath's pipe has the lowest precedence, so this parses as `(volumes[?hostPath] || []) | length(@)` — the null-guard is applied *before* `length()`, which is what makes the expression safe on a Pod with no volumes at all.

### 4.4 `foreach` preconditions — per-element gating

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: pin-third-party-images
  annotations:
    policies.kyverno.io/title: Third-party images must be pinned by digest
    policies.kyverno.io/category: Supply Chain
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  failurePolicy: Fail
  rules:
    - name: digest-required-for-external-images
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        all:
          # BACKGROUND is included so the rule still runs during scans, where
          # request.operation is the empty string.
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
              - BACKGROUND
      validate:
        message: >-
          Images not sourced from registry.internal.example.com must be pinned by
          digest, e.g. ghcr.io/org/app@sha256:<64-hex>. Mutable tags are not
          reproducible and are not admitted.
        foreach:
          # Element-scoped preconditions: each container is independently gated.
          # Internal images and infrastructure sidecars are skipped element by
          # element; the remaining containers are still evaluated.
          - list: request.object.spec.containers
            preconditions:
              all:
                - key: "{{ element.image }}"
                  operator: NotEquals
                  value: "registry.internal.example.com/*"     # wildcard on NotEquals
                - key: "{{ element.image }}"
                  operator: NotEquals
                  value: "*/pause:*"
            pattern:
              image: "*@sha256:*"
          - list: request.object.spec.initContainers || `[]`
            preconditions:
              all:
                - key: "{{ element.image }}"
                  operator: NotEquals
                  value: "registry.internal.example.com/*"
            pattern:
              image: "*@sha256:*"
```

`elementIndex` is also in scope inside a `foreach` and is occasionally the only way to express "everything except the first container":

```yaml
            preconditions:
              all:
                - key: "{{ elementIndex }}"
                  operator: GreaterThan
                  value: 0
```

### 4.5 Mutate-existing — target-scoped preconditions and the `target` variable

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: propagate-namespace-owner
  annotations:
    policies.kyverno.io/title: Propagate the namespace owner label to ConfigMaps
    policies.kyverno.io/category: FinOps
    policies.kyverno.io/severity: low
spec:
  background: true
  mutateExistingOnPolicyUpdate: true
  rules:
    - name: propagate-owner-label
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
                - UPDATE
      # Trigger-scoped gate: only namespaces that actually carry an owner.
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.owner || '' }}"
            operator: NotEquals
            value: ""
      mutate:
        targets:
          - apiVersion: v1
            kind: ConfigMap
            namespace: "{{ request.object.metadata.name }}"
            # Target-scoped gate: `target` is the EXISTING object being patched.
            # Two independent jobs here:
            #   1. honour an opt-out on the target itself;
            #   2. idempotency — do not issue a no-op UPDATE for ConfigMaps that
            #      already carry the right value. Without this, every policy
            #      resync rewrites every ConfigMap, bumping resourceVersion,
            #      waking every informer in the cluster, and filling the audit log.
            preconditions:
              all:
                - key: "{{ target.metadata.labels.\"policy.example.com/opt-out\" || '' }}"
                  operator: NotEquals
                  value: "true"
                - key: "{{ target.metadata.labels.owner || '' }}"
                  operator: NotEquals
                  value: "{{ request.object.metadata.labels.owner }}"
        patchStrategicMerge:
          metadata:
            labels:
              owner: "{{ request.object.metadata.labels.owner }}"
```

### 4.6 Generate — preconditions as the exception mechanism

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: bootstrap-default-deny-netpol
  annotations:
    policies.kyverno.io/title: Generate a default-deny NetworkPolicy per namespace
    policies.kyverno.io/category: Networking
    policies.kyverno.io/severity: high
spec:
  background: true
  rules:
    - name: generate-default-deny
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
      context:
        - name: nscfg
          configMap:
            name: netpol-bootstrap
            namespace: kyverno
      preconditions:
        all:
          # System and infrastructure namespaces are exempted through data,
          # not through a hard-coded exclude list inside the policy.
          - key: "{{ request.object.metadata.name }}"
            operator: AnyNotIn
            value: "{{ split(nscfg.data.\"exempt-namespaces\", ',') }}"
          # A namespace may opt into a different posture by labelling itself.
          - key: "{{ request.object.metadata.labels.\"network.example.com/policy\" || 'default-deny' }}"
            operator: Equals
            value: default-deny
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-ingress
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        data:
          metadata:
            labels:
              app.kubernetes.io/managed-by: kyverno
              policy.example.com/generated-by: bootstrap-default-deny-netpol
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
```

> ConfigMap values are strings. Kyverno will attempt to parse a value that is valid JSON (so `["kube-system","kyverno"]` becomes a real array), but relying on that is fragile when a human edits the ConfigMap. `split(nscfg.data.key, ',')` is explicit and always yields an array — which is what `AnyNotIn` requires.

### 4.7 Preconditions as correctness, not optimisation — JSON Patch guards

This is the case where removing the precondition does not merely add noise; it produces a broken cluster.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: batch-workload-scheduling
  annotations:
    policies.kyverno.io/title: Add a batch toleration and right-size large requests
    policies.kyverno.io/category: Scheduling
    policies.kyverno.io/severity: medium
spec:
  background: false
  failurePolicy: Fail
  rules:
    - name: append-batch-toleration
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
              selector:
                matchLabels:
                  workload-class: batch
      preconditions:
        all:
          # GUARD 1 — idempotency. A JSON Patch `add` to `/-` APPENDS. Applied
          # twice (CREATE then a later UPDATE, or on a mutate re-evaluation) it
          # produces duplicate tolerations that grow without bound.
          - key: "{{ request.object.spec.tolerations[?key == 'workload-class'] || `[]` | length(@) }}"
            operator: Equals
            value: 0
          # GUARD 2 — structural. `/spec/tolerations/-` requires the array to
          # already exist; on a Pod with no tolerations the patch errors and,
          # with failurePolicy: Fail, the CREATE is rejected.
          - key: "{{ request.object.spec.tolerations || `[]` | length(@) }}"
            operator: GreaterThan
            value: 0
      mutate:
        patchesJson6902: |-
          - op: add
            path: /spec/tolerations/-
            value:
              key: "workload-class"
              operator: "Equal"
              value: "batch"
              effect: "NoSchedule"

    - name: seed-tolerations-array
      # The complementary branch: Pods with no tolerations at all get the array
      # created via strategic merge, which is structurally safe.
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
              selector:
                matchLabels:
                  workload-class: batch
      preconditions:
        all:
          - key: "{{ request.object.spec.tolerations || `[]` | length(@) }}"
            operator: Equals
            value: 0
      mutate:
        patchStrategicMerge:
          spec:
            tolerations:
              - key: "workload-class"
                operator: "Equal"
                value: "batch"
                effect: "NoSchedule"

    - name: promote-large-requests-to-guaranteed
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
      mutate:
        foreach:
          - list: request.object.spec.containers
            preconditions:
              all:
                # Kubernetes quantity comparison: "8Gi" is parsed, not compared
                # as a string. "8192Mi" would also satisfy this.
                - key: "{{ element.resources.requests.memory || '0' }}"
                  operator: GreaterThan
                  value: 8Gi
                - key: "{{ element.resources.limits.memory || '' }}"
                  operator: Equals
                  value: ""
            patchStrategicMerge:
              spec:
                containers:
                  - name: "{{ element.name }}"
                    resources:
                      limits:
                        memory: "{{ element.resources.requests.memory }}"

    - name: annotate-short-lived-workloads
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
      preconditions:
        all:
          # Duration operators. Go duration syntax only: 168h, not 7d.
          - key: "{{ request.object.metadata.annotations.\"lifecycle.example.com/ttl\" || '0h' }}"
            operator: DurationGreaterThan
            value: 0h
          - key: "{{ request.object.metadata.annotations.\"lifecycle.example.com/ttl\" || '0h' }}"
            operator: DurationLessThanOrEquals
            value: 168h
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              lifecycle.example.com/class: ephemeral
```

### 4.8 Test fixtures and CI

```yaml
# tests/resources.yaml
---
apiVersion: v1
kind: Pod
metadata:
  name: web-tier1
  namespace: prod
  labels:
    app.kubernetes.io/tier: "1"
spec:
  restartPolicy: Always
  containers:
    - name: web
      image: registry.internal.example.com/web:1.4.2
      readinessProbe:
        httpGet:
          path: /healthz
          port: 8080
        initialDelaySeconds: 5
---
apiVersion: v1
kind: Pod
metadata:
  name: web-tier1-noprobe
  namespace: prod
  labels:
    app.kubernetes.io/tier: "1"
spec:
  restartPolicy: Always
  containers:
    - name: web
      image: registry.internal.example.com/web:1.4.2
---
apiVersion: v1
kind: Pod
metadata:
  name: scratch
  namespace: dev
  labels:
    app.kubernetes.io/tier: "3"          # precondition 1 fails -> skip
spec:
  restartPolicy: Always
  containers:
    - name: shell
      image: registry.internal.example.com/debug:latest
---
apiVersion: v1
kind: Pod
metadata:
  name: migration-abc123
  namespace: prod
  labels:
    app.kubernetes.io/tier: "1"
spec:
  restartPolicy: OnFailure               # precondition 3 fails -> skip
  containers:
    - name: migrate
      image: registry.internal.example.com/migrate:9
```

```yaml
# tests/kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-readiness-probe-tier1
policies:
  - ../policies/require-readiness-probe-tier1.yaml
resources:
  - resources.yaml
results:
  - policy: require-readiness-probe-tier1
    rule: readiness-probe-required
    kind: Pod
    resources:
      - prod/web-tier1
    result: pass
  - policy: require-readiness-probe-tier1
    rule: readiness-probe-required
    kind: Pod
    resources:
      - prod/web-tier1-noprobe
    result: fail
  # These two assertions are the point of the test suite: they lock in the
  # precondition behaviour. If someone widens the gate, the test goes red.
  - policy: require-readiness-probe-tier1
    rule: readiness-probe-required
    kind: Pod
    resources:
      - dev/scratch
      - prod/migration-abc123
    result: skip
```

```yaml
# .github/workflows/policy-ci.yaml
name: kyverno-policy-ci
on:
  pull_request:
    paths:
      - 'policies/**'
      - 'tests/**'
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install the Kyverno CLI
        run: |
          curl -sSL -o kyverno.tar.gz \
            https://github.com/kyverno/kyverno/releases/download/v1.12.5/kyverno-cli_v1.12.5_linux_x86_64.tar.gz
          tar -xzf kyverno.tar.gz kyverno
          sudo install -m 0755 kyverno /usr/local/bin/kyverno
          kyverno version
      - name: Lint policy schemas
        run: kyverno apply policies/ --resource tests/resources.yaml --detailed-results
      - name: Assert precondition behaviour
        run: kyverno test tests/ --detailed-results
```

---

## 5. CLI and terminal

> Outputs below were produced with Kyverno CLI v1.12.x against a Kyverno 1.12.x cluster. Table layout and log wording shift between minors; treat the *shape* of the output as the invariant and re-run the commands on your own version.

### 5.1 Prove the JMESPath before you put it in a precondition

`kyverno jp` is the fastest feedback loop that exists for this topic. Test the expression against a real object, in isolation, before it is buried inside a policy.

```console
$ cat > /tmp/pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: node-agent
  labels:
    app.kubernetes.io/tier: "1"
spec:
  volumes:
    - name: varlog
      hostPath: {path: /var/log}
    - name: cache
      emptyDir: {}
  containers:
    - name: agent
      image: ghcr.io/org/agent:1.2.3
EOF

$ kyverno jp query -i /tmp/pod.yaml 'spec.volumes[?hostPath] || `[]` | length(@)'
 # Reading from file
 # JMESPath expression
spec.volumes[?hostPath] || `[]` | length(@)

 # Result
1

$ kyverno jp query -i /tmp/pod.yaml 'metadata.labels."app.kubernetes.io/tier" || '"'"''"'"''
 # Result
"1"
```

The null-safety check that matters — run the same expression against an object where the path does not exist:

```console
$ echo '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"bare"},"spec":{"containers":[]}}' \
    | kyverno jp query 'spec.volumes[?hostPath] | length(@)'
Error: invalid type for length: <nil>, expected one of: [string array object]

$ echo '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"bare"},"spec":{"containers":[]}}' \
    | kyverno jp query 'spec.volumes[?hostPath] || `[]` | length(@)'
 # Result
0
```

The first form is exactly what produces a rule `error` at admission time. The `|| \`[]\`` is not decoration.

Kyverno's custom function set is discoverable from the CLI:

```console
$ kyverno jp function | grep -E '^(split|semver_compare|to_upper|time_since|parse_json)'
split(string, string) []string
semver_compare(string, string) bool
time_since(string, string, string) string
to_upper(string) string
parse_json(string) any
```

### 5.2 `kyverno apply` — see the `skip`

```console
$ kyverno apply policies/require-readiness-probe-tier1.yaml \
    --resource tests/resources.yaml

Applying 1 policy rule(s) to 4 resource(s)...

policy require-readiness-probe-tier1 -> resource prod/Pod/web-tier1-noprobe failed:
1. readiness-probe-required: validation failure: Tier-1 Pods must define a readinessProbe on every container. Add spec.containers[*].readinessProbe, or label the workload policy.example.com/exempt-probes=true with an approved exception ticket.

pass: 1, fail: 1, warn: 0, error: 0, skip: 2
```

`skip: 2` is the assertion. Those are `dev/scratch` (tier label mismatch) and `prod/migration-abc123` (`restartPolicy: OnFailure`). If that number is `0`, your preconditions are not doing anything; if it is `4`, they are closed shut.

The machine-readable form, which is what you assert on in CI:

```console
$ kyverno apply policies/require-readiness-probe-tier1.yaml \
    --resource tests/resources.yaml --policy-report -o yaml | head -60
apiVersion: wgpolicyk8s.io/v1alpha2
kind: ClusterPolicyReport
metadata:
  creationTimestamp: null
  name: merged
results:
- message: validation rule 'readiness-probe-required' passed.
  policy: require-readiness-probe-tier1
  resources:
  - apiVersion: v1
    kind: Pod
    name: web-tier1
    namespace: prod
  result: pass
  rule: readiness-probe-required
  scored: true
  source: kyverno
- message: 'validation failure: Tier-1 Pods must define a readinessProbe on every container.'
  policy: require-readiness-probe-tier1
  resources:
  - apiVersion: v1
    kind: Pod
    name: web-tier1-noprobe
    namespace: prod
  result: fail
  rule: readiness-probe-required
  scored: true
  source: kyverno
- message: preconditions not met
  policy: require-readiness-probe-tier1
  resources:
  - apiVersion: v1
    kind: Pod
    name: scratch
    namespace: dev
  result: skip
  rule: readiness-probe-required
  scored: true
  source: kyverno
summary:
  error: 0
  fail: 1
  pass: 1
  skip: 2
  warn: 0
```

Simulating an UPDATE requires the old object, which `kyverno apply` supplies through `--values-file`:

```yaml
# tests/values-update.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: pvc-update
policies:
  - name: pvc-storageclass-immutable
    resources:
      - name: data-web-0
        values:
          request.operation: UPDATE
          request.userInfo.username: "system:serviceaccount:apps:deployer"
          request.oldObject.spec.storageClassName: "gp3"
          request.object.spec.storageClassName: "io2"
```

```console
$ kyverno apply policies/pvc-storageclass-immutable.yaml \
    --resource tests/pvc.yaml --values-file tests/values-update.yaml

Applying 1 policy rule(s) to 1 resource(s) with 1 variable(s)...

policy pvc-storageclass-immutable -> resource default/PersistentVolumeClaim/data-web-0 failed:
1. block-storageclass-change: validation failure: spec.storageClassName is immutable (gp3 -> io2). Create a new PVC on the target StorageClass and migrate the data.

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

Flip `request.object.spec.storageClassName` to `gp3` in the values file and the same run yields `skip: 1` — the precondition-as-diff working exactly as designed.

### 5.3 `kyverno test` — regression-lock the gate

```console
$ kyverno test tests/

Loading test  ( tests/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 4 resources ...
  Checking results ...

│────│────────────────────────────────│──────────────────────────│─────────────────────────────│────────│
│ ID │ POLICY                         │ RULE                     │ RESOURCE                    │ RESULT │
│────│────────────────────────────────│──────────────────────────│─────────────────────────────│────────│
│ 1  │ require-readiness-probe-tier1  │ readiness-probe-required │ prod/Pod/web-tier1          │ Pass   │
│ 2  │ require-readiness-probe-tier1  │ readiness-probe-required │ prod/Pod/web-tier1-noprobe  │ Pass   │
│ 3  │ require-readiness-probe-tier1  │ readiness-probe-required │ dev/Pod/scratch             │ Pass   │
│ 4  │ require-readiness-probe-tier1  │ readiness-probe-required │ prod/Pod/migration-abc123   │ Pass   │
│────│────────────────────────────────│──────────────────────────│─────────────────────────────│────────│

Test Summary: 4 tests passed and 0 tests failed
```

`RESULT: Pass` here means *the assertion matched*, including the two rows whose asserted Kyverno result is `skip`. A widened precondition turns those into:

```console
│ 3  │ require-readiness-probe-tier1  │ readiness-probe-required │ dev/Pod/scratch             │ Fail   │

Test Summary: 3 tests passed and 1 tests failed

Aggregated Failed Test Cases :
│────│────────────────────────────────│──────────────────────────│─────────────────│──────────│────────│
│ ID │ POLICY                         │ RULE                     │ RESOURCE        │ RESULT   │ REASON │
│────│────────────────────────────────│──────────────────────────│─────────────────│──────────│────────│
│ 3  │ require-readiness-probe-tier1  │ readiness-probe-required │ dev/Pod/scratch │ Fail     │ Want skip, got fail │
│────│────────────────────────────────│──────────────────────────│──────────────────│─────────│────────│
```

### 5.4 In-cluster verification

```console
$ kubectl apply -f policies/require-readiness-probe-tier1.yaml
clusterpolicy.kyverno.io/require-readiness-probe-tier1 created

$ kubectl get cpol require-readiness-probe-tier1
NAME                            ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
require-readiness-probe-tier1   true        true         Enforce           True    12s   Ready

$ kubectl -n prod create -f tests/pod-tier1-noprobe.yaml --dry-run=server
Error from server: error when creating "tests/pod-tier1-noprobe.yaml": admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/prod/web-tier1-noprobe was blocked due to the following policies

require-readiness-probe-tier1:
  readiness-probe-required: 'validation failure: Tier-1 Pods must define a readinessProbe
    on every container. Add spec.containers[*].readinessProbe, or label the workload
    policy.example.com/exempt-probes=true with an approved exception ticket.'

$ kubectl -n dev create -f tests/pod-tier3.yaml --dry-run=server
pod/scratch created (server dry run)
```

Reading the `skip` results out of live PolicyReports:

```console
$ kubectl get polr -A
NAMESPACE   NAME                                   PASS   FAIL   WARN   ERROR   SKIP   AGE
dev         8f3a41c6-2b19-4a70-9d3e-7c6a1f0b2d55   0      0      0      0       3      6m
prod        1c9d02ab-77f4-4c8e-b0a1-93ee5d41c7f2   9      1      0      0       12     6m

$ kubectl get polr -n prod -o json \
  | jq -r '.items[].results[]
           | select(.policy=="require-readiness-probe-tier1")
           | [.result, .resources[0].name, .message] | @tsv'
pass	web-tier1	validation rule 'readiness-probe-required' passed.
fail	web-tier1-noprobe	validation failure: Tier-1 Pods must define a readinessProbe on every container.
skip	migration-abc123	preconditions not met

$ kubectl get polr -A -o json \
  | jq '[.items[].results[] | select(.result=="skip")] | group_by(.policy)
        | map({policy: .[0].policy, skipped: length}) '
[
  {
    "policy": "require-readiness-probe-tier1",
    "skipped": 12
  },
  {
    "policy": "restrict-hostpath-and-privileged",
    "skipped": 187
  }
]
```

That last query is the operational metric for this topic: a policy whose skip count is near-total is either correctly scoped or accidentally disabled, and only reading the preconditions tells you which.

### 5.5 Metrics

```console
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 >/dev/null 2>&1 &

$ curl -s localhost:8000/metrics | grep '^kyverno_policy_results_total' | head -5
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-readiness-probe-tier1",policy_namespace="-",policy_type="cluster",policy_validation_mode="enforce",resource_kind="Pod",resource_namespace="prod",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="readiness-probe-required",rule_result="pass",rule_type="validate"} 9
kyverno_policy_results_total{...,rule_result="fail",...} 1
kyverno_policy_results_total{...,rule_result="skip",...} 12
kyverno_policy_results_total{...,rule_result="error",...} 0
```

PromQL worth putting on a dashboard:

```promql
# Rules that never actually run — preconditions may be permanently closed.
sum by (policy_name, rule_name) (rate(kyverno_policy_results_total{rule_result="skip"}[1h]))
  / ignoring(rule_result) sum by (policy_name, rule_name) (rate(kyverno_policy_results_total[1h])) > 0.999

# Rules erroring — almost always unresolved variables in preconditions or context.
sum by (policy_name, rule_name) (increase(kyverno_policy_results_total{rule_result="error"}[15m])) > 0
```

---

## 6. Verification and failure diagnosis

### 6.1 Symptom table

| Symptom | Most likely cause | Probe | Fix |
|---|---|---|---|
| Rule never fires; everything is `skip` | `all` used where `any` was meant; or a label/annotation key is not spelled as it appears on the object | `kyverno jp query -i obj.yaml '<the key expression>'` | Fix the expression or swap `all`↔`any` |
| Rule fires on everything; `skip: 0` | `preconditions.all: []` from a templating bug, or a `NotEquals ""` against a null-guarded value that is never empty | `kubectl get cpol X -o jsonpath='{.spec.rules[0].preconditions}'` | Restore the condition |
| `error` result, message mentions variable substitution | Unguarded dereference of an optional path | `kyverno jp query` the raw path against a minimal object | Add `\|\| ''` / `` \|\| `[]` `` / `` \|\| `0` `` |
| Works at admission, `error` or wrong result in background scan | `request.operation`, `request.oldObject`, or `request.userInfo` used with `background: true` | `kubectl get polr -A -o json \| jq '.items[].results[] \| select(.result=="error")'` | `\|\| 'BACKGROUND'`, or set `background: false` |
| Policy rejected on `kubectl apply` | `request.userInfo` referenced while `background: true` | read the admission error verbatim | `background: false` |
| Numeric comparison always false | String/number type mismatch (`value: "3"` vs `value: 3`) | inspect the YAML quoting | unquote the number |
| `Equals` on `1Gi` vs `1024Mi` is false | `Equals` is literal; only Greater/Less parse quantities | — | use `GreaterThanOrEquals` + `LessThanOrEquals`, or normalise |
| Wildcard has no effect | wildcards apply to `Equals`/`NotEquals` between strings | test with `kyverno apply` | restructure to `Equals`/`NotEquals`, or use `AnyIn` with an explicit list |
| Duration comparison rejects the value | `7d` is not a Go duration | — | `168h` |
| Rule behaves differently on a Deployment than on a bare Pod | autogen path rewriting | §6.6 | anchor on the pod template explicitly |
| Preconditions pass, mutate-existing does nothing | RBAC on the background controller | §6.5 | aggregate a ClusterRole |
| Duplicate array entries accumulate | missing idempotency precondition on a JSON Patch `add` to `/-` | `kubectl get pod X -o jsonpath='{.spec.tolerations}'` | §4.7 GUARD 1 |

### 6.2 Walkthrough — the background-scan asymmetry

The single most common precondition bug. This rule works perfectly at admission and errors on every background scan:

```yaml
      preconditions:
        all:
          - key: "{{ request.operation }}"          # BROKEN under background scan
            operator: AnyIn
            value: [CREATE, UPDATE]
```

Reproduction and evidence:

```console
$ kubectl get polr -n prod -o json \
  | jq -r '.items[].results[] | select(.result=="error") | .message' | sort -u
failed to evaluate preconditions: failed to substitute variables in preconditions: \
  NotFoundVariableErr, variable request.operation not resolved at path /

$ kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=200 | grep -i precondition
E0813 09:14:22.118437  1 validation.go:141] "failed to evaluate preconditions" err="..." \
  policy="require-readiness-probe-tier1" rule="readiness-probe-required"
```

The fix is the idiom already used throughout §4:

```yaml
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: AnyIn
            value: [CREATE, UPDATE, BACKGROUND]
```

The admission-only variable set to memorise: `request.operation` (empty in background), `request.oldObject` (null), `request.userInfo` and its `username`/`groups`/`uid`/`extra` children, `request.roles`, `request.clusterRoles`, `serviceAccountName`, `serviceAccountNamespace`. Referencing `request.userInfo` with `background: true` is rejected outright:

```console
$ kubectl apply -f policies/pvc-storageclass-immutable-background-true.yaml
Error from server: error when creating "...": admission webhook "validate-policy.kyverno.svc" denied the request:
spec.background: Invalid value: true: variables `request.userInfo` are not allowed in background mode; set spec.background to false
```

### 6.3 Walkthrough — turning an admission-blocking error into a skip

```console
# Reproduce: a precondition that dereferences an optional array without a guard.
$ kubectl -n prod create -f tests/pod-no-volumes.yaml --dry-run=server
Error from server: error when creating "tests/pod-no-volumes.yaml": admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/prod/api was blocked due to the following policies

restrict-hostpath-and-privileged:
  hostpath-allowlist: 'failed to evaluate preconditions: failed to substitute variables:
    invalid type for length: <nil>, expected one of: [string array object]'
```

Two independent things went wrong, and both matter:

1. The expression was not null-safe.
2. `failurePolicy: Fail` turned a Kyverno-side evaluation error into a rejected `CREATE`. This is correct and intentional — a security policy that fails open is not a policy — but it means precondition expressions are on the availability critical path of every workload they match.

Turn up verbosity to see the substitution attempt:

```console
$ kubectl -n kyverno patch deploy kyverno-admission-controller --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"-v=4"}]'
deployment.apps/kyverno-admission-controller patched

$ kubectl -n kyverno rollout status deploy/kyverno-admission-controller
deployment "kyverno-admission-controller" successfully rolled out

$ kubectl -n kyverno logs deploy/kyverno-admission-controller -f | grep -i 'substitut\|precondition'
I0813 09:31:07.442918  1 vars.go:212] "variable substitution" path="/preconditions/any/0/key" \
  variable="request.object.spec.volumes[?hostPath] | length(@)"
E0813 09:31:07.443101  1 vars.go:230] "failed to substitute variable" err="invalid type for length: <nil>"

# Revert when finished — v=4 is expensive on a busy cluster.
$ kubectl -n kyverno patch deploy kyverno-admission-controller --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/containers/0/args/-"}]'
```

### 6.4 Walkthrough — `all` vs `any` inversion

The semantics invert under negation, and this is where correct-looking policies silently fail open. "Block Pods that use **any** disallowed capability" is not `any` + `Equals`; it is a `foreach` with `AnyNotIn`, or an `all` of `NotEquals`:

```yaml
        # WRONG — "any of these is not NET_RAW" is true as soon as the list has
        # two distinct entries, so it is essentially always true.
        any:
          - key: "{{ request.object.spec.containers[].securityContext.capabilities.add[] || `[]` }}"
            operator: AnyNotIn
            value: [NET_BIND_SERVICE]

        # RIGHT — "none of the requested capabilities is outside the allowlist".
        all:
          - key: "{{ request.object.spec.containers[].securityContext.capabilities.add[] || `[]` }}"
            operator: AllIn
            value: [NET_BIND_SERVICE, CHOWN, SETUID, SETGID]
```

Verify with a deliberately hostile fixture, not a benign one — the test that matters is the one where the rule must *fire*.

### 6.5 Walkthrough — preconditions pass, nothing happens (mutate-existing)

```console
$ kubectl -n kyverno logs deploy/kyverno-background-controller --tail=50 | grep -i forbidden
E0813 10:02:44.771208 1 mutation.go:118] "failed to patch target" \
  err="configmaps \"app-config\" is forbidden: User \"system:serviceaccount:kyverno:kyverno-background-controller\" cannot patch resource \"configmaps\" in API group \"\" in the namespace \"prod\"" \
  policy="propagate-namespace-owner" rule="propagate-owner-label"

$ kubectl auth can-i patch configmaps \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -n prod
no

$ kubectl apply -f infra/rbac-background-extra.yaml
clusterrole.rbac.authorization.k8s.io/kyverno:background-extra created

$ kubectl auth can-i patch configmaps \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -n prod
yes
```

The diagnostic discipline: **before** blaming the preconditions, confirm the rule was reached. `kubectl get polr` showing `skip` means preconditions rejected it; no report entry and a controller log error means preconditions passed and the *body* failed.

### 6.6 Walkthrough — autogen and precondition paths

Kyverno's pod-controller autogen clones a Pod rule for Deployments, StatefulSets, DaemonSets, Jobs and CronJobs, rewriting `request.object.spec...` prefixes to `request.object.spec.template.spec...` (and to `request.object.spec.jobTemplate.spec.template.spec...` for CronJobs). Two consequences that bite in production:

- A precondition on `request.object.spec.containers[...]` **is** rewritten and works on the controller.
- A precondition on `request.object.metadata.labels...` is **not** rewritten. In the generated Deployment rule it reads the *Deployment's* labels, not the pod template's. If your tier label lives only on `spec.template.metadata.labels`, the autogen'd rule silently skips every Deployment while the bare-Pod rule works — the classic "it passes in CI and never fires in the cluster" report.

Verify rather than assume. Render the effective rules and test against a controller, not a Pod:

```console
$ kubectl get cpol require-readiness-probe-tier1 -o yaml | yq '.status'
autogen:
  rules:
    - exclude: {resources: {}}
      generate: {}
      match:
        any:
          - resources:
              kinds: [Deployment, StatefulSet]
              operations: [CREATE, UPDATE]
      mutate: {}
      name: autogen-readiness-probe-required
      preconditions:
        all:
          - key: '{{ request.object.spec.template.metadata.labels."app.kubernetes.io/tier" || '''' }}'
            operator: Equals
            value: "1"
          ...
conditions:
  - message: Ready
    reason: Succeeded
    status: "True"
    type: Ready
ready: true

$ kyverno apply policies/require-readiness-probe-tier1.yaml --resource tests/deployment.yaml
Applying 1 policy rule(s) to 1 resource(s)...
pass: 0, fail: 0, warn: 0, error: 0, skip: 1     # <-- the bug, made visible
```

If the rendered rule is not what you need, stop relying on autogen for that rule: set `pod-policies.kyverno.io/autogen-controllers: none` and write the controller rule explicitly with the paths you intend.

### 6.7 The verification ladder for a precondition change

Never promote a precondition edit on inspection alone. In order, cheapest first:

1. `kyverno jp query -i <object>.yaml '<key expression>'` — against both a matching and a non-matching object, and against one where the path is absent.
2. `kyverno apply <policy> --resource fixtures.yaml` — confirm the `pass/fail/skip` split is the split you intended.
3. `kyverno test tests/` — assert `result: skip` explicitly so a future widening breaks CI.
4. `kubectl apply` the policy with `validationFailureAction: Audit`, then read `kubectl get polr -A` for a full background-scan cycle. This is the only step that exercises the background path.
5. `kubectl create --dry-run=server` against a known-violating object — the only step that proves enforcement.
6. Promote to `Enforce`, and watch `kyverno_policy_results_total{rule_result="error"}` for one deploy cycle.

Steps 4 and 5 catch different bugs and neither substitutes for the other.

---

## 7. Exam checklist

- `preconditions` sits at `spec.rules[].preconditions`, uses `any` (OR) and `all` (AND), and each entry is exactly `key` / `operator` / `value`.
- Both `any` and `all` present ⇒ **both** must be satisfied.
- A failed precondition produces **`skip`**, never `fail`, and never blocks — even in `Enforce`.
- The same `any`/`all`/operator grammar appears in `validate.deny.conditions`, where **true means block**.
- Preconditions run **after** `match`/`exclude`, **before** the rule body.
- `AnyIn`/`AllIn`/`AnyNotIn`/`AllNotIn` supersede the deprecated `In`/`NotIn`.
- `Equals`/`NotEquals` support `*` and `?` wildcards on strings; the comparison operators parse Kubernetes quantities; the `Duration*` operators parse Go durations (`168h`, never `7d`).
- `request.operation` is empty in background scans → `{{ request.operation || 'BACKGROUND' }}`.
- `request.userInfo` forces `background: false`; Kyverno rejects the policy otherwise.
- Every dereference of an optional path needs `|| ''`, `` || `[]` ``, or `` || `0` `` — an unresolved variable is an **error**, not a false.
- Quoted JMESPath identifiers for keys containing `.`, `/` or `-`, escaped inside YAML double quotes: `\"app.kubernetes.io/tier\"`.
- Preconditions also live at `foreach[].preconditions` (with `element`, `elementIndex`) and at `mutate.targets[].preconditions` (with `target`).
- Prefer `match.any[].resources.operations` over a precondition on `request.operation` — it narrows the webhook itself.

---

## Referencias

**Exam and curriculum**
- KCA curriculum (CNCF) — https://github.com/cncf/curriculum
- KCA curriculum PDF — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- Kyverno Certified Associate program page — https://training.linuxfoundation.org/certification/kyverno-certified-associate-kca/

**Kyverno — core documentation**
- Preconditions — https://kyverno.io/docs/writing-policies/preconditions/
- Match and exclude — https://kyverno.io/docs/writing-policies/match-exclude/
- Variables — https://kyverno.io/docs/writing-policies/variables/
- JMESPath and Kyverno's custom functions — https://kyverno.io/docs/writing-policies/jmespath/
- External data sources (`context`, ConfigMaps, API calls, deferred loading) — https://kyverno.io/docs/writing-policies/external-data-sources/
- Validate rules (`deny.conditions`, `foreach`, patterns, anchors) — https://kyverno.io/docs/writing-policies/validate/
- Mutate rules (`foreach`, `targets`, JSON Patch, strategic merge) — https://kyverno.io/docs/writing-policies/mutate/
- Generate rules — https://kyverno.io/docs/writing-policies/generate/
- Auto-generation rules for Pod controllers — https://kyverno.io/docs/writing-policies/autogen/
- Policy exceptions — https://kyverno.io/docs/writing-policies/exceptions/
- Policy API reference (`ClusterPolicy` CRD fields) — https://kyverno.io/docs/policy-types/cluster-policy/
- Policy reports — https://kyverno.io/docs/policy-reports/
- Kyverno CLI (`apply`, `test`, `jp`) — https://kyverno.io/docs/kyverno-cli/
- Kyverno configuration (`resourceFilters`, webhook settings) — https://kyverno.io/docs/installation/customization/
- Kyverno security and RBAC model — https://kyverno.io/docs/installation/security/
- Kyverno monitoring and metrics — https://kyverno.io/docs/monitoring/
- Kyverno policy library — https://kyverno.io/policies/
- Kyverno source (autogen, engine, operators) — https://github.com/kyverno/kyverno

**Kubernetes**
- Dynamic admission control (webhooks, `matchConditions`, `failurePolicy`) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Validating admission policy (CEL, `matchConditions`) — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Common Expression Language in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Resource quantity format — https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/quantity/
- JSON Patch and strategic merge patch in `kubectl` — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/
- Pod lifecycle and probes — https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Policy Working Group report API — https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report

**Specifications**
- JMESPath specification — https://jmespath.org/specification.html
- JSON Patch, RFC 6902 — https://datatracker.ietf.org/doc/html/rfc6902
- JSON Pointer, RFC 6901 (`~1` escaping) — https://datatracker.ietf.org/doc/html/rfc6901
- Go `time.ParseDuration` — https://pkg.go.dev/time#ParseDuration