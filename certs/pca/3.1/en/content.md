# 3.1 Metrics

> **Domain:** Observability Concepts / Prometheus Fundamentals · **Exam weight:** 3
> **Level:** Production SRE / Platform Architect

---

## 1. Motivation: the architectural problem metrics solve

A production platform running thousands of pods across dozens of nodes emits an
effectively infinite stream of events. You cannot store, index, or query every
event at every layer and still answer "is the checkout service healthy *right
now*?" in under a second. This is the core tension of observability at scale:
**fidelity versus cost and query latency.**

Metrics are the answer to one specific slice of that problem: a **metric is a
numeric measurement of a system, sampled at regular intervals and aggregated
over dimensions.** Instead of "user 8831 got HTTP 500 on `/checkout` at
12:04:07.812", a metric records "the `checkout` handler returned 34 `5xx`
responses in the last 15s". The individual identity is discarded; the *shape* of
the system over time is preserved.

That deliberate loss of per-event identity is precisely what makes metrics
cheap and fast:

- A Prometheus sample compresses to roughly **1–2 bytes on disk** (Gorilla /
  double-delta + XOR-of-floats encoding). A structured log line is hundreds of
  bytes to kilobytes.
- Metrics are **pre-aggregated by dimension** (labels), so a query over a
  month of data touches compact, ordered chunks instead of scanning raw events.
- They are **predictable in cardinality** — *if* you design them correctly.
  This "if" is the single biggest operational failure mode and gets its own
  section (§6).

The architectural role of metrics inside the observability triad:

| Signal | Question it answers | Cardinality profile | Cost per unit info | Retention |
|---|---|---|---|---|
| **Metrics** | *Is it broken? How broken? Trending which way?* | Bounded, low | Very low | Long (weeks–years) |
| **Logs** | *What exactly happened in this event?* | Unbounded, high | Medium–high | Medium (days–weeks) |
| **Traces** | *Where in the request path did latency/error occur?* | Very high (per-request) | High | Short (hours–days), sampled |

The production discipline: **alert and dashboard on metrics, then pivot to logs
and traces for the specific incident.** Metrics tell you *that* the SLO is
burning; the other two tell you *why*. Exemplars (§5) are the bridge that lets a
metric carry a trace ID so the pivot is one click, not a manual correlation.

---

## 2. The Prometheus data model: anatomy of a metric

Every Prometheus metric is a set of **time series**. A time series is uniquely
identified by a **metric name plus a set of key/value label pairs**:

```
<metric_name>{<label_name>="<label_value>", ...}
```

Internally, the metric name is just the reserved label `__name__`. These two
representations are identical:

```
http_requests_total{method="POST", handler="/api/v1/users", code="500"}
{__name__="http_requests_total", method="POST", handler="/api/v1/users", code="500"}
```

A **sample** attached to that series is a `(float64 value, int64 timestamp_ms)`
pair. So the full mental model is:

```
identity  = __name__ + sorted(label set)      # the time series
data      = stream of (timestamp, float64)     # the samples
```

**Critical consequence for design:** *every distinct combination of label values
is a separate time series with its own memory and storage footprint.* Total
series count is the Cartesian product of label cardinalities. Adding a
`user_id` label with 1M users to a metric that already has 5 methods × 20
handlers turns 100 series into 100 *million*. This is not a tuning knob — it is
the defining constraint of the entire system (§6).

Valid metric names match `[a-zA-Z_:][a-zA-Z0-9_:]*` (the colon is **reserved
for recording rules** — never use it in directly-instrumented metrics). Label
names match `[a-zA-Z_][a-zA-Z0-9_]*`; names with `__` prefix are reserved for
Prometheus internals.

---

## 3. The four metric types

Prometheus client libraries expose four types. The type is **advisory metadata**
in the exposition (`# TYPE`) — the server stores everything as float64 series —
but choosing the wrong type produces meaningless queries.

### 3.1 Counter

A **monotonically increasing** cumulative value that **resets to zero only on
process restart**. Examples: total requests served, total bytes sent, total
errors.

You **never graph the raw value** of a counter — its absolute number is
meaningless (it depends on how long the process has been up). You always apply a
rate function, which also transparently handles the restart-to-zero reset:

```promql
rate(http_requests_total[5m])          # per-second average over the window
increase(http_requests_total[1h])      # total increase over the window
```

By convention (and *required* by OpenMetrics) counters end in `_total`.

### 3.2 Gauge

A value that can **go up and down**. Examples: current memory usage, queue
depth, number of in-flight requests, temperature. Gauges are graphed directly
and support functions that assume arbitrary movement:

```promql
node_memory_MemAvailable_bytes                 # instantaneous value
delta(cpu_temp_celsius[1h])                     # change over window
predict_linear(node_filesystem_free_bytes[6h], 4*3600)   # extrapolate 4h ahead
```

**Design rule of thumb:** if `rate()` of it would ever be meaningful, it's a
counter; if you care about its current level, it's a gauge.

### 3.3 Histogram

A histogram samples observations (typically request durations or response
sizes) into **cumulative, pre-configured buckets**, and also exposes a running
sum and count. One logical histogram produces multiple series:

- `<name>_bucket{le="<upper_bound>"}` — one **counter per bucket**, cumulative:
  `le="0.5"` counts all observations ≤ 0.5s (including everything below it).
- `<name>_sum` — a counter of the sum of all observed values.
- `<name>_count` — a counter of the number of observations (identical to the
  `le="+Inf"` bucket).

Because buckets are counters, quantiles are computed **server-side at query
time** with `histogram_quantile()`, which linearly interpolates *within* the
matching bucket:

```promql
histogram_quantile(
  0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)
```

The key architectural advantage: **histograms are aggregatable.** Because the
raw counts live server-side, you can `sum by (le)` across every pod, region, or
version and *then* compute a correct global p99. You cannot do this with a
Summary.

The key trade-off: **you must choose bucket boundaries in advance.** A quantile
that falls in a bucket with no boundaries near it interpolates poorly. Buckets
too coarse → inaccurate quantiles; too fine → cardinality cost (each bucket is a
series).

### 3.4 Summary

A summary also tracks a `_sum` and `_count`, but instead of buckets it computes
**φ-quantiles client-side over a sliding time window**:

- `<name>{quantile="0.5"}`, `{quantile="0.9"}`, `{quantile="0.99"}` — precomputed
  quantiles.
- `<name>_sum`, `<name>_count`.

The advantage: the reported quantile is **accurate for that single instance**
without needing well-placed buckets, and querying is cheap (no server-side
interpolation). The fatal limitation: **quantiles cannot be aggregated.** The
average of three pods' p99 is *not* the fleet p99, and there is no correct way to
recover it. In a horizontally-scaled service — i.e. every production service —
this makes summaries far less useful for latency SLOs.

### 3.5 Native histograms (the modern option)

Classic histograms force the cardinality-vs-accuracy trade-off onto the operator
via bucket choice. **Native histograms** (experimental since Prometheus **v2.40**,
Nov 2022; enabled with `--enable-feature=native-histograms`) store observations
in **exponentially-spaced buckets generated automatically at high resolution**,
as a *single* series with a special sample type — dramatically lower cardinality
*and* better accuracy, aggregatable like classic histograms. This is the
strategic direction; classic histograms remain the safe, universally-supported
default for the exam and most production estates today.

### Histogram vs Summary — the decision table

| Dimension | Histogram | Summary |
|---|---|---|
| Quantile computed | Server-side, at query time (`histogram_quantile`) | Client-side, ahead of time |
| **Aggregatable across instances** | **Yes** (`sum by (le)`) | **No** — mathematically incorrect |
| Bucket/quantile choice | Buckets chosen ahead of time | Quantiles (φ) chosen ahead of time |
| Accuracy | Depends on bucket placement + interpolation | Exact for the instance, within configured error |
| Query-time CPU cost | Higher (interpolation over buckets) | Lower (value is precomputed) |
| Client CPU/memory cost | Lower | Higher (sliding-window quantile estimation) |
| Can change target quantile after the fact | **Yes** (any φ, any time) | No — must re-instrument |
| **Recommended default** | **Yes, for latency/size SLOs** | Only single-instance, non-aggregated cases |

**Production guidance:** default to histograms. Reach for a summary only when you
need an exact per-instance quantile that will never be aggregated, and you know
the target φ up front.

---

## 4. Exposition format & OpenMetrics

Prometheus scrapes a plain-text endpoint (conventionally `/metrics`) over HTTP.
The format is line-oriented: optional `# HELP` and `# TYPE` metadata, then
`name{labels} value [timestamp]` sample lines.

A complete, valid exposition covering all four types:

```text
# HELP http_requests_total Total number of HTTP requests processed.
# TYPE http_requests_total counter
http_requests_total{method="GET",handler="/api/v1/users",code="200"} 8027
http_requests_total{method="POST",handler="/api/v1/users",code="201"} 412
http_requests_total{method="POST",handler="/api/v1/users",code="500"} 3

# HELP process_resident_memory_bytes Resident memory size in bytes.
# TYPE process_resident_memory_bytes gauge
process_resident_memory_bytes 5.8236928e+07

# HELP http_request_duration_seconds Request latency in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{handler="/api/v1/users",le="0.05"} 6521
http_request_duration_seconds_bucket{handler="/api/v1/users",le="0.1"}  24054
http_request_duration_seconds_bucket{handler="/api/v1/users",le="0.5"}  33444
http_request_duration_seconds_bucket{handler="/api/v1/users",le="1"}    34001
http_request_duration_seconds_bucket{handler="/api/v1/users",le="+Inf"} 34039
http_request_duration_seconds_sum{handler="/api/v1/users"}   8734.212
http_request_duration_seconds_count{handler="/api/v1/users"} 34039

# HELP rpc_duration_seconds Backend RPC latency in seconds.
# TYPE rpc_duration_seconds summary
rpc_duration_seconds{service="billing",quantile="0.5"}  0.012
rpc_duration_seconds{service="billing",quantile="0.9"}  0.045
rpc_duration_seconds{service="billing",quantile="0.99"} 0.121
rpc_duration_seconds_sum{service="billing"}   17560.473
rpc_duration_seconds_count{service="billing"} 26934
```

Invariants worth memorising for the exam and for debugging:

- The `+Inf` bucket **must** exist and **must equal** `_count`.
- Buckets are **cumulative** and reported sorted by `le`.
- `_sum` can *decrease* between scrapes for histograms/summaries if negative
  observations are possible; otherwise it behaves like a counter.
- Client-supplied timestamps are legal but discouraged — let Prometheus stamp at
  scrape time.

**OpenMetrics** (CNCF, the successor spec Prometheus negotiates via
`Content-Type`) tightens this: mandatory `_total` suffix for counters, an
explicit `# EOF` terminator, optional `# UNIT`, and — crucially — **exemplars**:

```text
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.1"} 24054 # {trace_id="a1b2c3d4e5f6"} 0.087 1699920000.123
```

The trailing `# {trace_id=...} value timestamp` is an exemplar — a pointer from
an aggregate metric bucket to a concrete trace. This is the implementation of
the metrics→traces pivot from §1.

---

## 5. Instrumentation reference (Go client)

Metric types come from the client library, not the server. A minimal but
production-shaped Go instrumentation showing correct type selection, base units,
and a histogram with explicit buckets:

```go
package main

import (
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	// Counter: monotonic, _total suffix, labels bounded to enum-like values.
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "Total number of HTTP requests processed.",
	}, []string{"method", "handler", "code"}) // NEVER user_id / request_id here.

	// Gauge: current in-flight requests, moves up and down.
	inFlight = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "http_requests_in_flight",
		Help: "Number of HTTP requests currently being served.",
	})

	// Histogram: base unit seconds, buckets chosen for the service's SLO band.
	reqDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency in seconds.",
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
	}, []string{"handler"})
)

func instrument(handler string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		inFlight.Inc()
		defer inFlight.Dec()
		start := time.Now()

		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next(rec, r)

		reqDuration.WithLabelValues(handler).Observe(time.Since(start).Seconds())
		httpRequests.WithLabelValues(r.Method, handler,
			http.StatusText(rec.status)).Inc()
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func main() {
	http.HandleFunc("/api/v1/users",
		instrument("/api/v1/users", func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte("ok"))
		}))
	http.Handle("/metrics", promhttp.Handler()) // exposes /metrics
	http.ListenAndServe(":8080", nil)
}
```

**Naming rules baked into the above** (Prometheus naming best practices):

- Use **base units**: `seconds` not `milliseconds`, `bytes` not `kilobytes`.
- Suffix with the unit (`_seconds`, `_bytes`, `_total`).
- Don't encode the metric type in the name (`_count` on a gauge is misleading).
- Keep labels to **bounded, enumerable** dimensions. The `code` and `method`
  labels are safe (finite sets); a `user_id` label is a cardinality bomb.

---

## 6. Cardinality: the production killer

Cardinality is the number of active time series. Prometheus holds every active
series' index and most-recent chunk **in RAM** (the head block). Memory scales
roughly linearly with active series — a common field figure is on the order of a
few KB of head memory per active series once index + chunk overhead is counted.
A cardinality explosion is the single most common way to OOM-kill a Prometheus
server.

Cardinality = **product of label value counts**. Two rules prevent disaster:

1. **Never put an unbounded or high-cardinality value in a label.** Forbidden:
   `user_id`, `email`, `request_id`, `trace_id` (as a label), full URL with IDs,
   raw error messages, timestamps, container IDs, IP addresses in most contexts.
2. **Bound the ones you keep.** Normalise `/api/v1/users/8831` down to the route
   template `/api/v1/users/:id` before it becomes a label value.

Worked example of the trap:

| Metric | method | handler | code | user_id | Series |
|---|---|---|---|---|---|
| Safe | 5 | 20 | 15 | — | **1,500** |
| Bombed | 5 | 20 | 15 | 1,000,000 | **1.5 billion** |

The second row will not fit on any single server. Prometheus provides scrape-time
guardrails (§9) — `sample_limit`, `label_limit`, `target_limit` — to fail a
scrape rather than ingest a bomb, but the real fix is instrumentation
discipline.

---

## 7. Metric methodologies

Three complementary frameworks decide *which* metrics to emit. They are exam
material and daily practice.

| Method | Author / source | Scope | Signals |
|---|---|---|---|
| **Four Golden Signals** | Google SRE Book | User-facing systems | Latency, Traffic, Errors, Saturation |
| **RED** | Tom Wilkie (Grafana) | Request-driven services | **R**ate, **E**rrors, **D**uration |
| **USE** | Brendan Gregg | Resources (CPU, disk, NIC…) | **U**tilization, **S**aturation, **E**rrors |

- **RED** maps almost 1:1 onto the instrumentation in §5: `rate()` of the
  counter = Rate; `code=~"5.."` filtered rate = Errors; the histogram = Duration.
- **USE** is the resource-side complement: use it for nodes, disks, network
  queues — things node_exporter/cAdvisor expose.
- **Golden Signals** is the superset framing for the whole service; Saturation
  ("how full is the most constrained resource") is the one RED omits.

The production pattern: **RED for every service, USE for every resource, Golden
Signals as the dashboard organising principle.**

---

## 8. Complete infrastructure manifests

### 8.1 Prometheus server config (`prometheus.yml`)

Full, syntactically valid config with static targets, Kubernetes SD, scrape-time
cardinality guards, and `metric_relabel_configs` that drops a high-cardinality
label at ingestion:

```yaml
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 15s
  external_labels:
    cluster: prod-eu-west-1
    replica: A

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  # 1) Static target — the app from §5.
  - job_name: users-api
    metrics_path: /metrics
    static_configs:
      - targets: ["users-api.default.svc:8080"]
        labels:
          team: payments
    # Guardrails: reject a scrape that would ingest a cardinality bomb.
    sample_limit: 50000
    label_limit: 30
    label_value_length_limit: 2048
    target_limit: 200

  # 2) Kubernetes pod discovery via annotations.
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # Only scrape pods annotated prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      # Honour a custom metrics path annotation.
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      # Honour a custom port annotation on the pod IP.
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      # Promote useful k8s metadata to real labels.
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
    metric_relabel_configs:
      # Post-scrape: drop a label that would explode cardinality.
      - regex: user_id
        action: labeldrop
      # Drop an entire noisy metric family we do not use.
      - source_labels: [__name__]
        regex: go_gc_duration_seconds.*
        action: drop
```

### 8.2 Instrumented Deployment + Service (annotation-based discovery)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: users-api
  namespace: default
  labels:
    app: users-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: users-api
  template:
    metadata:
      labels:
        app: users-api
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: users-api
          image: registry.example.com/users-api:1.7.2
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
          readinessProbe:
            httpGet: { path: /metrics, port: 8080 }
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: users-api
  namespace: default
  labels:
    app: users-api
spec:
  selector:
    app: users-api
  ports:
    - name: http
      port: 8080
      targetPort: http
```

### 8.3 Prometheus Operator `ServiceMonitor`

The declarative, label-selected alternative to annotation scraping used by
kube-prometheus-stack:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: users-api
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # matched by the Prometheus CR's serviceMonitorSelector
spec:
  namespaceSelector:
    matchNames: ["default"]
  selector:
    matchLabels:
      app: users-api                 # selects the Service in §8.2
  endpoints:
    - port: http                     # references the Service port *name*
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      metricRelabelings:
        - regex: user_id
          action: labeldrop
```

### 8.4 Recording & alerting rules

Recording rules **pre-compute expensive/aggregated expressions** into new series
(note the `:` in the name — reserved for exactly this). This is how you keep
dashboards fast without exploding raw cardinality:

```yaml
groups:
  - name: users-api.rules
    interval: 30s
    rules:
      # Recording rule: fleet-wide error ratio, precomputed.
      - record: job:http_requests:error_ratio5m
        expr: |
          sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))
            /
          sum by (job) (rate(http_requests_total[5m]))

      # Recording rule: aggregatable p99 latency across all pods.
      - record: job:http_request_duration_seconds:p99_5m
        expr: |
          histogram_quantile(0.99,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m])))

      # Alert built on the recording rule.
      - alert: UsersApiHighErrorRatio
        expr: job:http_requests:error_ratio5m{job="users-api"} > 0.05
        for: 10m
        labels:
          severity: page
        annotations:
          summary: "users-api 5xx ratio above 5% for 10m"
          description: "Error ratio is {{ $value | humanizePercentage }}."
```

---

## 9. CLI commands & real terminal output

**Scrape the raw exposition and confirm the format:**

```console
$ curl -s http://users-api.default.svc:8080/metrics | head -n 8
# HELP http_requests_total Total number of HTTP requests processed.
# TYPE http_requests_total counter
http_requests_total{code="OK",handler="/api/v1/users",method="GET"} 8027
http_requests_total{code="Created",handler="/api/v1/users",method="POST"} 412
http_requests_total{code="Internal Server Error",handler="/api/v1/users",method="POST"} 3
# HELP http_request_duration_seconds HTTP request latency in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{handler="/api/v1/users",le="0.005"} 4120
```

**Lint the exposition (naming, type consistency, unit sanity):**

```console
$ curl -s http://localhost:8080/metrics | promtool check metrics
http_request_duration_seconds_bucket use base unit "seconds" ... OK
No metric problems detected
```

**Validate the server config and rule files before reload:**

```console
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
 SUCCESS: 1 rule files found
 SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

Checking /etc/prometheus/rules/users-api.yml
 SUCCESS: 3 rules found
```

**Run a PromQL query from the command line against a live server:**

```console
$ promtool query instant http://localhost:9090 \
    'sum by (code) (rate(http_requests_total{job="users-api"}[5m]))'
{code="Created"} => 4.13333 @[1699920000.000]
{code="Internal Server Error"} => 0.03333 @[1699920000.000]
{code="OK"} => 89.26667 @[1699920000.000]
```

**Compute a p99 the correct (aggregatable) way:**

```console
$ promtool query instant http://localhost:9090 \
    'histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))'
{} => 0.412 @[1699920000.000]
```

**Analyse TSDB cardinality (the diagnostic every SRE reaches for):**

```console
$ promtool tsdb analyze /prometheus
Block ID: 01HF8Z3K2QW7...
Duration: 2h0m0s
Series: 184213
Label names: 142
Postings (unique label pairs): 39204

Highest cardinality metric names:
   88213  http_request_duration_seconds_bucket
   14022  http_requests_total
    9210  go_memstats_alloc_bytes

Highest cardinality labels:
   41022  le
   12894  handler
    9231  pod
```

That first table is exactly how you catch a runaway metric before it OOMs the
server.

---

## 10. Verification & failure diagnostics

### 10.1 Is the target being scraped at all?

The synthetic `up` metric is `1` if the last scrape succeeded, `0` if it failed.
Combine with the `/targets` UI and the scrape-health metrics:

```console
$ promtool query instant http://localhost:9090 'up{job="users-api"}'
{instance="10.1.2.7:8080", job="users-api"} => 1 @[...]
{instance="10.1.2.9:8080", job="users-api"} => 0 @[...]   # <-- this pod is down

$ promtool query instant http://localhost:9090 \
    'scrape_samples_scraped{job="users-api"}'
{instance="10.1.2.7:8080"} => 214 @[...]

$ promtool query instant http://localhost:9090 \
    'scrape_duration_seconds{job="users-api"} > 0.9 * 10'   # near scrape_timeout
```

| Symptom | Likely cause | Confirm with |
|---|---|---|
| `up == 0` | Target unreachable, wrong port, TLS/auth | `/targets` "Error" column; `kubectl exec … curl :8080/metrics` |
| `up == 1` but no series | Wrong `metrics_path`, empty endpoint | `curl /metrics` directly |
| `scrape_samples_scraped` dropped to 0 | `sample_limit` hit, exporter crash | Prometheus log: `sample limit exceeded` |
| `scrape_duration_seconds` ≈ timeout | Exporter too slow / too many series | reduce cardinality, raise `scrape_timeout` |

### 10.2 Cardinality explosion

```console
# Total active series in the head block:
$ promtool query instant http://localhost:9090 'prometheus_tsdb_head_series'
{} => 1842137 @[...]                      # trending up sharply = investigate

# Series count per metric name (find the offender):
$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:3]'
[
  {"name":"http_request_duration_seconds_bucket","value":882130},
  {"name":"apiserver_request_duration_seconds_bucket","value":410221},
  {"name":"container_network_receive_bytes_total","value":98221}
]

# Which label is doing the damage:
$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.labelValueCountByLabelName[:3]'
[
  {"name":"le","value":41022},
  {"name":"id","value":38911},          # <-- unbounded label: cardinality bomb
  {"name":"handler","value":12894}
]
```

Remediation: `labeldrop` the offending label in `metric_relabel_configs`
(§8.1), fix the instrumentation, and enforce `sample_limit`.

### 10.3 Counter resets, staleness, and type mistakes

- **Counter reset:** if you see a latency/rate graph spike to a huge value, a
  process restarted and its counter reset to 0. `rate()`/`increase()` handle
  this automatically — a raw `delta()` on a counter does **not**. Using the
  wrong function is the bug, not the reset.
- **Staleness:** when a series stops being scraped (pod deleted), Prometheus
  inserts a *staleness marker* after ~5 minutes so the series no longer returns
  a value, preventing stale data from being graphed as current. If you see a
  metric "stuck" at an old value, check whether the target is actually gone
  (`up`, `/targets`) versus genuinely flat.
- **Histogram p99 is a straight line / obviously wrong:** your buckets don't
  bracket the real latency (e.g. all traffic lands above the largest finite
  bucket, so everything sits in `+Inf` and interpolation is meaningless). Add
  buckets around the observed latency band and re-instrument.
- **Summary p99 across pods looks too low/high:** you aggregated summary
  quantiles — mathematically invalid. Switch the metric to a histogram.

### 10.4 Quick end-to-end checklist

```console
# 1. Exposition is valid and well-named
curl -s $TARGET/metrics | promtool check metrics
# 2. Config and rules parse
promtool check config /etc/prometheus/prometheus.yml
# 3. Target is up and fresh
promtool query instant $PROM 'up{job="users-api"}'
promtool query instant $PROM 'time() - timestamp(up{job="users-api"}) < 30'
# 4. Cardinality is sane and not trending
promtool query instant $PROM 'prometheus_tsdb_head_series'
promtool tsdb analyze /prometheus | head -n 20
# 5. The SLO query returns a sane value
promtool query instant $PROM 'job:http_request_duration_seconds:p99_5m'
```

---

## 11. References

- Prometheus — Data model: https://prometheus.io/docs/concepts/data_model/
- Prometheus — Metric types: https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Metric & label naming best practices: https://prometheus.io/docs/practices/naming/
- Prometheus — Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- Prometheus — Instrumentation best practices: https://prometheus.io/docs/practices/instrumentation/
- Prometheus — Exposition formats: https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — `histogram_quantile()` function: https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile
- Prometheus — Storage / TSDB: https://prometheus.io/docs/prometheus/latest/storage/
- Prometheus — Native histograms: https://prometheus.io/docs/specs/native_histograms/
- Prometheus — Configuration (`scrape_configs`, relabeling, limits): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — `promtool` / TSDB tooling: https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- OpenMetrics specification: https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
- Prometheus Operator — `ServiceMonitor` / API reference: https://prometheus-operator.dev/docs/api-reference/api/
- Google SRE Book — Monitoring Distributed Systems (Four Golden Signals): https://sre.google/sre-book/monitoring-distributed-systems/
- Brendan Gregg — The USE Method: https://www.brendangregg.com/usemethod.html
- Tom Wilkie / Grafana — The RED Method: https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services-for-monitoring/
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf