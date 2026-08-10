# PCA 5.2 — Instrumentation

> **Domain:** Instrumentation and Exporters · **Exam weight:** 4
> **Profile:** SRE / Platform Architect — production-grade direct instrumentation with Prometheus client libraries.

Instrumentation is the discipline of emitting telemetry *from inside the code you own*. It is the boundary between "monitoring a black box from the outside with an exporter" and "the application describing its own behavior in a machine-readable contract." This topic is about that contract: the four metric types, the exposition format, naming and label discipline, client-library internals, and the failure modes that only appear at production scale.

---

## 1. Motivation and the production architectural problem

### 1.1 The observability gap direct instrumentation closes

An exporter (node_exporter, blackbox_exporter, mysqld_exporter) can only report what a system *externally exposes*: `/proc`, an admin socket, a health probe. It cannot see the semantics of *your* request path — which handler served a request, whether the business transaction committed, how long the p99 checkout took, how deep the internal work queue is. Those are properties only the process itself knows. **Direct instrumentation** makes the process publish them.

The architectural decision is this: Prometheus is a **pull-based** system. Your application does not send metrics anywhere. It maintains an in-memory registry of metrics and exposes them over HTTP at `/metrics` in a text exposition format. A Prometheus server *scrapes* that endpoint on an interval (typically 15–60 s), samples the current values, and stores them as time series.

```
┌────────────────────────────────────────────────────────────┐
│  Application process                                         │
│                                                              │
│   business code ──increments──▶ in-process metric registry   │
│                                    │                         │
│                                    │ render on demand        │
│                                    ▼                         │
│                               GET /metrics  (text format)    │
└──────────────────────────────────────┬─────────────────────┘
                                        │ scrape every 15s
                                        ▼
                              ┌───────────────────┐
                              │  Prometheus server │──▶ TSDB
                              └───────────────────┘
```

This has three consequences that dominate every design decision in this topic:

1. **Metrics are sampled, not streamed.** A counter incremented 10,000 times between two scrapes is observed as a single delta. The client never sends per-event data — it keeps running aggregates. This is why counters are monotonic and why you compute `rate()` server-side.
2. **Cardinality is the cost.** Every unique combination of metric name + label set is a separate time series with its own ~1–3 bytes/sample of storage, its own index entry, and its own memory in the head block. Instrumentation decisions made in a single line of application code multiply across every scrape target and live for the retention period. A label with unbounded values (a user ID, a raw URL path, a UUID) is the single most common way to take down a Prometheus server.
3. **The endpoint must be cheap and always available.** `/metrics` is scraped by potentially many servers, is on the critical path of alerting, and must respond even when the app is degraded. Rendering it must not lock business-critical structures or allocate unboundedly.

### 1.2 What "good instrumentation" must guarantee

| Property | Why it matters in production | Failure if violated |
|---|---|---|
| **Aggregatable** | Metrics from N replicas must sum/average correctly across the fleet | Client-side quantiles (Summary) can't be re-aggregated → fleet p99 is meaningless |
| **Bounded cardinality** | Series count must be predictable and finite | Head block OOM, scrape timeouts, index bloat |
| **Stable schema** | Dashboards and alerts reference names/labels | Renaming a metric silently breaks every alert |
| **Base units** | PromQL, dashboards, and humans expect seconds/bytes | Mixing ms and s produces wrong SLO math |
| **Cheap to render** | `/metrics` is on the alerting critical path | Scrape timeout → target marked `down` → false alerts |

The rest of this document is how each of these is achieved concretely.

---

## 2. The four metric types — mechanics and trade-offs

Prometheus client libraries expose exactly four core metric types. Choosing correctly is the highest-leverage instrumentation decision.

### 2.1 Comparative table

| Type | Value semantics | On restart | Client work | Exposed time series | Correct PromQL | Aggregatable across instances |
|---|---|---|---|---|---|---|
| **Counter** | Monotonically increasing float | Resets to 0 | O(1) increment | 1 (`_total`) | `rate()`, `increase()`, `irate()` | ✅ yes |
| **Gauge** | Arbitrary up/down float | Value is arbitrary | O(1) set/add/sub | 1 | raw value, `delta()`, `deriv()` | ✅ (sum/avg/max, contextual) |
| **Histogram** | Cumulative bucket counters + sum + count | All reset to 0 | O(log n) bucket find | N buckets + `_sum` + `_count` | `histogram_quantile()` over `rate(_bucket)` | ✅ yes (buckets are additive) |
| **Summary** | Client-computed φ-quantiles + sum + count | Quantiles reset | O(streaming quantile est.) | N quantiles + `_sum` + `_count` | read `{quantile=...}` directly | ❌ **quantiles cannot be re-aggregated** |

### 2.2 Counter

A **Counter** represents a cumulative total that only ever increases (or resets to zero on process restart). Requests served, errors, bytes processed, tasks completed. You *never* graph the raw counter value — you graph its per-second rate. Prometheus detects the reset (a decrease) and compensates, so `rate()` over a restart is still correct.

```go
requestsTotal := promauto.NewCounterVec(
    prometheus.CounterOpts{
        Namespace: "myapp",
        Name:      "http_requests_total",   // MUST end in _total
        Help:      "Total HTTP requests, by method, handler and status code.",
    },
    []string{"method", "handler", "code"},
)
// in the handler:
requestsTotal.WithLabelValues("GET", "/orders", "200").Inc()
```

**Anti-pattern:** using a Gauge you increment manually to count events. You lose reset detection and `increase()` correctness. If it only goes up, it is a Counter.

### 2.3 Gauge

A **Gauge** is a snapshot of something that goes up and down: in-flight requests, queue depth, temperature, memory in use, connection pool size. It is the only type where the *instantaneous value* is meaningful.

```go
inflight := promauto.NewGauge(prometheus.GaugeOpts{
    Namespace: "myapp",
    Name:      "http_inflight_requests",
    Help:      "In-flight HTTP requests right now.",
})
inflight.Inc()          // request start
defer inflight.Dec()    // request end
// or set an observed value:
queueDepth.Set(float64(len(workQueue)))
```

**Design caution:** a Gauge sampled at scrape time misses spikes between scrapes. If you care about the *peak* queue depth, a Gauge undercounts; consider a `_max` companion gauge you reset each scrape window, or a Histogram of observed depths.

### 2.4 Histogram vs Summary — the central trade-off

Both measure distributions (latency, response size). The difference is *where the quantile is computed*, and it is the most tested distinction in this domain.

- **Histogram** counts observations into pre-defined, **cumulative** buckets (`le` = "less than or equal"). It ships raw bucket counts. Quantiles are computed **server-side** at query time with `histogram_quantile()`. Because bucket counts are simple additive integers, you can `sum()` buckets across all replicas and *then* compute a fleet-wide quantile — this is correct.
- **Summary** computes φ-quantiles **client-side** using a streaming estimator over a sliding time window, and ships the already-computed quantile values. You cannot average a p99 from instance A with a p99 from instance B and get the fleet p99 — that math is invalid. Summaries also cannot expose an arbitrary quantile you didn't pre-configure.

| Dimension | Histogram | Summary |
|---|---|---|
| Quantile computed | Server-side at query time | Client-side, pre-configured φ |
| Aggregatable across instances | ✅ yes — sum buckets, then `histogram_quantile` | ❌ no — quantiles are non-additive |
| Arbitrary quantiles after the fact | ✅ any quantile the buckets can resolve | ❌ only the φ you chose |
| Accuracy | Bounded by bucket boundaries | High per-instance (streaming estimate) |
| CPU on client | Cheap (bucket increment) | More expensive (quantile estimation) |
| Time series count | 1 per bucket + `_sum` + `_count` | 1 per quantile + `_sum` + `_count` |
| Bucket/quantile choice | Must pick buckets up front | Must pick quantiles up front |
| Best for | Latency/size in a fleet, SLOs | Single-instance, exact per-instance quantiles |

**Production rule of thumb:** in Kubernetes, where you run N replicas behind a Service, **default to Histogram**. The whole point is fleet-wide latency, and only a Histogram gives you an aggregatable p99. Reach for Summary only when you have a single instance or genuinely need a precise per-instance quantile you'll never aggregate.

```go
// Histogram — buckets in SECONDS, tuned to the SLO you care about
requestDuration := promauto.NewHistogramVec(
    prometheus.HistogramOpts{
        Namespace: "myapp",
        Name:      "http_request_duration_seconds",
        Help:      "HTTP request latency in seconds.",
        // Default is prometheus.DefBuckets; override to bracket your SLO thresholds.
        Buckets:   []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
    },
    []string{"method", "handler"},
)
timer := prometheus.NewTimer(requestDuration.WithLabelValues("GET", "/orders"))
defer timer.ObserveDuration()
```

Choosing buckets is a real engineering task: buckets must bracket the latencies you SLO on. If your SLO is "99% under 300 ms," you *must* have a bucket boundary at or near `0.3`, or `histogram_quantile` interpolates linearly inside the bucket and your p99 is a guess.

### 2.5 Native (sparse) histograms

Classic histograms force a bucket/cardinality trade-off up front. **Native histograms** (a.k.a. sparse histograms, GA-track feature, `--enable-feature=native-histograms` on the server; supported in `client_golang` via `NativeHistogramBucketFactor`) use exponential buckets with a resolution factor, storing them as a single, compact, dynamically-bucketed series. This gives high-resolution quantiles at a fraction of the cardinality and lets you change resolution without re-instrumenting.

```go
requestDuration := promauto.NewHistogramVec(
    prometheus.HistogramOpts{
        Name:                            "myapp_http_request_duration_seconds",
        Help:                            "Latency, native histogram.",
        NativeHistogramBucketFactor:     1.1,   // ~10% relative bucket width
        NativeHistogramMaxBucketNumber:  160,   // cap bucket count to bound memory
        NativeHistogramMinResetDuration: time.Hour,
    },
    []string{"method", "handler"},
)
```

**Trade-off:** native histograms need Prometheus 2.40+ with the feature enabled, remote-write protocol v2 (or 1.x with native support), and tooling (Grafana) that understands them. On the exam and in most current production estates, classic bucketed histograms are still the baseline; native histograms are the direction of travel.

---

## 3. The exposition format — the wire contract

`/metrics` renders a UTF-8 text format. Understanding it byte-for-byte is what lets you debug a scrape.

```
# HELP myapp_http_requests_total Total HTTP requests, by method, handler and status code.
# TYPE myapp_http_requests_total counter
myapp_http_requests_total{method="GET",handler="/orders",code="200"} 14027
myapp_http_requests_total{method="GET",handler="/orders",code="500"} 3
# HELP myapp_http_request_duration_seconds HTTP request latency in seconds.
# TYPE myapp_http_request_duration_seconds histogram
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.005"} 8000
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.01"}  10120
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.025"} 12500
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.05"}  13400
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.1"}   13900
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.25"}  14010
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.5"}   14025
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="1"}     14029
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="2.5"}   14030
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="5"}     14030
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="10"}    14030
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="+Inf"}  14030
myapp_http_request_duration_seconds_sum{method="GET",handler="/orders"}   1893.4
myapp_http_request_duration_seconds_count{method="GET",handler="/orders"} 14030
# HELP myapp_http_inflight_requests In-flight HTTP requests right now.
# TYPE myapp_http_inflight_requests gauge
myapp_http_inflight_requests 7
```

Format invariants you must know:

- Each series is `metric_name{label="value",...} value [timestamp]`. The timestamp is almost always omitted — the scrape assigns it.
- `# HELP` and `# TYPE` are metadata lines, one per metric family. `# TYPE` is one of `counter`, `gauge`, `histogram`, `summary`, `untyped`.
- Histogram buckets are **cumulative**: `le="0.01"` includes everything ≤ 10 ms, so bucket counts are non-decreasing, and the last bucket `le="+Inf"` equals `_count`.
- A histogram of name `X` synthesizes series `X_bucket`, `X_sum`, `X_count`. A summary synthesizes `X{quantile=...}`, `X_sum`, `X_count`. **You cannot also define a plain metric named `X_count`** — it collides.
- **OpenMetrics** is the IETF-standardized, stricter successor to this format (mandatory `# EOF`, unit metadata, native exemplar support). Clients negotiate it via the `Accept` header; Prometheus scrapes it transparently.

---

## 4. Naming and labels — the schema discipline

This is where instrumentation succeeds or fails operationally. The rules are from the official [naming best practices](https://prometheus.io/docs/practices/naming/).

### 4.1 Metric naming

- `snake_case`, prefixed with a single-word application/library **namespace**: `myapp_http_requests_total`.
- Suffix carries the **unit**, and units are **base units**: `_seconds` (not `_milliseconds`), `_bytes` (not `_kilobytes`), `_ratio` for 0–1.
- Counters end in `_total`.
- The name identifies *one logical thing* — labels differentiate dimensions of it. `myapp_http_requests_total{code="200"}`, **not** `myapp_http_200_requests_total`.

### 4.2 Labels and the cardinality bomb

Every distinct label-value combination is a new time series. Total series for a metric ≈ product of the cardinalities of its labels × number of scrape targets.

```
series = replicas × card(method) × card(handler) × card(code)
       = 20       × 4            × 30             × 6         = 14,400 series
```

That is fine. Now add `user_id` (500,000 users): the metric alone becomes **7.2 billion** potential series. It will OOM the head block.

| Good label (bounded) | Bad label (unbounded) |
|---|---|
| `method` (GET/POST/… ~7) | `user_id`, `email`, `session_id` |
| `code` (2xx/3xx/4xx/5xx, or ~40 codes) | full request path with IDs (`/orders/8f3a...`) |
| `handler` (route template, ~dozens) | raw SQL query text |
| `queue` name, `region`, `pod` (bounded by fleet) | timestamps, UUIDs, unbounded IDs |

**Rules of thumb:**
- Keep total cardinality per instrumented target in the low thousands. A single metric family in the tens of thousands of series is a smell.
- Use the **route template** (`/orders/{id}`), never the concrete path (`/orders/8f3a`).
- Never put a value into a label if you can't enumerate the set in advance.
- If you truly need per-entity granularity, that is a job for logs or traces (high-cardinality by design), not metrics.

The `pod`, `instance`, `namespace`, `job` labels are usually **target labels** attached by Prometheus at scrape time via relabeling / service discovery — you do **not** hard-code them into your instrumentation.

---

## 5. Client library internals

### 5.1 Registries and collectors

A client library maintains a **Registry** — a set of `Collector`s. When `/metrics` is scraped, the registry calls `Collect()` on each collector and streams the results. Most metrics you create are auto-registered into the **default registry** (via `promauto` in Go), but production code often uses an explicit registry for isolation and testability.

```go
package main

import (
    "log"
    "net/http"
    "time"

    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/collectors"
    "github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
    // Explicit registry — no globals, testable, isolates library metrics.
    reg := prometheus.NewRegistry()

    // Add the standard Go runtime + process collectors explicitly.
    reg.MustRegister(
        collectors.NewGoCollector(),
        collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
    )

    requests := prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Namespace: "myapp",
            Name:      "http_requests_total",
            Help:      "Total HTTP requests by method, handler, code.",
        },
        []string{"method", "handler", "code"},
    )
    duration := prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Namespace: "myapp",
            Name:      "http_request_duration_seconds",
            Help:      "HTTP request latency in seconds.",
            Buckets:   []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
        },
        []string{"method", "handler"},
    )
    reg.MustRegister(requests, duration)

    mux := http.NewServeMux()
    mux.HandleFunc("/orders", func(w http.ResponseWriter, r *http.Request) {
        timer := prometheus.NewTimer(duration.WithLabelValues(r.Method, "/orders"))
        defer timer.ObserveDuration()
        // ... business logic ...
        w.WriteHeader(http.StatusOK)
        requests.WithLabelValues(r.Method, "/orders", "200").Inc()
    })

    // Expose the registry. EnableOpenMetrics lets exemplars flow.
    mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{
        EnableOpenMetrics: true,
    }))

    srv := &http.Server{
        Addr:         ":8080",
        Handler:      mux,
        ReadTimeout:  5 * time.Second,
        WriteTimeout: 10 * time.Second,
    }
    log.Fatal(srv.ListenAndServe())
}
```

The **Go collector** (`go_*` metrics: goroutines, GC pauses, heap) and **process collector** (`process_*`: open FDs, CPU, resident memory) are effectively free instrumentation you should always register.

### 5.2 The multiprocess problem (Python / prefork servers)

Prometheus assumes one process per scrape target holds all the state. This breaks under prefork WSGI servers (gunicorn with multiple workers, uWSGI): each worker has its own registry, but the scrape hits *one* worker chosen by the load balancer, so you'd see one worker's numbers, randomly. The Python client solves this with **multiprocess mode**: workers write metric state to memory-mapped files in a shared directory, and a special collector aggregates them at scrape time.

```python
# gunicorn.conf.py
import os
from prometheus_client import multiprocess

def child_exit(server, worker):
    # Clean up a dead worker's mmap files so counters don't leak.
    multiprocess.mark_process_dead(worker.pid)
```

```python
# app.py
import os
from prometheus_client import (
    Counter, Histogram, CollectorRegistry, multiprocess,
    generate_latest, CONTENT_TYPE_LATEST,
)

REQUESTS = Counter(
    "myapp_http_requests_total",
    "Total HTTP requests.",
    ["method", "handler", "code"],
)
LATENCY = Histogram(
    "myapp_http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["method", "handler"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
)

def metrics_app(environ, start_response):
    # Aggregate across all worker mmaps at scrape time.
    registry = CollectorRegistry()
    multiprocess.MultiProcessCollector(registry)
    data = generate_latest(registry)
    start_response("200 OK", [("Content-Type", CONTENT_TYPE_LATEST)])
    return [data]
```

Run it with the shared directory exported to every worker:

```bash
$ export PROMETHEUS_MULTIPROC_DIR=/var/run/prometheus
$ mkdir -p "$PROMETHEUS_MULTIPROC_DIR"
$ gunicorn -c gunicorn.conf.py -w 8 -b 0.0.0.0:8080 app:wsgi
```

**Gotcha:** in multiprocess mode, Gauges need an explicit aggregation mode (`multiprocess_mode='livesum' | 'liveall' | 'min' | 'max'`), and the `process_*` / `go_*` style runtime collectors don't aggregate meaningfully. The directory must be on `tmpfs`/emptyDir and cleaned between restarts.

---

## 6. Complete Kubernetes infrastructure (unabridged manifests)

The following is a production-shaped deployment: an instrumented app, a Service, a Prometheus Operator `ServiceMonitor` for scraping, a `PodMonitor` alternative, and a Pushgateway for batch jobs.

### 6.1 Instrumented application Deployment + Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: shop
  labels:
    app.kubernetes.io/name: orders-api
    app.kubernetes.io/part-of: shop
spec:
  replicas: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: orders-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: orders-api
      annotations:
        # Annotation-based scraping (used when NOT running the Operator).
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: orders-api
          image: registry.example.com/shop/orders-api:1.8.2
          ports:
            - name: http
              containerPort: 8080
            - name: metrics          # dedicated named port is best practice
              containerPort: 8080
          env:
            - name: PROMETHEUS_MULTIPROC_DIR
              value: /var/run/prometheus
          volumeMounts:
            - name: prom-multiproc
              mountPath: /var/run/prometheus
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: prom-multiproc
          emptyDir:
            medium: Memory       # tmpfs — mmap files must not hit disk
---
apiVersion: v1
kind: Service
metadata:
  name: orders-api
  namespace: shop
  labels:
    app.kubernetes.io/name: orders-api
spec:
  selector:
    app.kubernetes.io/name: orders-api
  ports:
    - name: http
      port: 80
      targetPort: http
    - name: metrics                 # ServiceMonitor selects THIS named port
      port: 8080
      targetPort: metrics
```

### 6.2 ServiceMonitor (Prometheus Operator) — the idiomatic path

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: orders-api
  namespace: shop
  labels:
    # Must match the Prometheus CR's serviceMonitorSelector, or it is ignored.
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: orders-api
  namespaceSelector:
    matchNames:
      - shop
  endpoints:
    - port: metrics                 # references the Service port NAME, not number
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      scheme: http
      honorLabels: false
      relabelings:
        # Attach a stable "pod" target label from the discovered pod name.
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
      metricRelabelings:
        # Drop a chatty Go GC series family to control cardinality.
        - sourceLabels: [__name__]
          regex: go_gc_duration_seconds.*
          action: drop
```

### 6.3 PodMonitor (when there is no Service, e.g. StatefulSet peers)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: orders-worker
  namespace: shop
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: orders-worker
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
```

### 6.4 Raw Prometheus scrape config (no Operator)

If you run Prometheus without the Operator, the equivalent of the annotations above is a `kubernetes_sd_configs` job with relabeling:

```yaml
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # Only scrape pods opting in via annotation.
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      # Override the scrape path from annotation, default /metrics.
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      # Override host:port from the annotated port.
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      # Promote useful metadata to real labels.
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
```

### 6.5 Pushgateway — for batch/ephemeral jobs only

Direct instrumentation assumes a long-lived process that Prometheus can pull from. A cron/batch job may finish before any scrape happens. The **Pushgateway** is a cache the job *pushes* its final metrics to, and Prometheus scrapes the gateway.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pushgateway
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels: { app: pushgateway }
  template:
    metadata:
      labels: { app: pushgateway }
    spec:
      containers:
        - name: pushgateway
          image: prom/pushgateway:v1.9.0
          args:
            - --persistence.file=/data/pushgateway.store
            - --persistence.interval=5m
          ports:
            - { name: http, containerPort: 9091 }
          volumeMounts:
            - { name: data, mountPath: /data }
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-reconcile
  namespace: shop
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: reconcile
              image: registry.example.com/shop/reconcile:1.2.0
              command: ["/bin/sh", "-c"]
              args:
                - |
                  start=$(date +%s)
                  ./reconcile.sh
                  end=$(date +%s)
                  cat <<EOF | curl --data-binary @- \
                    http://pushgateway.monitoring:9091/metrics/job/nightly_reconcile/instance/$HOSTNAME
                  # TYPE reconcile_last_success_timestamp_seconds gauge
                  reconcile_last_success_timestamp_seconds $end
                  # TYPE reconcile_duration_seconds gauge
                  reconcile_duration_seconds $((end - start))
                  # TYPE reconcile_rows_processed_total counter
                  reconcile_rows_processed_total 48213
                  EOF
```

**Pushgateway anti-patterns (must know):** it is **not** a way to convert Prometheus to push for long-running services, it does **not** expire pushed metrics on its own (a stale batch metric persists until overwritten or deleted), and it flattens the `instance` label (metrics carry `pushgateway`'s target labels unless you set `honor_labels: true`). Use it only for **service-level batch jobs**, and pair success metrics with an alert on `time() - reconcile_last_success_timestamp_seconds`.

---

## 7. CLI commands and real terminal output

### 7.1 Inspect the raw exposition

```bash
$ kubectl -n shop port-forward deploy/orders-api 8080:8080 &
$ curl -s localhost:8080/metrics | grep -E '^myapp_http_requests_total'
myapp_http_requests_total{code="200",handler="/orders",method="GET"} 14027
myapp_http_requests_total{code="500",handler="/orders",method="GET"} 3
myapp_http_requests_total{code="201",handler="/orders",method="POST"} 902
```

### 7.2 Validate format and lint with promtool

```bash
$ curl -s localhost:8080/metrics | promtool check metrics
myapp_http_request_duration_seconds: non-histogram/summary metric "myapp_http_request_duration_seconds_sum" ... OK
$ echo $?
0
```

`promtool check metrics` catches naming violations (missing `_total`, non-base units, illegal characters, `_sum`/`_count` collisions) — wire it into CI against a golden `/metrics` dump.

### 7.3 Confirm the target is up and being scraped

```bash
$ curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[]
           | select(.labels.job=="orders-api")
           | [.scrapeUrl, .health, .lastScrape, .lastScrapeDuration] | @tsv'
http://10.244.2.31:8080/metrics   up   2026-08-10T14:03:11.412Z   0.008
http://10.244.2.44:8080/metrics   up   2026-08-10T14:03:09.887Z   0.011
http://10.244.3.9:8080/metrics    up   2026-08-10T14:03:12.004Z   0.007
http://10.244.1.77:8080/metrics   up   2026-08-10T14:03:10.550Z   0.009
```

### 7.4 Query the instrumented signals (RED method)

```bash
# Request rate per handler over the last 5 minutes:
$ curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum by (handler) (rate(myapp_http_requests_total[5m]))' \
  | jq -r '.data.result[] | [.metric.handler, .value[1]] | @tsv'
/orders   23.47

# Error ratio (5xx / all):
$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=
    sum(rate(myapp_http_requests_total{code=~"5.."}[5m]))
  / sum(rate(myapp_http_requests_total[5m]))' \
  | jq -r '.data.result[0].value[1]'
0.000213

# Fleet-wide p99 latency — only correct because it is a Histogram:
$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=
    histogram_quantile(0.99,
      sum by (le) (rate(myapp_http_request_duration_seconds_bucket[5m])))' \
  | jq -r '.data.result[0].value[1]'
0.184
```

### 7.5 Count cardinality before it bites

```bash
# Series count for one metric family:
$ curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=count(myapp_http_requests_total)' \
  | jq -r '.data.result[0].value[1]'
312

# Top metrics by series count (via TSDB status):
$ curl -s 'http://localhost:9090/api/v1/status/tsdb' \
  | jq -r '.data.seriesCountByMetricName[] | [.value, .name] | @tsv' | head
184320  myapp_http_request_duration_seconds_bucket
 45201  container_cpu_usage_seconds_total
 14400  myapp_http_requests_total
```

That first line — a histogram bucket family at 184k series — is the alarm bell: check for an accidental high-cardinality label.

---

## 8. Verification and failure diagnosis

### 8.1 Diagnostic decision tree

```
Target missing / no data in Prometheus?
│
├─ Is the target listed under /api/v1/targets?
│   ├─ NO  → discovery/selector problem
│   │        · ServiceMonitor label ≠ Prometheus serviceMonitorSelector
│   │        · Service port has no NAME, or name ≠ endpoints[].port
│   │        · namespaceSelector excludes the app namespace
│   │        · (annotation mode) prometheus.io/scrape != "true"
│   │
│   └─ YES → check .health
│       ├─ down + "connection refused"  → app not listening on that port
│       ├─ down + "context deadline exceeded" → /metrics too slow → scrapeTimeout
│       ├─ down + 404                    → wrong path (/metrics vs /actuator/prometheus)
│       ├─ down + 401/403                → auth/mTLS required, no bearer/TLS config
│       └─ up but no series              → metric never incremented, or wrong name
│
├─ Series exist but values look wrong?
│   ├─ Counter graphed raw (sawtooth on restart) → wrap in rate()/increase()
│   ├─ p99 impossibly flat / capped     → SLO threshold outside bucket range
│   ├─ Fleet p99 nonsensical            → used Summary; can't aggregate quantiles
│   └─ Duplicate/last-worker values      → Python prefork w/o multiprocess mode
│
└─ Prometheus itself unhealthy (OOM, slow)?
    └─ scrape_samples_scraped / TSDB status → runaway cardinality label
```

### 8.2 The self-observability metrics (scrape health)

Prometheus attaches synthetic metrics to every scrape. Alert on these:

| Metric | Meaning | Alert on |
|---|---|---|
| `up` | 1 if scrape succeeded, 0 if failed | `up == 0` |
| `scrape_duration_seconds` | How long `/metrics` took to render | approaching `scrapeTimeout` |
| `scrape_samples_scraped` | Series returned this scrape | sudden jump → cardinality leak |
| `scrape_samples_post_metric_relabeling` | Series kept after relabel drops | verify drops actually apply |
| `scrape_series_added` | New series churn per scrape | high churn → label with unstable value |

```bash
# Which targets are down right now:
$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=up == 0' \
  | jq -r '.data.result[] | [.metric.job, .metric.instance] | @tsv'
orders-api   10.244.3.9:8080

# Targets whose scrape is dangerously close to timing out:
$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=scrape_duration_seconds > 0.8 * scrape_samples_limit' 2>/dev/null

# Cardinality-leak canary — a target whose series count exploded:
$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=topk(5, scrape_samples_scraped)' \
  | jq -r '.data.result[] | [.value[1], .metric.job, .metric.instance] | @tsv'
187650  orders-api   10.244.2.31:8080   ← 100x the others: leak
1874    orders-api   10.244.2.44:8080
1871    orders-api   10.244.3.9:8080
```

### 8.3 Common failures and their fix

| Symptom | Root cause | Fix |
|---|---|---|
| `up == 0`, "connection refused" | metrics server not started / wrong port | expose `/metrics` on the container port the Service names |
| Target absent entirely (Operator) | ServiceMonitor label ≠ `serviceMonitorSelector` | add the label the Prometheus CR selects on |
| Target absent, port mismatch | Service port has no `name`, or name ≠ `endpoints.port` | name the Service port; reference the name |
| `context deadline exceeded` | `/metrics` renders slowly (huge cardinality, locks) | reduce series; raise `scrapeTimeout` as stopgap; render lock-free |
| p99 flat at a bucket edge | SLO threshold not bracketed by a bucket | add a bucket boundary near the SLO value |
| Fleet quantile wrong | used Summary, aggregated its `{quantile}` series | switch to Histogram + `histogram_quantile` |
| Values jump around per scrape | Python prefork, no multiprocess mode | enable `PROMETHEUS_MULTIPROC_DIR` + `MultiProcessCollector` |
| Counter resets look like drops | graphing raw counter | always `rate()`/`increase()` |
| Series keep growing forever | unbounded label (user_id, raw path, UUID) | drop the label; use route templates; move to logs/traces |
| Batch job metric never appears | short-lived process finishes before scrape | push to Pushgateway with a job/instance grouping |
| Stale batch metric never clears | Pushgateway does not expire | DELETE the group on job start; alert on last-success timestamp |

### 8.4 Correlating metrics to traces — exemplars

An **exemplar** attaches a sampled trace ID to a specific histogram observation, letting you jump from "the p99 latency bucket spiked" to the exact trace. Requires OpenMetrics exposition and `--enable-feature=exemplar-storage` on the server.

```go
// Go: record an observation with an exemplar carrying the trace ID.
if obs, ok := duration.WithLabelValues("GET", "/orders").(prometheus.ExemplarObserver); ok {
    obs.ObserveWithExemplar(elapsed.Seconds(),
        prometheus.Labels{"trace_id": traceID})
}
```

```
# Exposition (OpenMetrics) — exemplar after the '#':
myapp_http_request_duration_seconds_bucket{handler="/orders",method="GET",le="0.5"} 14025 # {trace_id="a1b2c3d4"} 0.42 1.7e9
```

---

## 9. Instrumentation methodologies (what to instrument)

Deciding *which* metrics to emit is as important as the mechanics. Two canonical, complementary methods:

| Method | Applies to | Signals | Metric types |
|---|---|---|---|
| **RED** (Rate, Errors, Duration) | request-driven services | request rate, error rate, latency distribution | Counter (rate, errors), Histogram (duration) |
| **USE** (Utilization, Saturation, Errors) | resources (CPU, disk, queue) | how full, how backed-up, error count | Gauge (utilization/saturation), Counter (errors) |

A well-instrumented service exposes RED for its request path and USE for its internal resources (thread pools, connection pools, queues). Concretely, minimum viable instrumentation for an HTTP service is exactly the three metrics in the Go example above: `*_requests_total` (Counter → Rate + Errors) and `*_request_duration_seconds` (Histogram → Duration), plus an in-flight Gauge for saturation.

---

## References

- Prometheus — Instrumentation best practices: https://prometheus.io/docs/practices/instrumentation/
- Prometheus — Metric and label naming: https://prometheus.io/docs/practices/naming/
- Prometheus — Metric types (Counter, Gauge, Histogram, Summary): https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- Prometheus — Exposition formats: https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — Writing client libraries (guidelines): https://prometheus.io/docs/instrumenting/writing_clientlibs/
- Prometheus — Pushing metrics / Pushgateway usage: https://prometheus.io/docs/practices/pushing/
- Pushgateway project (README, when to use / not use): https://github.com/prometheus/pushgateway
- Go client library (`client_golang`): https://github.com/prometheus/client_golang and https://pkg.go.dev/github.com/prometheus/client_golang/prometheus
- Python client library (incl. multiprocess mode): https://github.com/prometheus/client_python
- Native histograms (design and status): https://prometheus.io/docs/specs/native_histograms/
- OpenMetrics specification: https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
- Exemplars: https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage and https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exemplars
- Prometheus Operator — ServiceMonitor / PodMonitor API: https://prometheus-operator.dev/docs/operator/design/
- `promtool check metrics`: https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- PCA curriculum (Instrumentation and Exporters domain): https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf