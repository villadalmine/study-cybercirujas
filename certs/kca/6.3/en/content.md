# Kyverno Metrics

**KCA Domain 6 — Monitoring, Reporting & Troubleshooting · Competency 6.3 · Exam weight 3.33%**

---

## 1. The production problem: an admission controller is on the write path

Every other component you monitor in Kubernetes is *adjacent* to the control plane. Kyverno is *inside* it.

When a `ValidatingWebhookConfiguration` points at `kyverno-svc.kyverno.svc:443`, the `kube-apiserver` will not persist a matched object until Kyverno answers. That single fact drives every metric decision that follows:

| Property | Consequence for observability |
|---|---|
| Kyverno is synchronous in the API request path | Its latency is **added** to every matched `CREATE`/`UPDATE`. Latency is an SLI of the *cluster*, not of Kyverno. |
| `failurePolicy: Fail` | If Kyverno is slow or down, the API server **rejects writes**. An outage of Kyverno becomes an outage of the cluster. |
| `failurePolicy: Ignore` | If Kyverno is slow or down, the API server **silently admits everything**. Your policies are off and nothing in Kyverno's own metrics will tell you — the request never arrived. |
| `webhookTimeoutSeconds` (default 10, max 30) | There is a hard latency budget. p99 approaching it is a pre-incident signal. |
| Background scan and `generate` rules are asynchronous | Their failures are invisible to users until an audit. They need a *separate* signal from admission. |

Two failure modes follow, and they are the reason this competency exists:

1. **Fail-closed brownout.** A policy adds an API call (`context.apiCall`), a registry lookup (`verifyImages`), or an expensive `foreach` over a large list. p99 admission latency climbs from 12 ms to 4 s. Nothing is "down". Then a Deployment rollout with 200 pods hits the webhook concurrently, the connection pool saturates, latency crosses 10 s, and the API server starts returning `Internal error occurred: failed calling webhook "validate.kyverno.svc-fail": context deadline exceeded`. The cluster stops accepting workloads.
2. **Fail-open silence.** The same brownout with `failurePolicy: Ignore` produces zero errors, zero rejections, and a compliance gap for the duration. The only place this is recorded is the **API server's** `apiserver_admission_webhook_fail_open_count` — not Kyverno's metrics, because Kyverno never saw the request.

Metrics are the only instrument that covers both. Policy reports tell you the *current* state of the cluster; metrics tell you the *rate of change*, the *latency*, and the *cost*.

### 1.1 Where metrics sit among Kyverno's signals

| Signal | Type | Answers | Retention/semantics | Cost |
|---|---|---|---|---|
| **Metrics** (`/metrics`, OTel) | Time series | "How fast? How often? Trending which way?" | Prometheus retention; aggregated, low fidelity per event | Cheap per event, cardinality is the risk |
| **PolicyReport / ClusterPolicyReport** | Kubernetes objects | "Which specific resources violate which rule *right now*?" | Reconciled current state; deleted with the resource | etcd objects, one per resource-owner |
| **Kubernetes Events** | Objects, TTL'd | "What did Kyverno decide about this one object, recently?" | ~1 h default TTL | Noisy; Kyverno omits some by default (`--omitEvents`) |
| **Logs** (`-v=2..6`) | Unstructured/structured lines | "Why did this specific evaluation behave that way?" | Log backend | Expensive at high verbosity |
| **Admission response to the user** | Synchronous message | "Why was my `kubectl apply` rejected?" | None | — |

The exam-relevant distinction: **a report answers "what is broken", a metric answers "how broken, how fast, and since when".** You cannot alert usefully on reports (they have no rate); you cannot audit a specific resource from a metric (it has no resource name — deliberately, to bound cardinality).

---

## 2. Architecture of the metrics pipeline

### 2.1 OpenTelemetry inside, Prometheus or OTLP outside

Kyverno does not instrument with the Prometheus client library directly. It uses the **OpenTelemetry SDK** as the internal instrumentation API, and then selects an exporter at startup:

```
  ┌────────────────────────────────────────────────────────┐
  │ Kyverno controller process                             │
  │                                                        │
  │  engine ──► metrics recorders (pkg/metrics)            │
  │  webhook ──►      │                                    │
  │  clients ──►      ▼                                    │
  │             OTel Meter Provider                        │
  │                   │                                    │
  │       ┌───────────┴────────────┐                       │
  │       ▼                        ▼                       │
  │  prometheus exporter      OTLP/gRPC exporter           │
  │  (pull, :8000/metrics)    (push, --otelCollector)      │
  └───────┬────────────────────────┬───────────────────────┘
          │ scrape                 │ OTLP
          ▼                        ▼
     Prometheus              OTel Collector ──► anything
```

Selection is made by `--otelConfig`:

| `--otelConfig` | Behaviour | `/metrics` endpoint | Typical use |
|---|---|---|---|
| `prometheus` (default) | Registers a Prometheus exporter and serves `:{--metricsPort}/metrics` | **Yes**, plaintext HTTP | Prometheus / VictoriaMetrics / Thanos pull |
| `grpc` | Pushes OTLP over gRPC to `--otelCollector` | **No** | Vendor backends, multi-cluster fan-in, mTLS-only estates |
| *(metrics disabled)* via `--disableMetrics=true` | No meter provider, no endpoint | No | Extreme cardinality/latency constraints only |

Trade-offs:

| Dimension | `prometheus` (pull) | `grpc` (push to OTel Collector) |
|---|---|---|
| Discovery | Prometheus SD finds the pod; a dead pod is `up == 0` — **liveness is free** | Collector cannot distinguish "silent" from "dead"; you need a separate up-check |
| Network direction | Prometheus → Kyverno (needs NetworkPolicy ingress on 8000) | Kyverno → Collector (egress); friendlier to locked-down namespaces |
| Transport security | Plaintext by default; TLS only if you front it | `--transportCreds` for TLS; native mTLS story |
| Aggregation | Per-scrape snapshot, counters monotonic between resets | Delta/cumulative per SDK config; collector can batch and re-export |
| Backpressure | None — scrape either succeeds or fails | Exporter queues; a slow collector can add memory pressure to Kyverno |
| Multi-tenant fan-in | One Prometheus per cluster, federate later | Natural: one collector, N clusters, one backend |
| Operational simplicity | High — one flag, one ServiceMonitor | Lower — a second component to run and monitor |

**Default and exam answer: `prometheus`, port `8000`, path `/metrics`, plaintext HTTP.**

### 2.2 Four controllers, four metrics endpoints — the most common production mistake

Since Kyverno 1.10 the monolith is split into four Deployments. Each is a separate process with its **own** OTel meter provider and its **own** `/metrics` endpoint. Scraping only `kyverno-svc-metrics` gives you admission data and nothing else.

| Controller | Deployment | Metrics Service | Emits (primarily) |
|---|---|---|---|
| **Admission** | `kyverno-admission-controller` | `kyverno-svc-metrics` | `kyverno_admission_requests_total`, `kyverno_admission_review_duration_seconds`, `kyverno_policy_results_total{rule_execution_cause="admission_request"}`, `kyverno_policy_execution_duration_seconds`, `kyverno_policy_changes_total`, `kyverno_policy_rule_info_total` |
| **Background** | `kyverno-background-controller` | `kyverno-background-controller-metrics` | results for `generate` and `mutateExisting` (UpdateRequest processing), controller metrics |
| **Reports** | `kyverno-reports-controller` | `kyverno-reports-controller-metrics` | `kyverno_policy_results_total{rule_execution_cause="background_scan"}`, report reconciliation controller metrics |
| **Cleanup** | `kyverno-cleanup-controller` | `kyverno-cleanup-controller-metrics` | `kyverno_cleanup_controller_deletedobjects_total`, controller metrics |

All four also export the shared families: `kyverno_controller_*`, `kyverno_client_queries_total`, plus Go runtime (`go_*`) and process (`process_*`) series.

> **Design consequence:** the same metric name appears on multiple endpoints with different label values. Any PromQL you write must aggregate across jobs *or* deliberately select one — `sum by (policy_name)(rate(kyverno_policy_results_total[5m]))` silently mixes admission and background-scan results unless you filter on `rule_execution_cause`.

### 2.3 The refresh interval — counters that are not monotonic forever

`metricsRefreshInterval` (ConfigMap `kyverno-metrics`) periodically **resets** the Prometheus registry. This is a deliberate cardinality/memory bound: without it, a series for a namespace that was deleted six months ago is still exported on every scrape, forever.

Consequences you must internalise:

- Never build dashboards on the **raw** counter value. `kyverno_policy_results_total` is not a lifetime total.
- Always use `rate()`, `irate()` or `increase()`. Prometheus detects counter resets and compensates, so these remain correct across a refresh.
- `increase(...[7d])` over a window longer than the refresh interval is still correct in Prometheus, but any external system reading the raw value is not.
- Setting it to `0` disables the reset — only do this with `namespaces.exclude` and `metricsExposure` tuned, or the series count grows without bound.

---

## 3. The metric catalogue

Metric names and label sets are **version-specific**. Section 8.1 shows how to enumerate exactly what your build exposes; treat the tables below as the 1.11–1.14 baseline and verify.

### 3.1 Policy inventory — `kyverno_policy_rule_info_total`

**Type:** Gauge (value `1` per existing rule, `0`/absent when removed)

| Label | Values | Notes |
|---|---|---|
| `policy_name` | e.g. `require-run-as-nonroot` | |
| `policy_namespace` | namespace, or `-` for `ClusterPolicy` | |
| `policy_type` | `cluster` \| `namespaced` | |
| `policy_validation_mode` | `enforce` \| `audit` | **The rollout signal** |
| `policy_background_mode` | `true` \| `false` | `spec.background` |
| `rule_name` | rule identifier | |
| `rule_type` | `validate` \| `mutate` \| `generate` \| `imageVerify` | |
| `status_ready` | `true` \| `false` | Policy compiled and webhook wired |

**What it is for:** it is the only metric that describes *configuration* rather than *traffic*. It answers "is the policy I applied actually loaded and ready?" and "how many rules are still in audit?" — a policy that exists in etcd but never reaches `status_ready="true"` is invisible in every other metric because it never evaluates.

```promql
# Rules that failed to become ready — a hard alert
kyverno_policy_rule_info_total{status_ready="false"} == 1

# Enforcement posture over time: what fraction of rules actually block?
sum(kyverno_policy_rule_info_total{policy_validation_mode="enforce"})
  /
sum(kyverno_policy_rule_info_total)
```

### 3.2 Verdicts — `kyverno_policy_results_total`

**Type:** Counter. The workhorse metric.

| Label | Values |
|---|---|
| `policy_name`, `policy_namespace`, `policy_type`, `policy_validation_mode`, `policy_background_mode` | as above |
| `rule_name`, `rule_type` | as above |
| `rule_result` | `pass` \| `fail` \| `warn` \| `error` \| `skip` |
| `rule_execution_cause` | `admission_request` \| `background_scan` |
| `resource_kind` | `Pod`, `Deployment`, … |
| `resource_namespace` | **highest-cardinality label** |
| `resource_request_operation` | `create` \| `update` \| `delete` |

**`rule_result` is the semantic core of the whole competency:**

| Value | Meaning | Who is at fault | Action |
|---|---|---|---|
| `pass` | Resource satisfied the rule | — | Baseline for ratios |
| `fail` | Resource **violated** the rule | The workload author | Expected traffic; alert on *spikes*, not on presence |
| `warn` | Violation reported non-blockingly (audit semantics) | The workload author | Rollout telemetry |
| `error` | The rule **could not be evaluated** — bad JMESPath, failed `context.apiCall`, registry unreachable, variable substitution failure | **You, the policy author** | Always alert. This is a Kyverno-side defect. |
| `skip` | Preconditions/`match` did not apply, or an exception matched | — | Useful to detect over-broad `PolicyException` |

> Confusing `fail` with `error` is the single most common misreading. `fail` is the system working. `error` is the system broken, and under `failurePolicy: Ignore` an `error` silently admits the resource.

### 3.3 Rule latency — `kyverno_policy_execution_duration_seconds`

**Type:** Histogram (`_bucket`, `_sum`, `_count`). Labels: the full `kyverno_policy_results_total` set.

This is **per-rule** engine time — it excludes webhook TLS handshake, JSON decoding, patch generation and the network path. Use it to attribute a latency regression to a specific rule.

### 3.4 Admission traffic — `kyverno_admission_requests_total`

**Type:** Counter. Labels: `resource_kind`, `resource_namespace`, `resource_request_operation`.

Counts AdmissionReview requests that **reached** Kyverno. Compare against the API server's view: a divergence means the webhook configuration is wrong or the API server is failing open before Kyverno is contacted.

### 3.5 End-to-end admission latency — `kyverno_admission_review_duration_seconds`

**Type:** Histogram. Labels: `resource_kind`, `resource_namespace`, `resource_request_operation`.

**This is the SLI.** It measures the full handling of an AdmissionReview inside Kyverno, and it is what must stay well below `webhookTimeoutSeconds`.

Default bucket boundaries (configurable, see §4):

```
0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 15, 20, 25, 30
```

Note the deliberate tail out to 30 s — the maximum legal webhook timeout. If your buckets stop at 10 s you cannot distinguish "slow" from "timed out".

### 3.6 Policy lifecycle — `kyverno_policy_changes_total`

**Type:** Counter. Labels: the policy identity set plus `policy_change_type` ∈ `created` | `updated` | `deleted`.

Correlation gold: overlay this on a latency graph and most regressions explain themselves. It is also a crude tamper signal — an unexpected `deleted` on a compliance policy deserves a page.

### 3.7 API server pressure — `kyverno_client_queries_total`

**Type:** Counter. Labels: `operation` (`Get`/`List`/`Watch`/`Create`/`Update`/`Patch`/`Delete`), `client_type` (`dynamic`, `kubeclient`, `kyvernoclient`, …), `resource_kind`, `resource_namespace`.

Kyverno is a heavy API client: informers, report writes, `generate` rule targets, `context.apiCall` lookups. On large clusters Kyverno can become the top consumer of API server priority-and-fairness capacity. This metric is how you prove it — or exonerate it.

### 3.8 Internal controllers — `kyverno_controller_*`

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `kyverno_controller_reconcile_total` | Counter | `controller_name` | Work processed |
| `kyverno_controller_requeue_total` | Counter | `controller_name` | Retries — sustained growth means a stuck object |
| `kyverno_controller_drop_total` | Counter | `controller_name` | Item **abandoned** after max retries — permanent data loss for that reconcile |
| `kyverno_controller_reconcile_duration_seconds` | Histogram | `controller_name` | Per-reconcile latency |

`kyverno_controller_drop_total > 0` means a report was never written or a `generate` target was never created. It is silent everywhere else.

### 3.9 Cleanup — `kyverno_cleanup_controller_deletedobjects_total`

**Type:** Counter. Labels: `policy_type`, `policy_namespace`, `policy_name`, `resource_group`, `resource_version`, `resource_kind`, `resource_namespace`.

Kyverno deleting objects is the highest-blast-radius thing it does. This metric plus a rate alert is the guardrail against a `CleanupPolicy` whose `match` block is broader than intended.

### 3.10 Quick reference

| Question | Metric |
|---|---|
| Are my policies loaded and ready? | `kyverno_policy_rule_info_total` |
| Is Kyverno adding latency to the cluster? | `kyverno_admission_review_duration_seconds` |
| Which rule is slow? | `kyverno_policy_execution_duration_seconds` |
| How much traffic does Kyverno see? | `kyverno_admission_requests_total` |
| Who is violating what, and how fast? | `kyverno_policy_results_total{rule_result="fail"}` |
| Are my policies broken? | `kyverno_policy_results_total{rule_result="error"}` |
| Did someone change a policy? | `kyverno_policy_changes_total` |
| Is Kyverno hammering the API server? | `kyverno_client_queries_total` |
| Are async reconciles being dropped? | `kyverno_controller_drop_total` |
| Is cleanup deleting more than expected? | `kyverno_cleanup_controller_deletedobjects_total` |
| **Is the webhook being bypassed?** | **`apiserver_admission_webhook_fail_open_count` (API server, not Kyverno)** |

---

## 4. Configuration

### 4.1 The `kyverno-metrics` ConfigMap — complete

This ConfigMap is read at startup **and** watched; most keys apply without a restart, but treat a restart as the safe path when changing `metricsRefreshInterval` or bucket boundaries.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kyverno-metrics
  namespace: kyverno
  labels:
    app.kubernetes.io/name: kyverno
    app.kubernetes.io/part-of: kyverno
data:
  # ------------------------------------------------------------------
  # Namespace filter. Applies to the *resource_namespace* label of the
  # resource being evaluated, not to Kyverno's own namespace.
  #   include: [] + exclude: []          -> every namespace is reported
  #   include: ["a","b"]                 -> ONLY a and b are reported
  #   exclude: ["kube-system","x-*"]     -> everything except those
  # include takes precedence: if include is non-empty, exclude is moot.
  # ------------------------------------------------------------------
  namespaces: |
    {
      "include": [],
      "exclude": ["kube-system", "kube-public", "kube-node-lease", "kyverno"]
    }

  # ------------------------------------------------------------------
  # Registry reset period. Bounds unbounded series growth from churny
  # namespaces. "0" disables the reset (use only with tight filters).
  # All PromQL must use rate()/increase(); raw values are not lifetime.
  # ------------------------------------------------------------------
  metricsRefreshInterval: 24h

  # ------------------------------------------------------------------
  # Default histogram buckets for every Kyverno histogram, in seconds.
  # Keep a bucket at and beyond your webhookTimeoutSeconds, or you
  # cannot distinguish "slow" from "timed out" in histogram_quantile.
  # ------------------------------------------------------------------
  bucketBoundaries: 0.005,0.01,0.025,0.05,0.1,0.25,0.5,1,2.5,5,10,15,20,25,30

  # ------------------------------------------------------------------
  # Per-metric exposure control. Three independent knobs per metric:
  #   enabled                 -> emit this metric family at all
  #   disabledLabelDimensions -> drop these labels AT THE SOURCE
  #                              (values are aggregated together)
  #   bucketBoundaries        -> per-histogram override of the default
  # Dropping a label here is strictly cheaper than dropping it in
  # Prometheus with metric_relabel_configs: the series is never built,
  # never serialised, and never transferred.
  # ------------------------------------------------------------------
  metricsExposure: |
    kyverno_policy_results_total:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
        - resource_request_operation
    kyverno_policy_execution_duration_seconds:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
        - resource_kind
      bucketBoundaries: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
    kyverno_admission_review_duration_seconds:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
      bucketBoundaries: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 20, 25, 30]
    kyverno_admission_requests_total:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
    kyverno_client_queries_total:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
```

> **Do not drop `rule_result`, `rule_execution_cause` or `policy_validation_mode`.** Every alert and every rollout gate in §6 and §7 depends on them. Drop `resource_namespace` first — it is the biggest multiplier and the least useful, because a PolicyReport already tells you the exact namespace and resource.

### 4.2 Helm values — complete, all four controllers

```yaml
# values-metrics.yaml — apply with:
#   helm upgrade --install kyverno kyverno/kyverno \
#     -n kyverno --create-namespace -f values-metrics.yaml
---
# ====================================================================
# The kyverno-metrics ConfigMap, rendered by the chart.
# ====================================================================
metricsConfig:
  create: true
  namespaces:
    include: []
    exclude:
      - kube-system
      - kube-public
      - kube-node-lease
      - kyverno
  metricsRefreshInterval: 24h
  bucketBoundaries:
    - 0.005
    - 0.01
    - 0.025
    - 0.05
    - 0.1
    - 0.25
    - 0.5
    - 1
    - 2.5
    - 5
    - 10
    - 15
    - 20
    - 25
    - 30
  metricsExposure:
    kyverno_policy_results_total:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
        - resource_request_operation
    kyverno_policy_execution_duration_seconds:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
        - resource_kind
    kyverno_admission_review_duration_seconds:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
    kyverno_client_queries_total:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace

# ====================================================================
# Admission controller — the one on the write path.
# ====================================================================
admissionController:
  replicas: 3
  webhookTimeoutSeconds: 10
  metering:
    disabled: false          # -> --disableMetrics=false
    config: prometheus       # -> --otelConfig=prometheus
    port: 8000               # -> --metricsPort=8000
    collector: ''            # -> --otelCollector=   (grpc mode only)
    creds: ''                # -> --transportCreds=  (grpc mode only)
  serviceMonitor:
    enabled: true
    interval: 30s
    scrapeTimeout: 25s
    secure: false            # metrics endpoint is plaintext HTTP
    additionalLabels:
      release: kube-prometheus-stack
    relabelings: []
    metricRelabelings:
      # Second line of defence against cardinality. The first is
      # disabledLabelDimensions above — prefer that.
      - sourceLabels: [__name__]
        regex: 'go_gc_.*|go_memstats_.*_bytes_total'
        action: drop
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      memory: 1Gi

# ====================================================================
# Background controller — generate / mutateExisting.
# ====================================================================
backgroundController:
  replicas: 2
  metering:
    disabled: false
    config: prometheus
    port: 8000
  serviceMonitor:
    enabled: true
    interval: 30s
    scrapeTimeout: 25s
    additionalLabels:
      release: kube-prometheus-stack

# ====================================================================
# Reports controller — background scans and report aggregation.
# Highest series volume: it evaluates every policy against every
# existing resource on resync.
# ====================================================================
reportsController:
  replicas: 2
  metering:
    disabled: false
    config: prometheus
    port: 8000
  serviceMonitor:
    enabled: true
    interval: 60s            # coarser: background scan is not latency-critical
    scrapeTimeout: 50s
    additionalLabels:
      release: kube-prometheus-stack

# ====================================================================
# Cleanup controller — deletions. Low volume, high blast radius.
# ====================================================================
cleanupController:
  replicas: 2
  metering:
    disabled: false
    config: prometheus
    port: 8000
  serviceMonitor:
    enabled: true
    interval: 30s
    scrapeTimeout: 25s
    additionalLabels:
      release: kube-prometheus-stack

# ====================================================================
# Ship the bundled Grafana dashboard as a ConfigMap with the sidecar
# label, so kube-prometheus-stack's grafana sidecar imports it.
# ====================================================================
grafana:
  enabled: true
  namespace: monitoring
  configMapName: kyverno-grafana-dashboard
  annotations: {}
  labels:
    grafana_dashboard: "1"
```

> **`additionalLabels` is the most frequent cause of a silently missing target.** `kube-prometheus-stack` installs a `Prometheus` CR whose `serviceMonitorSelector` matches `release: <stack-release-name>` by default. A ServiceMonitor without that label is valid, healthy, and completely ignored. Verify the selector before assuming your ServiceMonitor is wrong (§8.4).

### 4.3 Push mode: OTLP to an OpenTelemetry Collector

```yaml
# Helm override for gRPC/OTLP push mode.
admissionController:
  metering:
    disabled: false
    config: grpc
    collector: 'otel-collector.observability.svc.cluster.local:4317'
    creds: ''       # empty = insecure gRPC; set to a CA cert path for TLS
  serviceMonitor:
    enabled: false  # there is NO /metrics endpoint in grpc mode
```

Matching Collector, complete and deployable:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317

    processors:
      batch:
        timeout: 10s
        send_batch_size: 1024
      memory_limiter:
        check_interval: 5s
        limit_percentage: 80
        spike_limit_percentage: 25
      # Collector-side cardinality control: aggregate away the
      # resource_namespace dimension for the two hottest families.
      metricstransform:
        transforms:
          - include: kyverno_policy_results_total
            match_type: strict
            action: update
            operations:
              - action: aggregate_labels
                label_set: [policy_name, rule_name, rule_result, rule_execution_cause, policy_validation_mode]
                aggregation_type: sum
      attributes/cluster:
        actions:
          - key: cluster
            value: prod-eu-west-1
            action: insert

    exporters:
      prometheus:
        endpoint: 0.0.0.0:9464
        resource_to_telemetry_conversion:
          enabled: true
      debug:
        verbosity: basic

    service:
      telemetry:
        logs:
          level: info
        metrics:
          level: detailed
          address: 0.0.0.0:8888
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, attributes/cluster, metricstransform, batch]
          exporters: [prometheus]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-collector
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-collector
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-collector
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: collector
          image: otel/opentelemetry-collector-contrib:0.111.0
          args: ["--config=/conf/config.yaml"]
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: prom
              containerPort: 9464
            - name: self-metrics
              containerPort: 8888
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 200m
              memory: 400Mi
            limits:
              memory: 800Mi
          volumeMounts:
            - name: config
              mountPath: /conf
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-collector
spec:
  selector:
    app.kubernetes.io/name: otel-collector
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: otlp-grpc
    - name: prom
      port: 9464
      targetPort: prom
    - name: self-metrics
      port: 8888
      targetPort: self-metrics
```

---

## 5. Scrape infrastructure

### 5.1 One ServiceMonitor for all four controllers

Rather than four objects, select on the shared `part-of` label. Verify the label and port name first (§8.2) — they are chart-version dependent.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kyverno
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # MUST match Prometheus.spec.serviceMonitorSelector
spec:
  namespaceSelector:
    matchNames: ["kyverno"]
  selector:
    matchLabels:
      app.kubernetes.io/part-of: kyverno
  # Only Services that actually expose the metrics port will match an
  # endpoint; kyverno-svc (443/webhook) is selected but yields nothing.
  endpoints:
    - port: metrics-port
      path: /metrics
      scheme: http
      interval: 30s
      scrapeTimeout: 25s
      honorLabels: false
      relabelings:
        # Keep the controller identity as a first-class label so you can
        # slice by which process produced a series.
        - sourceLabels: [__meta_kubernetes_service_label_app_kubernetes_io_component]
          targetLabel: kyverno_controller
          action: replace
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
          action: replace
      metricRelabelings:
        # Drop Go GC histogram noise — large and rarely actionable here.
        - sourceLabels: [__name__]
          regex: 'go_gc_duration_seconds.*|go_memstats_.*'
          action: drop
        # Emergency cardinality valve: uncomment to collapse namespaces.
        # - regex: 'resource_namespace'
        #   action: labeldrop
```

### 5.2 Plain Prometheus (no Operator)

```yaml
scrape_configs:
  - job_name: kyverno
    scheme: http
    metrics_path: /metrics
    scrape_interval: 30s
    scrape_timeout: 25s
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names: [kyverno]
    relabel_configs:
      # Keep only the metrics ports of Kyverno services.
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_part_of]
        regex: kyverno
        action: keep
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        regex: metrics-port
        action: keep
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_component]
        target_label: kyverno_controller
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'go_memstats_.*|go_gc_.*'
        action: drop
```

### 5.3 NetworkPolicy — the silent-failure classic

If the `kyverno` namespace has a default-deny ingress policy, scrapes fail with `connection refused`/`i/o timeout` and the target shows `DOWN` with no Kyverno-side log line at all.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: kyverno
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/part-of: kyverno
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 8000
```

---

## 6. PromQL cookbook

### 6.1 The SLI: admission latency

```promql
# p99 end-to-end admission handling, per operation, across ALL admission pods
histogram_quantile(0.99,
  sum by (le, resource_request_operation) (
    rate(kyverno_admission_review_duration_seconds_bucket[5m])
  )
)

# Latency budget burn: fraction of reviews slower than 1s
1 - (
  sum(rate(kyverno_admission_review_duration_seconds_bucket{le="1"}[5m]))
  /
  sum(rate(kyverno_admission_review_duration_seconds_count[5m]))
)

# Headroom against the webhook timeout (webhookTimeoutSeconds: 10)
histogram_quantile(0.99,
  sum by (le) (rate(kyverno_admission_review_duration_seconds_bucket[5m]))
) / 10
```

### 6.2 Attribute a regression to a rule

```promql
# Top 10 slowest rules by p95 engine time
topk(10,
  histogram_quantile(0.95,
    sum by (le, policy_name, rule_name) (
      rate(kyverno_policy_execution_duration_seconds_bucket{rule_execution_cause="admission_request"}[5m])
    )
  )
)

# Mean engine time per rule — cheaper and often enough to spot the outlier
sum by (policy_name, rule_name) (rate(kyverno_policy_execution_duration_seconds_sum[5m]))
  /
sum by (policy_name, rule_name) (rate(kyverno_policy_execution_duration_seconds_count[5m]))
```

### 6.3 Broken policies (not violations)

```promql
# Rules that cannot be evaluated. Non-zero = defect.
sum by (policy_name, rule_name, rule_type) (
  rate(kyverno_policy_results_total{rule_result="error"}[5m])
) > 0

# Error ratio per policy
sum by (policy_name) (rate(kyverno_policy_results_total{rule_result="error"}[10m]))
  /
sum by (policy_name) (rate(kyverno_policy_results_total[10m]))
```

### 6.4 The audit → enforce rollout gate

The whole point of `Audit` mode is to gather this number before flipping to `Enforce`.

```promql
# Violations a policy WOULD have blocked in the last 24h, per policy.
# Promote to Enforce only when this is 0 (or an accepted list).
sort_desc(
  sum by (policy_name, rule_name) (
    increase(kyverno_policy_results_total{
      rule_result="fail",
      policy_validation_mode="audit",
      rule_execution_cause="admission_request"
    }[24h])
  )
)

# Which kinds would break — the blast-radius preview
sum by (policy_name, resource_kind) (
  increase(kyverno_policy_results_total{rule_result="fail", policy_validation_mode="audit"}[7d])
)
```

### 6.5 Enforcement impact (post-promotion)

```promql
# Requests actually blocked, per minute
sum by (policy_name, rule_name) (
  rate(kyverno_policy_results_total{
    rule_result="fail",
    policy_validation_mode="enforce",
    rule_execution_cause="admission_request"
  }[5m])
) * 60
```

### 6.6 Background scan vs admission

```promql
# Split the workload by origin — proves whether reports-controller is scraped
sum by (rule_execution_cause) (rate(kyverno_policy_results_total[5m]))

# Existing-fleet debt: violations found by scanning, not by admission
sum by (policy_name) (
  rate(kyverno_policy_results_total{rule_result="fail", rule_execution_cause="background_scan"}[15m])
)
```

### 6.7 Control-plane cost

```promql
topk(10,
  sum by (client_type, operation, resource_kind) (rate(kyverno_client_queries_total[5m]))
)

# Reconcile health
sum by (controller_name) (rate(kyverno_controller_drop_total[5m])) > 0
sum by (controller_name) (rate(kyverno_controller_requeue_total[5m]))
histogram_quantile(0.95,
  sum by (le, controller_name) (rate(kyverno_controller_reconcile_duration_seconds_bucket[5m])))
```

### 6.8 Cardinality self-audit

```promql
topk(15, count by (__name__) ({__name__=~"kyverno_.+"}))
count({__name__=~"kyverno_.+"})
count(count by (resource_namespace) (kyverno_policy_results_total))
topk(5, sum by (job) (scrape_samples_scraped))
```

---

## 7. Alerting — complete `PrometheusRule`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kyverno-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    # ================================================================
    # Availability of the admission path.
    # ================================================================
    - name: kyverno.availability
      rules:
        - alert: KyvernoTargetDown
          expr: up{job=~".*kyverno.*"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Kyverno metrics target down ({{ $labels.pod }})"
            description: >-
              Prometheus cannot scrape {{ $labels.job }}/{{ $labels.pod }}.
              If failurePolicy is Fail, the cluster may be rejecting writes;
              if Ignore, policies are being bypassed. Check the pod and the
              NetworkPolicy on the kyverno namespace.

        - alert: KyvernoNoAdmissionTraffic
          # Webhook is configured but Kyverno sees nothing: broken
          # webhook configuration, wrong CA bundle, or Service mismatch.
          expr: |
            sum(rate(kyverno_admission_requests_total[15m])) == 0
            and on() (sum(kyverno_policy_rule_info_total) > 0)
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "Kyverno has policies loaded but receives zero admission requests"
            description: >-
              Policies exist and are ready, yet no AdmissionReview reached
              Kyverno in 15 minutes. Inspect the ValidatingWebhookConfiguration
              rules/objectSelector and the caBundle.

    # ================================================================
    # Latency — the cluster-wide SLI.
    # ================================================================
    - name: kyverno.latency
      rules:
        - alert: KyvernoAdmissionLatencyHigh
          expr: |
            histogram_quantile(0.99,
              sum by (le) (rate(kyverno_admission_review_duration_seconds_bucket[5m]))
            ) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Kyverno p99 admission latency > 1s"
            description: "p99 is {{ $value | humanizeDuration }}; every matched write pays this."

        - alert: KyvernoAdmissionLatencyNearWebhookTimeout
          # 70% of a 10s webhookTimeoutSeconds. Adjust the divisor if you
          # changed the timeout.
          expr: |
            histogram_quantile(0.99,
              sum by (le) (rate(kyverno_admission_review_duration_seconds_bucket[5m]))
            ) > 7
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Kyverno p99 latency is approaching webhookTimeoutSeconds"
            description: >-
              p99 = {{ $value | humanizeDuration }} against a 10s timeout.
              With failurePolicy=Fail this becomes cluster-wide write
              rejection; with Ignore it becomes silent policy bypass.

    # ================================================================
    # Correctness of the policies themselves.
    # ================================================================
    - name: kyverno.policy-health
      rules:
        - alert: KyvernoRuleExecutionErrors
          expr: |
            sum by (policy_name, rule_name) (
              rate(kyverno_policy_results_total{rule_result="error"}[10m])
            ) > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Rule {{ $labels.policy_name }}/{{ $labels.rule_name }} is erroring"
            description: >-
              rule_result=error means the rule could NOT be evaluated (bad
              JMESPath, failed context.apiCall, unreachable registry). This is
              a policy defect, not a workload violation. Under
              failurePolicy=Ignore the resource is admitted unchecked.

        - alert: KyvernoPolicyNotReady
          expr: kyverno_policy_rule_info_total{status_ready="false"} == 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Policy {{ $labels.policy_name }} rule {{ $labels.rule_name }} is not ready"

        - alert: KyvernoEnforceDenialSpike
          expr: |
            sum by (policy_name, rule_name) (
              rate(kyverno_policy_results_total{
                rule_result="fail", policy_validation_mode="enforce",
                rule_execution_cause="admission_request"}[5m])
            ) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.policy_name }} is blocking >1 request/s"
            description: "Either a bad deploy or an over-broad policy. Check PolicyReports for the offending resources."

        - alert: KyvernoPolicyDeleted
          expr: increase(kyverno_policy_changes_total{policy_change_type="deleted"}[10m]) > 0
          labels:
            severity: info
          annotations:
            summary: "Policy {{ $labels.policy_name }} was deleted"

    # ================================================================
    # Asynchronous work and blast radius.
    # ================================================================
    - name: kyverno.background
      rules:
        - alert: KyvernoControllerDroppingWork
          expr: sum by (controller_name) (rate(kyverno_controller_drop_total[10m])) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Controller {{ $labels.controller_name }} is dropping items"
            description: >-
              Items abandoned after max retries. Reports may be stale and
              generate/mutateExisting targets may never be created.

        - alert: KyvernoCleanupDeletionSpike
          expr: |
            sum by (policy_name, resource_kind) (
              increase(kyverno_cleanup_controller_deletedobjects_total[10m])
            ) > 50
          labels:
            severity: critical
          annotations:
            summary: "CleanupPolicy {{ $labels.policy_name }} deleted >50 {{ $labels.resource_kind }} in 10m"

    # ================================================================
    # The API server's own view. NOT Kyverno metrics — and the only
    # place a fail-open bypass is ever recorded.
    # ================================================================
    - name: kyverno.apiserver-view
      rules:
        - alert: KyvernoWebhookFailingOpen
          expr: |
            increase(apiserver_admission_webhook_fail_open_count{name=~".*kyverno.*"}[10m]) > 0
          labels:
            severity: critical
          annotations:
            summary: "API server is failing OPEN on webhook {{ $labels.name }}"
            description: >-
              Requests are being admitted WITHOUT policy evaluation because
              the webhook (failurePolicy=Ignore) errored or timed out. This
              is a live compliance gap and is invisible in Kyverno's metrics.

        - alert: KyvernoWebhookApiserverLatencyHigh
          expr: |
            histogram_quantile(0.99,
              sum by (le, name) (
                rate(apiserver_admission_webhook_admission_duration_seconds_bucket{name=~".*kyverno.*"}[5m])
              )
            ) > 2
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "API server measures p99 {{ $value | humanizeDuration }} for {{ $labels.name }}"
            description: >-
              Compare with kyverno_admission_review_duration_seconds. A large
              gap is network/TLS/queueing outside the Kyverno process.
```

### 7.1 Why two vantage points are mandatory

| Measured from | Metric | Includes | Blind to |
|---|---|---|---|
| **Inside Kyverno** | `kyverno_admission_review_duration_seconds` | Engine, policy evaluation, patch generation | Requests that never arrived; TLS handshake; network; API-server-side queueing |
| **From the API server** | `apiserver_admission_webhook_admission_duration_seconds{name=~".*kyverno.*"}` | Everything, including network and TLS | Which policy/rule was responsible |
| **From the API server** | `apiserver_admission_webhook_rejection_count{name=~".*kyverno.*"}` | Denials and errors, with `rejection_code` and `error_type` | Rule attribution |
| **From the API server** | `apiserver_admission_webhook_fail_open_count{name=~".*kyverno.*"}` | **Silent bypasses** | Everything else |

Kyverno's webhook names, useful as label selectors: `validate.kyverno.svc-fail`, `validate.kyverno.svc-ignore`, `mutate.kyverno.svc-fail`, `mutate.kyverno.svc-ignore`.

---

## 8. Verification and failure diagnosis

The terminal transcripts below are from a representative cluster (kind, Kyverno installed via the `kyverno/kyverno` chart into namespace `kyverno`). Exact values will differ; the **shape** of the output and the reasoning are what matters.

### 8.1 Prove the endpoint exists and enumerate what it exposes

```bash
$ kubectl -n kyverno get deploy
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    3/3     3            3           4d2h
kyverno-background-controller   2/2     2            2           4d2h
kyverno-cleanup-controller      2/2     2            2           4d2h
kyverno-reports-controller      2/2     2            2           4d2h

$ kubectl -n kyverno get svc
NAME                                    TYPE        CLUSTER-IP       PORT(S)     AGE
kyverno-background-controller-metrics   ClusterIP   10.96.121.44     8000/TCP    4d2h
kyverno-cleanup-controller              ClusterIP   10.96.9.201      443/TCP     4d2h
kyverno-cleanup-controller-metrics      ClusterIP   10.96.55.180     8000/TCP    4d2h
kyverno-reports-controller-metrics      ClusterIP   10.96.203.17     8000/TCP    4d2h
kyverno-svc                             ClusterIP   10.96.180.22     443/TCP     4d2h
kyverno-svc-metrics                     ClusterIP   10.96.44.108     8000/TCP    4d2h
```

Four `*-metrics` Services. If you only see one, you are on Kyverno < 1.10 (monolith) or controllers are disabled.

Confirm the exporter mode from the running args — never from memory:

```bash
$ kubectl -n kyverno get deploy kyverno-admission-controller \
    -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' \
    | grep -E 'otel|metrics|disableMetrics'
--disableMetrics=false
--otelConfig=prometheus
--metricsPort=8000
--otelCollector=
--transportCreds=
```

Scrape it directly:

```bash
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 >/dev/null 2>&1 &
[1] 24815

$ curl -s localhost:8000/metrics | grep -c '^kyverno_'
1476

# Enumerate the metric FAMILIES this build exposes — the authoritative list
$ curl -s localhost:8000/metrics | grep '^# TYPE kyverno_' | sort
# TYPE kyverno_admission_requests_total counter
# TYPE kyverno_admission_review_duration_seconds histogram
# TYPE kyverno_client_queries_total counter
# TYPE kyverno_controller_drop_total counter
# TYPE kyverno_controller_reconcile_total counter
# TYPE kyverno_controller_requeue_total counter
# TYPE kyverno_policy_changes_total counter
# TYPE kyverno_policy_execution_duration_seconds histogram
# TYPE kyverno_policy_results_total counter
# TYPE kyverno_policy_rule_info_total gauge

# Inspect the real label set of one family
$ curl -s localhost:8000/metrics | grep '^kyverno_policy_results_total' | head -3
kyverno_policy_results_total{otel_scope_name="kyverno",policy_background_mode="true",policy_name="require-run-as-nonroot",policy_namespace="-",policy_type="cluster",policy_validation_mode="enforce",resource_kind="Pod",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="run-as-non-root",rule_result="pass",rule_type="validate"} 1184
kyverno_policy_results_total{otel_scope_name="kyverno",policy_background_mode="true",policy_name="require-run-as-nonroot",policy_namespace="-",policy_type="cluster",policy_validation_mode="enforce",resource_kind="Pod",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="run-as-non-root",rule_result="fail",rule_type="validate"} 37
kyverno_policy_results_total{otel_scope_name="kyverno",policy_background_mode="true",policy_name="disallow-host-path",policy_namespace="-",policy_type="cluster",policy_validation_mode="audit",resource_kind="Pod",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="host-path",rule_result="fail",rule_type="validate"} 9
```

Note `resource_namespace` is absent — that is `disabledLabelDimensions` from §4.1 working. Note `otel_scope_name` — the OpenTelemetry Prometheus exporter adds it; do not be surprised by it and do not `sum by ()` in a way that splits on it accidentally.

### 8.2 Discover the port name and labels your ServiceMonitor must use

```bash
$ kubectl -n kyverno get svc -l app.kubernetes.io/part-of=kyverno \
    -o custom-columns='NAME:.metadata.name,PORTNAME:.spec.ports[*].name,COMPONENT:.metadata.labels.app\.kubernetes\.io/component'
NAME                                    PORTNAME       COMPONENT
kyverno-background-controller-metrics   metrics-port   background-controller
kyverno-cleanup-controller              https          cleanup-controller
kyverno-cleanup-controller-metrics      metrics-port   cleanup-controller
kyverno-reports-controller-metrics      metrics-port   reports-controller
kyverno-svc                             https          admission-controller
kyverno-svc-metrics                     metrics-port   admission-controller
```

The ServiceMonitor in §5.1 selects `app.kubernetes.io/part-of: kyverno` and endpoint `metrics-port` — confirmed by this output. Never copy a port name from a blog post; read it from the cluster.

### 8.3 Generate traffic and watch a counter move

Kyverno metric families are created lazily. A brand-new install with no matched traffic legitimately exposes only `go_*`/`process_*` plus `kyverno_policy_rule_info_total`.

```bash
$ cat <<'EOF' | kubectl apply -f -
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
              kinds: ["Pod"]
      validate:
        message: "Pods must carry the label 'team'."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF
clusterpolicy.kyverno.io/require-team-label created

$ kubectl get clusterpolicy require-team-label
NAME                 ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
require-team-label   true        true         Audit             True    12s   Ready

$ curl -s localhost:8000/metrics \
  | grep 'kyverno_policy_rule_info_total.*require-team-label'
kyverno_policy_rule_info_total{otel_scope_name="kyverno",policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="audit",rule_name="check-team-label",rule_type="validate",status_ready="true"} 1

$ kubectl run probe-nolabel --image=nginx:1.27-alpine --restart=Never
pod/probe-nolabel created

$ curl -s localhost:8000/metrics \
  | grep 'kyverno_policy_results_total.*require-team-label'
kyverno_policy_results_total{otel_scope_name="kyverno",policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="audit",resource_kind="Pod",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="check-team-label",rule_result="fail",rule_type="validate"} 1
```

`rule_result="fail"` with `policy_validation_mode="audit"` and the Pod created: exactly the audit-mode rollout signal from §6.4. Flip to `Enforce` and the same counter increments while the Pod is rejected:

```bash
$ kubectl patch clusterpolicy require-team-label --type=merge \
    -p '{"spec":{"validationFailureAction":"Enforce"}}'
clusterpolicy.kyverno.io/require-team-label patched

$ kubectl run probe-nolabel-2 --image=nginx:1.27-alpine --restart=Never
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/default/probe-nolabel-2 was blocked due to the following policies

require-team-label:
  check-team-label: 'validation error: Pods must carry the label ''team''. rule
    check-team-label failed at path /metadata/labels/team/'

$ curl -s localhost:8000/metrics | grep 'kyverno_policy_changes_total'
kyverno_policy_changes_total{otel_scope_name="kyverno",policy_background_mode="true",policy_change_type="updated",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="enforce"} 1
```

Cleanup:

```bash
$ kubectl delete pod probe-nolabel --ignore-not-found
$ kubectl delete clusterpolicy require-team-label
```

### 8.4 Prometheus-side verification

```bash
$ kubectl -n monitoring get servicemonitor kyverno -o yaml | yq '.spec'
namespaceSelector:
  matchNames: [kyverno]
selector:
  matchLabels:
    app.kubernetes.io/part-of: kyverno
endpoints:
  - port: metrics-port
    path: /metrics
    interval: 30s

# THE check that catches the silent-ignore failure: does Prometheus even
# look at ServiceMonitors with your labels?
$ kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}'; echo
{"matchLabels":{"release":"kube-prometheus-stack"}}

$ kubectl -n monitoring get servicemonitor kyverno --show-labels
NAME      AGE   LABELS
kyverno   3d    release=kube-prometheus-stack
```

If those two do not match, the ServiceMonitor is inert and no error is logged anywhere.

Then confirm the targets are actually up — all four:

```bash
$ kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 >/dev/null 2>&1 &

$ curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.labels.job|test("kyverno"))
           | [.labels.job, .labels.kyverno_controller, .health, .lastError] | @tsv'
kyverno-svc-metrics                     admission-controller    up
kyverno-background-controller-metrics   background-controller   up
kyverno-reports-controller-metrics      reports-controller      up
kyverno-cleanup-controller-metrics      cleanup-controller      up

$ curl -sG 'localhost:9090/api/v1/query' \
    --data-urlencode 'query=sum by (rule_execution_cause) (rate(kyverno_policy_results_total[5m]))' \
  | jq -r '.data.result[] | "\(.metric.rule_execution_cause)\t\(.value[1])"'
admission_request       2.4666666666666663
background_scan         0.8333333333333334
```

Both causes present ⇒ admission **and** reports controllers are being scraped. If `background_scan` is missing, you have the §2.2 mistake.

Validate rules before shipping:

```bash
$ promtool check rules kyverno-rules.yaml
Checking kyverno-rules.yaml
  SUCCESS: 12 rules found
```

### 8.5 Diagnosis matrix

| Symptom | Most likely cause | Confirm with | Fix |
|---|---|---|---|
| `curl :8000/metrics` → connection refused | `--disableMetrics=true`, or `--otelConfig=grpc` (no HTTP endpoint in push mode), or wrong `--metricsPort` | `kubectl -n kyverno get deploy … -o jsonpath='{…args}'` | Set `metering.disabled: false`, `metering.config: prometheus` |
| Endpoint answers but **only** `go_*`/`process_*` | No matched admission traffic yet — families are lazily registered | `kubectl run` a matched resource (§8.3) | None; it is correct behaviour |
| `kyverno_policy_results_total` present, `kyverno_admission_requests_total` at 0 | Webhook not wired: bad `caBundle`, wrong `objectSelector`, or Service mismatch | `kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o yaml` | Restart admission controller to re-register; check `kyverno-svc` endpoints |
| A whole metric family is missing from `/metrics` | `metricsExposure.<metric>.enabled: false` | `kubectl -n kyverno get cm kyverno-metrics -o yaml` | Re-enable, restart the controller |
| A label is missing where docs say it exists | `disabledLabelDimensions`, or a `labeldrop` in `metricRelabelings` | Same ConfigMap; then ServiceMonitor | Remove the drop — cheapest at source |
| All namespaces collapse into one series | `namespaces.include`/`exclude` filter | Same ConfigMap | Adjust filter |
| Counters drop to zero on a schedule | `metricsRefreshInterval` reset | ConfigMap value | Expected. Use `rate()`/`increase()`, never raw values |
| Prometheus target `DOWN`, `context deadline exceeded` | NetworkPolicy blocking 8000, or `scrapeTimeout` < scrape duration | `kubectl -n kyverno get netpol`; target `lastError` | Apply §5.3; raise `scrapeTimeout` |
| ServiceMonitor exists, no target appears | `Prometheus.spec.serviceMonitorSelector` does not match its labels; or `namespaceSelector` wrong; or port name wrong | §8.4 | Add `release:` label; fix port name to `metrics-port` |
| Only admission metrics, no background/report data | Only `kyverno-svc-metrics` is scraped | `sum by (rule_execution_cause)(...)` returns one series | Select on `app.kubernetes.io/part-of: kyverno` (§5.1) |
| Same series duplicated with different `pod` | Multiple replicas — correct and expected | `count by (pod)(...)` | Always `sum by (…)` across pods; never graph a single replica |
| `histogram_quantile` returns `+Inf` | p99 falls beyond the largest finite bucket | `curl … \| grep '_bucket{le="+Inf"'` | Extend `bucketBoundaries` past `webhookTimeoutSeconds` |
| Prometheus memory climbs after enabling Kyverno | `resource_namespace` × `resource_kind` × `policy` × `rule` explosion | `topk(15, count by (__name__)({__name__=~"kyverno_.+"}))` | `disabledLabelDimensions: [resource_namespace]` |
| p99 latency high, no rule stands out | Cost is outside the engine: TLS, API calls, registry | `kyverno_client_queries_total`; compare with `apiserver_admission_webhook_admission_duration_seconds` | Cache with `enableConfigMapCaching`, reduce `context.apiCall`, add replicas |
| `rule_result="error"` sustained | Bad JMESPath, unreachable registry, failed `apiCall`, RBAC gap for a `context` lookup | `kubectl -n kyverno logs deploy/kyverno-admission-controller \| grep -i "failed to"` | Fix the rule; test with `kyverno apply` in CI |
| Writes rejected cluster-wide, Kyverno metrics look fine | Timeouts — Kyverno never recorded the request | `apiserver_admission_webhook_rejection_count{error_type="calling_webhook_error"}` | Scale out, raise timeout, or set `failurePolicy: Ignore` on non-critical webhooks |
| No violations detected, yet reports show them | Fail-open bypass at the API server | `apiserver_admission_webhook_fail_open_count{name=~".*kyverno.*"}` | Fix availability; reconsider `failurePolicy` |

### 8.6 Cardinality budget — do the arithmetic before you deploy

Worst-case series count for `kyverno_policy_results_total`:

```
policies × rules_per_policy × resource_kinds × namespaces
        × resource_request_operations(3) × rule_results(5) × rule_execution_causes(2)
```

A modest estate — 25 policies × 3 rules × 8 kinds × 300 namespaces × 3 × 5 × 2 — is **5.4 million** series, from one metric, per cluster. Add the histogram (`_bucket` multiplies by the number of boundaries + 2) and you are past what most Prometheus deployments will survive.

Mitigation, in order of preference:

| Lever | Where | Effect | Cost |
|---|---|---|---|
| `disabledLabelDimensions: [resource_namespace]` | Kyverno ConfigMap | ÷ 300 | Lose namespace attribution in metrics (PolicyReports still have it) |
| `namespaces.exclude` | Kyverno ConfigMap | Removes system churn | Those namespaces become invisible |
| `disabledLabelDimensions: [resource_request_operation]` | Kyverno ConfigMap | ÷ 3 | Cannot split create vs update |
| Shorter `bucketBoundaries` on `policy_execution_duration` | Kyverno ConfigMap | ÷ ~2 on that histogram | Coarser latency quantiles |
| `metricsExposure.<metric>.enabled: false` | Kyverno ConfigMap | Removes a family | Lose that signal entirely |
| `metricRelabelings` / `labeldrop` | ServiceMonitor | Same series reduction in TSDB | Kyverno still builds and serialises them — **wasted CPU and bandwidth** |
| `metricsRefreshInterval` | Kyverno ConfigMap | Bounds accumulated dead series | Counters reset |

**Rule of thumb:** drop at the source (`disabledLabelDimensions`) rather than at the scraper (`metricRelabelings`); the scraper-side drop pays the full production cost and only saves storage.

---

## 9. Exam-focused recall

- Default metrics port: **8000**, path **`/metrics`**, scheme **HTTP** (plaintext).
- Flags: `--otelConfig` (`prometheus` | `grpc`), `--metricsPort`, `--otelCollector`, `--transportCreds`, `--disableMetrics`.
- Configuration ConfigMap: **`kyverno-metrics`** in the Kyverno namespace. Keys: `namespaces`, `metricsRefreshInterval`, `bucketBoundaries`, `metricsExposure`.
- Instrumentation SDK: **OpenTelemetry**, exported either as a Prometheus pull endpoint or pushed via OTLP/gRPC.
- **Four controllers ⇒ four metrics Services** since 1.10.
- `rule_result` values: `pass`, `fail`, `warn`, `error`, `skip`. `fail` = violation; **`error` = the rule could not run**.
- `rule_execution_cause`: `admission_request` vs `background_scan`.
- Counters reset on `metricsRefreshInterval` ⇒ always `rate()`/`increase()`.
- Metrics ≠ reports: metrics have rates and latency, no resource names; reports have resource names, no history.
- Fail-open bypasses appear only in **`apiserver_admission_webhook_fail_open_count`**, never in Kyverno's metrics.

---

## 10. Referencias

**Kyverno — official documentation**
- Monitoring and metrics: https://kyverno.io/docs/monitoring/
- Installation and configuration: https://kyverno.io/docs/installation/
- Configuring Kyverno (ConfigMaps, flags): https://kyverno.io/docs/installation/customization/
- Container flags reference: https://kyverno.io/docs/installation/customization/#container-flags
- High availability and controller split: https://kyverno.io/docs/high-availability/
- Policy reports: https://kyverno.io/docs/policy-reports/
- Troubleshooting: https://kyverno.io/docs/troubleshooting/
- Cleanup policies: https://kyverno.io/docs/policy-types/cleanup-policy/

**Kyverno — source and chart**
- Repository: https://github.com/kyverno/kyverno
- Metrics implementation (`pkg/metrics`): https://github.com/kyverno/kyverno/tree/main/pkg/metrics
- Helm chart values (`metering`, `serviceMonitor`, `metricsConfig`, `grafana`): https://github.com/kyverno/kyverno/blob/main/charts/kyverno/values.yaml
- Helm chart README: https://github.com/kyverno/kyverno/blob/main/charts/kyverno/README.md
- Releases and version-specific metric changes: https://github.com/kyverno/kyverno/releases

**Kubernetes — the API server vantage point**
- Dynamic admission control (webhooks, `failurePolicy`, `timeoutSeconds`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes system metrics: https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
- Metrics reference (`apiserver_admission_webhook_*`): https://kubernetes.io/docs/reference/instrumentation/metrics/
- API Priority and Fairness: https://kubernetes.io/docs/concepts/cluster-administration/flow-control/

**Prometheus and the Operator**
- Metric types: https://prometheus.io/docs/concepts/metric_types/
- Querying basics and functions (`rate`, `increase`, `histogram_quantile`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Configuration (`scrape_configs`, `relabel_configs`, `metric_relabel_configs`): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Cardinality guidance (naming and labels): https://prometheus.io/docs/practices/naming/
- Prometheus Operator API (`ServiceMonitor`, `PrometheusRule`): https://prometheus-operator.dev/docs/api-reference/api/
- kube-prometheus-stack chart: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

**OpenTelemetry**
- Collector documentation: https://opentelemetry.io/docs/collector/
- Prometheus exporter: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/prometheusexporter
- Metrics transform processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/metricstransformprocessor

**Certification**
- KCA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- CNCF curriculum repository: https://github.com/cncf/curriculum