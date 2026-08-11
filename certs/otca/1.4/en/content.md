# OpenTelemetry Certified Associate (OTCA)
## Domain 1 — Fundamentals of Observability
### Topic 1.4 — Analysis and Outcomes

> **Exam weight:** 4.5 · **Profile:** Advanced SRE / Platform Architect
> **Prerequisites:** 1.1 Telemetry vs. Observability · 1.2 Signals (traces, metrics, logs) · 1.3 Context Propagation

---

## 1. Motivation: the architectural problem of "data without decisions"

Instrumentation is a means, not an end. A service can emit a perfectly modeled trace for every request, a histogram for every dependency call, and a structured log line for every state transition — and still leave the on-call engineer blind at 03:14. The gap is not *collection*; it is **analysis and the outcomes analysis produces.**

"Analysis and Outcomes" is the OTCA competency that closes the loop:

```
        ┌─────────────┐   ┌───────────┐   ┌────────────┐   ┌──────────────┐
signals │  instrument │ → │  collect  │ → │   store    │ → │   ANALYZE    │
        └─────────────┘   └───────────┘   └────────────┘   └──────┬───────┘
                                                                   │
                       outcomes ◄──────────────────────────────────┘
                       (detect · triage · RCA · improve)
```

The production failure mode this topic addresses is concrete and expensive: teams instrument aggressively, ship telemetry to a backend, and discover during the *first* real incident that the data cannot answer the question being asked. Symptoms:

- **Detection outcome missing** — an SLO regression is real for 20 minutes before anyone notices, because alerting is threshold-on-a-raw-metric (`cpu > 80%`) instead of symptom-based (user-facing error ratio). MTTD is high.
- **Triage outcome missing** — an alert fires but the metric that fired it cannot be pivoted to the traces that caused it. There is no exemplar, no shared `trace_id`, no correlated resource attribute. The engineer has a number and no path from the number to a cause. MTTR balloons.
- **RCA outcome missing** — the histogram shows p99 latency doubled, but the head-based sampler discarded exactly the slow, erroring traces (the interesting tail), so the exemplar traces are all fast successes. The data that mattered was analyzed out of existence *before* it was stored.
- **Cost/cardinality outcome inverted** — a well-meaning `user.id` dimension turned a 40-series metric into a 4-million-series metric; the analysis backend now OOMs during the incident it was supposed to help resolve.

The architectural insight OTCA tests: **you design telemetry for the analysis you intend to perform and the outcome you intend to produce.** Aggregation level, cardinality budget, sampling strategy, and cross-signal correlation keys are all *analysis decisions* made at instrumentation and pipeline time, not query time.

---

## 2. The outcome taxonomy — what analysis is *for*

Every analytical activity maps to one of four outcomes. This taxonomy is the mental model the exam expects, and the practical checklist an architect uses to justify each signal.

| Outcome | Question answered | Primary signal | Secondary signals | Latency budget | Key metric |
|---|---|---|---|---|---|
| **Detection** | "Is something wrong *for the user*?" | Metrics (SLIs) | Logs (error rate) | seconds–minutes | **MTTD** (mean time to detect) |
| **Triage** | "Where and how bad?" | Metrics + Traces | Logs | minutes | scope/blast-radius |
| **Root cause (RCA)** | "*Why* is it wrong?" | Traces | Logs, profiles | minutes–hours | **MTTR** (mean time to resolve) |
| **Continuous improvement** | "Is the system getting better/worse over time?" | Metrics (aggregated) | Traces (sampled) | days–quarters | error-budget trend, SLO history |

The chain is directional: **detection triggers triage, triage narrows to RCA, RCA feeds improvement.** OpenTelemetry's value is that the *same* correlated telemetry serves all four, because the signals share context (`trace_id`, `span_id`) and resource identity (`service.name`, `service.namespace`, `k8s.pod.name`).

### 2.1 Golden-signal frameworks: RED vs. USE vs. Four Golden Signals

Analysis needs a *dimensioning* discipline so you measure the right things. Three frameworks dominate; they are complementary, not competing.

| Framework | Scope | Signals it prescribes | Best for | Blind spot |
|---|---|---|---|---|
| **RED** (Weaver) | Request-driven services | **R**ate, **E**rrors, **D**uration | Microservices, APIs, anything with requests | Says nothing about saturation of resources |
| **USE** (Gregg) | Resources | **U**tilization, **S**aturation, **E**rrors | Hosts, disks, queues, CPU, memory | Ignores per-request experience |
| **Four Golden Signals** (Google SRE) | User-facing systems | Latency, Traffic, Errors, Saturation | End-to-end service health | Broad; needs RED/USE to operationalize |

Architect's rule of thumb: **RED for the request path (derived from traces/spans), USE for the resources those requests consume (host/infra metrics), Golden Signals as the SLO layer on top.** OpenTelemetry lets you generate RED metrics *from traces* via the Collector's `spanmetrics` connector — one instrumentation source, two analysis surfaces (see §4).

### 2.2 SLI → SLO → SLA → Error Budget — the math of outcomes

This is the quantitative core of "outcomes." Definitions the exam requires you to keep distinct:

- **SLI (Indicator)** — a *measured* ratio of good events to valid events. Dimensionless, in `[0,1]`.
  `SLI = good_events / valid_events`
- **SLO (Objective)** — an internal *target* for the SLI over a rolling window. E.g. `SLI ≥ 0.999 over 28d`.
- **SLA (Agreement)** — an *external contract* with financial/legal consequences; always looser than the SLO (the SLO is the early-warning line inside the SLA).
- **Error Budget** — the *permitted* unreliability: `1 − SLO`. For `99.9%`, the budget is `0.1%` of valid events.

The **error budget over a 28-day window** for a 99.9% availability SLO:

```
budget_fraction  = 1 − 0.999            = 0.001
window           = 28d = 40320 minutes
budget (time)    = 40320 × 0.001        = 40.32 minutes of "down" per 28 days
```

The **burn rate** normalizes consumption speed: a burn rate of `1` exhausts the budget exactly at the end of the window; `14.4` exhausts it in `28d / 14.4 ≈ 2 days`; over a 1-hour window a burn rate of 14.4 means you'd spend `2%` of a 30-day budget in that hour. Burn-rate alerting (§4.3) is the modern replacement for static-threshold alerting and is the single most examinable "outcome" mechanism.

---

## 3. Cross-signal correlation — the mechanism that makes analysis possible

An outcome is only reachable if you can *pivot* between signals mid-investigation. OpenTelemetry provides three correlation mechanisms, in increasing precision:

| Mechanism | How the join happens | Precision | Cost | Enables |
|---|---|---|---|---|
| **Time + resource attributes** | Same `service.name` / `k8s.pod.name` in the same time bucket | Coarse (statistical) | free | "these logs and this metric are from the same pod" |
| **Trace context in logs** | Log record carries `trace_id` + `span_id` (OTel log correlation) | Exact (per request) | one field per log | "show me every log line for *this* failed request" |
| **Exemplars** | Histogram bucket carries a sample `trace_id` of a request that landed in it | Exact (metric→trace) | tiny (sampled) | "click the p99 latency spike → jump to a slow trace" |

### 3.1 Exemplars — metrics that link back to traces

Exemplars are the flagship "analysis outcome" feature and heavily tested. An exemplar is a representative measurement attached to a metric data point that carries the `trace_id`/`span_id` of the request that produced it. When a histogram observation is recorded *inside a sampled span context*, the OTel SDK (or the Collector's `spanmetrics` connector) attaches the trace context as an exemplar.

Consequence for analysis: a Grafana panel showing `duration` p99 renders exemplar dots on the graph; clicking one deep-links to the exact trace in Tempo/Jaeger. That is the **detection → RCA** jump collapsed into one click. Requirements:
- The metric must be a histogram (exemplars attach to buckets).
- Exposition must be **OpenMetrics** (Prometheus text format does not carry exemplars) — `enable_open_metrics: true` on the Collector's `prometheus` exporter, and the scraper must send `Accept: application/openmetrics-text`.

---

## 4. Production infrastructure — telemetry engineered for outcomes

The following is a complete, deployable pipeline that turns raw OTLP traces into **analysis-ready RED metrics with exemplars**, then computes SLIs and burn-rate alerts. Nothing is elided.

### 4.1 OpenTelemetry Collector — generate RED metrics + exemplars from traces

`otelcol-config.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # Bound cardinality BEFORE it reaches the metrics pipeline: keep only the
  # dimensions that analysis actually pivots on; drop the unbounded ones.
  transform/scrub:
    metric_statements:
      - context: datapoint
        statements:
          - delete_key(attributes, "user.id")
          - delete_key(attributes, "http.url")   # unbounded (query strings)
  batch:
    timeout: 10s
    send_batch_size: 1024

connectors:
  # The spanmetrics connector consumes the TRACES pipeline and emits METRICS.
  # It is the canonical "derive RED from traces" component.
  spanmetrics:
    histogram:
      explicit:
        buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s]
    # Only these span attributes become metric labels. Cardinality is a
    # first-class analysis budget: every dimension multiplies series count.
    dimensions:
      - name: http.request.method
      - name: http.route
      - name: http.response.status_code
    exemplars:
      enabled: true               # attach trace_id/span_id to histogram buckets
    exclude_dimensions: []
    metrics_flush_interval: 15s
    metrics_expiration: 5m        # evict stale series to bound memory
    namespace: traces.span.metrics
    aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE

exporters:
  # Traces to a trace backend (Tempo/Jaeger) for RCA.
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true
  # Metrics to a Prometheus-scrapable endpoint, in OpenMetrics so exemplars survive.
  prometheus:
    endpoint: 0.0.0.0:8889
    enable_open_metrics: true      # MANDATORY for exemplar exposition
    resource_to_telemetry_conversion:
      enabled: true                # copy resource attrs (service.name) to labels
    metric_expiration: 5m

service:
  pipelines:
    # Pipeline A: traces flow to the trace backend AND fan into spanmetrics.
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/tempo, spanmetrics]
    # Pipeline B: spanmetrics acts as a RECEIVER here, feeding derived metrics out.
    metrics:
      receivers: [spanmetrics]
      processors: [transform/scrub, batch]
      exporters: [prometheus]
  telemetry:
    logs:
      level: info
    metrics:
      level: detailed
      address: 0.0.0.0:8888        # the Collector's OWN metrics (for self-analysis)
```

The connector emits two metrics under the `traces.span.metrics` namespace, exposed by the Prometheus exporter as:

- `traces_span_metrics_calls_total` — counter (request **rate** and **errors**)
- `traces_span_metrics_duration_milliseconds_bucket` — histogram (**duration**, carries exemplars)

with labels `service_name`, `span_name`, `span_kind`, `status_code`, and the whitelisted `http_*` dimensions.

### 4.2 Prometheus scrape + SLI recording rules

`prometheus.yml` (scrape stanza — the OpenMetrics `Accept` header is implicit when the exporter advertises it, but exemplar storage must be enabled):

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

# Exemplar storage is behind a feature flag on older releases; enable it.
# CLI: prometheus --enable-feature=exemplar-storage
storage:
  exemplars:
    max_exemplars: 100000

scrape_configs:
  - job_name: otel-collector-spanmetrics
    static_configs:
      - targets: ['otel-collector:8889']
  - job_name: otel-collector-internal
    static_configs:
      - targets: ['otel-collector:8888']

rule_files:
  - /etc/prometheus/rules/*.yml
```

`rules/sli-checkout.yml` — recording rules pre-compute the SLI so dashboards and alerts read a cheap, stable series instead of re-deriving it. The `status_code` label values emitted by the connector are `STATUS_CODE_UNSET | STATUS_CODE_OK | STATUS_CODE_ERROR`.

```yaml
groups:
  - name: sli:checkout:recording
    interval: 30s
    rules:
      # Total valid request rate for the checkout service (the SLI denominator).
      - record: sli:checkout:requests:rate5m
        expr: |
          sum(rate(traces_span_metrics_calls_total{
            service_name="checkout", span_kind="SPAN_KIND_SERVER"
          }[5m]))

      # Bad request rate (the SLI numerator's complement).
      - record: sli:checkout:errors:rate5m
        expr: |
          sum(rate(traces_span_metrics_calls_total{
            service_name="checkout", span_kind="SPAN_KIND_SERVER",
            status_code="STATUS_CODE_ERROR"
          }[5m]))

      # Availability SLI = 1 − (errors / total), guarded against 0/0.
      - record: sli:checkout:availability:ratio5m
        expr: |
          1 - (
            sli:checkout:errors:rate5m
            /
            clamp_min(sli:checkout:requests:rate5m, 1e-9)
          )

      # Latency SLI: fraction of requests served under the 500ms threshold.
      - record: sli:checkout:latency:ratio5m
        expr: |
          sum(rate(traces_span_metrics_duration_milliseconds_bucket{
            service_name="checkout", span_kind="SPAN_KIND_SERVER", le="500"
          }[5m]))
          /
          clamp_min(
            sum(rate(traces_span_metrics_duration_milliseconds_count{
              service_name="checkout", span_kind="SPAN_KIND_SERVER"
            }[5m])), 1e-9)
```

### 4.3 Multi-window, multi-burn-rate SLO alerting (the "detection" outcome)

Static thresholds produce either slow detection (window too long) or false pages (window too short). The Google SRE Workbook pattern uses **two windows per severity**: a long window that measures sustained burn and a short window that confirms the problem is *still happening* (killing the alert quickly on recovery). Targets for a **99.9% SLO** (budget `0.001`):

| Severity | Long window | Short window | Burn rate | Budget spent if sustained | Meaning |
|---|---|---|---|---|---|
| **Page** | 1h | 5m | 14.4 | ~2% in 1h | catastrophic; wake someone |
| **Page** | 6h | 30m | 6 | ~5% in 6h | fast burn; wake someone |
| **Ticket** | 24h | 2h | 3 | ~10% in 1d | notable; file a ticket |
| **Ticket** | 3d | 6h | 1 | ~10% in 3d | slow leak; investigate |

`rules/slo-checkout-alerts.yml`:

```yaml
groups:
  - name: slo:checkout:burnrate
    rules:
      # Error-budget burn = observed error ratio / (1 − SLO).
      # SLO = 0.999  →  budget = 0.001.
      - record: slo:checkout:error_budget_burn:5m
        expr: |
          (
            sum(rate(traces_span_metrics_calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[5m]))
            / clamp_min(sum(rate(traces_span_metrics_calls_total{service_name="checkout"}[5m])), 1e-9)
          ) / 0.001
      - record: slo:checkout:error_budget_burn:1h
        expr: |
          (
            sum(rate(traces_span_metrics_calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[1h]))
            / clamp_min(sum(rate(traces_span_metrics_calls_total{service_name="checkout"}[1h])), 1e-9)
          ) / 0.001
      - record: slo:checkout:error_budget_burn:30m
        expr: |
          (
            sum(rate(traces_span_metrics_calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[30m]))
            / clamp_min(sum(rate(traces_span_metrics_calls_total{service_name="checkout"}[30m])), 1e-9)
          ) / 0.001
      - record: slo:checkout:error_budget_burn:6h
        expr: |
          (
            sum(rate(traces_span_metrics_calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[6h]))
            / clamp_min(sum(rate(traces_span_metrics_calls_total{service_name="checkout"}[6h])), 1e-9)
          ) / 0.001

      # PAGE: fast burn (14.4×) confirmed on both 1h and 5m windows.
      - alert: CheckoutErrorBudgetFastBurn
        expr: |
          slo:checkout:error_budget_burn:1h > 14.4
          and
          slo:checkout:error_budget_burn:5m > 14.4
        for: 2m
        labels:
          severity: page
          slo: checkout-availability
        annotations:
          summary: "Checkout burning error budget at >14.4x (1h & 5m)"
          description: "At this rate the 28d budget is exhausted in ~2 days. Pivot: exemplars on duration histogram → Tempo."

      # PAGE: 6× burn confirmed on 6h and 30m windows.
      - alert: CheckoutErrorBudgetSlowerBurn
        expr: |
          slo:checkout:error_budget_burn:6h > 6
          and
          slo:checkout:error_budget_burn:30m > 6
        for: 5m
        labels:
          severity: page
          slo: checkout-availability
        annotations:
          summary: "Checkout burning error budget at >6x (6h & 30m)"
```

### 4.4 Kubernetes deployment of the Collector (analysis-tier gateway)

`otel-collector-gateway.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: observability
data:
  otelcol-config.yaml: |
    # (contents of §4.1)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector-gateway
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-collector
    app.kubernetes.io/component: gateway
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-collector
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-collector
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8889"
    spec:
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.116.0
          args: ["--config=/conf/otelcol-config.yaml"]
          ports:
            - { name: otlp-grpc,   containerPort: 4317 }
            - { name: otlp-http,   containerPort: 4318 }
            - { name: prom-export, containerPort: 8889 }
            - { name: self-metric, containerPort: 8888 }
          resources:
            requests: { cpu: "500m", memory: "512Mi" }
            limits:   { cpu: "2",    memory: "2Gi" }
          livenessProbe:
            httpGet: { path: /, port: 13133 }
          volumeMounts:
            - { name: config, mountPath: /conf }
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
spec:
  selector:
    app.kubernetes.io/name: otel-collector
  ports:
    - { name: otlp-grpc,   port: 4317, targetPort: 4317 }
    - { name: otlp-http,   port: 4318, targetPort: 4318 }
    - { name: prom-export, port: 8889, targetPort: 8889 }
```

> **Architectural note:** `spanmetrics` must run in a **gateway** (single logical instance per stream), not a per-node agent, because RED aggregation across all pods requires all spans of a service to converge on one connector; otherwise you get N partial histograms that cannot be summed correctly (cumulative temporality per-instance). Load-balance *by trace ID* upstream (`loadbalancing` exporter) so all spans of a trace — and thus consistent aggregation — hit the same gateway replica.

---

## 5. Verification and failure diagnosis

### 5.1 Validate the Collector config before rollout

```console
$ otelcol-contrib validate --config=otelcol-config.yaml
2026-08-10T14:02:11.334Z  info  service@v0.116.0/service.go:135  Setting up own telemetry...
2026-08-10T14:02:11.335Z  info  spanmetricsconnector@v0.116.0/connector.go:180  Building spanmetrics connector
Configuration is valid.
$ echo $?
0
```

### 5.2 Confirm derived metrics and labels exist

```console
$ curl -s http://localhost:8889/metrics | grep traces_span_metrics_calls_total | head -3
traces_span_metrics_calls_total{service_name="checkout",span_kind="SPAN_KIND_SERVER",span_name="POST /cart/checkout",status_code="STATUS_CODE_OK",http_request_method="POST",http_route="/cart/checkout"} 18423
traces_span_metrics_calls_total{service_name="checkout",span_kind="SPAN_KIND_SERVER",span_name="POST /cart/checkout",status_code="STATUS_CODE_ERROR",http_request_method="POST",http_route="/cart/checkout"} 37
traces_span_metrics_calls_total{service_name="payment",span_kind="SPAN_KIND_CLIENT",span_name="charge",status_code="STATUS_CODE_OK"} 18386
```

### 5.3 Verify exemplars survived the pipeline (the critical outcome check)

Plain Prometheus text format silently drops exemplars. You MUST request OpenMetrics:

```console
$ curl -s -H 'Accept: application/openmetrics-text' \
    http://localhost:8889/metrics \
  | grep 'duration_milliseconds_bucket' | grep '#' | head -1
traces_span_metrics_duration_milliseconds_bucket{service_name="checkout",le="500.0"} 18201 # {trace_id="4bf92f3577b34da6a3ce929d0e0e4736",span_id="00f067aa0ba902b7"} 431.7 1754835731.442
```

The trailing `# {trace_id=...} 431.7 <ts>` **is** the exemplar. If it is absent, exemplars are broken — see 5.6.

### 5.4 Prove the SLI query returns data

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=sli:checkout:availability:ratio5m' | jq '.data.result'
[
  {
    "metric": {},
    "value": [ 1754835800.221, "0.998" ]
  }
]
```

`0.998` availability against a `0.999` SLO → the budget is burning. Confirm the burn-rate alert would trip:

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=slo:checkout:error_budget_burn:5m' | jq -r '.data.result[0].value[1]'
19.6
```

`19.6 > 14.4` on the 5m window; if the 1h window agrees for 2 minutes, `CheckoutErrorBudgetFastBurn` pages.

### 5.5 Confirm exemplars are queryable from Prometheus (drives Grafana pivots)

```console
$ curl -s 'http://localhost:9090/api/v1/query_exemplars' \
    --data-urlencode 'query=traces_span_metrics_duration_milliseconds_bucket{service_name="checkout"}' \
    --data-urlencode "start=$(date -d '-1 hour' +%s)" \
    --data-urlencode "end=$(date +%s)" | jq '.data[0].exemplars[0]'
{
  "labels": { "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736", "span_id": "00f067aa0ba902b7" },
  "value": "431.7",
  "timestamp": 1754835731.442
}
```

### 5.6 Diagnosis matrix — symptom → root cause → fix

| Symptom during analysis | Likely root cause | Verification | Fix |
|---|---|---|---|
| SLI query returns empty `[]` | `status_code` label value mismatch (used `"ERROR"` not `"STATUS_CODE_ERROR"`) | `curl .../metrics \| grep status_code` and read actual values | Match connector's enum strings exactly |
| Exemplars missing in Grafana | Metric exposed as Prometheus text, not OpenMetrics | 5.3 shows no `#{trace_id}` | Set `enable_open_metrics: true`; start Prometheus with `--enable-feature=exemplar-storage` |
| Exemplars present but always fast/successful | Head-based sampling dropped the slow/erroring traces before the connector saw them | Compare error rate in metrics vs. traces in Tempo | Move to **tail-based sampling**; sample on `status=ERROR` and high latency |
| Prometheus OOM after adding a dimension | Unbounded-cardinality label (`user.id`, `http.url` with query string) | `count({__name__=~"traces_span_metrics.*"})` explodes | Drop it in `transform` (§4.1) or omit from `dimensions` |
| RED metric sums wrong across replicas | `spanmetrics` running per-agent; partial cumulative histograms summed | Series count differs per gateway pod | Run connector in a gateway; load-balance by `trace_id` |
| Burn-rate alert flaps on/off | Only a single (long) window; no short-window confirmation | Alert clears slowly after recovery | Add the multi-window pair (§4.3) |
| p99 latency query wrong after a restart | Cumulative counter reset not handled | Raw `_bucket` without `rate()` | Always wrap counters/buckets in `rate()`/`histogram_quantile(...rate())` |
| Logs can't be joined to the failing trace | Log records missing `trace_id`/`span_id` | Inspect a log line's attributes | Enable OTel log correlation / trace-context log injection |

### 5.7 Verify cardinality budget before it becomes an incident

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=count({__name__=~"traces_span_metrics_.*"})' \
  | jq -r '.data.result[0].value[1]'
2841
$ # Find the offending label if this number is unexpectedly large:
$ curl -s 'http://localhost:9090/api/v1/status/tsdb' \
  | jq '.data.seriesCountByLabelName[:5]'
[
  { "name": "http_route",  "value": 42 },
  { "name": "span_name",   "value": 40 },
  { "name": "status_code", "value": 3  },
  { "name": "__name__",    "value": 2  },
  { "name": "service_name","value": 11 }
]
```

A healthy analysis surface shows *bounded* label values. A `value` in the tens of thousands for any single label name is the fingerprint of an unbounded dimension that will degrade every query it participates in.

---

## 6. References

- OTCA Curriculum (official domains and competencies) — https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
- OpenTelemetry — Observability Primer (signals, correlation, analysis) — https://opentelemetry.io/docs/concepts/observability-primer/
- OpenTelemetry — Exemplars (specification & SDK behavior) — https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exemplars
- OpenTelemetry Collector — `spanmetrics` connector (RED-from-traces) — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector
- OpenTelemetry Collector — `prometheus` exporter (OpenMetrics / exemplars) — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/prometheusexporter
- OpenTelemetry Collector — deployment patterns (agent vs. gateway) — https://opentelemetry.io/docs/collector/deployment/
- OpenTelemetry — Sampling (head vs. tail; effect on analysis) — https://opentelemetry.io/docs/concepts/sampling/
- OpenTelemetry — Logs correlation (`trace_id`/`span_id` in log records) — https://opentelemetry.io/docs/specs/otel/logs/data-model/
- Google SRE Book — Service Level Objectives (SLI/SLO/SLA, error budgets) — https://sre.google/sre-book/service-level-objectives/
- Google SRE Workbook — Alerting on SLOs (multi-window, multi-burn-rate) — https://sre.google/workbook/alerting-on-slos/
- Prometheus — Querying exemplars (`query_exemplars` API) — https://prometheus.io/docs/prometheus/latest/querying/api/#querying-exemplars
- Prometheus — Recording & alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- The RED Method (Tom Wilkie) — https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/
- The USE Method (Brendan Gregg) — https://www.brendangregg.com/usemethod.html