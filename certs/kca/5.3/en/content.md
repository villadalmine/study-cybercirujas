# 5.3 Background Scans

> **Domain 5 — Applying policies in production · Exam weight: 2.91**
> Applies to Kyverno 1.10 → 1.14 (the four-controller architecture). Where a behaviour changed across that range it is flagged inline. Verify the exact version the exam pins with `kyverno version` and `kubectl -n kyverno get deploy -o wide`.

---

## 1. The architectural problem: admission control is a point-in-time control

A `ValidatingWebhookConfiguration` is an **event-driven, preventive** control. The API server calls Kyverno's admission controller only when an `AdmissionRequest` exists — that is, on `CREATE`, `UPDATE`, `DELETE` or `CONNECT` for the rules the webhook is registered for. The moment the object is persisted in etcd, Kyverno never looks at it again unless somebody touches it.

That single property produces a whole family of production blind spots. Every one of these is a real incident pattern, not a theoretical one:

| # | Blind spot | Why admission cannot see it | Typical detection lag without background scans |
|---|---|---|---|
| 1 | **Policy authored after the workloads** | The 4,000 Pods that predate `require-run-as-nonroot` were never sent to the webhook | Forever |
| 2 | **Policy mutated in place** | Tightening a `pattern` re-registers nothing; existing objects are not re-admitted | Until each workload is next redeployed |
| 3 | **Kyverno outage with `failurePolicy: Ignore`** | The API server fails open; requests are admitted unevaluated | Forever (silent) |
| 4 | **Context drift** — the policy reads a ConfigMap, an `apiCall`, or an image registry, and *that* changed | The resource did not change, so no `AdmissionRequest` is generated | Forever |
| 5 | **Signature revocation / image re-tag** (`verifyImages`) | The mutable tag now resolves to a different digest, or the key was revoked | Forever |
| 6 | **`resourceFilters` / `namespaceSelector` exclusions** | Deliberately excluded from the webhook to protect the control plane | Forever |
| 7 | **Namespace relabelled** | `namespaceSelector` stops/starts matching without touching the workload | Until next workload write |
| 8 | **Cluster upgrade removes an API** | Nothing wrote the object; the server-side representation changed | Until next `kubectl apply` |
| 9 | **`kubectl edit` while a policy was in `Audit`** | Audit never blocked anything | Forever |
| 10 | **`--dry-run=server` / bypass via aggregated API or direct etcd restore** | Restore paths (Velero, etcd snapshot) may bypass or race webhooks | Forever |

Kyverno's answer is a second, **detective** control plane: a controller that periodically re-evaluates every policy against every *live* object and writes the verdicts to `PolicyReport` / `ClusterPolicyReport` custom resources. That periodic re-evaluation is the **background scan**.

### 1.1 The two controls are complementary, not redundant

```
                       ┌──────────────────────────── PREVENTIVE ───────────────────────────┐
  kubectl apply ─────▶ kube-apiserver ─▶ ValidatingWebhook ─▶ kyverno-admission-controller
                            │                                          │
                            │                                          ├─▶ allow / deny (Enforce)
                            │                                          └─▶ EphemeralReport (admission)
                            ▼
                          etcd  ◀────────────── live cluster state
                            │
                            │  LIST/WATCH every `backgroundScanInterval`
                            ▼
        ┌──────────────── DETECTIVE ─────────────────┐
        kyverno-reports-controller  ──▶ EphemeralReport (background scan)
                    │
                    └──▶ aggregation ──▶ PolicyReport / ClusterPolicyReport
                                                │
                                                └──▶ Policy Reporter · Prometheus · SIEM · OPA-free dashboards
```

The mental model to carry into the exam and into production:

* **Admission control decides.** It is the only thing that can say *no*.
* **Background scan observes.** It can never block, never mutate, never delete. It only tells you the truth about what is in the cluster right now.
* A cluster with `Enforce` policies and **no** background scan has *unknown* compliance posture for everything created before the policy existed.
* A cluster with background scan and **only** `Audit` policies has *perfect visibility* and *zero* enforcement.

---

## 2. Where background scans live in the Kyverno architecture

Since **Kyverno 1.10** the monolithic `kyverno` deployment was split into four independently scalable controllers. Knowing which controller does what is directly exam-relevant, because "background" is an overloaded word in Kyverno.

| Deployment | Responsibility | Does it perform *background scans*? | Scaling model |
|---|---|---|---|
| `kyverno-admission-controller` | Serves the validating/mutating webhooks; evaluates `validate`, `mutate`, `verifyImages` at admission; writes admission `EphemeralReport`s | **No** | HA, N replicas, all active (stateless behind a Service) |
| `kyverno-background-controller` | Reconciles `generate` rules and `mutate` rules with `targets` (mutateExisting) via `UpdateRequest` objects | **No** — this is background *processing*, not background *scanning* | Leader-elected |
| `kyverno-reports-controller` | **Performs background scans**; aggregates ephemeral reports into `PolicyReport`/`ClusterPolicyReport` | **Yes — this is the one** | Leader-elected; memory-bound by informer caches |
| `kyverno-cleanup-controller` | `CleanupPolicy` / `ClusterCleanupPolicy`, TTL-based deletion | No | Leader-elected |

> **Exam trap.** The *background controller* does **not** run background scans. `generate` and `mutateExisting` are its job. If background scan reports stop appearing, you look at `kyverno-reports-controller`; if a generated `NetworkPolicy` stops being synchronised, you look at `kyverno-background-controller`.

### 2.1 The report CRD lineage

Kyverno writes intermediate, short-lived report objects and then aggregates them. The intermediate CRDs were renamed across versions — this is the single most common source of "the docs say X but my cluster has Y".

| Kyverno line | Intermediate CRDs (short-lived) | Aggregated, user-facing CRDs |
|---|---|---|
| 1.8 – 1.9 | `reportchangerequests.kyverno.io`, `clusterreportchangerequests.kyverno.io` | `policyreports` / `clusterpolicyreports` (`wgpolicyk8s.io/v1alpha2`) |
| 1.10 | `admissionreports.kyverno.io/v1alpha2`, `backgroundscanreports.kyverno.io/v1alpha2` (+ `cluster*` variants) | same |
| 1.11+ | consolidated into `ephemeralreports.reports.kyverno.io/v1` and `clusterephemeralreports.reports.kyverno.io/v1` | same |

The **aggregated** API is stable and is what you build on:

* `PolicyReport` — namespaced (`polr`)
* `ClusterPolicyReport` — cluster-scoped (`cpolr`)
* Group/version: `wgpolicyk8s.io/v1alpha2`, owned by the Kubernetes **Policy WG**, *not* by Kyverno. Trivy-operator, Falco sidekick, kube-bench exporters and others write the same shape. This is why the report API is worth learning independently of Kyverno.

Since 1.10 the aggregation model is **one report per scanned resource**, named after the resource `uid` and carrying an `ownerReference` to it, so reports are garbage-collected by Kubernetes when the resource dies. Older releases produced one report per namespace (`polr-ns-<namespace>`), which is why old runbooks tell you to `kubectl get polr polr-ns-default` and yours does not exist.

---

## 3. `spec.background`: the switch, and the context it costs you

Every `Policy` and `ClusterPolicy` carries a boolean:

```yaml
spec:
  background: true    # default
```

* `background: true` (default) — the policy participates in background scans. Its `validate` and `verifyImages` rules are re-evaluated against live resources every interval.
* `background: false` — the policy is evaluated **only** at admission. It contributes **nothing** to background-scan results.

### 3.1 Why you would ever set it to `false`

A background scan has no `AdmissionRequest`. There is no user, no group, no service account, no impersonation chain, no `dryRun` flag — the reports controller simply read an object out of etcd. Kyverno therefore synthesises a minimal policy context, and a well-defined set of variables becomes unavailable.

| Variable | Available at admission | Available in background scan | Notes |
|---|---|---|---|
| `request.object` | ✅ | ✅ | The live object from the API server |
| `request.oldObject` | ✅ (on UPDATE) | ❌ (always empty) | There is no "previous" state in a scan |
| `request.userInfo.username` | ✅ | ❌ | No requester exists |
| `request.userInfo.groups` | ✅ | ❌ | |
| `request.roles` / `request.clusterRoles` | ✅ | ❌ | |
| `serviceAccountName` / `serviceAccountNamespace` | ✅ | ❌ | Derived from `userInfo` |
| `request.operation` | ✅ (`CREATE`/`UPDATE`/`DELETE`) | ⚠️ synthetic | Treat its value as an implementation detail; recent releases report `BACKGROUND`. Do not branch on it in a background-enabled policy. |
| `images` (from `verifyImages` context) | ✅ | ✅ | Re-resolved against the registry |
| `{{ configMap.… }}`, `{{ apiCall }}`, `{{ globalReference }}` | ✅ | ✅ | Re-read every scan — this is what makes context drift detectable |

Kyverno **enforces this statically**. Its own policy-validating webhook rejects a policy that combines `background: true` with a forbidden variable:

```console
$ kubectl apply -f restrict-privileged-to-platform-team.yaml
Error from server: error when creating "restrict-privileged-to-platform-team.yaml": \
admission webhook "validate-policy.kyverno.svc" denied the request: \
spec.rules[0].validate.deny.conditions: variable {{request.userInfo.groups}} is not allowed \
in background mode. Set spec.background=false to disable background mode for this policy rule.
```

### 3.2 The design consequence

Any policy whose decision depends on **who** did something is inherently un-scannable, because identity is not a property of the stored object. In production this splits your policy catalogue in two:

| Policy family | Decision input | `background` | Detective coverage |
|---|---|---|---|
| **Posture policies** — "Pods must not run as root", "images must come from `registry.internal`", "PVCs must set a storageClass" | The object itself | `true` | Full |
| **Authorization policies** — "only `system:serviceaccount:platform:deployer` may set `hostNetwork`", "only members of `sre` may delete a `PersistentVolume`" | The requester | `false` | **None** — compensate with API-server audit logs |

> **Architectural guidance.** Prefer posture over authorization wherever the two can express the same rule. `background: false` is a permanent, invisible hole in your compliance reporting. If you must write an identity-based rule, pair it with a background-enabled posture rule that catches the resulting state, and alert on the audit log for the identity dimension.

### 3.3 Which rule types produce background-scan results

| Rule type | Evaluated in background scan | Produces report results | Handled by |
|---|---|---|---|
| `validate` (pattern / deny / cel / foreach) | ✅ | ✅ `pass` / `fail` / `warn` / `skip` / `error` | reports-controller |
| `verifyImages` | ✅ (re-resolves digests, re-checks signatures/attestations) | ✅ | reports-controller |
| `mutate` (plain, admission-time) | ❌ | ❌ | admission-controller only |
| `mutate` with `targets` (mutateExisting) | ❌ — reconciled, not scanned | ❌ | background-controller via `UpdateRequest` |
| `generate` | ❌ — reconciled, not scanned | ❌ | background-controller via `UpdateRequest` |

This is why a cluster full of `generate` policies shows an empty `polr` list and nothing is broken.

### 3.4 Result semantics

| `result` | Meaning | Common cause |
|---|---|---|
| `pass` | Rule evaluated, resource compliant | — |
| `fail` | Rule evaluated, resource violates it | The finding you care about. `Enforce` and `Audit` both yield `fail` in a scan — a scan **never blocks** |
| `warn` | Unscored result (`scored: false`) | Advisory policies; results excluded from the pass/fail score |
| `skip` | Rule did not apply | `preconditions` false, `exclude` matched, or a `PolicyException` matched |
| `error` | Rule could not be evaluated | RBAC denial, unreachable `apiCall`, registry timeout, malformed variable, CRD not served |

`error` is the one that silently destroys a compliance programme: an unevaluated rule looks like "no failures" on a naive dashboard. **Alert on `error`, not only on `fail`.**

---

## 4. Trade-offs and tuning surface

### 4.1 Admission-time reports vs background scans

Both feed the same `PolicyReport`. They can be enabled independently.

| Dimension | Admission reports (`--admissionReports`) | Background scans (`--backgroundScan`) |
|---|---|---|
| Trigger | Every matching `AdmissionRequest` | Timer (`--backgroundScanInterval`) + policy change |
| Freshness | Sub-second | Up to one interval stale |
| Covers pre-existing resources | ❌ | ✅ |
| Detects context drift (ConfigMap/apiCall/registry) | ❌ | ✅ |
| Survives a Kyverno outage window | ❌ | ✅ (heals on next scan) |
| API-server load | Proportional to change rate | Proportional to `resources × policies` per interval |
| etcd object churn | High on busy clusters (one ephemeral report per admission) | Bounded, periodic |
| Identity-aware policies (`background: false`) | ✅ | ❌ |
| Can block | ✅ (`Enforce`) | ❌ ever |

**Production recommendation for large clusters:** keep `backgroundScan=true`, and consider `admissionReports=false` if your change rate is high and you only need periodic posture. You keep enforcement (blocking is done by the admission controller, not by reports) and you shed the per-admission etcd write amplification.

### 4.2 Reports-controller flags

Set with `--flag=value` on the `kyverno-reports-controller` container, or through Helm.

| Flag | Default | Effect | When to change |
|---|---|---|---|
| `--backgroundScan` | `true` | Master switch for background scanning | `false` to run Kyverno purely as an admission gate |
| `--backgroundScanInterval` | `1h` | Full-sweep period | Lengthen (`4h`, `24h`) on clusters with >20k scanned objects; shorten only with measured headroom |
| `--backgroundScanWorkers` | `2` | Concurrency of the scan work queue | Raise to shorten sweep wall-clock; raises API-server QPS and controller CPU |
| `--skipResourceFilters` | `true` | **`true` = the ConfigMap `resourceFilters` are IGNORED by the scan** | Set `false` to make background scans honour the same exclusions as admission |
| `--admissionReports` | `true` | Emit ephemeral reports from admission | `false` to cut etcd churn |
| `--aggregateReports` | `true` | Aggregate ephemeral → `PolicyReport` | Leave on; `false` leaves you with raw ephemerals |
| `--policyReports` | `true` | Emit reports for Kyverno policies | — |
| `--validatingAdmissionPolicyReports` | `false` (1.11+) | Also report on native `ValidatingAdmissionPolicy` outcomes | Enable when migrating rules to CEL/VAP and you want one pane of glass |
| `--enablePolicyException` | `false` | Honour `PolicyException` objects (→ `skip` results) | Enable with a restricted `--exceptionNamespace` |
| `--enableConfigMapCaching` | `true` | Cache `configMap` context lookups | `false` if you need scans to see ConfigMap changes immediately |
| `--maxAPICallResponseLength` | `2000000` | Cap on `apiCall` response bytes | Raise for large `apiCall` contexts, at memory cost |

> **The `--skipResourceFilters` polarity is the single most-missed detail of this topic.** The name reads as "skip these resources"; it actually means "skip *applying* the filters". Default `true` ⇒ your carefully-curated `kube-system` exclusion does **not** apply to background scans, and your report dashboard fills with control-plane findings.

### 4.3 Kyverno background scans vs other posture tooling

| Tool | Scope | Report API | Enforcement | Fit |
|---|---|---|---|---|
| **Kyverno background scan** | Any Kubernetes resource, driven by the same policies that enforce at admission | `wgpolicyk8s.io` PolicyReport | Yes, via the same policy at admission | Single source of truth for policy — one artefact, two controls |
| Gatekeeper `audit` (`auditInterval`) | Any resource matched by a `Constraint` | Status on the `Constraint` object (+ `violations`) | Yes, via the same constraint | Equivalent design; violations live in constraint status, so per-resource reporting needs extra tooling |
| Trivy-operator | Images, workloads, RBAC, infra config | PolicyReport-compatible + own CRDs | No | Vulnerability-first, not policy-first |
| Polaris | Workload best practices | Own JSON/dashboard | Optional webhook | Opinionated fixed checks |
| kube-bench / kube-hunter | Node & control-plane CIS benchmarks | Own JSON | No | Host-level, complements Kyverno; Kyverno cannot see kubelet flags |
| Falco | Runtime syscalls | Events | No | Runtime, not desired-state — orthogonal |
| Native `ValidatingAdmissionPolicy` | CEL on any resource | None natively (Kyverno can generate them) | Yes | No built-in detective control — this is exactly the gap Kyverno's VAP reports fill |

---

## 5. Complete manifests

### 5.1 A background-scannable posture policy

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-requests-limits
  annotations:
    policies.kyverno.io/title: Require CPU and memory requests and limits
    policies.kyverno.io/category: Resource Management
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Unbounded Pods make the scheduler's fit decisions meaningless and let a single
      workload evict its neighbours. This policy is authored to be background-scannable
      so that the fleet that predates it is inventoried, not merely gated going forward.
spec:
  # Explicit. The default is true, but stating it makes the detective posture
  # of this policy a reviewable property of the manifest.
  background: true
  # Cluster-wide report + block on new/updated objects.
  validationFailureAction: Audit          # 1.13+: prefer spec.rules[].validate.failureAction
  # Evaluate every rule, do not stop at the first match.
  applyRules: All
  rules:
    - name: validate-resources
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
                - kube-public
                - kyverno
      validate:
        # 1.13+: per-rule action supersedes spec.validationFailureAction
        failureAction: Audit
        # 1.13+: do not block UPDATEs to resources that were already violating.
        # Critical for incremental remediation of findings surfaced by the scan.
        allowExistingViolations: true
        message: >-
          CPU/memory requests and limits are required.
          Pod "{{ request.object.metadata.name }}" is missing at least one of them.
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    cpu: "?*"
                    memory: "?*"
                  limits:
                    memory: "?*"
```

Applying it and watching the scan pick up pre-existing objects:

```console
$ kubectl apply -f require-resource-requests-limits.yaml
clusterpolicy.kyverno.io/require-resource-requests-limits created

$ kubectl get cpol require-resource-requests-limits \
    -o custom-columns='NAME:.metadata.name,BACKGROUND:.spec.background,ACTION:.spec.validationFailureAction,READY:.status.conditions[?(@.type=="Ready")].status'
NAME                               BACKGROUND   ACTION   READY
require-resource-requests-limits   true         Audit    True
```

> Note the **autogen** behaviour: Kyverno silently synthesises `autogen-validate-resources` rules for `Deployment`, `StatefulSet`, `DaemonSet`, `Job`, `CronJob`, `ReplicaSet` and `ReplicationController`. Background scans evaluate those too, so a single non-compliant Deployment yields findings on *both* the Deployment and its Pods. Deduplicate by owner in dashboards, or restrict autogen with the `pod-policies.kyverno.io/autogen-controllers` annotation.

### 5.2 A policy that *cannot* be scanned

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-hostpath-to-platform-team
  annotations:
    policies.kyverno.io/severity: high
spec:
  # MANDATORY: the rule reads request.userInfo, which does not exist in a scan.
  # Kyverno's policy webhook rejects this manifest if background is left at true.
  background: false
  validationFailureAction: Enforce
  rules:
    - name: only-platform-may-mount-hostpath
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        all:
          - key: "{{ request.object.spec.volumes[?hostPath != null] | length(@) }}"
            operator: GreaterThan
            value: 0
      validate:
        message: >-
          hostPath volumes may only be created by members of the platform-team group.
          Requester "{{ request.userInfo.username }}" is not authorised.
        deny:
          conditions:
            all:
              - key: "platform-team"
                operator: AnyNotIn
                value: "{{ request.userInfo.groups }}"
```

The compensating posture policy — this one *is* scannable and inventories every existing `hostPath` mount regardless of who created it:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: audit-hostpath-usage
spec:
  background: true
  validationFailureAction: Audit
  rules:
    - name: no-hostpath
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "hostPath volumes are not permitted outside the platform namespaces."
        pattern:
          spec:
            =(volumes):
              - X(hostPath): "null"
```

### 5.3 Reports-controller tuning — Helm values

```yaml
# values-reports.yaml — Helm chart kyverno/kyverno 3.x
reportsController:
  replicas: 1                       # leader-elected; >1 buys failover, not throughput
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      memory: 4Gi                   # informer caches scale with scanned object count
  # Reports controller is the memory hot spot. Do NOT set a CPU limit: throttling
  # during a sweep stretches the scan past the interval and queues compound.
  serviceMonitor:
    enabled: true
    namespace: monitoring
    interval: 30s
  priorityClassName: system-cluster-critical
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule

features:
  admissionReports:
    enabled: true
  aggregateReports:
    enabled: true
  policyReports:
    enabled: true
  validatingAdmissionPolicyReports:
    enabled: false
  backgroundScan:
    enabled: true
    backgroundScanWorkers: 4        # --backgroundScanWorkers
    backgroundScanInterval: 2h      # --backgroundScanInterval
    skipResourceFilters: false      # honour config.resourceFilters during scans
  policyExceptions:
    enabled: true
    namespace: kyverno-exceptions
  configMapCaching:
    enabled: true

config:
  # Excluded from admission AND — because skipResourceFilters is false — from scans.
  resourceFilters:
    - "[Event,*,*]"
    - "[*,kube-system,*]"
    - "[*,kube-public,*]"
    - "[*,kube-node-lease,*]"
    - "[Node,*,*]"
    - "[Node/*,*,*]"
    - "[APIService,*,*]"
    - "[APIService/*,*,*]"
    - "[TokenReview,*,*]"
    - "[SubjectAccessReview,*,*]"
    - "[SelfSubjectAccessReview,*,*]"
    - "[Binding,*,*]"
    - "[Pod/binding,*,*]"
    - "[ReplicaSet,*,*]"
    - "[ReplicaSet/*,*,*]"
    - "[EphemeralReport,*,*]"
    - "[ClusterEphemeralReport,*,*]"
    - "[ClusterRole,*,kyverno:*]"
    - "[ClusterRoleBinding,*,kyverno:*]"
    - "[ServiceAccount,kyverno,kyverno*]"
    - "[ConfigMap,kyverno,kyverno]"
    - "[Deployment,kyverno,kyverno*]"
```

```console
$ helm upgrade --install kyverno kyverno/kyverno \
    --namespace kyverno --create-namespace \
    --version 3.3.4 \
    -f values-reports.yaml
Release "kyverno" has been upgraded. Happy Helming!
NAME: kyverno
NAMESPACE: kyverno
STATUS: deployed
REVISION: 7
```

### 5.4 Tuning without Helm — a strategic patch

```yaml
# reports-controller-args.patch.yaml
spec:
  template:
    spec:
      containers:
        - name: controller
          args:
            - --caSecretName=kyverno-svc.kyverno.svc.kyverno-tls-ca
            - --tlsSecretName=kyverno-svc.kyverno.svc.kyverno-tls-pair
            - --backgroundScan=true
            - --backgroundScanInterval=2h
            - --backgroundScanWorkers=4
            - --skipResourceFilters=false
            - --admissionReports=false
            - --aggregateReports=true
            - --policyReports=true
            - --enablePolicyException=true
            - --exceptionNamespace=kyverno-exceptions
            - --enableConfigMapCaching=true
            - --loggingFormat=json
            - --v=2
```

```console
$ kubectl -n kyverno patch deploy kyverno-reports-controller \
    --type strategic --patch-file reports-controller-args.patch.yaml
deployment.apps/kyverno-reports-controller patched

$ kubectl -n kyverno rollout status deploy/kyverno-reports-controller
Waiting for deployment "kyverno-reports-controller" rollout to finish: 1 old replicas are pending termination...
deployment "kyverno-reports-controller" successfully rolled out
```

### 5.5 RBAC for scanning custom resources

The reports controller can only scan what it can `list` and `watch`. Kyverno ships an aggregated `ClusterRole`; you extend it with a label, never by editing Kyverno's own roles (Helm will overwrite them).

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:reports-controller:platform-crds
  labels:
    rbac.kyverno.io/aggregate-to-reports-controller: "true"
rules:
  - apiGroups: ["acid.zalan.do"]
    resources: ["postgresqls"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["cert-manager.io"]
    resources: ["certificates", "issuers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gateways", "httproutes"]
    verbs: ["get", "list", "watch"]
```

The aggregation labels, one per controller — mixing them up is a classic self-inflicted outage:

| Label | Grants to |
|---|---|
| `rbac.kyverno.io/aggregate-to-admission-controller: "true"` | admission controller |
| `rbac.kyverno.io/aggregate-to-background-controller: "true"` | background controller (`generate`/`mutateExisting` — needs **write** verbs) |
| `rbac.kyverno.io/aggregate-to-reports-controller: "true"` | reports controller (**read-only** is sufficient) |
| `rbac.kyverno.io/aggregate-to-cleanup-controller: "true"` | cleanup controller (needs `delete`) |

### 5.6 A `PolicyException` and its effect on scan results

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: legacy-cache-hostpath-waiver
  namespace: kyverno-exceptions
  annotations:
    waiver.internal/ticket: SEC-4471
    waiver.internal/expires: "2026-12-31"
spec:
  exceptions:
    - policyName: audit-hostpath-usage
      ruleNames:
        - no-hostpath
        - autogen-no-hostpath
  match:
    any:
      - resources:
          kinds:
            - Pod
            - StatefulSet
          namespaces:
            - legacy
          names:
            - "legacy-cache*"
```

Effect: on the next scan, those resources move from `fail` to **`skip`** in the report — visible, attributable, and countable, which is exactly the property an auditor asks for. Silently narrowing the policy's `match` block would make the same finding vanish with no trace.

### 5.7 An aggregated `PolicyReport` as produced by a scan

```yaml
apiVersion: wgpolicyk8s.io/v1alpha2
kind: PolicyReport
metadata:
  name: 3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa
  namespace: prod
  labels:
    app.kubernetes.io/managed-by: kyverno
  ownerReferences:
    - apiVersion: v1
      kind: Pod
      name: legacy-cache-0
      uid: 3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa
scope:
  apiVersion: v1
  kind: Pod
  name: legacy-cache-0
  namespace: prod
  uid: 3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa
summary:
  pass: 3
  fail: 1
  warn: 0
  error: 0
  skip: 1
results:
  - source: kyverno
    policy: require-resource-requests-limits
    rule: validate-resources
    category: Resource Management
    severity: medium
    result: fail
    scored: true
    message: >-
      CPU/memory requests and limits are required. Pod "legacy-cache-0" is missing
      at least one of them. rule validate-resources failed at path /spec/containers/0/resources/limits/
    timestamp:
      seconds: 1786594800
      nanos: 0
    resources:
      - apiVersion: v1
        kind: Pod
        name: legacy-cache-0
        namespace: prod
        uid: 3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa
  - source: kyverno
    policy: audit-hostpath-usage
    rule: no-hostpath
    result: skip
    scored: true
    message: rule skipped due to policy exception legacy-cache-hostpath-waiver
    timestamp:
      seconds: 1786594800
      nanos: 0
    resources:
      - apiVersion: v1
        kind: Pod
        name: legacy-cache-0
        namespace: prod
        uid: 3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa
```

---

## 6. CLI walkthrough with real output

### 6.1 Confirm the scanner is running and how it is configured

```console
$ kubectl -n kyverno get deploy
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    3/3     3            3           41d
kyverno-background-controller   1/1     1            1           41d
kyverno-cleanup-controller      1/1     1            1           41d
kyverno-reports-controller      1/1     1            1           41d

$ kubectl -n kyverno get deploy kyverno-reports-controller \
    -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}'
--caSecretName=kyverno-svc.kyverno.svc.kyverno-tls-ca
--tlsSecretName=kyverno-svc.kyverno.svc.kyverno-tls-pair
--backgroundScan=true
--backgroundScanInterval=2h
--backgroundScanWorkers=4
--skipResourceFilters=false
--admissionReports=false
--aggregateReports=true
--policyReports=true
--enablePolicyException=true
--exceptionNamespace=kyverno-exceptions
--loggingFormat=json
--v=2
```

### 6.2 Inventory which policies are actually scannable

```console
$ kubectl get cpol -o custom-columns=\
'NAME:.metadata.name,BACKGROUND:.spec.background,ACTION:.spec.validationFailureAction,READY:.status.conditions[?(@.type=="Ready")].status'
NAME                                 BACKGROUND   ACTION    READY
audit-hostpath-usage                 true         Audit     True
disallow-latest-tag                  true         Audit     True
require-resource-requests-limits     true         Audit     True
require-run-as-nonroot               true         Enforce   True
restrict-hostpath-to-platform-team   false        Enforce   True
verify-internal-image-signatures     true         Enforce   True

$ # The compliance hole, in one line:
$ kubectl get cpol,pol -A -o json \
    | jq -r '.items[] | select(.spec.background == false) | "\(.kind)/\(.metadata.name)"'
ClusterPolicy/restrict-hostpath-to-platform-team
```

### 6.3 Read the reports

```console
$ kubectl get polr -A
NAMESPACE   NAME                                   KIND          NAME              PASS   FAIL   WARN   ERROR   SKIP   AGE
legacy      3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa   Pod           legacy-cache-0    3      1      0      0       1      12m
legacy      7b1d0e55-2af9-41c0-8f22-1a9c3ee0b7d1   StatefulSet   legacy-cache      3      1      0      0       1      12m
prod        9c44a012-77b5-4a10-b0e1-5d2f8a6c9e34   Deployment    checkout-api      6      0      0      0       0      12m
prod        c0de1f88-1122-4b33-9911-77aa55bb33cc   Pod           batch-loader-9x2   4      2      0      1       0      12m

$ kubectl get cpolr
NAME                                   KIND               NAME              PASS   FAIL   WARN   ERROR   SKIP   AGE
1c9b77aa-4402-4b6a-8a10-3d5e9f0a1122   ClusterRoleBinding cluster-admin-ci   0      1      0      0       0     12m
```

Aggregate the fleet posture — the query you actually put on a dashboard:

```console
$ kubectl get polr -A -o json \
  | jq -r '[.items[].results[]? | select(.result=="fail")] | group_by(.policy)
           | map({policy: .[0].policy, failures: length}) | sort_by(-.failures) | .[]
           | "\(.failures)\t\(.policy)"'
41	require-resource-requests-limits
18	disallow-latest-tag
7	require-run-as-nonroot
2	audit-hostpath-usage

$ # Errors — the results that look like "no finding" but are actually "no evaluation"
$ kubectl get polr,cpolr -A -o json \
  | jq -r '.items[].results[]? | select(.result=="error")
           | "\(.policy)/\(.rule)\t\(.message)"' | sort -u
verify-internal-image-signatures/check-signature	failed to fetch image descriptor: GET https://registry.internal/v2/: dial tcp 10.42.9.7:443: i/o timeout
```

### 6.4 Force an immediate re-scan

There is no `kubectl kyverno rescan`. Three supported ways to make the reports controller re-evaluate without waiting for the interval:

```console
$ # 1. Touch the policy — a spec change bumps resourceVersion and invalidates cached verdicts.
$ kubectl annotate cpol require-resource-requests-limits rescan="$(date +%s)" --overwrite
clusterpolicy.kyverno.io/require-resource-requests-limits annotated

$ # 2. Delete the aggregated reports; the controller rebuilds them.
$ kubectl delete polr --all -A
policyreport.wgpolicyk8s.io "3f2a91c4-6c8e-4c2b-9a41-70b1f0d5e3aa" deleted
policyreport.wgpolicyk8s.io "7b1d0e55-2af9-41c0-8f22-1a9c3ee0b7d1" deleted
policyreport.wgpolicyk8s.io "9c44a012-77b5-4a10-b0e1-5d2f8a6c9e34" deleted
policyreport.wgpolicyk8s.io "c0de1f88-1122-4b33-9911-77aa55bb33cc" deleted

$ # 3. Restart the controller (blunt; drops in-flight work and rewarms informers).
$ kubectl -n kyverno rollout restart deploy/kyverno-reports-controller
deployment.apps/kyverno-reports-controller restarted
```

### 6.5 The CLI equivalent — offline and CI background scanning

`kyverno apply --cluster` performs the same engine evaluation against live cluster state, from your workstation or a CI runner, without touching the reports controller. This is how you validate a policy's *blast radius* before merging it.

```console
$ kyverno version
Version: 1.13.4
Time: 2025-03-11T09:41:22Z

$ kyverno apply ./policies/ --cluster --namespace prod --policy-report

Applying 9 policy rule(s) to 214 resource(s)...

----------------------------------------------------------------------
POLICY REPORT:
----------------------------------------------------------------------
apiVersion: wgpolicyk8s.io/v1alpha2
kind: ClusterPolicyReport
metadata:
  name: clusterpolicyreport
results:
- message: 'validation error: CPU/memory requests and limits are required. rule validate-resources
    failed at path /spec/containers/0/resources/limits/'
  policy: require-resource-requests-limits
  resources:
  - apiVersion: v1
    kind: Pod
    name: batch-loader-9x2
    namespace: prod
    uid: c0de1f88-1122-4b33-9911-77aa55bb33cc
  result: fail
  rule: validate-resources
  scored: true
  source: kyverno
  timestamp:
    nanos: 0
    seconds: 1786594800
- message: validation rule 'validate-resources' passed.
  policy: require-resource-requests-limits
  resources:
  - apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
    namespace: prod
    uid: 9c44a012-77b5-4a10-b0e1-5d2f8a6c9e34
  result: pass
  rule: autogen-validate-resources
  scored: true
  source: kyverno
  timestamp:
    nanos: 0
    seconds: 1786594800
summary:
  error: 0
  fail: 2
  pass: 205
  skip: 7
  warn: 0
```

A pre-merge gate that fails the pipeline if a candidate policy would flag anything already running:

```console
$ kyverno apply ./candidate-policy.yaml --cluster --policy-report -o out.yaml
$ yq '.summary.fail' out.yaml
41
$ test "$(yq '.summary.fail' out.yaml)" -eq 0 || {
    echo "candidate policy would flag 41 live resources; ship it as Audit first"; exit 1; }
candidate policy would flag 41 live resources; ship it as Audit first
```

> This is the standard promotion workflow: **author → `Audit` + background scan → measure the fail count → remediate to zero → flip to `Enforce`**. Going straight to `Enforce` on a cluster you have not scanned is how you discover at 03:00 that a `StatefulSet` cannot be rescheduled.

### 6.6 Metrics

```console
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 >/dev/null 2>&1 &
$ curl -s localhost:8000/metrics | grep -m2 '^kyverno_policy_results_total'
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-resource-requests-limits",policy_namespace="",policy_type="cluster",policy_validation_mode="audit",resource_kind="Pod",resource_namespace="prod",resource_request_operation="",rule_execution_cause="background_scan",rule_name="validate-resources",rule_result="fail",rule_type="validate"} 41
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-resource-requests-limits",policy_namespace="",policy_type="cluster",policy_validation_mode="audit",resource_kind="Pod",resource_namespace="prod",resource_request_operation="CREATE",rule_execution_cause="admission_request",rule_name="validate-resources",rule_result="pass",rule_type="validate"} 1183
```

The label that matters is **`rule_execution_cause`**: `background_scan` vs `admission_request`. It is what lets you prove, on a graph, that the detective control is alive.

```yaml
# PrometheusRule — three alerts that cover the real failure modes
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kyverno-background-scan
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: kyverno-background-scan
      rules:
        - alert: KyvernoBackgroundScanStalled
          # No background-scan result has been recorded in 3x the scan interval.
          expr: |
            sum(increase(kyverno_policy_results_total{rule_execution_cause="background_scan"}[6h])) == 0
          for: 30m
          labels:
            severity: critical
          annotations:
            summary: Kyverno background scans have produced no results in 6h
            description: >-
              The detective control is dark. Pre-existing and drifted resources are not
              being evaluated. Check kyverno-reports-controller logs and RBAC.

        - alert: KyvernoPolicyEvaluationErrors
          # `error` results are unevaluated rules masquerading as clean.
          expr: |
            sum by (policy_name) (
              increase(kyverno_policy_results_total{rule_result="error"}[15m])
            ) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: 'Kyverno policy {{ $labels.policy_name }} is erroring, not evaluating'

        - alert: KyvernoReportsControllerRestarting
          expr: |
            increase(kube_pod_container_status_restarts_total{
              namespace="kyverno", container="controller",
              pod=~"kyverno-reports-controller-.*"}[30m]) > 2
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: reports-controller is crash-looping (commonly OOMKilled during a sweep)
```

---

## 7. Operating background scans at scale

### 7.1 The cost model

Work per sweep ≈ `Σ over policies ( matched resources × rules )`, plus one API `LIST` per scanned `GroupVersionKind` per informer resync, plus one report write per resource whose verdict changed.

| Pressure | Where it lands | Symptom | Lever |
|---|---|---|---|
| Informer caches for every scanned kind | reports-controller **memory** | `OOMKilled`, crash-loop during sweep | Raise memory limit; narrow `match` blocks; `skipResourceFilters=false`; exclude high-cardinality kinds (`Event`, `ReplicaSet`, `EndpointSlice`) |
| Rule evaluation | reports-controller **CPU** | Sweep does not finish before the next tick; queues compound | Raise `backgroundScanWorkers`; lengthen `backgroundScanInterval`; **never** set a CPU limit that throttles the sweep |
| Report objects | **etcd** size, apiserver watch fan-out | etcd DB growth, slow `LIST` on `polr` | Reduce matched resource count; `admissionReports=false`; keep `aggregateReports=true` |
| `apiCall` / registry lookups in policy context | External dependency | `error` results, timeouts | `enableConfigMapCaching`; use `GlobalContextEntry` (1.11+) instead of per-evaluation `apiCall` |
| Autogen duplication | Everything above ×2 | Double findings per workload | `pod-policies.kyverno.io/autogen-controllers: none` where Pod-level coverage suffices |

### 7.2 Sizing rule of thumb

* < 5,000 scanned objects: defaults (`1h`, 2 workers, 512Mi) are fine.
* 5,000 – 50,000: `backgroundScanInterval: 2h`, `backgroundScanWorkers: 4–8`, memory limit 2–4Gi, `skipResourceFilters: false`.
* \> 50,000: scope policies with `namespaceSelector`, consider `admissionReports: false`, `backgroundScanInterval: 6h–24h`, memory limit ≥ 8Gi, and measure sweep duration before touching worker count.

**Always measure the sweep duration before shortening the interval.** If a sweep takes longer than the interval, you have built a queue that never drains and the controller will eventually OOM.

### 7.3 Consuming the reports

Raw `PolicyReport` objects are an API, not a product. In production, put a consumer in front of them:

* **Policy Reporter** (`kyverno/policy-reporter`) — UI, Prometheus metrics per policy/namespace/severity, and targets for Slack, Elasticsearch, Loki, S3, Teams, webhooks. It is the reference consumer and speaks the `wgpolicyk8s.io` API, so it also ingests Trivy-operator reports.
* **kube-state-metrics custom resource state** — if you already run KSM and want report summaries as first-class metrics without another deployment:

```yaml
# kube-state-metrics CustomResourceStateMetrics config
kind: CustomResourceStateMetrics
spec:
  resources:
    - groupVersionKind:
        group: wgpolicyk8s.io
        version: v1alpha2
        kind: PolicyReport
      metricNamePrefix: policyreport
      labelsFromPath:
        namespace: [metadata, namespace]
        scope_kind: [scope, kind]
        scope_name: [scope, name]
      metrics:
        - name: summary_fail
          help: "Failing results in this PolicyReport"
          each:
            type: Gauge
            gauge:
              path: [summary, fail]
        - name: summary_error
          help: "Errored results in this PolicyReport"
          each:
            type: Gauge
            gauge:
              path: [summary, error]
```

---

## 8. Verification and failure diagnosis

### 8.1 Ordered triage: "the reports are empty"

```console
$ # 1 — Is the scanner even deployed and healthy?
$ kubectl -n kyverno get pods -l app.kubernetes.io/component=reports-controller
NAME                                          READY   STATUS    RESTARTS   AGE
kyverno-reports-controller-6d9c7f4b58-p2xkq   1/1     Running   0          14m

$ # 2 — Is background scanning switched on?
$ kubectl -n kyverno get deploy kyverno-reports-controller \
    -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -iE 'backgroundScan|policyReports|aggregate'
"--backgroundScan=true"
"--backgroundScanInterval=2h"
"--backgroundScanWorkers=4"
"--aggregateReports=true"
"--policyReports=true"

$ # 3 — Does the policy opt in to background mode?
$ kubectl get cpol my-policy -o jsonpath='{.spec.background}{"\n"}'
false                                   # <-- root cause in a large fraction of cases

$ # 4 — Is the policy Ready?
$ kubectl describe cpol my-policy | sed -n '/Status/,$p'
Status:
  Conditions:
    Message:  Ready
    Reason:   Succeeded
    Status:   True
    Type:     Ready
  Rule Count:
    Generate:   0
    Mutate:     0
    Validate:   1
    Verify images: 0

$ # 5 — Is anything being excluded before it reaches the engine?
$ kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}' | tr ']' ']\n' | head
[Event,*,*]
[*,kube-system,*]
[*,kube-public,*]
[*,kube-node-lease,*]
[Node,*,*]

$ # 6 — What is the controller actually saying?
$ kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=50 | grep -iE 'error|forbidden|skip'
```

### 8.2 Symptom → cause → fix

| Symptom | Root cause | Diagnosis | Fix |
|---|---|---|---|
| `kubectl get polr -A` returns nothing at all | `--backgroundScan=false` or `--policyReports=false` | Inspect controller args | Re-enable; `features.backgroundScan.enabled=true` |
| Some policies report, one never does | That policy has `background: false` | `kubectl get cpol -o custom-columns=...BACKGROUND...` | Remove the identity-dependent variable, or accept the gap and add a compensating posture policy |
| Policy rejected at `kubectl apply` | `background: true` + `request.userInfo` / `serviceAccountName` / `request.roles` | Read the webhook denial message verbatim | Set `background: false` (§5.2) |
| Reports full of `result: error`, message `... is forbidden: User "system:serviceaccount:kyverno:kyverno-reports-controller" cannot list resource ...` | Missing RBAC for a CRD | `kubectl auth can-i list <resource> --as=system:serviceaccount:kyverno:kyverno-reports-controller` | Aggregated `ClusterRole` with `rbac.kyverno.io/aggregate-to-reports-controller: "true"` (§5.5) |
| Findings for `kube-system` despite `resourceFilters` | `--skipResourceFilters=true` (default) | Check the flag | `--skipResourceFilters=false` |
| Results are stale after editing the policy | Cached verdict keyed by policy `resourceVersion` not yet re-queued | Compare report `timestamp` with the policy's `metadata.resourceVersion` change | Annotate the policy to bump `resourceVersion`, or delete the reports (§6.4) |
| Duplicate findings per workload | Autogen rules report on both controller and Pod | Look for `autogen-` prefixed `rule` names in results | Deduplicate by `ownerReference` downstream, or set `pod-policies.kyverno.io/autogen-controllers` |
| `Enforce` policy shows `fail` for a live resource, yet nothing was blocked | Background scan **never** blocks; the resource predates the policy | Expected behaviour | Remediate the resource; `Enforce` only guards future writes |
| Cannot update a violating resource to fix an unrelated field | `Enforce` + `allowExistingViolations: false` | Admission denial on UPDATE | `allowExistingViolations: true` (1.13+), or temporarily flip to `Audit` |
| reports-controller `OOMKilled` every interval | Informer caches for high-cardinality kinds | `kubectl -n kyverno describe pod ...` → `Last State: Terminated, Reason: OOMKilled` | Raise memory limit; `skipResourceFilters=false`; exclude `Event`/`ReplicaSet`; lengthen interval |
| Sweep never completes; queue depth grows | Interval shorter than sweep duration, or CPU throttling | Correlate `rule_execution_cause="background_scan"` rate with the interval; check `container_cpu_cfs_throttled_seconds_total` | Lengthen interval, raise workers, remove the CPU limit |
| Findings vanished with no waiver record | Someone narrowed the policy `match`/`exclude` | `kubectl get cpol <name> -o yaml \| diff` against Git | Use `PolicyException` instead — it yields auditable `skip` results (§5.6) |
| `verifyImages` reports `error` intermittently | Registry rate-limit or network timeout during scan | Error message contains the registry host | Registry pull-through cache, `imagePullSecrets` for the reports controller, lengthen interval |

### 8.3 End-to-end verification lab

```console
$ # A. Create a violating resource BEFORE the policy exists.
$ kubectl create ns bgscan-demo
namespace/bgscan-demo created

$ kubectl -n bgscan-demo run legacy --image=nginx:latest --restart=Never
pod/legacy created

$ # B. Now install a background-enabled Audit policy.
$ kubectl apply -f require-resource-requests-limits.yaml
clusterpolicy.kyverno.io/require-resource-requests-limits created

$ # C. Admission never saw this Pod. Prove the scan does.
$ kubectl get polr -n bgscan-demo
No resources found in bgscan-demo namespace.        # not scanned yet — wait for the tick

$ kubectl annotate cpol require-resource-requests-limits force-rescan="1" --overwrite
clusterpolicy.kyverno.io/require-resource-requests-limits annotated

$ sleep 20 && kubectl get polr -n bgscan-demo
NAME                                   KIND   NAME     PASS   FAIL   WARN   ERROR   SKIP   AGE
5e77b1a0-9f31-4c88-a2d3-6b0c4e91fa22   Pod    legacy   0      1      0      0       0      8s

$ kubectl get polr -n bgscan-demo -o jsonpath='{.items[0].results[0].message}{"\n"}'
CPU/memory requests and limits are required. Pod "legacy" is missing at least one of them.

$ # D. Confirm the finding came from the scan, not from admission.
$ curl -s localhost:8000/metrics \
    | grep 'rule_execution_cause="background_scan"' \
    | grep 'resource_namespace="bgscan-demo"'
kyverno_policy_results_total{...,resource_namespace="bgscan-demo",rule_execution_cause="background_scan",rule_result="fail",rule_type="validate"} 1

$ # E. Prove the report is owned by the resource and is GC'd with it.
$ kubectl delete pod -n bgscan-demo legacy
pod "legacy" deleted
$ kubectl get polr -n bgscan-demo
No resources found in bgscan-demo namespace.

$ kubectl delete ns bgscan-demo
namespace "bgscan-demo" deleted
```

---

## 9. Exam-focused summary

| Claim | True? |
|---|---|
| Background scans can block a non-compliant resource | **No.** They only report. Blocking is admission-only. |
| `spec.background` defaults to `true` | **Yes.** |
| The `kyverno-background-controller` performs background scans | **No.** The `kyverno-reports-controller` does. The background controller handles `generate` and `mutateExisting`. |
| `generate` and `mutate` rules produce background-scan results | **No.** Only `validate` and `verifyImages`. |
| A policy using `request.userInfo` can run in background mode | **No.** Kyverno rejects the policy unless `background: false`. |
| The default scan interval is 1 hour | **Yes** (`--backgroundScanInterval=1h`). |
| `--skipResourceFilters=true` means the scan skips filtered resources | **No.** It means the *filters are skipped*, so those resources **are** scanned. Default is `true`. |
| `PolicyReport` is a Kyverno-owned API | **No.** It is `wgpolicyk8s.io/v1alpha2`, from the Kubernetes Policy Working Group. |
| A `PolicyException` makes findings disappear from reports | **No.** It converts them to `result: skip`, which remains visible and countable. |
| `Enforce` retroactively fixes or deletes existing violations | **No.** It reports `fail` and blocks only future writes. |

**The one-sentence version:** background scans are Kyverno's detective control — the reports controller re-evaluates every `background: true` policy's `validate` and `verifyImages` rules against live cluster state every `backgroundScanInterval`, writing verdicts to `PolicyReport`/`ClusterPolicyReport`; they never block, they cost memory proportional to the resources they watch, and they are the only mechanism that can tell you the truth about resources your webhook never saw.

---

## Referencias

- KCA curriculum (CNCF): <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- CNCF curriculum repository: <https://github.com/cncf/curriculum>
- Kyverno Certified Associate — exam page: <https://training.linuxfoundation.org/certification/kyverno-certified-associate-kca/>
- Kyverno documentation (root): <https://kyverno.io/docs/>
- Kyverno — Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Kyverno — Background processing / `spec.background`: <https://kyverno.io/docs/writing-policies/background/>
- Kyverno — Installation customization and container flags: <https://kyverno.io/docs/installation/customization/>
- Kyverno — Policy Exceptions: <https://kyverno.io/docs/writing-policies/exceptions/>
- Kyverno — `validate` rules: <https://kyverno.io/docs/writing-policies/validate/>
- Kyverno — Auto-generation rules for Pod controllers: <https://kyverno.io/docs/writing-policies/autogen/>
- Kyverno — Monitoring and metrics: <https://kyverno.io/docs/monitoring/>
- Kyverno — Troubleshooting: <https://kyverno.io/docs/troubleshooting/>
- Kyverno CLI — `apply`: <https://kyverno.io/docs/kyverno-cli/usage/apply/>
- Kyverno policy library: <https://kyverno.io/policies/>
- Kyverno source: <https://github.com/kyverno/kyverno>
- Kyverno Helm chart: <https://github.com/kyverno/kyverno/tree/main/charts/kyverno>
- Kyverno chart on ArtifactHub: <https://artifacthub.io/packages/helm/kyverno/kyverno>
- Policy Reporter (report consumer, UI and metrics): <https://github.com/kyverno/policy-reporter>
- Kubernetes Policy WG — PolicyReport CRD specification: <https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report>
- Kubernetes — Dynamic Admission Control: <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- Kubernetes — Validating Admission Policy: <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/>
- Kubernetes — Using RBAC authorization (aggregated ClusterRoles): <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>
- kube-state-metrics — Custom Resource State metrics: <https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/extend/customresourcestate-metrics.md>