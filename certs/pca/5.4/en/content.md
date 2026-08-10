# 5.4 — Structuring and Naming Metrics

> **Domain 5 · Exam weight: 4**
> Level: Principal Platform Architect / Senior SRE
> Authoring language: English (technical terms kept in English)

Metric naming is the one design decision in a Prometheus deployment that is simultaneously (a) trivially easy to get wrong, (b) extremely expensive to change once dashboards, alerts, recording rules and downstream federation depend on it, and (c) the single largest lever over TSDB cost and query performance. A metric name and its label set are a *public API contract* between the instrumented workload and every consumer — Grafana panels, alerting rules, `remote_write` receivers, and the on-call engineer running an ad-hoc PromQL query at 3 a.m. This topic is about designing that contract so that it is aggregatable, discoverable, unit-consistent, and cardinality-safe.

---

## 1. Motivation: the production architectural problem

### 1.1 Why naming is an architectural concern, not a style preference

Prometheus stores every time series as a set of key/value pairs. A time series is uniquely identified by its **metric name plus the exact set of label name/value pairs**. Internally there is no such thing as a "metric name" separate from a label — the name is just a reserved label:

```
http_requests_total{method="GET", code="200", job="api", instance="10.0.3.4:8080"}
```

is stored as:

```
{__name__="http_requests_total", method="GET", code="200", job="api", instance="10.0.3.4:8080"}
```

Two consequences fall directly out of this data model, and both are exam-critical:

1. **Every distinct label-value combination is a *new* independent time series** with its own chunk in the head block, its own entry in the inverted index, and its own memory footprint (~1–4 KB of RAM resident per active series). Naming/labelling choices *are* capacity-planning choices.
2. **A metric name must have a single, consistent meaning across all its label dimensions**, because consumers will `sum()`, `avg()` and `rate()` across those dimensions without knowing the physical meaning. If `temperature_celsius` sometimes means CPU temperature and sometimes ambient temperature depending on a label, then `avg(temperature_celsius)` is nonsense — but PromQL will happily compute it.

### 1.2 The failure modes a good naming scheme prevents

| Failure mode | Root cause | Blast radius |
|---|---|---|
| **Cardinality explosion / OOMKilled TSDB** | Unbounded label value (user ID, email, full URL path, request ID) put in a label | Whole Prometheus server down; all alerting blind |
| **Non-aggregatable metric** | Same metric name means different things per label; or mixing units in one metric | Silent wrong numbers on dashboards & SLOs |
| **Broken `rate()`** | Counter not suffixed `_total`, or a gauge that can decrease named like a counter | Alerts fire on resets or never fire |
| **Unit ambiguity** | `latency` (is it ms? s? µs?) or `memory` (bytes? MB? pages?) | Cross-team dashboards silently off by 1000× |
| **Colon collisions with recording rules** | Exporter emits `job:foo:rate` directly | Recording-rule namespace polluted; overwrite risk |
| **Undiscoverable metrics** | No consistent `namespace_subsystem_name` prefix | Engineers can't find metrics; duplicate instrumentation |

The rest of this document is the set of rules and verification tooling that eliminate each row.

---

## 2. The anatomy of a metric name

### 2.1 Grammar (hard constraints enforced by the parser)

These are not conventions — the exposition parser and TSDB **reject** violations.

| Element | Allowed regex | Notes |
|---|---|---|
| Metric name | `[a-zA-Z_:][a-zA-Z0-9_:]*` | Colon `:` is **reserved for recording rules** and must NOT be used in directly-instrumented / exporter metrics |
| Label name | `[a-zA-Z_][a-zA-Z0-9_]*` | No colons in label names at all |
| Reserved label prefix | `__` | Double-underscore label names (`__name__`, `__address__`, `__meta_*`) are reserved for internal/relabeling use — never emit them from an exporter |
| Label value | any valid UTF-8 | Empty value `""` is semantically identical to the label being absent |

> Since Prometheus 2.x with the UTF-8 feature flag / OpenMetrics 1.0, names *may* contain arbitrary UTF-8 when quoted (`{"http.request.duration"}`), but for PCA and for portability you assume the **legacy charset above**. Sticking to `snake_case` ASCII is the safe, universally-compatible default.

### 2.2 The conventional structure: `namespace_subsystem_name_unit_suffix`

```
        prometheus_http_request_duration_seconds_bucket
        └────────┘ └──┘ └──────────────┘ └─────┘ └────┘
        namespace  sub  name             unit    _bucket (type suffix)
```

- **namespace / application prefix** — a single word identifying the software or library exposing the metric (`prometheus_`, `node_`, `process_`, `go_`, `http_`, `etcd_`). Prevents collisions when many exporters are scraped by one server. In client libraries this is set once as `Namespace`.
- **subsystem** — optional logical grouping inside the app (`http`, `grpc`, `db`, `queue`).
- **name** — what is being measured, describing the *whole application subsystem*, not one instance of it. Word between metric name components is `_`.
- **unit** — the base unit as a word (`seconds`, `bytes`, `ratio`, `celsius`). Always singular for the unit, describing the base unit.
- **type suffix** — `_total` (counter), `_bucket`/`_sum`/`_count` (histogram), `_info`, etc. (§2.4).

### 2.3 Base units — always use SI base units, never scaled or prefixed

Prometheus stores raw float64 samples and hard-codes **no units**. The convention is to always instrument in base units and let the *display layer* (Grafana, `humanize` functions) scale. This makes every metric of a family directly comparable and arithmetic across teams safe.

| Quantity family | Base unit (suffix) | Do NOT use |
|---|---|---|
| Time / duration | `seconds` | milliseconds, microseconds, nanoseconds, minutes, days |
| Data size | `bytes` | bits, kilobytes, megabytes, KiB, MiB |
| Network throughput | `bytes` (then `rate()` → bytes/s) | bits, Mbps |
| Ratio / fraction / utilization | `ratio` (values `0`–`1`) | percent (`0`–`100`) |
| Temperature | `celsius` | fahrenheit, kelvin |
| Length | `meters` | — |
| Voltage | `volts` | — |
| Electric current | `amperes` | — |
| Energy | `joules` | — |
| Power | expose energy in `joules`; derive power via `rate()` | watts (avoid raw) |
| Mass | `grams` | kilograms (avoids a unit prefix) |

**Rule of thumb:** if you ever find yourself dividing by 1000 or multiplying by 100 in a PromQL query, you named the metric with the wrong unit.

### 2.4 Reserved suffixes and per-type naming rules

| Metric type | Naming rule | Reserved suffixes it generates | `rate()`-able? |
|---|---|---|---|
| **Counter** | MUST end in `_total`. Monotonically increasing; only goes up or resets to 0. | `_total` (and `_created` under OpenMetrics) | Yes — this is the whole point |
| **Gauge** | No `_total`. A snapshot value that can go up and down. Name the thing measured + unit. | none | No — use raw value, `delta`, `deriv` |
| **Histogram** | Base name + `_seconds`/`_bytes`; client generates three series families | `_bucket{le="…"}`, `_sum`, `_count` | Yes on `_bucket`, `_sum`, `_count` |
| **Summary** | Base name + unit; client computes quantiles | `{quantile="…"}`, `_sum`, `_count` | Yes on `_sum`, `_count`; **not** on quantiles |
| **Info** | End in `_info`; a gauge always `= 1` carrying metadata as labels | `_info` | No — join with `group_left` |
| **Stateset / Enum** | one series per possible state, value `0`/`1` | — | No |

Reserved suffixes you must **never** attach to the wrong type: `_total`, `_sum`, `_count`, `_bucket`, `_bucket` are structural — attaching `_sum` to a plain gauge, or omitting `_total` from a counter, breaks tooling and PromQL idioms (`rate(x_total[5m])`, `histogram_quantile(0.99, rate(x_bucket[5m]))`).

The **`le`** label (histogram bucket upper bound, inclusive, `less-or-equal`) and the **`quantile`** label (summary) are reserved and mandatory for those types; every histogram must include a `+Inf` bucket that equals `_count`.

### 2.5 Metric-name vs label: when to split into a new metric

A frequent design decision: does a new dimension become a **label** on the existing metric, or a **new metric name**?

Decision test — **the aggregation-invariance rule**: *When you sum or average this metric across the label, is the result still meaningful and of the same unit?*

- **Yes → make it a label.** e.g. `http_requests_total{code="200"}` vs `{code="500"}` — summing gives total requests. ✅
- **No → make it a separate metric name.** e.g. do NOT do `node_metric{type="cpu_seconds"}` vs `{type="memory_bytes"}` — these have different units and summing them is meaningless. Use distinct names `node_cpu_seconds_total` and `node_memory_bytes`. ❌

| Approach | Example | Aggregatable? | Cardinality | Verdict |
|---|---|---|---|---|
| Split by label | `http_requests_total{code=…}` | `sum` = total requests ✔ | Bounded (few codes) | ✅ Correct |
| Split by label, mixed units | `resource_usage{kind="cpu\|mem"}` | `sum` mixes seconds+bytes ✖ | Bounded | ❌ Wrong |
| Split by metric name | `..._cpu_seconds_total`, `..._memory_bytes` | N/A (different metrics) | Bounded | ✅ Correct |
| Encode value in name | `http_requests_200_total`, `http_requests_500_total` | Can't `sum by (code)` easily | Bounded but rigid | ⚠️ Anti-pattern — prefer a label |

---

## 3. Cardinality: the production killer

Cardinality is the number of active time series. It is **multiplicative** across labels:

```
series(metric) = Π (distinct values of each label) × 1 (the metric name)
```

Example — an HTTP metric with these label cardinalities:

```
http_request_duration_seconds_bucket
  method:   6   (GET,POST,PUT,DELETE,PATCH,HEAD)
  code:    15   (200,201,204,301,400,401,403,404,409,422,429,500,502,503,504)
  handler:120   (route templates)
  le:      12   (histogram buckets incl +Inf)
  instance:40  (pods)
= 6 × 15 × 120 × 12 × 40 = 5,184,000 active series
```

That is ~5–20 GB of head-block RAM for **one metric family**. Now imagine someone puts the raw `path` (with IDs) instead of the templated `handler`:

```
  path: unbounded (e.g. /users/8f3a…/orders/9921)
```

→ cardinality grows without limit until the server is `OOMKilled`. This is the number-one production incident cause in Prometheus.

### 3.1 High-cardinality label anti-patterns (never put these in a label)

- User IDs, email addresses, customer IDs, session/request IDs, trace IDs
- Full URL paths with embedded IDs (use a **templated route**: `/users/:id`)
- Raw error messages / stack traces (use a bounded `error_code`/`reason`)
- Timestamps, epochs, or anything unbounded and growing
- Container image SHAs, pod names with random suffixes (use `deployment`/`app`)
- Kubernetes UIDs

### 3.2 Governance controls

| Control | Where | Purpose |
|---|---|---|
| `sample_limit` | scrape config | Hard cap; drops the whole scrape if a target exceeds N series |
| `label_limit`, `label_value_length_limit`, `label_name_length_limit` | scrape config | Reject pathological targets |
| `metric_relabel_configs` `action: drop`/`labeldrop` | scrape config | Prune known-bad metrics/labels at ingest |
| Recording rules | rule files | Pre-aggregate away raw cardinality for dashboards |
| `--storage.tsdb.retention.*`, sharding | server flags | Contain the cost after the fact |

---

## 4. Histogram vs Summary — the naming-adjacent trade-off

Both measure distributions of durations/sizes and both consume the same base name + unit, but they generate different series and have opposite aggregation properties. Choosing wrong is a naming-contract decision because the emitted series names differ (`_bucket` vs `quantile`).

| Dimension | **Histogram** | **Summary** |
|---|---|---|
| Series emitted | `_bucket{le}`, `_sum`, `_count` | `{quantile}`, `_sum`, `_count` |
| Quantile computed | **Server-side** at query time via `histogram_quantile()` | **Client-side**, baked in at scrape time |
| Aggregatable across instances | **Yes** — buckets are additive; `sum by (le)(rate(..._bucket[5m]))` then `histogram_quantile` | **No** — you cannot average quantiles; `avg(quantile="0.99")` is statistically invalid |
| Quantile accuracy | Bounded by chosen `le` buckets; need good bucket layout | Exact per-instance within a sliding window |
| Client CPU cost | Low | Higher (streaming quantile estimation) |
| Choose buckets at instrument time? | Yes (must pre-plan bucket boundaries) | No (choose objectives instead) |
| Native/exponential histograms (2.40+) | Auto-scaling buckets, tiny footprint, no `le` explosion | N/A |
| **Use when** | You need aggregatable SLO latency across pods/regions | You need an exact per-target quantile and can't aggregate |

**SRE default: histograms** (and native histograms where available), because SLOs and dashboards must aggregate across replicas. Summaries are for the rare case where you need an exact single-target quantile and will never aggregate.

---

## 5. Complete, production-ready manifests

### 5.1 Correct instrumentation — Go client library (naming applied)

```go
// file: internal/metrics/metrics.go
package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Namespace/subsystem enforce the `payments_http_...` prefix on every metric.
const (
	namespace = "payments"
	subsystem = "http"
)

var (
	// COUNTER — monotonically increasing → mandatory `_total` suffix.
	// Labels are all BOUNDED: method (~6), code (~15), handler is a
	// TEMPLATED route, never the raw path.
	RequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "requests_total", // → payments_http_requests_total
			Help:      "Total number of HTTP requests processed, by method, route template and response code.",
		},
		[]string{"method", "handler", "code"},
	)

	// HISTOGRAM — base unit is SECONDS (never milliseconds). Buckets
	// chosen around the SLO (250ms) so histogram_quantile is accurate there.
	RequestDurationSeconds = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "request_duration_seconds", // → payments_http_request_duration_seconds_{bucket,sum,count}
			Help:      "HTTP request latency in seconds.",
			Buckets:   []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
			// NativeHistogramBucketFactor: 1.1, // enable exponential/native histogram
		},
		[]string{"method", "handler"},
	)

	// GAUGE — snapshot that goes up and down → NO `_total`. Unit = bytes.
	InflightRequests = promauto.NewGauge(
		prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "inflight_requests", // → payments_http_inflight_requests
			Help:      "Number of HTTP requests currently being served.",
		},
	)

	// INFO metric — constant gauge = 1 carrying build metadata as labels.
	// Consumed via a group_left join, never aggregated.
	BuildInfo = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Namespace: namespace,
			Name:      "build_info", // → payments_build_info
			Help:      "Build metadata; value is always 1.",
		},
		[]string{"version", "revision", "goversion"},
	)
)
```

Resulting exposition on `/metrics` (note the auto-generated reserved suffixes and the `+Inf` bucket equal to `_count`):

```text
# HELP payments_http_requests_total Total number of HTTP requests processed, by method, route template and response code.
# TYPE payments_http_requests_total counter
payments_http_requests_total{code="200",handler="/v1/charge",method="POST"} 48213
payments_http_requests_total{code="422",handler="/v1/charge",method="POST"} 137

# HELP payments_http_request_duration_seconds HTTP request latency in seconds.
# TYPE payments_http_request_duration_seconds histogram
payments_http_request_duration_seconds_bucket{handler="/v1/charge",method="POST",le="0.005"} 12
payments_http_request_duration_seconds_bucket{handler="/v1/charge",method="POST",le="0.25"} 47901
payments_http_request_duration_seconds_bucket{handler="/v1/charge",method="POST",le="+Inf"} 48350
payments_http_request_duration_seconds_sum{handler="/v1/charge",method="POST"} 5123.44
payments_http_request_duration_seconds_count{handler="/v1/charge",method="POST"} 48350

# HELP payments_http_inflight_requests Number of HTTP requests currently being served.
# TYPE payments_http_inflight_requests gauge
payments_http_inflight_requests 7

# HELP payments_build_info Build metadata; value is always 1.
# TYPE payments_build_info gauge
payments_build_info{goversion="go1.22.3",revision="a1b2c3d",version="2.4.1"} 1
```

### 5.2 Scrape config with cardinality guardrails and metric_relabel hygiene

```yaml
# file: prometheus/scrape/payments.yml
scrape_configs:
  - job_name: payments-api
    scrape_interval: 15s
    metrics_path: /metrics
    # --- Cardinality guardrails: fail the scrape rather than the server ---
    sample_limit: 100000            # drop whole scrape if target exceeds this
    label_limit: 30                 # max labels per series
    label_name_length_limit: 200
    label_value_length_limit: 400
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: payments
        action: keep
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: instance
    metric_relabel_configs:
      # Drop a known high-cardinality metric leaking raw paths.
      - source_labels: [__name__]
        regex: payments_http_requests_by_raw_path_total
        action: drop
      # Strip an accidental unbounded label if it ever appears.
      - regex: (request_id|session_id|user_email)
        action: labeldrop
```

### 5.3 Recording rules — the `level:metric:operations` naming convention

Recording rules are the **only** place colons `:` are allowed in a metric name. The convention `level:metric:operations` communicates the aggregation applied, and pre-computing them shrinks dashboard cardinality/latency.

```yaml
# file: prometheus/rules/payments-recording.yml
groups:
  - name: payments-slo
    interval: 30s
    rules:
      # level = job (aggregation level) : metric : operation
      - record: job:payments_http_requests:rate5m
        expr: sum by (job) (rate(payments_http_requests_total[5m]))

      # 5xx error ratio, dimensionless (ratio 0–1), pre-aggregated per job.
      - record: job:payments_http_requests_errors:ratio_rate5m
        expr: |
          sum by (job) (rate(payments_http_requests_total{code=~"5.."}[5m]))
          /
          sum by (job) (rate(payments_http_requests_total[5m]))

      # p99 latency aggregated across all pods (histograms ARE aggregatable).
      - record: job:payments_http_request_duration_seconds:p99_5m
        expr: |
          histogram_quantile(
            0.99,
            sum by (job, le) (rate(payments_http_request_duration_seconds_bucket[5m]))
          )
```

### 5.4 Prometheus Operator `ServiceMonitor` (mirrors §5.2 in CRD form)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: payments-api
  namespace: payments
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: payments
  sampleLimit: 100000
  labelLimit: 30
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 15s
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: payments_http_requests_by_raw_path_total
          action: drop
        - regex: (request_id|session_id|user_email)
          action: labeldrop
```

---

## 6. CLI commands and real terminal output

### 6.1 Inspect what a target actually exposes

```console
$ curl -s http://localhost:8080/metrics | grep '^payments_http_requests_total'
payments_http_requests_total{code="200",handler="/v1/charge",method="POST"} 48213
payments_http_requests_total{code="422",handler="/v1/charge",method="POST"} 137
```

### 6.2 Lint naming conventions with `promtool check metrics`

`promtool check metrics` reads exposition from **stdin** and reports naming/type violations — run it in CI against a captured `/metrics` dump.

```console
$ curl -s http://localhost:8080/metrics | promtool check metrics
$ echo "exit=$?"
exit=0
```

Now feed it a badly-named file to see the linter fire:

```console
$ cat bad_metrics.prom
# TYPE http_requests counter
http_requests{code="200"} 5
# TYPE queue_depth_total gauge
queue_depth_total 12
# TYPE latencyMillis gauge
latencyMillis 42

$ promtool check metrics < bad_metrics.prom
http_requests counter metrics should have "_total" suffix
queue_depth_total non-counter metrics should not have "_total" suffix
latencyMillis metric names should be written in 'snake_case' not 'camelCase'
latencyMillis use base unit "seconds" instead of "millis"
$ echo "exit=$?"
exit=1
```

### 6.3 Validate recording-rule (colon) names

```console
$ promtool check rules prometheus/rules/payments-recording.yml
Checking prometheus/rules/payments-recording.yml
  SUCCESS: 3 rules found
```

### 6.4 Measure cardinality from the running server (TSDB status)

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:5]'
[
  { "name": "payments_http_request_duration_seconds_bucket", "value": 5184000 },
  { "name": "payments_http_requests_total",                  "value": 5400 },
  { "name": "apiserver_request_duration_seconds_bucket",     "value": 240000 },
  { "name": "go_gc_duration_seconds",                        "value": 3200 },
  { "name": "payments_http_inflight_requests",               "value": 40 }
]
```

Find which **label** is driving cardinality:

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb \
    | jq '.data.labelValueCountByLabelName[] | select(.value > 1000)'
{ "name": "handler",     "value": 120 }
{ "name": "le",          "value": 12 }
{ "name": "__name__",    "value": 8421 }
{ "name": "path",        "value": 918273 }   # <-- unbounded label; this is the leak
```

Count total active series and top offenders via PromQL:

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=topk(5, count by (__name__)({__name__=~".+"}))' \
    | jq -r '.data.result[] | "\(.value[1])\t\(.metric.__name__)"'
5184000	payments_http_request_duration_seconds_bucket
918273	payments_http_requests_by_raw_path_total
240000	apiserver_request_duration_seconds_bucket
5400	payments_http_requests_total
3200	go_gc_duration_seconds
```

### 6.5 Confirm a metric aggregates and `rate()`s correctly

```console
$ promtool query instant http://localhost:9090 \
    'sum by (job) (rate(payments_http_requests_total[5m]))'
payments_http_requests_total{job="payments-api"} => 331.4 @[1754870400]

$ promtool query instant http://localhost:9090 \
    'histogram_quantile(0.99, sum by (le)(rate(payments_http_request_duration_seconds_bucket[5m])))'
{} => 0.238 @[1754870400]
```

---

## 7. Verification and failure diagnosis guide

A ladder from cheapest/free static checks to runtime confirmation.

| Symptom | Diagnostic command | Likely root cause | Fix |
|---|---|---|---|
| CI naming lint fails | `promtool check metrics < dump.prom` | Counter missing `_total`; camelCase; wrong unit; `_sum`/`_bucket` on wrong type | Rename per §2.4; use base unit §2.3 |
| Prometheus RSS climbing, `OOMKilled` | `curl .../status/tsdb \| jq .data.labelValueCountByLabelName` | Unbounded label (path/id/email) | Template the route; `labeldrop` / `metric_relabel_configs` §5.2 |
| Scrape shows `up{}==1` but 0 samples for a metric | `curl .../targets` → check `lastError`; check `sample_limit` | Scrape exceeded `sample_limit` and was dropped whole | Raise limit *and* cut cardinality; investigate the offender |
| `rate()` returns huge spikes / negatives absorbed wrong | Query raw counter; look for non-monotonic drops | Counter is actually a gauge (name lies about type) | Rename to a gauge; remove `_total`; or fix instrumentation |
| `avg`/`sum` gives absurd values | Inspect the metric's labels & `# HELP`/`# TYPE` | Same metric name, mixed units/meaning across labels | Split into distinct metric names §2.5 |
| `histogram_quantile` returns `NaN`/wrong | Verify `+Inf` bucket exists & buckets increase; ensure `sum by (le)` | Missing `+Inf`, non-cumulative buckets, or aggregated without `le` | Use client library (auto-correct buckets); keep `le` in aggregation |
| Two metrics collide / overwrite | `count by (__name__)`; check for a `:` in exporter output | Exporter emitted a `level:metric:op` (recording-rule) name | Remove colons from direct instrumentation §2.1 |
| Info metric double-counts on join | Check `payments_build_info` value ≠ 1 or extra labels | Info metric used as a value, not a `group_left` label carrier | Keep value `=1`; join with `* on(instance) group_left(version)` |

**Static-first workflow (all free, run in CI):**

```console
$ promtool check metrics < <(curl -s localhost:8080/metrics)   # naming/type lint
$ promtool check rules prometheus/rules/*.yml                  # recording/alert names + colons
$ promtool check config prometheus.yml                         # scrape limits, relabel syntax
```

Only after the free checks pass do you spend runtime/RAM confirming cardinality via `/api/v1/status/tsdb`.

---

## 8. Referencias

- Metric and label naming (base units, suffixes, conventions) — https://prometheus.io/docs/practices/naming/
- Data model (name/label grammar, reserved `__` labels) — https://prometheus.io/docs/concepts/data_model/
- Metric types (counter/gauge/histogram/summary) — https://prometheus.io/docs/concepts/metric_types/
- Instrumentation best practices (labels, cardinality, `_total`) — https://prometheus.io/docs/practices/instrumentation/
- Histograms and summaries (aggregation trade-offs) — https://prometheus.io/docs/practices/histograms/
- Recording rules and the `level:metric:operations` naming — https://prometheus.io/docs/practices/rules/
- Writing exporters (naming/units for exporters) — https://prometheus.io/docs/instrumenting/writing_exporters/
- Exposition formats — https://prometheus.io/docs/instrumenting/exposition_formats/
- OpenMetrics specification (reserved suffixes, `_info`, `_created`) — https://github.com/OpenMetrics/OpenMetrics/blob/main/specification/OpenMetrics.md
- Native/exponential histograms — https://prometheus.io/docs/specs/native_histograms/
- `promtool` (check metrics/rules/config) — https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- TSDB status API (cardinality inspection) — https://prometheus.io/docs/prometheus/latest/querying/api/#tsdb-stats
- Go client library — https://github.com/prometheus/client_golang
- Prometheus Certified Associate curriculum — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf