# Client Libraries

**PCA Domain 4 — Instrumentation and Exporters · Topic 5.1**
*Exam weight: 4 · Level: SRE / Platform Architect*

---

## 1. The Production Problem: What a Client Library Actually Solves

Prometheus is a **pull-based** system. The server does not receive metrics; it periodically issues an HTTP `GET /metrics` against every target it discovers and parses a plain-text (or protobuf) payload in the *exposition format*. This inverts the usual push/agent model and shifts a hard problem into the application process itself: **the process must, at scrape time, be able to serialize a globally consistent, thread-safe snapshot of every metric it owns, in a byte-for-byte correct format, with sub-millisecond overhead, while serving production traffic.**

Doing this by hand — concatenating strings on a `/metrics` handler — fails in production for concrete, repeatable reasons:

- **Concurrency.** A counter like `http_requests_total` is incremented from thousands of goroutines/threads simultaneously. A naïve `count++` loses updates under contention. The library must provide atomic, lock-free (or sharded-lock) increments.
- **Consistency at scrape time.** A histogram's `_bucket`, `_sum`, and `_count` series must reflect the *same* observations. If a scrape reads `_count` after `_sum` was updated by another thread, `histogram_quantile()` produces impossible values (e.g., a p99 below the p50).
- **Format correctness.** The exposition format has exact rules: `# HELP`/`# TYPE` lines, label escaping, `le`/`quantile` reserved labels, `+Inf` bucket, cumulative bucket counts, base-unit naming. A single malformed line makes Prometheus reject the **entire** scrape (`up == 0` for that target), not just one metric.
- **Lifecycle and registration.** Metrics must be created once, registered exactly once (double-registration panics/raises), and discoverable by a central registry that the HTTP handler walks at scrape time.
- **Cardinality safety.** Label values map 1:1 to time series. Uncontrolled labels (user IDs, request paths, error strings) create a cardinality explosion that OOM-kills both the app and the Prometheus server.

A **client library** is the reusable implementation of all of the above. It gives you the four metric types, a `Registry`, a `Collector` interface, and an HTTP handler that negotiates content type and serializes atomically. Officially maintained libraries exist for **Go, Java/JVM, Python, Ruby, and Rust**; dozens of community libraries cover Node.js, .NET, PHP, C++, Rust, etc.

> Architectural rule of thumb: **instrument in the process that owns the truth.** If your app knows the number, use a client library (direct instrumentation). If the truth lives in a system you *don't* control (a database, the kernel, a NIC), you write an **exporter** — which is itself just a client library plus a custom `Collector` that scrapes the third-party system on demand (Topic covered under Exporters).

---

## 2. Anatomy of a Client Library

Every official library shares the same conceptual model. Learn the model once; the API names differ per language.

```
        ┌──────────────────────────────────────────────┐
        │                Application code                │
        │   counter.Inc()   hist.Observe(0.42)   ...     │
        └───────────────────────┬──────────────────────┘
                                 │ registers
                                 ▼
        ┌──────────────────────────────────────────────┐
        │                   Registry                     │
        │  (default + optional custom registries)        │
        │  holds Collectors, enforces unique names,      │
        │  detects label/type collisions                 │
        └───────────────────────┬──────────────────────┘
                                 │ Collect() at scrape time
                                 ▼
        ┌──────────────────────────────────────────────┐
        │              HTTP exposition handler           │
        │  GET /metrics → negotiate Content-Type →       │
        │  walk registry → serialize atomic snapshot     │
        └───────────────────────┬──────────────────────┘
                                 │ HTTP GET (Accept: ...)
                                 ▼
                          Prometheus server scrape
```

**Key components:**

| Component | Responsibility | Go example | Python example |
|---|---|---|---|
| **Metric** | A single instrument (one series family). | `prometheus.Counter` | `Counter(...)` |
| **MetricVec** | A metric partitioned by label dimensions; one child series per label-value combination. | `CounterVec` | `Counter(..., ["method"])` |
| **Collector** | Anything that can produce metrics on demand via `Collect()`. Metrics are Collectors; custom collectors let you sample external state at scrape time. | `prometheus.Collector` | `Collector` (via `collect()`) |
| **Registry** | Owns Collectors, guarantees name uniqueness, produces the exposition. | `prometheus.NewRegistry()` | `CollectorRegistry()` |
| **Exposition/Handler** | Serializes the registry over HTTP, negotiating text vs OpenMetrics vs protobuf. | `promhttp.HandlerFor(reg, ...)` | `make_wsgi_app` / `start_http_server` |

**Default registry vs. custom registry (production decision).** Libraries ship a global *default registry* pre-loaded with runtime collectors (`go_*`, `process_*` in Go; `process_*`, `python_*` in Python). Convenient, but it is global mutable state: it makes unit tests order-dependent and can leak metrics between logical components. In multi-tenant libraries, sidecars, or when you want a clean `/metrics`, create an **explicit** `Registry` and register only what you own.

---

## 3. The Four Metric Types — Mechanics and Trade-offs

### 3.1 Counter
A monotonically increasing value that resets to 0 only on process restart. Never `Dec()`. You almost never read a counter directly in PromQL — you take `rate()`/`increase()`, which are *reset-aware*. Use for: requests served, errors, bytes sent, tasks completed.

### 3.2 Gauge
A value that goes up and down. Read directly, or with `delta()`/`deriv()`. Use for: in-flight requests, queue depth, temperature, memory in use, replica count.

### 3.3 Histogram
Observations are counted into **cumulative buckets** defined by upper bounds (`le`, "less than or equal"). Exposes three series families: `_bucket{le="..."}` (cumulative counts, including a mandatory `+Inf`), `_sum`, and `_count`. Quantiles are computed **server-side** with `histogram_quantile()` by interpolating within a bucket.

### 3.4 Summary
Also exposes `_sum` and `_count`, but computes **client-side, pre-aggregated φ-quantiles** (`quantile="0.99"`) over a sliding time window. No buckets.

### Histogram vs Summary — the classic exam trade-off

| Property | **Histogram** | **Summary** |
|---|---|---|
| Quantile computed | Server-side, at query time (`histogram_quantile`) | Client-side, streaming estimate |
| **Aggregatable across instances** | **Yes** — buckets are counters, `sum by (le)` is valid | **No** — you cannot average pre-computed quantiles |
| Choose bucket bounds up front | Yes (must know your latency range) | No |
| Quantile accuracy | Bounded by bucket resolution | Configurable error (`objectives`), exact within window |
| Client CPU cost | Cheap (increment a bucket) | More expensive (streaming quantile algorithm) |
| Series per metric (classic) | `#buckets + 2` | `#quantiles + 2` |
| Arbitrary quantile after the fact | Yes (any quantile from buckets) | No (only pre-declared φ) |
| Apdex / SLO threshold counting | Trivial (`le="0.3"` bucket) | Not possible |

**Production guidance:** default to **Histogram**. The single feature that decides most real cases is *aggregatability*: with N replicas behind a load balancer, you want the fleet-wide p99, and only histograms let you do `histogram_quantile(0.99, sum(rate(..._bucket[5m])) by (le))`. Reach for a Summary only when you need an exact quantile on a **single** instance and cannot pre-select buckets.

### 3.5 Native Histograms (Prometheus 2.40+, experimental → stabilizing)
Classic histograms force a cardinality/accuracy trade-off through fixed buckets. **Native (sparse, exponential) histograms** store buckets with an automatically chosen exponential schema (`NativeHistogramBucketFactor` controls resolution, e.g. `1.1` ≈ 10% relative bucket width). One metric, one series, dynamic bucket boundaries, scraped over protobuf or OpenMetrics. `histogram_quantile()` works directly on them. They dramatically cut series cardinality while raising quantile precision — enable when your client library and Prometheus version both support it.

```go
// Go: opt into native histograms alongside classic buckets
prometheus.HistogramOpts{
    Name:                            "myapp_http_request_duration_seconds",
    Help:                            "Latency distribution.",
    Buckets:                         prometheus.DefBuckets, // classic fallback
    NativeHistogramBucketFactor:     1.1,                   // enable native
    NativeHistogramMaxBucketNumber:  160,                   // cap cardinality
    NativeHistogramMinResetDuration: time.Hour,
}
```

---

## 4. Cardinality and Naming — the #1 Way Instrumentation Kills Production

**Every unique combination of a metric name and its label values is a distinct time series.** Series count is the master resource in Prometheus (RAM, head-block size, WAL). A single bad label detonates the server.

```go
// CARDINALITY BOMB — never do this
requests.WithLabelValues(userID, requestPath, err.Error()).Inc()
// userID (10^6) × path (10^4, unbounded) × error string (unbounded) = effectively infinite series
```

**Rules for label design:**
- Labels must be **bounded and low-cardinality**: `method` (≈7), `code` (≈40), `handler` (a *fixed route template*, not the raw URL).
- Never put unbounded values in labels: user IDs, email, full paths, raw SQL, timestamps, error messages, trace IDs (use **exemplars** for those — see §7).
- The metric name identifies *what*; labels identify *dimensions of the same thing*. `http_requests_total{code="500"}` — not `http_500_requests_total`.

**Naming conventions (enforced culturally, linted by `promtool`):**
- `snake_case`, form `namespace_subsystem_name_unit_suffix`.
- Use **base units**: `seconds` (not ms), `bytes` (not KB), `ratio` in `[0,1]`.
- Counters end in `_total`. `_sum`/`_count`/`_bucket` are reserved for histograms/summaries.
- Suffix reflects the unit: `_seconds`, `_bytes`, `_info` (for the info pattern, always value `1`).

| Anti-pattern | Fix |
|---|---|
| `latency_ms` | `request_duration_seconds` |
| `http_requests` (counter without `_total`) | `http_requests_total` |
| label `path="/user/42/orders/9981"` | label `route="/user/:id/orders/:oid"` |
| label `error="connection refused: 10.0.0.1:5432"` | label `error_type="connection_refused"` (bounded enum) |
| one metric per HTTP code | one metric, `code` label |

---

## 5. Direct Instrumentation — Full, Runnable Examples

### 5.1 Go (`client_golang`) — the reference implementation

```go
// main.go
package main

import (
	"math/rand"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Package-level, created once. promauto auto-registers to the default registry.
var (
	httpRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Namespace: "myapp",
			Subsystem: "http",
			Name:      "requests_total",
			Help:      "Total HTTP requests processed, by method and response code.",
		},
		[]string{"method", "code"},
	)

	httpRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Namespace: "myapp",
			Subsystem: "http",
			Name:      "request_duration_seconds",
			Help:      "HTTP request latency distribution in seconds.",
			// DefBuckets = {.005,.01,.025,.05,.1,.25,.5,1,2.5,5,10}
			Buckets: prometheus.DefBuckets,
		},
		[]string{"route"},
	)

	httpInFlight = promauto.NewGauge(
		prometheus.GaugeOpts{
			Namespace: "myapp",
			Subsystem: "http",
			Name:      "in_flight_requests",
			Help:      "HTTP requests currently being served.",
		},
	)

	buildInfo = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Namespace: "myapp",
			Name:      "build_info",
			Help:      "Build metadata; value is always 1. Join on this in PromQL.",
		},
		[]string{"version", "revision", "go_version"},
	)
)

func instrument(route string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpInFlight.Inc()
		defer httpInFlight.Dec()

		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next(sw, r)

		elapsed := time.Since(start).Seconds()
		httpRequestDuration.WithLabelValues(route).Observe(elapsed)
		httpRequestsTotal.WithLabelValues(r.Method, http.StatusText(sw.status)).Inc()
	}
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func handleWork(w http.ResponseWriter, r *http.Request) {
	time.Sleep(time.Duration(rand.Intn(300)) * time.Millisecond)
	w.Write([]byte("ok\n"))
}

func main() {
	buildInfo.WithLabelValues("1.4.2", "abc1234", "go1.22").Set(1)

	http.HandleFunc("/work", instrument("/work", handleWork))
	// promhttp.Handler() serves the DEFAULT registry, negotiating text/OpenMetrics.
	http.Handle("/metrics", promhttp.Handler())
	http.ListenAndServe(":8080", nil)
}
```

```go
// go.mod
module myapp

go 1.22

require github.com/prometheus/client_golang v1.19.1
```

The default registry auto-includes `go_*` (GC, goroutines, memstats) and `process_*` (open FDs, CPU, RSS) collectors — free, and essential for on-call.

### 5.2 Python (`prometheus_client`)

```python
# app.py
import random
import time
from prometheus_client import Counter, Gauge, Histogram, start_http_server

REQUESTS = Counter(
    "myapp_http_requests_total",
    "Total HTTP requests processed.",
    ["method", "code"],
)
LATENCY = Histogram(
    "myapp_http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
)
IN_FLIGHT = Gauge(
    "myapp_http_in_flight_requests",
    "HTTP requests currently being served.",
)


@IN_FLIGHT.track_inprogress()          # decorator manages Inc()/Dec()
@LATENCY.labels(route="/work").time()  # decorator observes wall time
def handle_work():
    time.sleep(random.random() * 0.3)
    REQUESTS.labels(method="GET", code="200").inc()
    return "ok"


if __name__ == "__main__":
    # Spins up a dedicated WSGI server exposing /metrics on :8000
    start_http_server(8000)
    while True:
        handle_work()
```

```
# requirements.txt
prometheus-client==0.20.0
```

### 5.3 Java (JVM — `client_java` 1.x, `io.prometheus.metrics`)

```java
// App.java
import io.prometheus.metrics.core.metrics.Counter;
import io.prometheus.metrics.core.metrics.Histogram;
import io.prometheus.metrics.exporter.httpserver.HTTPServer;
import io.prometheus.metrics.instrumentation.jvm.JvmMetrics;

public class App {
    static final Counter requests = Counter.builder()
        .name("myapp_http_requests_total")
        .help("Total HTTP requests processed.")
        .labelNames("method", "code")
        .register();

    static final Histogram latency = Histogram.builder()
        .name("myapp_http_request_duration_seconds")
        .help("HTTP request latency in seconds.")
        .classicUpperBounds(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10)
        .nativeInitialSchema(3)          // opt into native histogram
        .labelNames("route")
        .register();

    public static void main(String[] args) throws Exception {
        JvmMetrics.builder().register();  // jvm_* + process_* collectors

        // one observation
        long t0 = System.nanoTime();
        // ... handle work ...
        latency.labelValues("/work").observe((System.nanoTime() - t0) / 1e9);
        requests.labelValues("GET", "200").inc();

        HTTPServer.builder().port(8080).buildAndStart(); // serves /metrics
        Thread.currentThread().join();
    }
}
```

### Client-library feature comparison (for choosing / auditing)

| Feature | Go | Java (1.x) | Python | Ruby | Rust |
|---|---|---|---|---|---|
| Officially maintained | ✅ | ✅ | ✅ | ✅ | ✅ |
| Native histograms | ✅ | ✅ | partial | ⏳ | ⏳ |
| Exemplars | ✅ | ✅ | ✅ | ⏳ | partial |
| Default runtime metrics | `go_*`,`process_*` | `jvm_*`,`process_*` | `process_*`,`python_*` | `process_*` | opt-in |
| Multiprocess mode | N/A (single proc) | N/A | ✅ (gunicorn/uWSGI) | ✅ | N/A |
| Push (Pushgateway) | ✅ | ✅ | ✅ | ✅ | ✅ |

> **Python gotcha:** under a pre-forking server (gunicorn, uWSGI) each worker is a separate process with its own registry, so a scrape hits a random worker and counters look non-monotonic. Fix with **multiprocess mode**: set `PROMETHEUS_MULTIPROC_DIR` to a shared tmpfs and use `MultiProcessCollector`. This is a frequent production incident.

---

## 6. The Exposition Format (what your library actually emits)

A scrape of the Go example above:

```
$ curl -s http://localhost:8080/metrics
# HELP myapp_build_info Build metadata; value is always 1. Join on this in PromQL.
# TYPE myapp_build_info gauge
myapp_build_info{go_version="go1.22",revision="abc1234",version="1.4.2"} 1
# HELP myapp_http_in_flight_requests HTTP requests currently being served.
# TYPE myapp_http_in_flight_requests gauge
myapp_http_in_flight_requests 3
# HELP myapp_http_request_duration_seconds HTTP request latency distribution in seconds.
# TYPE myapp_http_request_duration_seconds histogram
myapp_http_request_duration_seconds_bucket{route="/work",le="0.005"} 0
myapp_http_request_duration_seconds_bucket{route="/work",le="0.01"} 2
myapp_http_request_duration_seconds_bucket{route="/work",le="0.05"} 41
myapp_http_request_duration_seconds_bucket{route="/work",le="0.1"} 118
myapp_http_request_duration_seconds_bucket{route="/work",le="0.25"} 372
myapp_http_request_duration_seconds_bucket{route="/work",le="0.5"} 511
myapp_http_request_duration_seconds_bucket{route="/work",le="+Inf"} 511
myapp_http_request_duration_seconds_sum{route="/work"} 74.83
myapp_http_request_duration_seconds_count{route="/work"} 511
# HELP myapp_http_requests_total Total HTTP requests processed, by method and response code.
# TYPE myapp_http_requests_total counter
myapp_http_requests_total{code="OK",method="GET"} 511
# HELP go_goroutines Number of goroutines that currently exist.
# TYPE go_goroutines gauge
go_goroutines 11
# HELP process_resident_memory_bytes Resident memory size in bytes.
# TYPE process_resident_memory_bytes gauge
process_resident_memory_bytes 1.4909e+07
```

**Format rules your library guarantees (and you must not break in exporters):**
- One `# HELP` and one `# TYPE` per metric family, before its samples.
- Bucket counts are **cumulative** and **monotonically non-decreasing**; the final `le="+Inf"` count equals `_count`.
- Label values are UTF-8, with `\`, `"`, and `\n` escaped.
- Optional trailing millisecond timestamp (rarely used; let Prometheus timestamp at scrape).

**Content-Type negotiation** (the handler picks based on the scraper's `Accept`):

| Format | Content-Type | Notes |
|---|---|---|
| Text (`0.0.4`) | `text/plain; version=0.0.4; charset=utf-8` | Universal default |
| OpenMetrics | `application/openmetrics-text; version=1.0.0; charset=utf-8` | Adds exemplars, `# EOF`, `_created` |
| Protobuf | `application/vnd.google.protobuf; ...` | Required for scraping native histograms |

OpenMetrics differs by ending the stream with a literal `# EOF` and encoding exemplars inline:

```
myapp_http_request_duration_seconds_bucket{route="/work",le="0.1"} 118 # {trace_id="4bf92f3577b34da6"} 0.087 1723200000.123
# EOF
```

---

## 7. Exemplars — Linking Metrics to Traces

Exemplars attach a high-cardinality *sample* (a trace ID) to a *single observation* inside a bucket, without turning it into a label (so no cardinality explosion). This is the bridge from a p99 latency spike to the exact trace that caused it.

```go
// Go: requires OpenMetrics negotiation on the handler
httpRequestDuration.WithLabelValues("/work").(prometheus.ExemplarObserver).
    ObserveWithExemplar(elapsed, prometheus.Labels{"trace_id": traceID})

// Handler must allow exemplars:
http.Handle("/metrics", promhttp.HandlerFor(
    prometheus.DefaultGatherer,
    promhttp.HandlerOpts{EnableOpenMetrics: true},
))
```

Prometheus must be started with `--enable-feature=exemplar-storage` to retain them.

---

## 8. Pushgateway — Instrumenting Batch Jobs

Pull breaks for **short-lived batch jobs** that exit before any scrape can reach them. The Pushgateway is a metrics cache that such a job pushes to on completion, and Prometheus scrapes the gateway instead.

```
   ephemeral cron job ──push──▶  Pushgateway  ◀──scrape── Prometheus
   (exits in 8s)                 (persists last push)
```

```python
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

registry = CollectorRegistry()
g = Gauge("batch_last_success_unixtime", "Last successful run.", registry=registry)
g.set_to_current_time()

# 'job' becomes the job label; grouping key isolates instances
push_to_gateway("pushgateway.monitoring.svc:9091",
                job="nightly_etl", registry=registry)
```

```
$ echo "batch_records_processed 42815" \
    | curl --data-binary @- http://pushgateway:9091/metrics/job/nightly_etl/instance/pod-7
```

**Pushgateway is a footgun — know the failure modes (exam-relevant):**

| Trap | Consequence | Mitigation |
|---|---|---|
| Metrics **persist forever** after push | Dead job's metrics look "live"; alerts never clear | Delete group on job end (`DELETE .../metrics/job/...`); use `push_time_seconds` in alerts |
| No `up` metric per job | You cannot detect a job that never ran | Alert on `time() - batch_last_success_unixtime > threshold` |
| Single instance | SPOF and a fan-in bottleneck | Keep it small; **only** for service-level batch jobs |
| Misused as a push agent | Loses all pull-model health signals | Use exporters/direct pull for anything long-lived |

> Rule: use Pushgateway **only** for service-level batch jobs, never as a general "push my app metrics" endpoint.

---

## 9. Kubernetes: Full, Uncut Manifests

Two scraping mechanisms. **Prometheus Operator** (`ServiceMonitor`/`PodMonitor` CRDs) is the production standard; legacy **pod annotations** work with vanilla Prometheus `kubernetes_sd`.

### 9.1 Deployment + Service + ServiceMonitor (Operator)

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: apps
  labels:
    app.kubernetes.io/name: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: myapp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: myapp
    spec:
      containers:
        - name: myapp
          image: registry.example.com/myapp:1.4.2
          ports:
            - name: http-metrics      # named port referenced by the ServiceMonitor
              containerPort: 8080
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          readinessProbe:
            httpGet: { path: /metrics, port: http-metrics }
            initialDelaySeconds: 5
            periodSeconds: 10
---
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: apps
  labels:
    app.kubernetes.io/name: myapp
spec:
  selector:
    app.kubernetes.io/name: myapp
  ports:
    - name: http-metrics
      port: 8080
      targetPort: http-metrics
---
# servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp
  namespace: apps
  labels:
    release: kube-prometheus-stack   # MUST match Prometheus.spec.serviceMonitorSelector
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: myapp   # selects the Service above
  namespaceSelector:
    matchNames: [apps]
  endpoints:
    - port: http-metrics              # matches Service port NAME, not number
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      scheme: http
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
      metricRelabelings:
        # drop noisy Go GC series to save cardinality
        - sourceLabels: [__name__]
          regex: go_gc_duration_seconds.*
          action: drop
```

### 9.2 PodMonitor (no Service needed)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: myapp
  namespace: apps
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: myapp
  podMetricsEndpoints:
    - port: http-metrics
      interval: 15s
      path: /metrics
```

### 9.3 Legacy annotation-based (vanilla Prometheus)

```yaml
# in the Pod template metadata:
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
```

### Discovery mechanism trade-offs

| Mechanism | Needs Operator | Needs a Service | Granularity | Best for |
|---|---|---|---|---|
| **ServiceMonitor** | ✅ | ✅ | Per Service endpoint | Standard app instrumentation |
| **PodMonitor** | ✅ | ❌ | Per Pod | Headless/StatefulSet, no Service |
| **Annotations** | ❌ | ❌ | Per Pod | Vanilla Prometheus, legacy setups |

---

## 10. CLI Verification & Failure Diagnosis

**Step 1 — Does the endpoint serve valid, well-formed output?**

```
$ curl -s http://localhost:8080/metrics | head -n 5
# HELP myapp_build_info Build metadata; value is always 1. Join on this in PromQL.
# TYPE myapp_build_info gauge
myapp_build_info{go_version="go1.22",revision="abc1234",version="1.4.2"} 1

$ curl -s http://localhost:8080/metrics | wc -l
187
```

**Step 2 — Lint with `promtool` (catches naming/format violations before Prometheus does):**

```
$ curl -s http://localhost:8080/metrics | promtool check metrics
myapp_http_requests_total counter metric should have "_total" suffix   # (already ok example)
latency_ms non-histogram and non-summary metric with "_ms" suffix; use base unit "seconds"
myapp_queue_size no help text
```

A clean pass is silent (exit 0). Wire this into CI so a bad metric never ships.

**Step 3 — Negotiate OpenMetrics / verify exemplars:**

```
$ curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' \
    http://localhost:8080/metrics | grep -A0 '# {'
myapp_http_request_duration_seconds_bucket{route="/work",le="0.1"} 118 # {trace_id="4bf9..."} 0.087 1723200000.123
```

**Step 4 — Confirm the target is UP in Prometheus:**

```
$ curl -s 'http://prometheus:9090/api/v1/query?query=up{job="myapp"}' | jq '.data.result'
[
  {
    "metric": { "job": "myapp", "instance": "10.1.2.3:8080", "node": "worker-2" },
    "value": [ 1723200015.0, "1" ]
  }
]
```

`up == 1` means the scrape succeeded and the format parsed. `up == 0` with the target present means it was reached but failed (bad format, timeout, non-200). A **missing** target means service discovery didn't select it.

**Step 5 — Inspect scrape health and errors:**

```
$ curl -s 'http://prometheus:9090/api/v1/query?query=scrape_samples_scraped{job="myapp"}' \
    | jq '.data.result[0].value[1]'
"187"

# Series produced by this job (cardinality watch)
$ curl -s 'http://prometheus:9090/api/v1/query?query=count({job="myapp"})' \
    | jq '.data.result[0].value[1]'
"42"
```

**Step 6 — Was the target even discovered? (kubectl / targets API):**

```
$ curl -s http://prometheus:9090/api/v1/targets \
    | jq '.data.activeTargets[] | select(.labels.job=="myapp") | {health, scrapeUrl, lastError}'
{
  "health": "up",
  "scrapeUrl": "http://10.1.2.3:8080/metrics",
  "lastError": ""
}

$ kubectl -n monitoring logs deploy/prometheus -c prometheus | grep -i myapp | tail -3
```

### Troubleshooting matrix

| Symptom | Root cause | Diagnosis | Fix |
|---|---|---|---|
| Target missing from Prometheus | ServiceMonitor label ≠ `serviceMonitorSelector`, or namespace not watched | `kubectl get servicemonitor -A --show-labels`; check `Prometheus.spec.serviceMonitorSelector` | Add matching `release:` label / correct `namespaceSelector` |
| `up == 0`, `lastError: server returned HTTP 404` | Wrong `path` or `port` in the monitor | `curl` the pod IP directly | Fix `path`/named `port` |
| `up == 0`, "text format parsing error" | Malformed exposition (hand-rolled handler, bad escaping) | `curl … | promtool check metrics` | Use the client library; never concatenate strings |
| Counter "goes backwards" | Multiprocess server (gunicorn) without multiproc mode | Scrape twice, compare | Set `PROMETHEUS_MULTIPROC_DIR` + `MultiProcessCollector` |
| `duplicate metrics collector registration attempted` (panic/raise) | Metric created inside a request handler, not once at init | Stack trace at registration | Create metrics once at package/module load |
| Prometheus OOM after deploy | Cardinality bomb from an unbounded label | `topk(10, count by (__name__)({...}))` | Drop the label; use `metricRelabelings` to `drop`/`labeldrop` |
| p99 latency query is empty | Buckets never crossed (all obs > max `le`) or wrong `le` aggregation | inspect `_bucket` series | Re-choose buckets; `sum by (le)` before `histogram_quantile` |
| Batch metrics never clear | Pushgateway retains last push | `curl pushgateway:9091/metrics` | `DELETE` the group; alert on `push_time_seconds` |

---

## 11. Reference Architecture Checklist (Production)

1. **One registry per logical component**; default registry only for simple single-purpose services.
2. **Metrics defined once** at init, never inside handlers.
3. **Histograms over summaries** unless you need single-instance exact quantiles.
4. **Bounded labels only**; route templates not raw paths; error *types* not error strings.
5. **Base units** (`_seconds`, `_bytes`), `_total` on counters, `promtool check metrics` in CI.
6. **`/metrics` behind a readiness probe** and, in hostile environments, an auth proxy / network policy — the endpoint leaks internal topology.
7. **Exemplars + OpenMetrics** to bridge to traces; enable `exemplar-storage` server-side.
8. **Pushgateway only for service-level batch jobs**, always paired with a `last_success` staleness alert.
9. **Native histograms** where supported to cut cardinality and sharpen quantiles.
10. **Scrape yourself first**: verify with `curl` + `promtool` before blaming service discovery.

---

## Referencias

- Prometheus — Client libraries (official list & overview): https://prometheus.io/docs/instrumenting/clientlibs/
- Prometheus — Writing client libraries (spec for library authors): https://prometheus.io/docs/instrumenting/writing_clientlibs/
- Prometheus — Metric types (Counter, Gauge, Histogram, Summary): https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Exposition formats & content negotiation: https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — Metric and label naming best practices: https://prometheus.io/docs/practices/naming/
- Prometheus — Instrumentation best practices: https://prometheus.io/docs/practices/instrumentation/
- Prometheus — Histograms and summaries (aggregation & `histogram_quantile`): https://prometheus.io/docs/practices/histograms/
- Prometheus — Native histograms: https://prometheus.io/docs/specs/native_histograms/
- Go client library (`client_golang`): https://github.com/prometheus/client_golang · https://pkg.go.dev/github.com/prometheus/client_golang/prometheus
- Python client library (`client_python`): https://github.com/prometheus/client_python · Multiprocess mode: https://prometheus.github.io/client_python/multiprocess/
- Java client library (`client_java`): https://github.com/prometheus/client_java · https://prometheus.github.io/client_java/
- Ruby client library: https://github.com/prometheus/client_ruby
- Rust client library: https://github.com/prometheus/client_rust
- Pushgateway (usage & anti-patterns): https://github.com/prometheus/pushgateway · https://prometheus.io/docs/practices/pushing/
- Exemplars & OpenMetrics: https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage · https://openmetrics.io/
- Prometheus Operator — ServiceMonitor / PodMonitor API: https://prometheus-operator.dev/docs/operator/api/ · https://github.com/prometheus-operator/prometheus-operator
- `promtool` (check metrics): https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- PCA curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf