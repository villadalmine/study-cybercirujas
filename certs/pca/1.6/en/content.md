# Histograms — PCA 1.6 (Prometheus Certified Associate)

> Metric type deep-dive: classic (cumulative) histograms, `histogram_quantile()`, aggregation semantics, native (sparse exponential) histograms, and their production trade-offs. Level: SRE / Platform Architect.

---

## 1. Motivation — the production problem histograms solve

The single most misleading number in a latency dashboard is `avg(latency)`. A service can hold a mean of 40 ms while 1 % of users wait 4 s, and the average will never move enough to page anyone. SLOs are written against **tails** ("99 % of requests under 300 ms"), and tails require **distributions**, not central tendencies.

You have three architectural options for capturing a distribution in a pull-based system like Prometheus:

1. **Ship every observation** (event log / tracing). Perfect fidelity, unbounded cardinality and storage. Not a metrics problem.
2. **Compute the quantile on the client** (Summary). Cheap to query, *impossible to aggregate* across replicas — you cannot average p99s.
3. **Count observations into buckets on the client, compute the quantile at query time** (Histogram). Bounded cost, *aggregatable*, quantiles are estimates bounded by bucket width.

Prometheus histograms are option 3. The decisive property for a distributed system is **aggregability**: bucket counts are plain counters, so `sum by (le)` across 200 pods is arithmetically valid, and *then* you estimate the quantile of the fleet. That is the property Summaries cannot offer, and it is why histograms are the default instrument for RED/USE latency and for SLO error budgets.

The cost you pay is **the bucket layout is a design decision made at instrumentation time**, and a badly chosen layout silently caps the accuracy of every quantile you will ever compute from it. Native histograms (Section 6) exist to remove exactly that design decision.

---

## 2. Anatomy of a classic histogram

A single histogram named `<base>` explodes into **N+2 time series** on every scrape:

| Series | Meaning |
|---|---|
| `<base>_bucket{le="<upper_bound>"}` | **Cumulative** count of observations ≤ `upper_bound`. One per bucket. |
| `<base>_bucket{le="+Inf"}` | Count of *all* observations. Always equals `_count`. |
| `<base>_sum` | Running sum of all observed values. |
| `<base>_count` | Total number of observations. |

Two facts that trip up almost everyone:

- **Buckets are cumulative, not disjoint.** `le` means *less-than-or-equal*. A request of 0.07 s increments **every** bucket with `le ≥ 0.07`. The count in the "0.1 to 0.25" band is `bucket{le="0.25"} − bucket{le="0.1"}`, computed at query time — it is never stored.
- **The `+Inf` bucket is mandatory.** Without it, `histogram_quantile()` cannot know the total and returns `NaN`.

Text view of the cumulative shape (each bar includes everything to its left):

```
observation = 0.07s  ─► increments le=0.1, 0.25, 0.5, 1, 2.5, 5, 10, +Inf

le:    0.005  0.01  0.025  0.05  0.1   0.25  0.5   1     +Inf
count:   3     8     19     44   210   980  1180  1195   1200   (cumulative, monotonic non-decreasing)
         └──────────────── strictly non-decreasing left→right ────────────┘
```

### Default buckets differ per client library — a real aggregation hazard

| Client | Default buckets (seconds) |
|---|---|
| Go (`prometheus.DefBuckets`) | `.005 .01 .025 .05 .1 .25 .5 1 2.5 5 10` |
| Python (`prometheus_client`) | `.005 .01 .025 .05 .075 .1 .25 .5 .75 1.0 2.5 5.0 7.5 10.0 +Inf` |

If a Go service and a Python service expose `http_request_duration_seconds` with these defaults and you do `sum by (le)`, the `le` sets **do not align** — the Python-only boundaries (`.075`, `.75`, `7.5`) become partial sums and your fleet quantile is quietly wrong. **Standardise bucket layouts across every service that shares a metric name.**

---

## 3. `histogram_quantile()` — mechanics, interpolation, and its sharp edges

```promql
histogram_quantile(φ scalar, b instant-vector)
```

It reads the `le` labels of `b` as bucket upper bounds and returns the estimated φ-quantile. Within the bucket that contains the quantile, it assumes a **linear (uniform) distribution** and interpolates. That linearity assumption is the entire source of estimation error: the wider the bucket, the more the estimate can drift from reality.

### The canonical latency-quantile query

You almost never query raw buckets — they are cumulative counters that reset on restart. Wrap them in `rate()`, then aggregate **preserving `le`**:

```promql
histogram_quantile(
  0.95,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)
```

Per-route p99, keeping the dimensions you care about:

```promql
histogram_quantile(
  0.99,
  sum by (le, route) (rate(http_request_duration_seconds_bucket[5m]))
)
```

**Order of operations is non-negotiable:** `rate()` first (per-series, handles counter resets), then `sum by (le)`, then `histogram_quantile()` last. Reverse it and you are averaging quantiles — statistically meaningless.

### Documented edge-case behaviour (memorise for the exam)

| Condition | Result |
|---|---|
| `b` has fewer than two buckets | `NaN` |
| Highest bucket's `le` is **not** `+Inf` | `NaN` |
| Vector has 0 observations | `NaN` |
| φ < 0 | `-Inf` |
| φ > 1 | `+Inf` |
| Quantile lands in the **highest** (`+Inf`) bucket | returns the **upper bound of the second-highest** bucket (cannot interpolate into infinity) → *signal your top bucket is too low* |
| Quantile lands in the **lowest** bucket, and that bucket's upper bound > 0 | lower bound assumed to be **0**, linear interpolation applied |

**Interpretation for operators:** if `histogram_quantile(0.99, …)` keeps returning exactly your second-highest boundary (e.g. always `5` when the top real bucket is `le="5"` and then `+Inf`), your p99 is *above* the top finite bucket and the histogram literally cannot see it. Add higher buckets.

### The quantile-estimation error, quantified

The result can only ever be one of the bucket boundaries' interpolated values. If real p99 is 380 ms but your buckets jump `0.25 → 0.5`, the estimate is pinned somewhere in `[0.25, 0.5]` under a uniform assumption — potentially off by ±60 ms. **Put a bucket boundary where your SLO threshold is.** For a 300 ms SLO, `le="0.3"` must exist.

### Averages are exact (unlike quantiles)

`_sum` and `_count` give you the true mean for free — no interpolation:

```promql
rate(http_request_duration_seconds_sum[5m])
/
rate(http_request_duration_seconds_count[5m])
```

### SLO / Apdex fraction — "what share of traffic met the target"

Because buckets are counts, the fraction under a threshold is a division, no `histogram_quantile()` needed. This is **more accurate** than deriving a quantile, and it is the correct primitive for error budgets:

```promql
# Fraction of requests served in ≤ 300ms over the last 5m (needs le="0.3" to exist)
  sum(rate(http_request_duration_seconds_bucket{le="0.3"}[5m]))
/ sum(rate(http_request_duration_seconds_count[5m]))
```

Apdex (satisfied within T, tolerating up to 4T):

```promql
(
    sum(rate(http_request_duration_seconds_bucket{le="0.3"}[5m]))
  + sum(rate(http_request_duration_seconds_bucket{le="1.2"}[5m]))
) / 2
/   sum(rate(http_request_duration_seconds_count[5m]))
```

---

## 4. Trade-off tables

### 4.1 Histogram vs Summary

| Dimension | **Histogram** | **Summary** |
|---|---|---|
| Where the quantile is computed | Query time (`histogram_quantile`) | Client, at observation time |
| Exposed series | `_bucket{le}` × N, `_sum`, `_count` | `{quantile}` × K, `_sum`, `_count` |
| **Aggregatable across instances** | **Yes** (`sum by (le)`) | **No** — averaging quantiles is invalid |
| Which quantiles available | **Any φ, chosen at query time** | Only the K quantiles pre-configured at build time |
| Accuracy driver | Bucket layout (interpolation error) | Configured φ-error / sliding window |
| Client CPU cost | Low (counter increments) | Higher (streaming quantile estimator) |
| Query cost | Higher (interpolation over N buckets) | Trivial (read the value) |
| Threshold / Apdex fraction | **Yes** — bucket division | No (only the pre-chosen quantiles) |
| Cardinality | N buckets per label set | K quantiles per label set |
| Sub-second precision on a fixed φ | Needs a matching bucket boundary | Precise by construction |

**Rule of thumb:** use a **Histogram** by default (aggregation + SLO fractions). Use a **Summary** only when you need a precise fixed quantile on a **single non-replicated** instance and cannot pre-place buckets — e.g. a batch job's per-run p99 that is never summed across machines.

### 4.2 Classic vs Native histogram

| Dimension | **Classic histogram** | **Native (sparse, exponential) histogram** |
|---|---|---|
| Bucket boundaries | Fixed, chosen at instrumentation time | Automatic, exponential, self-adjusting |
| Series per histogram | 1 per bucket + `_sum` + `_count` | **1 single time series** (buckets are internal) |
| Storage / cardinality | High (N series × label sets) | Low (sparse, only populated buckets stored) |
| Resolution | Whatever you hard-coded | Controlled by `schema` (bucket factor `2^(2^-schema)`) |
| Cross-service alignment | Fragile (`le` sets must match exactly) | Uniform by construction (same schema math) |
| Exposition format | Text or OpenMetrics | Protobuf (native); classic text can be scraped alongside |
| Status | Stable | **Experimental** — server flag `--enable-feature=native-histograms` |
| Query functions | `histogram_quantile` over `le` buckets | `histogram_quantile`, `histogram_fraction`, `histogram_count`, `histogram_sum`, `histogram_avg`, `histogram_stddev`, `histogram_stdvar` |

---

## 5. Instrumentation manifests (uncut)

### 5.1 Go — classic + native in one instrument

```go
package main

import (
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var httpDuration = promauto.NewHistogramVec(
	prometheus.HistogramOpts{
		Name: "http_request_duration_seconds",
		Help: "Duration of HTTP requests in seconds.",

		// --- Classic buckets: a boundary sits exactly on the 0.3s SLO target ---
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2.5, 5, 10},

		// --- Native histogram: enable exponential auto-buckets (factor 1.1 ≈ schema 3) ---
		// The client picks the finest schema whose factor is <= the requested factor.
		NativeHistogramBucketFactor:     1.1,
		NativeHistogramMaxBucketNumber:  160,             // cap sparse-bucket growth
		NativeHistogramMinResetDuration: time.Hour,       // bound memory on runaway spread
	},
	[]string{"method", "route", "code"},
)

func instrument(route string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next(rec, r)
		httpDuration.
			WithLabelValues(r.Method, route, http.StatusText(rec.status)).
			Observe(time.Since(start).Seconds())
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(c int) { s.status = c; s.ResponseWriter.WriteHeader(c) }

func main() {
	http.HandleFunc("/api", instrument("/api", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok"))
	}))
	http.Handle("/metrics", promhttp.Handler())
	http.ListenAndServe(":8080", nil)
}
```

### 5.2 Python — explicit buckets aligned to the same SLO

```python
from prometheus_client import Histogram, start_http_server
import time

# Bucket set MUST match the Go service's boundaries for valid cross-service sum by (le).
HTTP_DURATION = Histogram(
    "http_request_duration_seconds",
    "Duration of HTTP requests in seconds.",
    ["method", "route", "code"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2.5, 5, 10),
)

def handle(method: str, route: str):
    start = time.perf_counter()
    try:
        # ... do work ...
        code = "OK"
    finally:
        HTTP_DURATION.labels(method, route, code).observe(time.perf_counter() - start)

if __name__ == "__main__":
    start_http_server(8080)
```

### 5.3 Prometheus scrape config (`prometheus.yml`) — native histograms enabled

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

# Server must be started with:  --enable-feature=native-histograms
# With that flag, Prometheus negotiates the Protobuf exposition format automatically,
# so native histograms are ingested where the target exposes them.

scrape_configs:
  - job_name: api
    # Also keep the classic _bucket series alongside the native one during migration:
    always_scrape_classic_histograms: true
    static_configs:
      - targets: ["api.default.svc:8080"]
        labels:
          service: api
```

### 5.4 Kubernetes — Deployment + Service + ServiceMonitor (Prometheus Operator)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: shop
  labels: { app: api }
spec:
  replicas: 3
  selector:
    matchLabels: { app: api }
  template:
    metadata:
      labels: { app: api }
    spec:
      containers:
        - name: api
          image: registry.example.com/shop/api:1.8.2
          ports:
            - name: http-metrics
              containerPort: 8080
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: shop
  labels: { app: api }
spec:
  selector: { app: api }
  ports:
    - name: http-metrics
      port: 8080
      targetPort: http-metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api
  namespace: shop
  labels: { release: kube-prometheus-stack }
spec:
  selector:
    matchLabels: { app: api }
  endpoints:
    - port: http-metrics
      interval: 15s
      path: /metrics
```

To ingest native histograms via the Operator, enable the feature on the `Prometheus` CR (protobuf is required for native exposition):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: main
  namespace: monitoring
spec:
  enableFeatures:
    - native-histograms
  scrapeProtocols:
    - PrometheusProto          # native histograms need the protobuf protocol
    - OpenMetricsText1.0.0
    - PrometheusText0.0.4
  serviceMonitorSelector:
    matchLabels: { release: kube-prometheus-stack }
```

### 5.5 Recording + alerting rules (`PrometheusRule`)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: api-latency
  namespace: monitoring
  labels: { release: kube-prometheus-stack, role: alert-rules }
spec:
  groups:
    - name: api.latency.recording
      interval: 30s
      rules:
        # Pre-aggregate buckets ONCE, preserving le, so quantiles are cheap downstream.
        - record: job_route:http_request_duration_seconds_bucket:rate5m
          expr: |
            sum by (job, route, le) (
              rate(http_request_duration_seconds_bucket[5m])
            )

        - record: job_route:http_request_duration_seconds:p99
          expr: |
            histogram_quantile(
              0.99,
              job_route:http_request_duration_seconds_bucket:rate5m
            )

        # SLO good-event ratio: fraction served within the 300ms target.
        - record: job:http_request_slo_ratio:rate5m
          expr: |
              sum by (job) (rate(http_request_duration_seconds_bucket{le="0.3"}[5m]))
            / sum by (job) (rate(http_request_duration_seconds_count[5m]))

    - name: api.latency.alerts
      rules:
        - alert: ApiP99LatencyHigh
          expr: job_route:http_request_duration_seconds:p99 > 0.5
          for: 10m
          labels: { severity: warning }
          annotations:
            summary: "p99 latency > 500ms on {{ $labels.route }}"
            description: "p99 is {{ $value | humanizeDuration }} for job {{ $labels.job }} route {{ $labels.route }}."

        # Multi-window, multi-burn-rate error-budget burn (99.9% target → budget 0.001).
        - alert: ApiLatencySLOBurnFast
          expr: |
            (1 - job:http_request_slo_ratio:rate5m) > (14.4 * 0.001)
            and
            (1 - (
                sum by (job) (rate(http_request_duration_seconds_bucket{le="0.3"}[1h]))
              / sum by (job) (rate(http_request_duration_seconds_count[1h]))
            )) > (14.4 * 0.001)
          for: 2m
          labels: { severity: critical }
          annotations:
            summary: "Fast latency-SLO burn (14.4x) on {{ $labels.job }}"
```

---

## 6. Native histograms — the design lever

Native histograms replace "pick your buckets and hope" with a single self-scaling series. Bucket boundaries are exponential: for a given `schema` s, the growth factor between adjacent buckets is `2^(2^-s)`.

| `schema` | Bucket factor `2^(2^-s)` | Character |
|---|---|---|
| 0 | 2.000 | each bucket doubles the previous |
| 3 | 1.0905 | ≈ 9 % steps (matches client factor 1.1) |
| 5 | 1.0219 | ≈ 2.2 % steps |
| 8 | 1.0027 | very high resolution |

Internally a native histogram carries **positive buckets**, **negative buckets**, and a **zero bucket** (observations within `zero_threshold` of 0). This is why native histograms handle negative values and values spanning many orders of magnitude that classic fixed buckets cannot.

Query functions operate on the native histogram sample directly — **no `le` label**:

```promql
# p99 straight from a native histogram
histogram_quantile(0.99, sum(rate(http_request_duration_seconds[5m])))

# Fraction of requests in [0, 0.3] — the SLO ratio, no manual bucket picking
histogram_fraction(0, 0.3, sum(rate(http_request_duration_seconds[5m])))

# Exact mean, count, sum, stddev
histogram_avg(rate(http_request_duration_seconds[5m]))
histogram_count(rate(http_request_duration_seconds[5m]))
histogram_sum(rate(http_request_duration_seconds[5m]))
histogram_stddev(rate(http_request_duration_seconds[5m]))
```

**Migration pattern:** run `always_scrape_classic_histograms: true` so both representations coexist; dashboards and alerts cut over one panel at a time; drop the classic buckets only after the native version is trusted.

---

## 7. CLI & terminal verification

### 7.1 Read the raw exposition — classic histogram

```console
$ curl -s http://localhost:8080/metrics | grep '^http_request_duration_seconds'
# HELP http_request_duration_seconds Duration of HTTP requests in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.005"} 3
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.01"} 8
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.025"} 19
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.05"} 44
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.1"} 210
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.2"} 940
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.3"} 1088
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.5"} 1180
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="1"} 1195
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="2.5"} 1199
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="5"} 1200
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="10"} 1200
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="+Inf"} 1200
http_request_duration_seconds_sum{method="GET",route="/api",code="OK"} 156.34
http_request_duration_seconds_count{method="GET",route="/api",code="OK"} 1200
```

Sanity checks you can eyeball: buckets are **monotonic non-decreasing**, `le="+Inf"` (1200) **equals `_count`** (1200), and the counts climb steeply through `le="0.2"→"0.3"` telling you the mass of traffic lives around 150–250 ms.

### 7.2 See the negotiated native-histogram protobuf presence

```console
$ curl -s -H 'Accept: application/vnd.google.protobuf;proto=io.prometheus.client.MetricFamily;encoding=delimited' \
       http://localhost:8080/metrics | protoc --decode_raw | head
# (binary protobuf; native histograms are only exposed over this format)

$ promtool query instant http://localhost:9090 \
    'histogram_count(rate(http_request_duration_seconds[5m]))'
http_request_duration_seconds{method="GET", route="/api"} => 80.0 @[1754640000]
```

### 7.3 Evaluate the quantile against the server

```console
$ promtool query instant http://localhost:9090 \
    'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))'
{} => 0.2743 @[1754640000.000]

$ promtool query instant http://localhost:9090 \
    'histogram_quantile(0.99, sum by (le, route) (rate(http_request_duration_seconds_bucket[5m])))'
{route="/api"}   => 0.4821 @[1754640000.000]
{route="/login"} => 0.9210 @[1754640000.000]
```

### 7.4 Lint the rules and unit-test the quantile logic

```console
$ promtool check rules api-latency.rules.yaml
Checking api-latency.rules.yaml
  SUCCESS: 5 rules found
```

`histogram.test.yaml`:

```yaml
rule_files:
  - api-latency.rules.yaml

evaluation_interval: 1m

tests:
  - interval: 1m
    input_series:
      - series: 'http_request_duration_seconds_bucket{job="api", route="/api", le="0.3"}'
        values: '0+30x10'      # 30 obs/min ≤ 300ms
      - series: 'http_request_duration_seconds_bucket{job="api", route="/api", le="+Inf"}'
        values: '0+40x10'      # 40 obs/min total  → 10/min are slow
      - series: 'http_request_duration_seconds_count{job="api", route="/api"}'
        values: '0+40x10'
    promql_expr_test:
      - expr: job:http_request_slo_ratio:rate5m
        eval_time: 5m
        exp_samples:
          - labels: 'job:http_request_slo_ratio:rate5m{job="api"}'
            value: 0.75        # 30/40 within target
```

```console
$ promtool test rules histogram.test.yaml
Unit Testing:  histogram.test.yaml
  SUCCESS
```

---

## 8. Verification & failure-diagnosis guide

| Symptom | Root cause | Fix |
|---|---|---|
| `histogram_quantile(...)` returns **`NaN`** | No `+Inf` bucket in the vector, or `<2` buckets, or 0 observations in the window | Ensure exposition includes `le="+Inf"`; confirm the metric is scraped; widen the range if traffic is sparse |
| p99 is **pinned to the second-highest boundary** and never moves | The real quantile is above your top finite bucket (`+Inf` bucket case) | Add higher buckets (e.g. `20`, `60`) so the tail is measurable |
| Quantile looks **quantised / stair-steps** between two values | Buckets too wide around the quantile; interpolation has nothing to interpolate | Add boundaries near the region of interest; put one exactly on the SLO threshold |
| Cross-service `sum by (le)` gives **wrong / spiky** quantiles | Different services expose **different `le` sets** (e.g. Go vs Python defaults) | Standardise the exact bucket list across all producers of that metric |
| p99 **jumps down after a deploy** then recovers | Buckets are counters; restart reset — you forgot `rate()`/`increase()` | Always `rate(..._bucket[...])` before aggregating |
| p99 is **implausibly low** vs traces | Averaging quantiles: `avg(histogram_quantile(...))` instead of quantile-of-sum | Aggregate buckets first (`sum by (le)`), apply `histogram_quantile` **last** |
| `le="+Inf"` ≠ `_count` | Broken exporter / label-drop rewriting `le` | Inspect raw `/metrics`; check `metric_relabel_configs` isn't stripping `le` |
| Native-histogram queries return empty, classic works | Server started without `--enable-feature=native-histograms`, or target not scraped over protobuf | Enable the feature flag; set `scrapeProtocols` to include `PrometheusProto` |
| Cardinality / TSDB memory blow-up on a histogram | N buckets × high-cardinality labels (e.g. `user_id`, raw `path`) | Drop unbounded labels; reduce buckets; migrate to native histograms |
| Alert flaps at the SLO boundary | Threshold sits between two coarse buckets | Add a bucket boundary exactly at the SLO value, or use `histogram_fraction` on a native histogram |

**Independent count check** (a series must satisfy the histogram invariant on every scrape):

```promql
# Should be exactly 0 everywhere; any non-zero means a broken exporter.
http_request_duration_seconds_count
  - ignoring(le) http_request_duration_seconds_bucket{le="+Inf"}
```

**Grafana heatmap** (bucket-native visualisation of the whole distribution over time):

```promql
sum by (le) (rate(http_request_duration_seconds_bucket[$__rate_interval]))
```
Panel type *Heatmap*, format *Heatmap*, Y-axis unit *seconds* — reads the `le` label as the bucket axis.

---

## 9. Referencias

- Metric types — Histogram & Summary: https://prometheus.io/docs/concepts/metric_types/
- Instrumentation best practices — Histograms and quantile errors: https://prometheus.io/docs/practices/histograms/
- `histogram_quantile()` and native-histogram functions: https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile
- Native histograms concept: https://prometheus.io/docs/concepts/native_histograms/
- Native histograms specification: https://prometheus.io/docs/specs/native_histograms/
- Metric and label naming: https://prometheus.io/docs/practices/naming/
- Go client library (`HistogramOpts`, `DefBuckets`, native options): https://pkg.go.dev/github.com/prometheus/client_golang/prometheus#HistogramOpts
- Python client library (`Histogram`): https://prometheus.github.io/client_python/instrumenting/histogram/
- OpenMetrics specification (histogram exposition): https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
- `promtool` unit testing rules: https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus Operator API (`Prometheus`, `ServiceMonitor`, `PrometheusRule`): https://prometheus-operator.dev/docs/api-reference/api/
- Google SRE Workbook — Alerting on SLOs (multiwindow burn-rate): https://sre.google/workbook/alerting-on-slos/
- PCA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf