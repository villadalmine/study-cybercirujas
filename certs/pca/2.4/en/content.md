# PCA 2.4 — Data Model and Labels

> **Domain:** Prometheus Fundamentals · **Exam weight:** 4
> **Author profile:** Principal Platform Architect / Senior SRE — production depth
> **Scope:** the internal representation of a metric in Prometheus, the label system that gives it dimensionality, cardinality as the dominant operational risk, and the relabeling machinery that lets you shape series *before* they are ingested.

---

## 1. Motivation: why the data model is the thing that decides whether your Prometheus survives production

Every other subject in this certification — PromQL, alerting, recording rules, federation — is a consequence of exactly one design decision: **Prometheus stores every observation as a sample belonging to a uniquely-identified time series, and that identity is a metric name plus an unordered set of key/value labels.**

A single time series in Prometheus is:

```
<metric_name>{<label_name>="<label_value>", ...}  ->  stream of (timestamp_ms, float64) samples
```

Concretely, this line from the exposition format:

```
http_requests_total{method="POST", handler="/api/v1/write", code="200"} 14872
```

is **not** "a metric with three labels." It is one specific time series whose full identity — the thing the TSDB indexes, hashes and de-duplicates on — is the entire label set *including the metric name*. Internally Prometheus stores the metric name as a reserved label named `__name__`. So the series above is identical to:

```
{__name__="http_requests_total", method="POST", handler="/api/v1/write", code="200"}
```

That equivalence is the single most important fact in this topic. Everything downstream follows from it:

- **Aggregation is set arithmetic over labels.** `sum by (code) (rate(http_requests_total[5m]))` works because labels are the grouping keys.
- **Cardinality is combinatorial.** The number of distinct series is the *cartesian product* of the distinct values of every label. One badly chosen label (a user ID, a full URL path, a raw error string) multiplies your series count without bound.
- **The head block is memory-resident.** Every active series holds an in-memory chunk plus index entries. Series count — not sample count, not query rate — is the first-order driver of Prometheus RSS.

### The production failure this topic exists to prevent

The archetypal outage is not a crashed query. It is **cardinality explosion**: a well-meaning developer adds a label whose value is unbounded (`user_id`, `request_id`, `session`, `pod` for churning pods, a full URL with IDs embedded), a deploy ships it, and over the next hours the Prometheus head block grows from 500k series to 8M series. Symptoms, in order of appearance:

1. `prometheus_tsdb_head_series` climbs linearly and does not plateau.
2. RSS grows until the process is OOM-killed by the kernel or the Kubernetes `memory` limit.
3. On restart, WAL replay takes tens of minutes because the WAL is now enormous, so your monitoring is *down during the incident it should be observing*.
4. Queries time out because the inverted index posting lists are huge.

The label system is therefore a **capacity-planning surface**, not a convenience. The rest of this document treats it that way.

---

## 2. The formal data model

### 2.1 The four constituents

| Constituent | Definition | Constraints |
|---|---|---|
| **Metric name** | Human-readable name of the measured quantity, stored internally as label `__name__`. | Must match `[a-zA-Z_:][a-zA-Z0-9_:]*` (legacy). Colons `:` are **reserved for recording rules** — never emit them from an exporter. |
| **Labels** | Key/value pairs that partition a metric name into dimensions. Together with the name they form the series identity. | Names match `[a-zA-Z_][a-zA-Z0-9_]*` (legacy). Names beginning `__` are **reserved for Prometheus internals**. Values are arbitrary UTF-8 strings. |
| **Sample** | A single observation: a `float64` value plus a millisecond-precision `int64` Unix timestamp. Native histograms carry a structured value instead of a scalar. | An empty label value is semantically identical to the label being absent. |
| **Timestamp** | `int64` milliseconds since the Unix epoch. | Prometheus samples are near-real-time; out-of-order ingestion is bounded and off by default (see `out_of_order_time_window`). |

Formally, a time series is the map:

```
identity  = { __name__: "...", label_a: "...", label_b: "...", ... }
series    = identity  ->  [ (t0, v0), (t1, v1), ... ]   monotonic in t
```

Two samples with the same identity and the same timestamp are a duplicate; Prometheus keeps the first and rejects the rest within a scrape.

### 2.2 UTF-8 names (Prometheus 3.x)

Since **Prometheus 3.0** (Nov 2024) metric and label *names* may contain arbitrary UTF-8, not only the legacy `[a-zA-Z0-9_:]` set. This matters in production when scraping OpenTelemetry data, where names like `http.server.request.duration` and labels like `service.name` are idiomatic. The rules:

- The legacy regex is now the *legacy validation scheme*; the *UTF-8 scheme* is the default in 3.x.
- Names that are not legacy-valid must be quoted in PromQL and in the exposition format:

```promql
{"http.server.request.duration", "service.name"="checkout"}
```

- Emitting UTF-8 names requires the exposition `escaping` negotiation; scrapers and exporters advertise support via the `Accept` header content-type parameter `escaping=allow-utf-8`.

Trade-off to internalize: UTF-8 names remove the "sanitize dots to underscores" translation layer for OTel pipelines, but they force quoting everywhere in PromQL and break tooling that assumed the legacy charset. In a greenfield OTel-native stack, adopt them; in an established Prometheus estate, keep the legacy convention (`_` separators) to avoid a query-rewrite migration.

### 2.3 The reserved label namespace (`__`)

These labels exist during target discovery and scraping; most are stripped before storage unless you explicitly keep them.

| Label | Meaning | Lifetime |
|---|---|---|
| `__name__` | The metric name. | **Persisted** — it *is* the name. |
| `__address__` | `host:port` Prometheus will scrape. | Discovery/relabel only; becomes `instance` if you don't override. |
| `__scheme__` | `http` / `https`. | Discovery/relabel only. |
| `__metrics_path__` | Path to scrape (default `/metrics`). | Discovery/relabel only. |
| `__param_<name>` | URL query parameter `<name>` added to the scrape request. | Discovery/relabel only. |
| `__meta_*` | Service-discovery metadata (e.g. `__meta_kubernetes_pod_label_app`). | Discovery/relabel only — **never persisted**; must be copied into a real label to survive. |
| `__scrape_interval__`, `__scrape_timeout__` | Per-target overrides. | Discovery/relabel only. |
| `__tmp_*` | Convention for scratch labels you create mid-relabel and want ignored. | Discovery/relabel only. |

The two labels Prometheus attaches automatically to every scraped sample are **`job`** (from the scrape config's `job_name`) and **`instance`** (defaulting to `__address__`). These are your primary identity axes; everything else is dimension.

### 2.4 Metric types and how they shape labels

The type lives in `# TYPE` metadata, not in the identity — but each type imposes a label discipline you must respect:

| Type | Series footprint | Label discipline |
|---|---|---|
| **counter** | 1 series | Monotonic; suffix `_total`. Never reset except on process restart (which `rate()` handles). |
| **gauge** | 1 series | Arbitrary up/down. |
| **histogram** (classic) | **`N buckets + 2`** series per label set | Emits `_bucket{le="..."}`, `_sum`, `_count`. The `le` label is a *reserved dimension* — a 10-bucket histogram is 12× the cardinality of a gauge with the same labels. |
| **summary** | `M quantiles + 2` series | Emits `{quantile="..."}`, `_sum`, `_count`. Quantiles computed client-side, not aggregatable across instances. |
| **native histogram** (3.x) | **1 series** | Single series carries a dynamic-resolution sparse bucket schema. The cardinality answer to classic-histogram bucket bloat. |

> **Architect's note:** the classic histogram multiplier is the second most common cause of silent cardinality growth after unbounded label values. A `request_duration_seconds` histogram with 15 buckets, across 4 methods × 20 handlers × 3 codes, is `15+2 = 17` series per combination × 240 combinations = **4,080 series** from a single instrumented metric on one instance. Multiply by instance count. Native histograms collapse the `+15` to `+0`.

---

## 3. Cardinality: the dominant trade-off

**Cardinality of a metric = the number of distinct label-value combinations it produces.** It is multiplicative across labels and additive across instances.

### 3.1 Worked cardinality model

```
series(metric) = Π (distinct values of each label)   [per instance]
total_series   = Σ over instances series(metric)
```

Example — a request counter with labels `method`, `handler`, `code`, `pod`:

| Label | Cardinality | Bounded? |
|---|---|---|
| `method` | 5 (GET/POST/PUT/DELETE/PATCH) | ✅ closed set |
| `handler` | 30 | ✅ closed set (route table) |
| `code` | 15 (2xx/3xx/4xx/5xx common ones) | ✅ bounded |
| `pod` | **grows with every rollout** | ❌ unbounded over time |

Per-instant series = 5 × 30 × 15 = **2,250**. Add `pod` (say 40 live) → 90,000. Now roll the deployment 10× a day for a week with a 15-day retention and churned pods still indexed in the head until they age out: the `pod` axis silently accumulates. This is why **`pod`, `container_id`, `image_id` are relabel-managed**, and why raw `user_id`/`request_id`/`email`/`full_path` **must never be labels** — they are logs/traces fields, not metrics dimensions.

### 3.2 Good-label vs bad-label decision table

| Candidate label | Verdict | Reason |
|---|---|---|
| `method`, `code`, `region`, `env`, `service`, `version` | ✅ | Bounded, closed set, useful for aggregation. |
| `handler`/`route` **templated** (`/users/:id`) | ✅ | Bounded to the route table. |
| `handler`/`path` **raw** (`/users/8134`) | ❌ | Unbounded — one series per ID. |
| `user_id`, `session_id`, `request_id`, `trace_id` | ❌❌ | Unbounded, high-churn — cardinality bomb; belongs in traces/logs. |
| `email`, `ip`, `hostname` (of clients) | ❌ | Unbounded and PII. |
| `error_message` (raw string) | ❌ | Unbounded; use a bounded `error_type`/`reason`. |
| `le` (histogram), `quantile` (summary) | ⚠️ reserved | Managed by the client library; you don't set them, but budget for their multiplier. |

**Rule of thumb (memorize for the exam and for on-call):** a label is acceptable only if you can name every possible value it will *ever* take. If the set is open, it is not a label.

### 3.3 Where cardinality can be capped

| Layer | Mechanism | Trade-off |
|---|---|---|
| **Instrumentation** | Choose bounded labels; template routes. | Cheapest, but requires developer discipline. |
| **Scrape config** | `sample_limit`, `label_limit`, `label_name_length_limit`, `label_value_length_limit` — hard caps that **fail the scrape** if exceeded. | Blunt: a breach drops the *whole* target's scrape, so `up` goes to 0. Protective but noisy. |
| **`metric_relabel_configs`** | `drop`/`labeldrop`/`keep` after scrape, before storage. | Surgical; the standard tool for taming a metric you don't control. |
| **Native histograms** | Replace classic bucket series. | Requires 3.x + client library support + PromQL that understands them. |
| **Recording rules + downsampling / remote write** | Pre-aggregate and ship reduced series to long-term storage (Thanos/Mimir/Cortex). | Moves the problem, doesn't erase local head cost. |

---

## 4. Complete, production-grade manifests

### 4.1 Prometheus scrape config with label lifecycle fully expressed

This `prometheus.yml` shows the full label pipeline: global limits, Kubernetes SD, `relabel_configs` (shape the *target* before scraping) and `metric_relabel_configs` (shape *samples* after scraping, before storage).

```yaml
# prometheus.yml — production baseline for a Kubernetes-hosted target set
global:
  scrape_interval:     30s
  scrape_timeout:      10s
  evaluation_interval: 30s
  external_labels:
    cluster: prod-eu-west-1
    __replica__: prometheus-0        # used by Thanos/dedup; double-underscore = reserved

  # Estate-wide guardrails: a target that exceeds ANY of these fails its scrape.
  sample_limit: 50000                # max samples accepted per scrape
  label_limit: 30                    # max labels per series
  label_name_length_limit: 128
  label_value_length_limit: 512
  target_limit: 2000                 # max targets a single SD may yield

scrape_configs:
  - job_name: kubernetes-pods
    scrape_interval: 30s
    kubernetes_sd_configs:
      - role: pod

    relabel_configs:
      # 1. Only scrape pods explicitly opted-in via annotation.
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"

      # 2. Honor a custom metrics path annotation, default stays /metrics.
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)

      # 3. Rewrite __address__ to the annotated port (host:port -> host:annotatedport).
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__

      # 4. Promote useful __meta_* discovery labels into PERSISTED labels.
      #    __meta_* is stripped before storage, so copy what you want to keep.
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
        action: replace
        target_label: app
      - source_labels: [__meta_kubernetes_pod_node_name]
        action: replace
        target_label: node

      # 5. Map all pod labels generically, sanitizing '.' and '-' to '_'.
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)

      # 6. Drop the noisy internal pod-template-hash label if it leaked in.
      - action: labeldrop
        regex: pod_template_hash

    metric_relabel_configs:
      # A. Kill a known cardinality bomb: a raw-path histogram from a 3rd-party image.
      - source_labels: [__name__]
        regex: http_request_duration_seconds_bucket
        action: drop

      # B. Drop a per-request-id label that a library emits unbidden.
      - action: labeldrop
        regex: request_id

      # C. Keep only the metrics we actually alert/graph on from a chatty exporter.
      - source_labels: [__name__]
        regex: (go_gc_duration_seconds|go_goroutines|process_.*|http_requests_total|http_request_duration_seconds.*)
        action: keep
```

### 4.2 The pod side of the contract — annotations that drive the relabeling above

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/version: "2.7.1"
spec:
  replicas: 3
  selector:
    matchLabels: { app.kubernetes.io/name: checkout }
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
        app.kubernetes.io/version: "2.7.1"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9102"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: checkout
          image: registry.example.com/checkout:2.7.1
          ports:
            - name: http-metrics
              containerPort: 9102
```

### 4.3 Correct instrumentation — bounded labels, templated route, native histogram (Go client)

```go
package main

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	// Counter: bounded labels only. NOTE: no user_id, no raw path, no request_id.
	httpRequests = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests processed, partitioned by method, templated route and status code.",
		},
		[]string{"method", "route", "code"}, // route is the TEMPLATE, e.g. "/orders/:id"
	)

	// Native histogram: ONE series per label set, dynamic-resolution buckets.
	requestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:                            "http_request_duration_seconds",
			Help:                            "Request latency in seconds.",
			NativeHistogramBucketFactor:     1.1, // enables native histograms
			NativeHistogramMaxBucketNumber:  160,
			NativeHistogramMinResetDuration: time.Hour,
		},
		[]string{"method", "route", "code"},
	)
)

func instrument(method, route, code string, seconds float64) {
	httpRequests.WithLabelValues(method, route, code).Inc()
	requestDuration.WithLabelValues(method, route, code).Observe(seconds)
}

func main() {
	http.Handle("/metrics", promhttp.Handler())
	_ = http.ListenAndServe(":9102", nil)
}
```

The `route` label must be the **matched route pattern** (`/orders/:id`), populated from your router (chi's `chi.RouteContext(r.Context()).RoutePattern()`, gin's `c.FullPath()`, etc.) — *never* `r.URL.Path`, which carries the raw ID and is unbounded.

---

## 5. CLI and terminal workflows

### 5.1 Reading the exposition format straight from a target

```console
$ curl -s http://localhost:9102/metrics | grep -E '^http_requests_total'
# HELP http_requests_total Total HTTP requests processed, partitioned by method, templated route and status code.
# TYPE http_requests_total counter
http_requests_total{code="200",method="GET",route="/orders/:id"} 84213
http_requests_total{code="200",method="POST",route="/orders"} 12048
http_requests_total{code="404",method="GET",route="/orders/:id"} 317
http_requests_total{code="500",method="POST",route="/orders"} 6
```

Note: label order in the wire format is irrelevant — `{a="1",b="2"}` and `{b="2",a="1"}` are the *same* series. Prometheus sorts labels internally.

### 5.2 Inspecting series identity via the HTTP API

```console
$ curl -s -G 'http://localhost:9090/api/v1/series' \
    --data-urlencode 'match[]=http_requests_total{code="500"}' | jq .
{
  "status": "success",
  "data": [
    {
      "__name__": "http_requests_total",
      "code": "500",
      "instance": "10.42.3.17:9102",
      "job": "kubernetes-pods",
      "method": "POST",
      "namespace": "shop",
      "pod": "checkout-6f9c8b7d5c-2xk4p",
      "route": "/orders"
    }
  ]
}
```

This is the payoff of §2.1 made visible: the API returns the **full identity map** including `__name__`, the auto-attached `job`/`instance`, and the labels we promoted from `__meta_*` during relabeling (`namespace`, `pod`).

### 5.3 Enumerating a label's value set — the cardinality smell test

```console
$ curl -s 'http://localhost:9090/api/v1/label/route/values' | jq -r '.data[]' | head
/orders
/orders/:id
/health
/metrics

$ # If this returned thousands of numeric-looking values, the route label is RAW, not templated -> bomb.
```

### 5.4 PromQL series-selector fundamentals

```promql
# Exact match on one label
http_requests_total{code="500"}

# Negative match
http_requests_total{code!="200"}

# Regex match / negation (fully anchored: ^...$ is implicit)
http_requests_total{route=~"/orders.*"}
http_requests_total{code!~"2.."}

# Select by metric name via __name__ (equivalent to naming it)
{__name__="http_requests_total", code="500"}

# Match a family of metrics by name regex — powerful and dangerous for cardinality
{__name__=~"http_.*", job="kubernetes-pods"}
```

An empty-matcher rule the exam likes to test: **a selector must have at least one matcher that does not match the empty string.** `{code=~".*"}` alone is rejected; `{__name__="x", code=~".*"}` is fine.

---

## 6. Verification and failure diagnosis

### 6.1 Standing cardinality dashboard — the four queries to keep pinned

```promql
# 1. Total live series in the head block (the number that OOM-kills you).
prometheus_tsdb_head_series

# 2. Series growth rate — should be ~flat in steady state; a positive slope = a leak.
deriv(prometheus_tsdb_head_series[30m])

# 3. Top metric names by series count (needs the metadata; approximate via count).
topk(10, count by (__name__)({__name__=~".+"}))

# 4. Per-job scrape sample volume — spikes precede series growth.
topk(10, scrape_samples_scraped)
```

### 6.2 The built-in TSDB status endpoint — first stop in any cardinality incident

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data | {numSeries, numLabelPairs, seriesCountByMetricName: .seriesCountByMetricName[0:5]}'
{
  "numSeries": 7841233,
  "numLabelPairs": 118402,
  "seriesCountByMetricName": [
    { "name": "http_request_duration_seconds_bucket", "value": 3120044 },
    { "name": "apiserver_request_duration_seconds_bucket", "value": 981220 },
    { "name": "http_requests_total", "value": 402118 },
    { "name": "container_memory_working_set_bytes", "value": 210338 },
    { "name": "go_gc_duration_seconds", "value": 88410 }
  ]
}
```

The same data is rendered at **Status → TSDB Status** in the web UI, with four tables: *Top 10 series count by metric name*, *by label name*, *by label value pair*, and *memory usage by label name*. The offender above is obvious: a classic `_bucket` histogram dominating with 3.1M series — the case for `metric_relabel_configs` drop or migrating it to a native histogram.

### 6.3 Offline forensic analysis with `promtool`

```console
$ promtool tsdb analyze /prometheus
Block ID: 01JQ8F3 V...
Duration: 2h0m0s
Series: 7841233
Label names: 214
Postings (unique label pairs): 118402

Label pairs most involved in churning series:
21134  __name__=http_request_duration_seconds_bucket
 9981  namespace=shop
 8820  le=+Inf

Highest cardinality labels:
1240233  pod
 402118  route          <-- red flag: 'route' should be bounded to the route table
   9932  le
    214  namespace

Highest cardinality metric names:
3120044  http_request_duration_seconds_bucket
 981220  apiserver_request_duration_seconds_bucket
```

`route` with 402k values is the diagnosis: someone shipped `r.URL.Path` instead of the templated pattern. The `pod` axis at 1.24M is expected churn (pods come and go), but if it dwarfs live-pod count, WAL/head retention is holding stale series — check `--storage.tsdb.head-chunks-write-queue-size` and retention.

### 6.4 Verifying a `metric_relabel_config` actually took effect

```console
$ # Before storage, confirm the target is discovered and its final (post-relabel) labels:
$ curl -s http://localhost:9090/api/v1/targets | \
    jq '.data.activeTargets[] | select(.labels.job=="kubernetes-pods") | {health, labels, lastError}' | head -30
{
  "health": "up",
  "labels": {
    "app": "checkout",
    "instance": "10.42.3.17:9102",
    "job": "kubernetes-pods",
    "namespace": "shop",
    "node": "ip-10-42-3-17",
    "pod": "checkout-6f9c8b7d5c-2xk4p"
  },
  "lastError": ""
}
```

`discoveredLabels` vs `labels` on this endpoint is the single best relabel debugger: `discoveredLabels` is the pre-relabel `__meta_*` set, `labels` is what survived to become the persisted identity. If a label you expected is missing, your relabel rule dropped or never wrote it.

### 6.5 Failure signature reference

| Symptom | Likely cause | Confirm with | Fix |
|---|---|---|---|
| `up == 0` for a target that is healthy | `sample_limit` / `label_limit` breached — Prometheus drops the whole scrape | `scrape_samples_scraped` vs limit; target `lastError` shows `sample limit exceeded` | Raise limit *or* (better) `metric_relabel_configs: drop` the offending metric |
| `numSeries` climbs, never plateaus | Unbounded label value (raw path, id, ip) | `/api/v1/status/tsdb` top label-value pairs; `promtool tsdb analyze` | `labeldrop` the label or fix instrumentation to template it |
| A label vanished after adding a rule | `__meta_*` not promoted, or a `labeldrop`/`replace` clobbered it | `/api/v1/targets` → compare `discoveredLabels` vs `labels` | Add a `replace` to copy `__meta_*` → real label *before* the drop |
| `many-to-many matching not allowed` in PromQL | Two selectors share identity because a distinguishing label was dropped | `count by (...)` both sides | Restore the label or use `on()/ignoring()`/`group_left` |
| Two series collapsed into one | A `replace`/`labeldrop` removed the only label that distinguished them → duplicate identity → duplicate-sample rejection | `/api/v1/series` shows fewer series than expected | Keep a distinguishing label |
| Histogram series count explodes | Classic histogram bucket multiplier × high label cardinality | TSDB status shows `_bucket` dominating | Reduce bucket count, reduce label dims, or migrate to native histograms |
| Labels differ only by empty value | `foo=""` treated as absent; series merge unexpectedly | `/api/v1/series` | Never rely on empty-string labels as a dimension |

### 6.6 Pre-flight validation (catch it before it ships)

```console
$ promtool check config prometheus.yml
Checking prometheus.yml
 SUCCESS: 1 rule files found
 SUCCESS: prometheus.yml is valid prometheus config file syntax

$ # Dry-run relabeling logic against a sample label set (Prometheus 2.51+):
$ promtool check config --lint-fatal prometheus.yml && echo "relabel + limits validated"
relabel + limits validated
```

---

## References

- Prometheus — Data model: https://prometheus.io/docs/concepts/data_model/
- Prometheus — Metric types: https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Metric and label naming best practices: https://prometheus.io/docs/practices/naming/
- Prometheus — Instrumentation & cardinality guidance: https://prometheus.io/docs/practices/instrumentation/
- Prometheus — Histograms and summaries (bucket cardinality): https://prometheus.io/docs/practices/histograms/
- Prometheus — Native histograms: https://prometheus.io/docs/specs/native_histograms/
- Prometheus — Configuration (`scrape_config`, limits, `relabel_configs`, `metric_relabel_configs`): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — Relabeling guide: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
- Prometheus — Querying basics (selectors, matchers, `__name__`): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — HTTP API (`/api/v1/series`, `/api/v1/labels`, `/api/v1/status/tsdb`, `/api/v1/targets`): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — Exposition formats and UTF-8 names: https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus 3.0 release notes (UTF-8 names, native histograms GA path): https://prometheus.io/blog/2024/11/14/prometheus-3-0/
- `promtool tsdb analyze` — storage docs: https://prometheus.io/docs/prometheus/latest/storage/
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf