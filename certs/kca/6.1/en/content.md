# KCA 6.1 — Policy Reports

> **Domain 6 · Weight 3.33** — Kyverno Certified Associate
> Level: Principal Platform Architect / Senior SRE

---

## 1. The architectural problem: admission control is a stateless verdict, governance is a stateful question

An admission webhook answers exactly one question, once, for one `AdmissionReview`:

> *"Should this API request be allowed?"*

That verdict is transient. It exists for the duration of one HTTP round trip between the API server and the webhook, it is delivered to whoever ran `kubectl apply`, and then it is gone. Nothing in Kubernetes persists it.

This is fine for enforcement. It is useless for governance. The questions a platform team actually gets asked in production are all *stateful* and *retrospective*:

| Question asked in production | Can an admission webhook answer it? |
|---|---|
| "Which 340 workloads currently violate `require-run-as-non-root`?" | **No** — it never saw them; they were created before the policy existed. |
| "If I flip this policy from `Audit` to `Enforce` on Monday, what breaks?" | **No** — enforcement decisions are not recorded. |
| "Team `payments` owns 12 namespaces. What is their compliance score this sprint?" | **No** — no aggregation, no ownership dimension. |
| "The auditor wants evidence that PCI-scoped namespaces were compliant on 2026-07-01." | **No** — no history, no evidence artifact. |
| "Did this Deployment stop violating the policy, or did someone add an exception?" | **No** — no diff, no per-resource state. |

The gap is structural, and it produces three failure modes that are extremely common in real clusters:

**Failure mode 1 — the "Enforce day-one" outage.** A team writes a correct policy, sets `Enforce`, and applies it cluster-wide. Existing workloads are untouched (admission control is not retroactive), so nothing appears broken. Three weeks later a node drains, a ReplicaSet tries to recreate 200 Pods, and *every single one is rejected*. The policy was never wrong; the team simply had no instrument that could show pre-existing violations.

**Failure mode 2 — log scraping as a compliance database.** Teams grep the admission controller logs, ship them to Loki, and build dashboards on log lines. This "works" until log retention rolls over, a controller restarts, replicas scale out, or the log format changes between minor versions. Compliance state derived from logs is not reproducible, and an auditor will say so.

**Failure mode 3 — Kubernetes Events as the source of truth.** Kyverno can emit Events for policy results, and Events are real API objects — but they are garbage collected by `kube-apiserver` after `--event-ttl` (default **1 hour**) and they are deliberately lossy under load (event aggregation and rate limiting are built into the client). Events are a *notification* channel, not a *state* channel.

### The design answer: a declarative, per-resource, queryable, GC-linked compliance object

The Kubernetes **Policy Working Group** (wg-policy) solved this by defining an open CRD-based API — `PolicyReport` and `ClusterPolicyReport` — that stores the *current evaluation state* of every resource against every policy as first-class Kubernetes objects. Kyverno is the reference producer.

Because reports are ordinary API objects, they inherit the entire Kubernetes control plane for free:

- **Queryable with `kubectl`**, RBAC, field/label selectors, and `-o jsonpath`/`jq`.
- **Watchable**, so UIs and alerting pipelines are event-driven rather than polling.
- **Owner-referenced** to the resource they describe, so the API server's garbage collector deletes the report the instant the workload is deleted — no orphan reaper to write, no TTL cron.
- **Namespaced**, so a tenant can be granted `get/list/watch` on reports in their own namespaces and nowhere else.
- **Vendor-neutral**, so Kyverno, Trivy Operator, Falco, kube-bench and Nirmata all write into one schema that one UI can render.

The mental model to carry into the exam and into production:

```
Admission response   →  a VERDICT   (transient, per-request, blocking)
Kubernetes Event     →  a SIGNAL    (~1h TTL, lossy, human-facing)
Prometheus metric    →  a FLOW      (counters; rate of evaluations over time)
PolicyReport         →  the STOCK   (current compliance state, durable, per-resource)
Controller log       →  a TRACE     (debugging the engine, not the fleet)
```

**Metrics tell you how many evaluations failed last hour. Reports tell you what is broken right now.** These are different questions and you need both.

---

## 2. The API: `wgpolicyk8s.io/v1alpha2`

Policy Reports are **not a Kyverno API**. They are an open specification maintained by Kubernetes SIG/WG Policy (repository: `kubernetes-sigs/wg-policy-prototypes`). Kyverno ships and owns the CRDs in its distribution, but any tool may produce or consume them.

Two kinds, split exactly along the namespaced/cluster-scoped boundary of the resource being described:

| | `PolicyReport` | `ClusterPolicyReport` |
|---|---|---|
| API group/version | `wgpolicyk8s.io/v1alpha2` | `wgpolicyk8s.io/v1alpha2` |
| Short name | `polr` | `cpolr` |
| Scope of the report object | Namespaced | Cluster |
| Describes resources of kind | Namespaced (`Pod`, `Deployment`, `Service`, `Ingress`, `Role`…) | Cluster-scoped (`Namespace`, `ClusterRole`, `PersistentVolume`, `CRD`, `Node`…) |
| Lives in | The same namespace as the resource | Cluster scope |
| RBAC delegation | Per-tenant (`Role` in their namespace) | Platform team only |

**Exam signal:** if a question shows a violating `Namespace` or `ClusterRole` and asks where the result appears, the answer is `ClusterPolicyReport` (`cpolr`), *not* `polr`. The split follows the **scope of the resource under evaluation**, never the scope of the policy. A `ClusterPolicy` matching Pods writes to namespaced `PolicyReport` objects.

### 2.1 Anatomy of a report — complete, unabridged object

```yaml
apiVersion: wgpolicyk8s.io/v1alpha2
kind: PolicyReport
metadata:
  # Kyverno 1.10+ names the report after the UID of the resource it describes.
  name: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913
  namespace: payments
  labels:
    app.kubernetes.io/managed-by: kyverno
  annotations:
    audit.kyverno.io/last-scan-time: "2026-08-14T09:41:07Z"
  # This ownerReference is the whole garbage-collection strategy.
  # Delete the Deployment -> the API server deletes this report. No reaper needed.
  ownerReferences:
    - apiVersion: apps/v1
      kind: Deployment
      name: checkout-api
      uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913
      controller: true
      blockOwnerDeletion: false

# 'scope' is the single resource this report describes. Kyverno 1.10+ writes
# one report per resource; older versions aggregated a whole namespace into
# 'polr-ns-<namespace>', which did not scale and produced etcd-sized objects.
scope:
  apiVersion: apps/v1
  kind: Deployment
  name: checkout-api
  namespace: payments
  uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913

summary:
  pass: 4
  fail: 2
  warn: 1
  error: 1
  skip: 1

results:
  # --- 1. A clean pass -------------------------------------------------------
  - source: kyverno
    policy: require-labels
    rule: autogen-check-for-labels        # NOTE the autogen- prefix, see §5.3
    category: Best Practices
    severity: medium
    result: pass
    scored: true
    message: validation rule 'autogen-check-for-labels' passed.
    timestamp:
      seconds: 1786174867
      nanos: 0
    resources:
      - apiVersion: apps/v1
        kind: Deployment
        name: checkout-api
        namespace: payments
        uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913

  # --- 2. A scored violation -------------------------------------------------
  - source: kyverno
    policy: require-run-as-nonroot
    rule: autogen-run-as-non-root
    category: Pod Security Standards (Restricted)
    severity: high
    result: fail
    scored: true
    message: >-
      validation error: Running as root is not allowed. The fields
      spec.securityContext.runAsNonRoot, spec.containers[*].securityContext.runAsNonRoot,
      spec.initContainers[*].securityContext.runAsNonRoot, and
      spec.ephemeralContainers[*].securityContext.runAsNonRoot must be `true`.
      rule autogen-run-as-non-root failed at path
      /spec/template/spec/containers/0/securityContext/runAsNonRoot/
    timestamp:
      seconds: 1786174867
      nanos: 0
    resources:
      - apiVersion: apps/v1
        kind: Deployment
        name: checkout-api
        namespace: payments
        uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913

  # --- 3. A violation of an UNSCORED policy -> 'warn', not 'fail' ------------
  - source: kyverno
    policy: require-team-annotation
    rule: check-team
    category: Ownership
    severity: low
    result: warn
    scored: false                         # driven by policies.kyverno.io/scored: "false"
    message: 'validation error: annotation `owner.company.io/team` is recommended.'
    timestamp:
      seconds: 1786174867
      nanos: 0
    resources:
      - apiVersion: apps/v1
        kind: Deployment
        name: checkout-api
        namespace: payments
        uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913

  # --- 4. Engine failure, NOT a compliance failure ---------------------------
  - source: kyverno
    policy: check-image-registry
    rule: validate-registry-allowlist
    category: Supply Chain
    severity: high
    result: error
    scored: true
    message: >-
      failed to evaluate rule: failed to load context: failed to execute APICall:
      configmaps "registry-allowlist" not found in namespace "kyverno"
    timestamp:
      seconds: 1786174867
      nanos: 0
    resources:
      - apiVersion: apps/v1
        kind: Deployment
        name: checkout-api
        namespace: payments
        uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913

  # --- 5. Skipped by a PolicyException ---------------------------------------
  - source: kyverno
    policy: disallow-host-path
    rule: host-path
    category: Pod Security Standards (Baseline)
    severity: high
    result: skip
    scored: true
    message: rule skipped due to policy exception 'payments/exempt-legacy-storage'
    timestamp:
      seconds: 1786174867
      nanos: 0
    properties:
      exceptions: payments/exempt-legacy-storage
    resources:
      - apiVersion: apps/v1
        kind: Deployment
        name: checkout-api
        namespace: payments
        uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913
```

### 2.2 The five result values — precise semantics

This table is the single highest-yield piece of knowledge in this domain. Misreading `warn` vs `fail` or `error` vs `fail` is the most common production mistake in compliance dashboards, because it silently changes the denominator of every compliance percentage you publish.

| `result` | Meaning | How it is produced | Counts as a violation? | SRE action |
|---|---|---|---|---|
| `pass` | Rule evaluated; the resource satisfies it. | Normal evaluation. | No | None |
| `fail` | Rule evaluated; the resource violates it; the rule is **scored**. | Default for a violated `validate` rule. | **Yes** | Remediate the workload or grant an exception |
| `warn` | Rule evaluated; the resource violates it; the rule is **unscored**. | Policy annotation `policies.kyverno.io/scored: "false"`. | No — excluded from the failure count | Advisory backlog |
| `error` | The rule **could not be evaluated**. | Variable substitution failure, `apiCall`/`configMap` context load failure, RBAC denial, malformed JMESPath, unreachable registry for `imageVerify`. | **No — and this is the trap** | **Page someone.** An `error` is an unknown, not a pass. |
| `skip` | The rule did not apply to this resource. | `preconditions` evaluated false, or a matching `PolicyException`. | No | Verify the exception is intentional and time-boxed |

> **Production rule:** never compute compliance as `pass / (pass + fail)`. An `error` is an *unmeasured* resource. A cluster where the reports controller lost RBAC on a CRD will happily report 100% compliance while measuring nothing. Alert on `summary.error > 0` with the same severity as `summary.fail`.

> **Exam trap — `Audit` vs `Enforce` does not change the result value.** `validationFailureAction` (Kyverno ≤1.12) / `validate.failureAction` (Kyverno 1.13+) controls **whether admission is blocked**, not what appears in the report. An `Audit` violation is reported as `fail`. The real second-order effect is subtler and worth internalising:
>
> Under `Enforce`, a violating **create** is rejected — the resource never exists, so **no report is written for it** (there is nothing to own the report). Therefore `fail` entries in a healthy `Enforce` cluster come almost exclusively from **background scans of pre-existing resources**. If you switch a policy to `Enforce` and your `fail` count drops to zero overnight, you have not fixed anything — you have stopped observing.

---

## 3. Kyverno's report pipeline: who writes what, and when

Since Kyverno **1.10** the monolith is split into four independently scalable deployments. Reports are the responsibility of one of them.

| Deployment | Responsibility | Relevance to reports |
|---|---|---|
| `kyverno-admission-controller` | Serves `ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration` | Emits **intermediate (ephemeral) reports** for each admitted request |
| `kyverno-background-controller` | `generate` and `mutate` on existing resources | Not a report producer |
| `kyverno-cleanup-controller` | `CleanupPolicy` / TTL-based deletion | Not a report producer |
| `kyverno-reports-controller` | **Background scanning + aggregation into `polr`/`cpolr`** | **The only writer of `PolicyReport`/`ClusterPolicyReport`** |

**Architectural consequence:** if `reportsController.enabled=false` in the Helm chart, admission control keeps working perfectly and **zero reports are ever produced**. This is the number-one cause of "my policies work but `kubectl get polr` is empty". It is also a legitimate production choice on very large clusters — see §7.

### 3.1 The two independent evaluation paths

```
                    ┌──────────────────────────────────────────────┐
  kubectl apply ──▶ │ kube-apiserver                               │
                    └───────────────┬──────────────────────────────┘
                                    │ AdmissionReview
                                    ▼
                    ┌──────────────────────────────────────────────┐
                    │ kyverno-admission-controller                 │
                    │  · evaluates matching rules                  │
                    │  · returns allow/deny  (the VERDICT)         │
                    │  · writes an EPHEMERAL/intermediate report   │
                    └───────────────┬──────────────────────────────┘
                                    │ ephemeralreports.reports.kyverno.io
                                    ▼
   every --backgroundScanInterval   ┌──────────────────────────────────────────┐
   (default 1h) ──────────────────▶ │ kyverno-reports-controller               │
   full re-evaluation of all        │  · BACKGROUND SCAN of existing resources │
   matched existing resources       │  · AGGREGATES ephemeral + scan results   │
                                    │  · reconciles on policy add/update/delete│
                                    └───────────────┬──────────────────────────┘
                                                    │
                                                    ▼
                          wgpolicyk8s.io/v1alpha2 PolicyReport / ClusterPolicyReport
                                     (one object per resource, owned by it)
```

| Dimension | Admission-time results | Background-scan results |
|---|---|---|
| Trigger | A `CREATE`/`UPDATE` API request | Timer (`--backgroundScanInterval`, default `1h`) + policy change events |
| Covers | Only resources touched since the policy was installed | **All** existing matched resources |
| Latency to appear in `polr` | Seconds (aggregation cycle) | Up to one full interval |
| Sees `request.userInfo`, `request.operation`, `request.roles` | **Yes** | **No** — there is no AdmissionRequest |
| Disabled by | `--admissionReports=false` | `spec.background: false` on the policy, or `--backgroundScanInterval` |
| Honours the `resourceFilters` ConfigMap | Always | Only if `--skipResourceFilters=false` |
| Purpose | Immediate feedback, drift the moment it happens | Retroactive truth, the "what would break" answer |

> **Exam signal — the `background` / `userInfo` incompatibility.** Kyverno **rejects at admission** any policy with `background: true` (the default) that references AdmissionRequest-only variables such as `{{request.userInfo.username}}`, `{{request.roles}}`, `{{request.clusterRoles}}` or `{{request.operation}}`. The error looks like:
>
> ```
> admission webhook "validate-policy.kyverno.svc" denied the request:
> path: spec.rules[0].validate.pattern: variables {{request.userInfo.username}}
> are not allowed
> ```
>
> The fix is `spec.background: false` — and the **price** is that the policy is then admission-only and **produces no background-scan results**, so it can never tell you about pre-existing violations. That trade-off is a design decision, not a workaround.

### 3.2 Intermediate reports — the layer you will meet during triage

Between the admission controller and the final `polr` there is a short-lived staging layer. Its API has evolved:

| Kyverno version | Intermediate report kinds | API group |
|---|---|---|
| ≤ 1.9 | none (reports written directly, aggregated per namespace as `polr-ns-<ns>`) | — |
| 1.10 | `AdmissionReport`, `ClusterAdmissionReport`, `BackgroundScanReport`, `ClusterBackgroundScanReport` | `kyverno.io/v1alpha2` |
| 1.11+ | consolidated into `EphemeralReport`, `ClusterEphemeralReport` | `reports.kyverno.io/v1` |

These objects are an implementation detail: **do not build tooling on them**, they are not the stable contract. They are extremely useful for one thing — proving *where* the pipeline is stuck:

```
$ kubectl get ephemeralreports.reports.kyverno.io -A --no-headers | wc -l
4
```

A **growing, non-draining** count of ephemeral reports means the aggregation loop in the reports controller is failing or throttled. A count that stays near zero while `polr` objects exist means the pipeline is healthy.

### 3.3 API evolution matrix (know which rung you are standing on)

| Concept | Stable / exam-relevant answer | Notes |
|---|---|---|
| Report API | `wgpolicyk8s.io/v1alpha2`, kinds `PolicyReport`/`ClusterPolicyReport` | The KCA target. Owned by Kubernetes WG Policy, not Kyverno. |
| Short names | `polr`, `cpolr` | Memorise these; the exam uses them. |
| Report granularity | One report per resource (Kyverno 1.10+) | Pre-1.10 clusters aggregated per namespace. |
| Reports producer | `kyverno-reports-controller` (1.10+) | Separately enable/disable/scale. |
| Successor API | The WG Policy API has been rebranded as **OpenReports** (`openreports.io`, kinds `Report`/`ClusterReport`) | Newer Kyverno releases can emit it; `wgpolicyk8s.io/v1alpha2` remains the compatible baseline. Confirm what your cluster actually serves with `kubectl api-resources` before writing tooling. |

---

## 4. Complete, production-grade manifests

### 4.1 A policy engineered *for* reporting

The report is only as useful as the metadata the policy carries. `category` and `severity` come **exclusively** from annotations — Kyverno copies them verbatim into every result. A policy without them produces reports you cannot slice, prioritise, or route.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-nonroot
  annotations:
    # --> Copied into results[].category. This is your dashboard's group-by key.
    policies.kyverno.io/category: Pod Security Standards (Restricted)
    # --> Copied into results[].severity. Valid: critical | high | medium | low | info
    policies.kyverno.io/severity: high
    # --> 'true' keeps result=fail. Set "false" to downgrade violations to result=warn.
    policies.kyverno.io/scored: "true"
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/title: Require runAsNonRoot
    policies.kyverno.io/description: >-
      Containers must not run as the root user. Reported as `fail` in Audit mode
      so that pre-existing workloads are surfaced before enforcement is enabled.
spec:
  # background: true is REQUIRED for pre-existing resources to be scanned.
  # It is the default; it is written explicitly here because it is load-bearing.
  background: true

  # Kyverno 1.13+ moved failureAction under the rule. On <=1.12 use the
  # top-level `spec.validationFailureAction: Audit` instead.
  rules:
    - name: run-as-non-root
      match:
        any:
          - resources:
              kinds:
                - Pod
      # Exclude control-plane namespaces from BOTH admission and scanning.
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-node-lease
                - kube-public
                - kyverno
      validate:
        failureAction: Audit            # Audit => report but do not block
        failureActionOverrides:
          - action: Enforce             # ...except here, where we already converged
            namespaces:
              - payments
              - identity
        message: >-
          Running as root is not allowed. Set
          spec.securityContext.runAsNonRoot=true or set it on every container.
        pattern:
          spec:
            =(securityContext):
              =(runAsNonRoot): "true"
            containers:
              - =(securityContext):
                  =(runAsNonRoot): "true"
```

**The two-annotation discipline.** Ship no policy without `category` and `severity`. They are free at authoring time and impossible to backfill across an existing report corpus without regenerating every report.

### 4.2 An unscored ("advisory") policy — the safe rollout primitive

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-annotation
  annotations:
    policies.kyverno.io/category: Ownership
    policies.kyverno.io/severity: low
    # THIS is what turns fail -> warn. Violations stop polluting the failure
    # budget while the org backfills ownership metadata.
    policies.kyverno.io/scored: "false"
spec:
  background: true
  rules:
    - name: check-team
      match:
        any:
          - resources:
              kinds: [Deployment, StatefulSet, DaemonSet, CronJob]
      validate:
        failureAction: Audit
        message: 'annotation `owner.company.io/team` is recommended.'
        pattern:
          metadata:
            annotations:
              owner.company.io/team: "?*"
```

**Rollout ladder** — each rung is a distinct, reversible change with a distinct report signature:

| Stage | `scored` | `failureAction` | Report result | Admission | Purpose |
|---|---|---|---|---|---|
| 1. Discover | `false` | `Audit` | `warn` | allowed | Measure blast radius with zero risk to SLOs |
| 2. Commit | `true` | `Audit` | `fail` | allowed | Failures now count; drive the count to zero |
| 3. Pin per namespace | `true` | `Audit` + `failureActionOverrides: Enforce` | `fail` (legacy only) | blocked in converged namespaces | Prevent regression where you already won |
| 4. Enforce fleet-wide | `true` | `Enforce` | `fail` count → 0 | blocked | Steady state |

Never jump from stage 1 to stage 4. Stage 2 exists precisely so that the `fail` count is an honest, monitorable burn-down.

### 4.3 `PolicyException` — turning `fail` into an auditable `skip`

An exception is the correct way to retire a violation you have consciously accepted. Unlike deleting or narrowing the policy, it is **scoped, declarative, reviewable, and visible in the report** as `skip` with the exception name in `properties`.

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: exempt-legacy-storage
  namespace: payments
  annotations:
    owner.company.io/team: payments-platform
    owner.company.io/ticket: PLAT-4471
    owner.company.io/expires: "2026-12-31"   # advisory; enforce with a CleanupPolicy
spec:
  exceptions:
    - policyName: disallow-host-path
      ruleNames:
        - host-path
        - autogen-host-path          # ALWAYS list the autogen variants (see §5.3)
        - autogen-cronjob-host-path
  match:
    any:
      - resources:
          kinds:
            - Pod
            - Deployment
          namespaces:
            - payments
          names:
            - legacy-ledger-*
```

Exceptions must be enabled on the controllers — they are off by default in some distributions:

```yaml
# Helm values
features:
  policyExceptions:
    enabled: true
    namespace: ""       # "" = any namespace; set to a single namespace to centralise
```

### 4.4 Helm values: the complete reporting control surface

```yaml
# values.yaml — Kyverno chart, reporting-relevant settings only
reportsController:
  enabled: true
  replicas: 1                 # leader-elected; >1 gives HA, not throughput
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      memory: 2Gi             # NO cpu limit: throttling here silently stalls scans
  # Escape hatch for any flag not surfaced by the chart:
  extraArgs:
    backgroundScanWorkers: 5

admissionController:
  replicas: 3
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      memory: 2Gi

features:
  admissionReports:
    enabled: true             # false => admission results never reach polr;
                              #          background scan becomes the only source
  backgroundScan:
    enabled: true
    backgroundScanInterval: 1h
    backgroundScanWorkers: 5
    # false => background scans HONOUR the resourceFilters ConfigMap.
    # Default true means scans IGNORE those filters. See §7.2 — this is the
    # single most effective etcd-pressure lever in the chart.
    skipResourceFilters: false
  reporting:
    validate: true
    mutate: false             # mutation results are usually dashboard noise
    mutateExisting: false
    imageVerify: true
    generate: false
  policyExceptions:
    enabled: true
    namespace: ""
```

Equivalent raw container flags, for clusters not installed via Helm:

```yaml
# Deployment: kyverno-reports-controller
        args:
          - --backgroundScanInterval=1h
          - --backgroundScanWorkers=5
          - --skipResourceFilters=false
          - --enableReporting=validate,imageVerify
          - --v=2
```

### 4.5 RBAC — the silent producer of `result: error`

Kyverno's controllers use **aggregated ClusterRoles**. Out of the box they can read the built-in kinds. The moment a policy matches a **CRD** — `Certificate`, `VirtualService`, `Rollout`, `ScaledObject` — the reports controller cannot `list/watch` it and every background evaluation becomes `result: error`, or produces no report at all.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:custom-resources
  labels:
    # These aggregation labels are the extension point. Without them, this
    # ClusterRole is dead weight.
    rbac.kyverno.io/aggregate-to-reports-controller: "true"
    rbac.kyverno.io/aggregate-to-background-controller: "true"
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
rules:
  - apiGroups: ["cert-manager.io"]
    resources: ["certificates", "issuers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.istio.io"]
    resources: ["virtualservices", "gateways"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["argoproj.io"]
    resources: ["rollouts"]
    verbs: ["get", "list", "watch"]
```

### 4.6 Read-only report access for a tenant

Reports are namespaced, so tenants can safely self-serve their own compliance state without seeing anyone else's:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: policy-report-reader
  namespace: payments
rules:
  - apiGroups: ["wgpolicyk8s.io"]
    resources: ["policyreports"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-report-reader
  namespace: payments
roleBinding: {}
subjects:
  - kind: Group
    name: team-payments
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: policy-report-reader
  apiGroup: rbac.authorization.k8s.io
```

### 4.7 Scraping Kyverno's own metrics

Each 1.10+ controller exposes its own metrics service. One `ServiceMonitor` covers all of them:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kyverno
  namespace: kyverno
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames: [kyverno]
  selector:
    matchLabels:
      app.kubernetes.io/part-of: kyverno
  endpoints:
    - port: metrics-port
      interval: 30s
      scrapeTimeout: 25s
      honorLabels: true
```

Alerting rules that catch the failure modes described in §5 and §7:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kyverno-reporting
  namespace: kyverno
spec:
  groups:
    - name: kyverno.reporting
      rules:
        # An 'error' is an UNMEASURED resource, not a passing one.
        - alert: KyvernoRuleEvaluationErrors
          expr: sum(rate(kyverno_policy_results_total{rule_result="error"}[15m])) > 0
          for: 15m
          labels: {severity: critical}
          annotations:
            summary: Kyverno rules are erroring — compliance data is incomplete
            runbook: Check reports-controller RBAC and any apiCall/configMap context

        # If the reports controller dies, polr goes stale and looks compliant.
        - alert: KyvernoReportsControllerDown
          expr: absent(up{job=~".*reports-controller.*"} == 1)
          for: 10m
          labels: {severity: critical}
          annotations:
            summary: No reports controller is scraping — PolicyReports are frozen

        - alert: KyvernoPolicyFailuresRising
          expr: |
            sum by (policy_name) (
              rate(kyverno_policy_results_total{rule_result="fail"}[30m])
            ) > 0
          for: 30m
          labels: {severity: warning}
```

### 4.8 Policy Reporter — the UI and routing layer

`kubectl` is the API; Policy Reporter (a Kyverno-org project) is the aggregation, UI, metrics-exporter and notification-router on top of the same CRDs. Because it consumes the **open** `wgpolicyk8s.io` API, it renders Kyverno, Trivy Operator and Falco results in one pane.

```console
$ helm repo add policy-reporter https://kyverno.github.io/policy-reporter
"policy-reporter" has been added to your repositories

$ helm repo update
Update Complete. ⎈Happy Helming!⎈

$ helm install policy-reporter policy-reporter/policy-reporter \
    --namespace policy-reporter --create-namespace \
    --set ui.enabled=true \
    --set kyvernoPlugin.enabled=true \
    --set monitoring.enabled=true
NAME: policy-reporter
LAST DEPLOYED: Fri Aug 14 09:52:11 2026
NAMESPACE: policy-reporter
STATUS: deployed
REVISION: 1
```

> Values changed between major versions of the chart: v2 uses `kyvernoPlugin.enabled`, v3 uses `plugin.kyverno.enabled`. Always run `helm show values policy-reporter/policy-reporter` against the chart version you are actually installing rather than copying values from a blog post.

```console
$ kubectl -n policy-reporter get pods
NAME                                  READY   STATUS    RESTARTS   AGE
policy-reporter-6b7d9f8c4-ktz9m       1/1     Running   0          61s
policy-reporter-kyverno-plugin-...    1/1     Running   0          61s
policy-reporter-ui-7c8d5b9f6-x2vqp    1/1     Running   0          61s

$ kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080
Forwarding from 127.0.0.1:8082 -> 8080
```

Notification targets are declarative — this is how a `fail` becomes a page rather than a dashboard nobody opens:

```yaml
target:
  slack:
    channels:
      - webhook: https://hooks.slack.com/services/XXX/YYY/ZZZ
        minimumSeverity: high
        skipExistingOnStartup: true      # do NOT replay history on every restart
        filter:
          namespaces:
            exclude: ["kube-system", "kyverno"]
  loki:
    host: http://loki.observability:3100
    minimumSeverity: warning
```

---

## 5. Working the CLI

### 5.1 Discovery and shape of the data

```console
$ kubectl api-resources --api-group=wgpolicyk8s.io
NAME                   SHORTNAMES   APIVERSION                    NAMESPACED   KIND
clusterpolicyreports   cpolr        wgpolicyk8s.io/v1alpha2       false        ClusterPolicyReport
policyreports          polr         wgpolicyk8s.io/v1alpha2       true         PolicyReport
```

```console
$ kubectl get polr -A
NAMESPACE   NAME                                   KIND         NAME             PASS   FAIL   WARN   ERROR   SKIP   AGE
default     1c0d4e8b-2a6f-4d17-8b3e-9f0a5c2d7e41   Pod          nginx            3      1      0      0       0      12m
payments    7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913   Deployment   checkout-api     4      2      1      1       1      12m
payments    a4b8c1d2-3e5f-4071-92a3-6b7c8d9e0f11   ReplicaSet   checkout-api-…   4      2      1      1       1      12m
payments    e2f5a7c9-1b3d-4e6f-8a09-2c4d6e8f0a13   Pod          checkout-api-…   4      2      1      1       1      12m
identity    9d1e3f5a-7b9c-4d0e-a2f4-6b8d0f2a4c61   Deployment   authn-gateway    6      0      0      0       0      12m

$ kubectl get cpolr
NAME                                   KIND        NAME          PASS   FAIL   WARN   ERROR   SKIP   AGE
b3c5d7e9-0f2a-4b6c-8d0e-1f3a5b7c9d02   Namespace   payments      1      1      0      0       0      12m
c4d6e8f0-1a3b-4c5d-9e0f-2a4b6c8d0e13   Namespace   identity      2      0      0      0       0      12m
```

**Read the columns carefully.** The first `NAME` is the report object (a UID). The second `NAME` (with `KIND`) is `scope` — the resource actually being evaluated. This duplication trips people up constantly.

Note also that `checkout-api` appears **three times**: `Deployment`, `ReplicaSet`, `Pod`. Kyverno's **auto-generation** feature expands a Pod rule into equivalent rules for Pod controllers, so a single logical violation is reported once per object in the ownership chain. Every fleet-wide count you compute must decide which layer it is counting — see §5.3.

### 5.2 Targeted triage

Fleet-wide failure ranking — the query to run first on any new cluster:

```console
$ kubectl get polr,cpolr -A -o json \
  | jq -r '.items[].results[] | select(.result=="fail")
           | [.severity, .policy, .rule] | @tsv' \
  | sort | uniq -c | sort -rn
     84	high	require-run-as-nonroot	autogen-run-as-non-root
     41	high	disallow-privilege-escalation	autogen-privilege-escalation
     28	medium	require-requests-limits	autogen-validate-resources
     12	high	disallow-host-path	autogen-host-path
      6	medium	require-labels	autogen-check-for-labels
```

Which namespaces carry the debt:

```console
$ kubectl get polr -A -o json \
  | jq -r '.items[] | select(.summary.fail > 0)
           | "\(.metadata.namespace)\t\(.scope.kind)/\(.scope.name)\t\(.summary.fail)"' \
  | sort -k3 -rn | head
payments	Deployment/checkout-api	2
payments	ReplicaSet/checkout-api-7d9c8b5f4	2
payments	Pod/checkout-api-7d9c8b5f4-x2mlq	2
legacy	  Deployment/ledger-batch	2
```

**Find every `error` — the unmeasured surface:**

```console
$ kubectl get polr,cpolr -A -o json \
  | jq -r '.items[].results[] | select(.result=="error")
           | "\(.policy)/\(.rule): \(.message)"' | sort -u
check-image-registry/validate-registry-allowlist: failed to evaluate rule: failed to load context: failed to execute APICall: configmaps "registry-allowlist" not found in namespace "kyverno"
require-cert-issuer/check-issuer: failed to evaluate rule: cert-manager.io/v1, Kind=Certificate is forbidden: User "system:serviceaccount:kyverno:kyverno-reports-controller" cannot list resource "certificates"
```

Both lines are actionable and neither would appear in a naive "compliance %" dashboard.

Single-resource drill-down — the exam-style command:

```console
$ kubectl -n payments get polr -o json \
  | jq -r '.items[] | select(.scope.kind=="Deployment" and .scope.name=="checkout-api")
           | .results[] | "\(.result)\t\(.policy)/\(.rule)\t\(.message)"'
pass	require-labels/autogen-check-for-labels	validation rule 'autogen-check-for-labels' passed.
fail	require-run-as-nonroot/autogen-run-as-non-root	validation error: Running as root is not allowed...
warn	require-team-annotation/check-team	validation error: annotation `owner.company.io/team` is recommended.
error	check-image-registry/validate-registry-allowlist	failed to evaluate rule: failed to load context...
skip	disallow-host-path/host-path	rule skipped due to policy exception 'payments/exempt-legacy-storage'
```

Kyverno labels reports by managing controller, which lets you separate producers when several tools write `polr`:

```console
$ kubectl get polr -A -l app.kubernetes.io/managed-by=kyverno --no-headers | wc -l
1247
```

### 5.3 The `autogen-` prefix — a guaranteed source of confusion

A rule matching `kind: Pod` is auto-expanded by Kyverno into equivalent rules named `autogen-<rule>` for Deployment/StatefulSet/DaemonSet/Job/ReplicaSet/ReplicationController, and `autogen-cronjob-<rule>` for CronJob. Consequences you must design around:

| Symptom | Cause | Correct response |
|---|---|---|
| One violation appears 3× (Deployment, ReplicaSet, Pod) | Autogen + ownership chain, each object gets its own report | Count at **one** layer. For "how many workloads are broken", filter `scope.kind` to controllers; for "how much running compute is non-compliant", filter to `Pod`. |
| A `PolicyException` has no effect | Only the base rule name was listed | Add every `autogen-*` variant to `spec.exceptions[].ruleNames` |
| Report `rule` name does not match the policy YAML | Autogen renamed it | Expected; strip the prefix when correlating |

Inspect what Kyverno actually generated:

```console
$ kubectl get clusterpolicy require-run-as-nonroot -o jsonpath='{.status.autogen.rules[*].name}'
autogen-run-as-non-root autogen-cronjob-run-as-non-root
```

To disable autogen for one policy (and get one report entry per Pod only):

```yaml
metadata:
  annotations:
    pod-policies.kyverno.io/autogen-controllers: none
```

### 5.4 `kyverno apply --policy-report` — reports without a cluster

The Kyverno CLI evaluates policies against manifests offline and emits a real `ClusterPolicyReport`. This is the correct CI gate: it fails a pull request *before* the resource ever reaches a cluster, with the same schema your runtime dashboards use.

```console
$ kyverno version
Version: v1.13.2
Time: 2026-03-11T14:22:07Z
Git commit ID: 9c1d4f8

$ kyverno apply ./policies/ --resource ./manifests/ --policy-report

Applying 8 policy rule(s) to 3 resource(s)...

policy require-run-as-nonroot -> resource payments/Deployment/checkout-api failed:
1. autogen-run-as-non-root: validation error: Running as root is not allowed. The
fields spec.securityContext.runAsNonRoot, spec.containers[*].securityContext.runAsNonRoot
must be `true`. rule autogen-run-as-non-root failed at path
/spec/template/spec/containers/0/securityContext/runAsNonRoot/

----------------------------------------------------------------------
POLICY REPORT:
----------------------------------------------------------------------
apiVersion: wgpolicyk8s.io/v1alpha2
kind: ClusterPolicyReport
metadata:
  name: merged
results:
- message: validation rule 'autogen-check-for-labels' passed.
  policy: require-labels
  resources:
  - apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
    namespace: payments
  result: pass
  rule: autogen-check-for-labels
  scored: true
  source: kyverno
- message: 'validation error: Running as root is not allowed...'
  policy: require-run-as-nonroot
  resources:
  - apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
    namespace: payments
  result: fail
  rule: autogen-run-as-non-root
  scored: true
  source: kyverno
summary:
  error: 0
  fail: 1
  pass: 5
  skip: 2
  warn: 0

pass: 5, fail: 1, warn: 0, error: 0, skip: 2
```

```console
$ echo $?
1
```

**Non-zero exit on failure is what makes this a gate.** A minimal CI job:

```yaml
# .github/workflows/policy-gate.yml
name: policy-gate
on: [pull_request]
jobs:
  kyverno-apply:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Kyverno CLI
        run: |
          curl -sSL -o kyverno.tar.gz \
            https://github.com/kyverno/kyverno/releases/download/v1.13.2/kyverno-cli_v1.13.2_linux_x86_64.tar.gz
          tar -xzf kyverno.tar.gz && sudo mv kyverno /usr/local/bin/
      - name: Evaluate policies against rendered manifests
        run: |
          helm template ./chart > /tmp/rendered.yaml
          kyverno apply ./policies/ \
            --resource /tmp/rendered.yaml \
            --policy-report \
            --audit-warn > /tmp/report.yaml
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: policy-report
          path: /tmp/report.yaml
```

`--audit-warn` reports `Audit`-mode failures as `warn` instead of `fail`, so a PR is only blocked by policies you have already committed to enforcing. Same ladder as §4.2, applied left of the cluster.

---

## 6. Verification and failure diagnosis

### 6.1 Health ladder — run in order, stop at the first failing rung

```console
# Rung 1 — do the CRDs exist at all?
$ kubectl get crd | grep -E 'policyreport|reports.kyverno'
clusterpolicyreports.wgpolicyk8s.io          2026-05-02T11:03:44Z
policyreports.wgpolicyk8s.io                 2026-05-02T11:03:44Z
clusterephemeralreports.reports.kyverno.io   2026-05-02T11:03:45Z
ephemeralreports.reports.kyverno.io          2026-05-02T11:03:45Z

# Rung 2 — is the ONLY writer of polr actually running?
$ kubectl -n kyverno get deploy
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    3/3     3            3           104d
kyverno-background-controller   1/1     1            1           104d
kyverno-cleanup-controller      1/1     1            1           104d
kyverno-reports-controller      1/1     1            1           104d

# Rung 3 — is it configured to report at all?
$ kubectl -n kyverno get deploy kyverno-reports-controller \
    -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
["--backgroundScanInterval=1h"
"--backgroundScanWorkers=5"
"--skipResourceFilters=false"
"--enableReporting=validate,imageVerify"
"--v=2"]

# Rung 4 — is the policy eligible for background scanning?
$ kubectl get cpol require-run-as-nonroot -o jsonpath='{.spec.background}{"\n"}'
true

# Rung 5 — is the policy ready and its webhook configured?
$ kubectl get cpol
NAME                     ADMISSION   BACKGROUND   READY   AGE   MESSAGE
require-run-as-nonroot   true        true         True    9d    Ready
require-labels           true        true         True    9d    Ready
require-team-annotation  true        true         True    2d    Ready

# Rung 6 — is the intermediate layer draining?
$ kubectl get ephemeralreports.reports.kyverno.io -A --no-headers | wc -l
3

# Rung 7 — do final reports exist and are they fresh?
$ kubectl get polr -A --no-headers | wc -l
1247
$ kubectl get polr -A -o json \
  | jq -r '[.items[].metadata.annotations["audit.kyverno.io/last-scan-time"]] | max'
"2026-08-14T09:41:07Z"
```

### 6.2 Failure catalogue

#### `kubectl get polr -A` returns nothing

| Check | Command | Fix |
|---|---|---|
| Reports controller absent | `kubectl -n kyverno get deploy kyverno-reports-controller` | `--set reportsController.enabled=true` |
| Reports controller CrashLooping | `kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=100` | Usually OOMKilled — raise the memory limit |
| Reporting disabled for the rule type | inspect `--enableReporting` | Add `validate` (and `imageVerify` if used) |
| No policy is background-eligible | `kubectl get cpol -o custom-columns=NAME:.metadata.name,BG:.spec.background` | Remove `request.userInfo`-family variables so `background: true` is legal |
| Every resource is filtered out | `kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}'` | Narrow the filters, or set `--skipResourceFilters=true` |
| First scan has not run yet | `--backgroundScanInterval=1h` and Kyverno restarted 5 min ago | Wait, or force a rescan (§6.3) |

```console
$ kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=20
I0814 09:41:07.223  reports-controller  "msg"="starting background scan" "interval"="1h0m0s" "workers"=5
I0814 09:41:09.881  reports-controller  "msg"="background scan completed" "resources"=4123 "duration"="2.658s"
E0814 09:41:09.902  reports-controller  "msg"="failed to list resource" "gvk"="cert-manager.io/v1, Kind=Certificate" "error"="certificates.cert-manager.io is forbidden: User \"system:serviceaccount:kyverno:kyverno-reports-controller\" cannot list resource \"certificates\" in API group \"cert-manager.io\" at the cluster scope"
```

That last line is §4.5 — apply the aggregated `ClusterRole`.

#### Reports exist but show zero `fail` even though violations are obvious

| Cause | How to confirm | Reasoning |
|---|---|---|
| The policy is `Enforce`, so violating **creates** are rejected and never persisted | `kubectl get events -A --field-selector reason=PolicyViolation` | No object ⇒ no report. Absence of `fail` under `Enforce` is expected, not proof of compliance. |
| The policy is unscored | `kubectl get cpol X -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/scored}'` | Violations land in `warn`, not `fail` |
| A `PolicyException` matched | grep the report for `result: skip` and `properties.exceptions` | Working as intended; verify the exception is still justified |
| `spec.background: false` | `kubectl get cpol X -o jsonpath='{.spec.background}'` | Pre-existing resources are never scanned |
| `exclude` block or namespaceSelector removes the namespace | read `spec.rules[].exclude` | The rule genuinely does not apply |

Verify RBAC directly rather than guessing:

```console
$ kubectl auth can-i list certificates.cert-manager.io \
    --as=system:serviceaccount:kyverno:kyverno-reports-controller
no
```

#### Reports are stale

```console
$ kubectl get polr -A -o json | jq -r '
    .items[] | "\(.metadata.annotations["audit.kyverno.io/last-scan-time"])\t\(.metadata.namespace)/\(.scope.name)"' \
  | sort | head -3
2026-08-13T02:14:51Z	legacy/ledger-batch
2026-08-13T02:14:51Z	legacy/ledger-cron
2026-08-14T09:41:07Z	payments/checkout-api
```

A 31-hour-old timestamp against a 1-hour interval means the reports controller is not completing scans. Ordered causes:

1. **CPU limit throttling.** Background scanning is CPU-bound. Check `container_cpu_cfs_throttled_seconds_total`. Remove the CPU limit; keep the memory limit.
2. **Insufficient workers.** Raise `--backgroundScanWorkers`.
3. **API server rate limiting.** Look for `client-side throttling` in the logs and raise `--clientRateLimitQPS` / `--clientRateLimitBurst`.
4. **A single expensive rule.** `apiCall`-based context loading against a slow endpoint serialises the scan.

#### Reports outlive their resources

```console
$ kubectl -n payments get polr 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913 \
    -o jsonpath='{.metadata.ownerReferences}' | jq .
[
  {
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "name": "checkout-api",
    "uid": "7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913",
    "controller": true,
    "blockOwnerDeletion": false
  }
]
```

If `ownerReferences` is empty, GC cannot work and the report will leak. If it is populated and the report still survives its owner, the cluster's `kube-controller-manager` garbage collector is degraded — that is a control-plane problem, not a Kyverno one.

### 6.3 Forcing a rescan without waiting an hour

A background scan is triggered by policy change events, not only by the timer. Touching a policy's spec forces immediate re-evaluation of everything it matches:

```console
$ kubectl annotate cpol require-run-as-nonroot \
    ops.company.io/rescan="$(date -u +%FT%TZ)" --overwrite
clusterpolicy.kyverno.io/require-run-as-nonroot annotated

$ sleep 20 && kubectl -n payments get polr -o json \
  | jq -r '.items[0].metadata.annotations["audit.kyverno.io/last-scan-time"]'
"2026-08-14T10:07:33Z"
```

The blunter instrument — restart the controller, which triggers a full scan on startup:

```console
$ kubectl -n kyverno rollout restart deploy/kyverno-reports-controller
deployment.apps/kyverno-reports-controller restarted
$ kubectl -n kyverno rollout status deploy/kyverno-reports-controller
deployment "kyverno-reports-controller" successfully rolled out
```

On a large cluster this schedules a full re-scan of every matched resource. Do not do it during an incident on the API server.

---

## 7. Scale: reports are etcd objects, and etcd is finite

This is where Policy Reports stop being a feature and start being a capacity-planning problem. It is also the difference between a KCA-level answer and a Platform-Architect-level one.

### 7.1 The arithmetic

Reports are stored in etcd like everything else. Two independent pressures:

**Object count.** One report per matched resource. A cluster with 4,000 Pods + 900 Deployments + 900 ReplicaSets + 2,000 other matched objects ≈ **7,800 report objects**, regardless of how many policies you run.

**Object size.** Each report carries one `results[]` entry per matched rule, each holding a full message and a resource reference (~350–600 bytes). Thirty rules ⇒ roughly 12–20 KB per report.

```console
$ kubectl get polr,cpolr -A -o json | jq '
    {objects: (.items|length),
     bytes: ([.items[] | (.|tostring|length)] | add),
     mib: (([.items[] | (.|tostring|length)] | add) / 1048576 | .*100|round/100)}'
{
  "objects": 7812,
  "bytes": 96428813,
  "mib": 91.96
}
```

92 MiB is comfortable against a default 2 GiB etcd quota — but it is not the only consumer, and the more dangerous number is **write amplification**, not size. Every `UPDATE` to a matched resource triggers admission → ephemeral report → aggregation → a `PolicyReport` write. A cluster running CronJobs that create 500 Pods a minute generates 500 report create/delete cycles a minute, each one a full etcd write plus a watch fan-out to every report consumer.

Also note the hard ceiling: **etcd rejects any single object larger than ~1.5 MiB** (`--max-request-bytes` default). Per-resource reports (Kyverno 1.10+) make this nearly unreachable; the old namespace-aggregated model hit it routinely on large namespaces, which is exactly why the model changed.

### 7.2 Tuning knobs and their honest trade-offs

| Knob | Effect | Cost of turning it |
|---|---|---|
| `--skipResourceFilters=false` | Background scans honour the `resourceFilters` ConfigMap — the largest single reduction available | Filtered resources are **invisible** to compliance reporting. Document exactly what you blinded. |
| `resourceFilters` in the `kyverno` ConfigMap | Exclude `Event`, `kube-system`, node-lease, and high-churn kinds | Same as above |
| `--backgroundScanInterval` (↑ to `4h`/`24h`) | Fewer full re-evaluations | Staler data; drift persists longer before detection |
| `--backgroundScanWorkers` (↑) | Scans finish faster | More API server QPS and controller CPU |
| `--enableReporting=validate` only | Drops mutate/generate/imageVerify results | Loses mutation and image-verification visibility |
| `--admissionReports=false` | No per-admission reports; background scan becomes the only source | Loses near-real-time drift detection; freshness drops to the scan interval |
| `spec.background: false` per policy | That policy never scans existing resources | Cannot answer "what would break"; mandatory if the rule uses `request.userInfo` |
| `reportsController.enabled=false` | No reports at all; admission control unaffected | Full loss of compliance state. Legitimate only when an external system owns reporting. |
| Autogen off (`pod-policies.kyverno.io/autogen-controllers: none`) | ~3× fewer report entries for Pod-shaped rules | Controllers are no longer evaluated at admission — violations are caught only at Pod creation, i.e. after the Deployment is accepted |

A concrete, safe starting configuration for a large multi-tenant cluster:

```yaml
# kyverno ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: kyverno
  namespace: kyverno
data:
  resourceFilters: >-
    [Event,*,*]
    [*,kube-system,*]
    [*,kube-public,*]
    [*,kube-node-lease,*]
    [Node,*,*]
    [Node/*,*,*]
    [APIService,*,*]
    [APIService/*,*,*]
    [TokenReview,*,*]
    [SubjectAccessReview,*,*]
    [SelfSubjectAccessReview,*,*]
    [Binding,*,*]
    [ReplicaSet,*,*]
    [EndpointSlice,*,*]
    [Endpoints,*,*]
    [ClusterRole,*,kyverno:*]
    [ClusterRoleBinding,*,kyverno:*]
    [ServiceAccount,kyverno,kyverno*]
    [ConfigMap,kyverno,kyverno]
  webhooks: '[{"namespaceSelector":{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["kyverno","kube-system"]}]}}]'
```

Filtering out `ReplicaSet` alone removes an entire redundant layer of the autogen ownership chain (§5.3) — roughly a third of report objects on a Deployment-heavy cluster — while losing no unique compliance information, because the Deployment and the Pod are both still evaluated.

### 7.3 Reports vs metrics — do not substitute one for the other

```promql
# FLOW: rate of failing rule evaluations. Says nothing about how many
# resources are currently broken — a stable violation with no writes
# produces no admission evaluations at all.
sum by (policy_name) (rate(kyverno_policy_results_total{rule_result="fail"}[5m]))

# STOCK: current number of failing resources. Only available from the
# report objects (exported as metrics by Policy Reporter).
sum by (policy) (policy_report_result{status="fail"})
```

A dashboard built solely on `kyverno_policy_results_total` will show a beautiful flat line at zero for a cluster where 340 workloads have been violating a policy for six months, because nobody has updated them and therefore no admission request has been evaluated. **The report is the stock; the metric is the flow.** Governance questions are always about the stock.

---

## 8. Interoperability: one schema, many producers

Because `wgpolicyk8s.io` is an open API, Kyverno is one producer among several. This is why the abstraction was worth standardising:

| Producer | What it reports | Report kind |
|---|---|---|
| **Kyverno** | Policy validation, image verification, mutation results | `PolicyReport` / `ClusterPolicyReport` |
| **Trivy Operator** (via adapter/plugin) | Vulnerabilities, misconfiguration, exposed secrets | Native CRDs, surfaced through the same UI |
| **Falco** (wg-policy adapter) | Runtime security events | `PolicyReport` |
| **kube-bench** (wg-policy adapter) | CIS Kubernetes Benchmark results | `ClusterPolicyReport` |
| **Kubernetes `ValidatingAdmissionPolicy`** | CEL-based admission results, reported by Kyverno when it manages the VAP | `PolicyReport` with a distinguishing `source` |
| **Policy Reporter** | *Consumer* — UI, Prometheus exporter, Slack/Teams/Loki/S3/Elasticsearch routing | — |

`results[].source` is the field that keeps them apart. Always filter by it when a cluster runs more than one producer:

```console
$ kubectl get polr,cpolr -A -o json \
  | jq -r '.items[].results[].source' | sort | uniq -c
   3891 kyverno
    412 falco
     87 kube-bench
```

---

## 9. Exam-focused summary

1. **API**: `wgpolicyk8s.io/v1alpha2` — `PolicyReport` (`polr`, namespaced) and `ClusterPolicyReport` (`cpolr`, cluster-scoped). Owned by **Kubernetes WG Policy**, not by Kyverno.
2. **Which kind?** Determined by the **scope of the evaluated resource**, never by the scope of the policy. A `ClusterPolicy` matching Pods writes namespaced `polr`.
3. **Producer**: `kyverno-reports-controller` (a separate deployment since Kyverno 1.10). Disable it and admission control still works while reports vanish entirely.
4. **Five results**: `pass`, `fail`, `warn`, `error`, `skip`. `warn` ⇐ `policies.kyverno.io/scored: "false"`. `skip` ⇐ preconditions or a `PolicyException`. `error` ⇐ the rule could not be evaluated — it is an *unknown*, not a pass.
5. **`Audit` vs `Enforce` does not change the result value** — it changes whether admission blocks. Under `Enforce`, violating creates are rejected and therefore never produce a report.
6. **`spec.background: true`** (default) is what makes pre-existing resources visible. It is **incompatible** with `request.userInfo`/`request.roles`/`request.operation` variables; those force `background: false` and admission-only reporting.
7. **`category` and `severity`** come only from the `policies.kyverno.io/category` and `policies.kyverno.io/severity` annotations.
8. **Naming and GC**: one report per resource, named after the resource UID, with an `ownerReference` to it — deletion is handled by the Kubernetes garbage collector.
9. **Default background scan interval is `1h`** (`--backgroundScanInterval`). Force an early rescan by modifying a policy.
10. **Offline reporting**: `kyverno apply <policies> --resource <manifests> --policy-report` emits a `ClusterPolicyReport` named `merged` and exits non-zero on failure — the CI gate.
11. **`autogen-` prefixed rule names** appear in reports for Pod-controller kinds and **must** be listed in `PolicyException.spec.exceptions[].ruleNames`.
12. **Policy Reporter** is the UI/exporter/notification router built on these CRDs; it is a consumer, not a producer.

---

## 10. Referencias

**Certification and curriculum**
- KCA curriculum (CNCF): https://github.com/cncf/curriculum
- Kyverno Certified Associate (Linux Foundation): https://training.linuxfoundation.org/certification/kyverno-certified-associate-kca/

**Policy Reports — Kyverno official documentation**
- Policy Reports: https://kyverno.io/docs/policy-reports/
- Kyverno documentation root: https://kyverno.io/docs/
- Installation and container flags / customization: https://kyverno.io/docs/installation/customization/
- Monitoring and metrics: https://kyverno.io/docs/monitoring/
- Kyverno CLI (`apply`, `test`): https://kyverno.io/docs/kyverno-cli/
- Policy library (canonical annotation usage): https://kyverno.io/policies/

**Source and API definitions**
- Kyverno source repository: https://github.com/kyverno/kyverno
- Kubernetes WG Policy — Policy Report API prototypes and adapters: https://github.com/kubernetes-sigs/wg-policy-prototypes
- Kyverno Helm chart values reference: https://artifacthub.io/packages/helm/kyverno/kyverno

**Reporting ecosystem**
- Policy Reporter documentation: https://kyverno.github.io/policy-reporter/
- Policy Reporter source: https://github.com/kyverno/policy-reporter

**Kubernetes upstream**
- Dynamic admission control: https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Validating Admission Policy (CEL): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Garbage collection and owner references: https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Using RBAC authorization (aggregated ClusterRoles): https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Custom Resource Definitions: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/