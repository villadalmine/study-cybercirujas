# Topic 3.3 — Tracing and Spans

> **PCA domain:** Observability Concepts. **Exam weight:** 3.
> This topic sits at the boundary between the three telemetry signals. For the PCA you are not expected to *operate* a tracing backend, but you *are* expected to understand what a span is, how a trace is assembled from spans, how tracing differs from and complements Prometheus metrics, and — the point examiners actually probe — how **exemplars** bridge a Prometheus histogram to an individual trace.

---

## 1. The production problem: why metrics and logs stop being enough

Consider a request path in a moderately decomposed system:

```
client → api-gateway → checkout → payments → ledger
                          │           └────→ fraud-scoring
                          └────────────────→ inventory → cache → db
```

You have Prometheus. Your dashboards say `http_request_duration_seconds` p99 for `checkout` jumped from 120 ms to 4.2 s at 14:03. That is a **metric**: an aggregate. It tells you *that* checkout is slow and *how often*, but it has structurally discarded the one thing you now need — **which downstream call, on which specific request, consumed the 4 seconds.**

Three things break down at scale, and they are the architectural motivation for tracing:

1. **Aggregation destroys causality.** A histogram bucket is a counter. `checkout p99 = 4.2s` cannot be decomposed into "3.9 s was `fraud-scoring` waiting on a lock." The information was never recorded per-request; it was folded into a bucket on ingest.

2. **Metrics cannot carry high-cardinality identity.** The obvious "fix" — add `user_id`, `request_id`, `downstream_host` as labels — is precisely what the Prometheus data model forbids, because every unique label-set is a new time series. A million users × 20 endpoints × 5 status codes is a cardinality bomb that will OOM your TSDB. Per-request identity does **not** belong in a metric label; it belongs in a trace.

3. **Logs are correlated only by luck.** You *can* log a `request_id` in every service, but you must (a) propagate it correctly across every network hop, (b) index it in every backend, and (c) manually reconstruct ordering and parent/child relationships from timestamps across machines with **clock skew**. Logs give you events; they do not give you the *shape* of the request.

**Distributed tracing** solves this by making the request itself the unit of observation. One request = one **trace**, identified by a `trace_id` that is generated once at the edge and **propagated** through every hop. Each unit of work within that trace is a **span**. The result is a causal tree (technically a DAG) that shows exactly where time went, per request, across process boundaries.

The mental model for the PCA:

| Signal | Question it answers | Cardinality | Scope |
|---|---|---|---|
| **Metrics** (Prometheus) | *How often / how much / how bad, in aggregate?* | Low (bounded label-sets) | Fleet-wide, time-series |
| **Logs** | *What exactly happened at this instant?* | High (free text) | Per-event |
| **Traces** | *Where did this one request spend its time, across services?* | Very high (per-request) | Per-request, cross-service |

They are complementary, not competing. The correct production posture is: **metrics to detect and alert, traces to localize, logs to root-cause.** Exemplars (Section 3) are what let you jump directly from the first to the second.

---

## 2. Anatomy of a span and a trace

### 2.1 The span

A **span** is a single named, timed operation. It is the atomic building block of a trace. Every span carries the following fields (OpenTelemetry data model):

| Field | Meaning | Example |
|---|---|---|
| `trace_id` | 16-byte (128-bit) ID shared by **every** span in the request. Rendered as 32 hex chars. | `4bf92f3577b34da6a3ce929d0e0e4736` |
| `span_id` | 8-byte (64-bit) ID unique to **this** span. 16 hex chars. | `00f067aa0ba902b7` |
| `parent_span_id` | `span_id` of the span that caused this one. Empty ⇒ this is the **root span**. | `a1b2c3d4e5f60718` |
| `name` | Low-cardinality operation name. | `HTTP GET /checkout` |
| `start_time` / `end_time` | Wall-clock, nanosecond precision. Difference = span **duration**. | `2026-08-08T14:03:01.120Z` |
| `kind` | Role in the request (see below). | `SERVER` |
| `status` | `UNSET` / `OK` / `ERROR`. | `ERROR` |
| `attributes` | Key/value metadata (semantic conventions). | `http.response.status_code=500` |
| `events` | Timestamped points *inside* a span (e.g. an exception). | `exception` @ 14:03:05 |
| `links` | Causal references to spans in **other** traces (e.g. a batched job). | → `trace_id=…` |

### 2.2 Span kind — why it matters

`SpanKind` disambiguates the two sides of every network call and is what lets a backend correctly stitch a client span to the corresponding server span:

| Kind | Meaning | Emitted by |
|---|---|---|
| `SERVER` | Handling an inbound request. | The callee (server side of RPC/HTTP). |
| `CLIENT` | Making an outbound synchronous call. | The caller. |
| `PRODUCER` | Enqueuing an async message. | Message publisher. |
| `CONSUMER` | Processing an async message. | Message subscriber. |
| `INTERNAL` | Work with no remote counterpart (default). | In-process functions. |

A single HTTP hop produces **two** spans that share the same logical operation: a `CLIENT` span in the caller and a `SERVER` span in the callee, linked by the propagated context.

### 2.3 The trace

A **trace** is the set of all spans sharing a `trace_id`, assembled into a tree by `parent_span_id`. Visualized as a waterfall:

```
Trace 4bf92f35…  (total 4.21 s)
│
├─ [SERVER]  api-gateway  GET /checkout        ├──────────────────────────────┤  4.21s
│   └─ [CLIENT] api-gateway → checkout          ├─────────────────────────────┤  4.19s
│       └─ [SERVER] checkout  handle            ├────────────────────────────┤   4.15s
│           ├─ [CLIENT] checkout → inventory     ├─┤                             0.08s
│           │   └─ [SERVER] inventory  lookup      ├┤                            0.05s
│           ├─ [CLIENT] checkout → payments       ├──┤                          0.11s
│           └─ [CLIENT] checkout → fraud-scoring        ├──────────────────────┤ 3.94s  ← the culprit
│               └─ [SERVER] fraud-scoring  score          ├────────────────────┤ 3.90s
│                   └─ [INTERNAL] wait_for_model_lock       ├──────────────────┤ 3.88s  ← root cause
```

The waterfall answers the question the metric could not: **3.88 s of the 4.21 s was a lock wait inside `fraud-scoring`.** No amount of metric aggregation would have isolated that individual request; the trace does it structurally.

### 2.4 Context propagation — the mechanism that makes it distributed

A trace only spans services if the `trace_id` and current `span_id` cross the wire. This is **context propagation**, injected into and extracted from carrier headers. The industry standard is **W3C Trace Context**, two HTTP headers:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  └── trace_id (32 hex) ───────────┘ └ parent span ┘ └ flags
             └ version
tracestate:  vendor1=opaqueValue,vendor2=opaqueValue
```

Decoding `traceparent`:
- `00` — version.
- `4bf9…4736` — the 128-bit `trace_id` (constant across the whole request).
- `00f067aa0ba902b7` — the caller's `span_id`, which becomes the callee's `parent_span_id`.
- `01` — `trace-flags`; bit 0 = **sampled**. `01` means "recorded and exported"; `00` means "not sampled".

If any service in the chain fails to propagate `traceparent`, the trace **breaks**: the downstream service starts a *new* root span with a *new* `trace_id`, and you get two disconnected trace fragments instead of one waterfall. This is the single most common tracing failure in production (Section 7).

---

## 3. The bridge to Prometheus: exemplars

This is the PCA-relevant integration and the part examiners care about most. **Exemplars** connect a Prometheus metric sample to a specific trace — closing the "detect with metrics → localize with traces" loop *inside the metric itself*.

An exemplar is an **annotation attached to a metric sample** that records: a value, a timestamp, and a set of labels — conventionally `trace_id` (and often `span_id`). It is exposed in the **OpenMetrics** exposition format after a `#`:

```
# HELP http_request_duration_seconds Request latency
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.1",service="checkout"} 24054
http_request_duration_seconds_bucket{le="0.5",service="checkout"} 24333
http_request_duration_seconds_bucket{le="1",service="checkout"} 24344
http_request_duration_seconds_bucket{le="5",service="checkout"} 24357 # {trace_id="4bf92f3577b34da6a3ce929d0e0e4736",span_id="00f067aa0ba902b7"} 4.19 1.7549e+09
http_request_duration_seconds_bucket{le="+Inf",service="checkout"} 24357
```

Read the last bucket line: the `le="5"` bucket recorded an observation of **4.19 s** at that timestamp, and *that particular observation came from trace `4bf92f35…`*. In Grafana, that exemplar renders as a diamond marker on the latency graph; clicking it deep-links to the trace waterfall in Tempo/Jaeger.

**Key facts for the exam:**

- Exemplars require the **OpenMetrics** format (`Accept: application/openmetrics-text`). The legacy Prometheus text format cannot carry them.
- Prometheus stores exemplars **only** when the feature flag is set: `--enable-feature=exemplar-storage`. Storage is a fixed-size **in-memory circular buffer** (`--storage.exemplars.exemplars-limit`), *not* on-disk TSDB — old exemplars are overwritten; they are for recent-correlation, not long-term history.
- Exemplars are queried through a **dedicated API**, not PromQL evaluation: `GET /api/v1/query_exemplars`.
- Only certain metric types carry them meaningfully — chiefly **histograms** and **counters** — since the whole point is "which request produced this observation."

---

## 4. Comparative tables (trade-offs)

### 4.1 Tracing backends

| | **Jaeger** | **Grafana Tempo** | **Zipkin** |
|---|---|---|---|
| Origin | CNCF (graduated) | Grafana Labs | Original (OpenZipkin) |
| Storage | Cassandra / Elasticsearch / Badger | **Object storage** (S3/GCS/Azure) | Cassandra / ES / MySQL |
| Indexing | Full index on tags/service/operation | **No index by default** — trace-ID lookup + TraceQL scan | Tag index |
| Cost profile | Higher (index storage) | **Lowest** (object storage, no index) | Moderate |
| Query by attributes | Rich | TraceQL (scans blocks) | Basic |
| Metrics correlation | Via exemplars + SPM | **Tight** — native exemplar → trace deep-link, metrics-generator | Via exemplars |
| Best fit | Attribute-heavy search | Cheap high-volume retention, "I have the trace_id" | Legacy / simple |

Tempo's design bet: **you almost always arrive via an exemplar or a known `trace_id`** (from a metric or a log), so paying to index every span is waste. Cheap object storage + trace-ID lookup covers the dominant access pattern.

### 4.2 Context propagation formats

| Format | Header(s) | Standard? | Notes |
|---|---|---|---|
| **W3C Trace Context** | `traceparent`, `tracestate` | **W3C Recommendation** | The default and recommended format; interoperable. |
| **B3 (Zipkin)** | `X-B3-TraceId`, `X-B3-SpanId`, `X-B3-Sampled`, `X-B3-ParentSpanId` (or single `b3`) | De facto | Ubiquitous in older/Istio meshes. |
| **Jaeger** | `uber-trace-id` | Vendor | Legacy Jaeger clients. |
| **Baggage** | `baggage` | W3C | Carries app-level key/values (not IDs) across the trace. |

Mismatched formats between two services silently break the trace — a gateway emitting `b3` to a service configured to read only `traceparent` produces a broken trace. Configure a **composite propagator** (`tracecontext,baggage,b3`) at boundaries.

### 4.3 Sampling strategies

Tracing every request at scale is expensive; **sampling** decides which traces to keep.

| Strategy | When decided | Pro | Con |
|---|---|---|---|
| **Head sampling** | At the root, *before* the request runs (e.g. keep 1%). Decision propagated in `trace-flags`. | Cheap, simple, no buffering. | Blind — decides before knowing if the request errored or was slow. Rare errors get dropped. |
| **Tail sampling** | At the collector, *after* the full trace completes, based on latency/error/attributes. | Keeps the *interesting* traces (errors, slow). | Must buffer all spans of a trace in memory until complete; needs `groupbytrace`; more collector cost. |
| **Probabilistic** | Head, fixed ratio. | Predictable volume. | Same blindness as head. |
| **Rate-limiting** | Head, N traces/sec cap. | Bounds cost hard. | Can starve low-traffic services. |

Production pattern: **head-sample generously (or 100%) → tail-sample at the collector** to keep 100% of errors + slow traces and a small % of the rest.

### 4.4 The three pillars, side by side

| | Metrics | Logs | Traces |
|---|---|---|---|
| Data shape | Numeric time series | Timestamped text/structured events | Span DAG per request |
| Query language | PromQL | LogQL / Lucene / SQL | TraceQL / tag search |
| Storage cost | Low | High (volume) | High (volume) — mitigated by sampling |
| Cardinality tolerance | **Low** | High | Very high |
| Primary use | Alert, trend, SLO | Root-cause detail | Localize latency across services |
| Cross-signal link | — | `trace_id` field | `trace_id` ⇄ exemplar / log |

---

## 5. Complete infrastructure and manifests

The following is a production-shaped, end-to-end tracing pipeline on Kubernetes: **instrumented app → OpenTelemetry Collector → Tempo**, plus a **Prometheus** configured for exemplar storage so metrics deep-link to those traces. Every manifest is complete and syntactically valid.

### 5.1 OpenTelemetry Collector (Deployment + Config)

```yaml
# otel-collector.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-conf
  namespace: observability
data:
  otel-collector-config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      # Buffer complete traces before the tail sampler can judge them.
      groupbytrace:
        wait_duration: 10s
        num_traces: 100000
      # Keep 100% of errors and slow traces, 5% of the rest.
      tail_sampling:
        decision_wait: 12s
        num_traces: 100000
        policies:
          - name: keep-errors
            type: status_code
            status_code: { status_codes: [ERROR] }
          - name: keep-slow
            type: latency
            latency: { threshold_ms: 1000 }
          - name: sample-the-rest
            type: probabilistic
            probabilistic: { sampling_percentage: 5 }
      batch:
        timeout: 5s
        send_batch_size: 1024
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25

    exporters:
      otlp/tempo:
        endpoint: tempo.observability.svc.cluster.local:4317
        tls:
          insecure: true
      # Emit RED metrics derived from spans, for Prometheus to scrape.
      prometheus:
        endpoint: 0.0.0.0:8889
        enable_open_metrics: true      # required so exemplars are exposed
      debug:
        verbosity: basic

    connectors:
      spanmetrics:
        histogram:
          explicit:
            buckets: [10ms, 50ms, 100ms, 500ms, 1s, 5s]
        exemplars:
          enabled: true                # attach trace_id exemplars to the histogram

    service:
      pipelines:
        traces:
          receivers:  [otlp]
          processors: [memory_limiter, groupbytrace, tail_sampling, batch]
          exporters:  [otlp/tempo, spanmetrics]
        metrics/spanmetrics:
          receivers:  [spanmetrics]
          exporters:  [prometheus]
      telemetry:
        metrics:
          address: 0.0.0.0:8888
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
  labels: { app: otel-collector }
spec:
  replicas: 2
  selector:
    matchLabels: { app: otel-collector }
  template:
    metadata:
      labels: { app: otel-collector }
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.109.0
          args: ["--config=/conf/otel-collector-config.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: prom-exp,  containerPort: 8889 }
          resources:
            requests: { cpu: "200m", memory: "400Mi" }
            limits:   { cpu: "1",    memory: "1Gi" }
          volumeMounts:
            - { name: conf, mountPath: /conf }
      volumes:
        - name: conf
          configMap:
            name: otel-collector-conf
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
  labels: { app: otel-collector }
spec:
  selector: { app: otel-collector }
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: 4317 }
    - { name: otlp-http, port: 4318, targetPort: 4318 }
    - { name: prom-exp,  port: 8889, targetPort: 8889 }
```

### 5.2 Grafana Tempo (single-binary, object-storage backed)

```yaml
# tempo.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-conf
  namespace: observability
data:
  tempo.yaml: |
    server:
      http_listen_port: 3200
    distributor:
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
    ingester:
      max_block_duration: 5m
    compactor:
      compaction:
        block_retention: 336h        # 14 days
    storage:
      trace:
        backend: s3
        s3:
          endpoint: minio.observability.svc.cluster.local:9000
          bucket: tempo-traces
          insecure: true
          access_key: ${S3_ACCESS_KEY}
          secret_key: ${S3_SECRET_KEY}
        wal:
          path: /var/tempo/wal
    metrics_generator:
      registry:
        external_labels: { source: tempo }
      storage:
        path: /var/tempo/generator/wal
        remote_write:
          - url: http://prometheus.observability.svc.cluster.local:9090/api/v1/write
    overrides:
      defaults:
        metrics_generator:
          processors: [service-graphs, span-metrics]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tempo
  namespace: observability
spec:
  replicas: 1
  selector: { matchLabels: { app: tempo } }
  template:
    metadata:
      labels: { app: tempo }
    spec:
      containers:
        - name: tempo
          image: grafana/tempo:2.6.0
          args: ["-config.file=/etc/tempo/tempo.yaml"]
          ports:
            - { name: http,      containerPort: 3200 }
            - { name: otlp-grpc, containerPort: 4317 }
          envFrom:
            - secretRef: { name: tempo-s3-credentials }
          volumeMounts:
            - { name: conf, mountPath: /etc/tempo }
      volumes:
        - name: conf
          configMap: { name: tempo-conf }
---
apiVersion: v1
kind: Service
metadata:
  name: tempo
  namespace: observability
spec:
  selector: { app: tempo }
  ports:
    - { name: http,      port: 3200, targetPort: 3200 }
    - { name: otlp-grpc, port: 4317, targetPort: 4317 }
```

### 5.3 Prometheus configured for exemplars

The critical bits: the **feature flag**, the **exemplar buffer limit**, and scraping the collector's OpenMetrics endpoint.

```yaml
# prometheus-deploy.yaml (excerpt — container args + scrape config)
containers:
  - name: prometheus
    image: prom/prometheus:v2.54.1
    args:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--enable-feature=exemplar-storage"          # ← without this, exemplars are dropped
      - "--storage.exemplars.exemplars-limit=100000" # in-memory circular buffer size
      - "--web.enable-remote-write-receiver"         # accept Tempo's remote_write
```

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: otel-spanmetrics
    honor_labels: true
    metrics_path: /metrics
    scheme: http
    static_configs:
      - targets: ["otel-collector.observability.svc.cluster.local:8889"]
```

> Prometheus auto-negotiates OpenMetrics via `Accept: application/openmetrics-text` on scrape; the collector's `prometheus` exporter sets `enable_open_metrics: true`, so exemplars survive the hop.

### 5.4 Application auto-instrumentation (OpenTelemetry Operator CR)

Rather than editing app code, the OTel Operator injects the SDK as a sidecar/init-container via an annotation:

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: checkout-instrumentation
  namespace: shop
spec:
  exporter:
    endpoint: http://otel-collector.observability.svc.cluster.local:4318
  propagators:
    - tracecontext        # W3C traceparent/tracestate
    - baggage
    - b3                  # accept legacy callers too
  sampler:
    type: parentbased_traceidratio
    argument: "1.0"       # head-sample 100%; the collector tail-samples
```

```yaml
# The workload opts in with one annotation:
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-python: "checkout-instrumentation"
    spec:
      containers:
        - name: checkout
          image: registry.internal/shop/checkout:1.8.2
```

---

## 6. CLI commands and real terminal output

### 6.1 Confirm the app is exporting spans (OTLP reachability)

```console
$ kubectl -n shop exec deploy/checkout -- \
    curl -s -o /dev/null -w "%{http_code}\n" \
    http://otel-collector.observability.svc.cluster.local:4318/v1/traces \
    -X POST -H "Content-Type: application/json" -d '{"resourceSpans":[]}'
200
```

### 6.2 Inspect what the collector is doing

```console
$ kubectl -n observability logs deploy/otel-collector | grep -iE "TracesExporter|refused|dropped" | tail -5
2026-08-08T14:03:22.114Z  info  TracesExporter  {"kind": "exporter", "data_type": "traces", "name": "otlp/tempo", "#spans": 1043}
2026-08-08T14:03:37.220Z  info  TracesExporter  {"kind": "exporter", "data_type": "traces", "name": "otlp/tempo", "#spans": 987}

# Collector's own metrics — accepted vs refused spans
$ kubectl -n observability exec deploy/otel-collector -- \
    curl -s localhost:8888/metrics | grep -E "receiver_accepted_spans|exporter_send_failed"
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 1.284501e+06
otelcol_exporter_send_failed_spans{exporter="otlp/tempo"} 0
```

### 6.3 Verify the OpenMetrics exposition carries exemplars

```console
$ kubectl -n observability exec deploy/otel-collector -- \
    curl -s -H 'Accept: application/openmetrics-text' localhost:8889/metrics \
    | grep 'duration.*# {trace_id' | head -1
traces_span_metrics_duration_milliseconds_bucket{service_name="checkout",span_name="HTTP GET /checkout",le="5000"} 24357 # {trace_id="4bf92f3577b34da6a3ce929d0e0e4736",span_id="00f067aa0ba902b7"} 4190.4 1.754901e+09
```

The `# {trace_id=…}` suffix is the exemplar. If it is absent, either `enable_open_metrics` is false or you fetched without the OpenMetrics `Accept` header.

### 6.4 Confirm Prometheus actually stored the exemplar

```console
$ kubectl -n observability port-forward svc/prometheus 9090:9090 &
$ curl -s -G 'http://localhost:9090/api/v1/query_exemplars' \
    --data-urlencode 'query=traces_span_metrics_duration_milliseconds_bucket{service_name="checkout"}' \
    --data-urlencode 'start=2026-08-08T14:00:00Z' \
    --data-urlencode 'end=2026-08-08T14:05:00Z' | python3 -m json.tool
{
    "status": "success",
    "data": [
        {
            "seriesLabels": {
                "__name__": "traces_span_metrics_duration_milliseconds_bucket",
                "service_name": "checkout",
                "span_name": "HTTP GET /checkout"
            },
            "exemplars": [
                {
                    "labels": { "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
                                "span_id":  "00f067aa0ba902b7" },
                    "value": "4190.4",
                    "timestamp": 1754901801.774
                }
            ]
        }
    ]
}
```

If `data` is `[]` here but Section 6.3 showed exemplars, the feature flag is missing (`--enable-feature=exemplar-storage`).

### 6.5 Fetch the actual trace from Tempo by that `trace_id`

```console
$ kubectl -n observability port-forward svc/tempo 3200:3200 &
$ curl -s http://localhost:3200/api/traces/4bf92f3577b34da6a3ce929d0e0e4736 \
    | jq '.batches[].scopeSpans[].spans[] | {name, kind, durMs: ((.endTimeUnixNano|tonumber - (.startTimeUnixNano|tonumber))/1e6)}'
{ "name": "HTTP GET /checkout",       "kind": 2, "durMs": 4210.1 }
{ "name": "checkout → fraud-scoring", "kind": 3, "durMs": 3940.6 }
{ "name": "wait_for_model_lock",      "kind": 1, "durMs": 3880.2 }
{ "name": "checkout → inventory",     "kind": 3, "durMs": 80.4 }
{ "name": "checkout → payments",      "kind": 3, "durMs": 110.7 }
```

(`kind`: 1=INTERNAL, 2=SERVER, 3=CLIENT.) The metric alert → exemplar → trace → root-cause span path is now closed end-to-end.

### 6.6 Search Tempo by attribute (TraceQL)

```console
$ curl -s -G http://localhost:3200/api/search \
    --data-urlencode 'q={ .service.name="checkout" && duration > 1s && status=error }' \
    | jq '.traces[] | {traceID, durMs: .durationMs, root: .rootTraceName}'
{ "traceID": "4bf92f3577b34da6a3ce929d0e0e4736", "durMs": 4210, "root": "HTTP GET /checkout" }
```

### 6.7 Validate collector config before rollout

```console
$ docker run --rm -v "$PWD/otel-collector-config.yaml:/c.yaml" \
    otel/opentelemetry-collector-contrib:0.109.0 validate --config=/c.yaml
$ echo $?
0
```

---

## 7. Verification and failure diagnosis

The dominant tracing failures are **broken traces** (context not propagated) and **missing exemplars** (config gaps). Work them methodically.

### 7.1 Broken trace — the request produces two disconnected `trace_id`s

**Symptom:** in the UI, `checkout`'s span tree ends at a service boundary; the downstream service appears as a *separate* root trace.

**Root cause ladder:**

1. **Header not propagated.** The intermediate service starts a fresh trace. Confirm by capturing headers on the callee:
   ```console
   $ kubectl -n shop exec deploy/fraud-scoring -- \
       sh -c 'nc -l -p 8080 | grep -i traceparent'
   # (no output) → traceparent never arrived → caller isn't injecting it
   ```
2. **Propagator format mismatch.** Caller emits `b3`, callee reads only `tracecontext`. Fix: set a composite propagator (`tracecontext,baggage,b3`) on **both** ends (Section 5.4).
3. **A proxy strips unknown headers.** An ingress/mesh that whitelists headers may drop `traceparent`. Explicitly allow it in the proxy config.

### 7.2 No spans reach the backend at all

```console
# Is the app even exporting? Check the SDK's own error stream.
$ kubectl -n shop logs deploy/checkout | grep -iE "otel|export|4317|4318" | tail
Failed to export spans: connection refused: otel-collector:4317

# → endpoint wrong or collector Service down. Verify:
$ kubectl -n observability get endpoints otel-collector
NAME             ENDPOINTS                             AGE
otel-collector   10.244.1.7:4317,10.244.2.9:4317       6d
```
Empty `ENDPOINTS` ⇒ selector/label mismatch between Service and pods.

### 7.3 Spans arrive but everything is dropped — sampling misconfig

```console
$ kubectl -n observability exec deploy/otel-collector -- \
    curl -s localhost:8888/metrics | grep tail_sampling
otelcol_processor_tail_sampling_count_traces_sampled{policy="sample-the-rest",sampled="false"} 1.9e+06
otelcol_processor_tail_sampling_count_traces_sampled{policy="keep-errors",sampled="true"}      412
```
If `sampled="false"` dominates and even errors are missing, check that `groupbytrace.wait_duration` ≥ your longest request, and `decision_wait` ≥ `wait_duration` — otherwise the tail sampler judges incomplete traces and discards them.

### 7.4 Exemplars missing in Prometheus (metrics are fine)

Binary-search the pipeline:

| Check | Command | If it fails |
|---|---|---|
| Collector emits exemplars? | §6.3 `grep '# {trace_id'` | Set `enable_open_metrics: true`; `spanmetrics.exemplars.enabled: true`. |
| Prometheus scrapes OpenMetrics? | `curl .../targets` → check `scrapePool` | Prometheus negotiates it automatically; verify target is `up`. |
| Feature flag on? | `curl .../api/v1/status/flags \| grep exemplar` | Add `--enable-feature=exemplar-storage`. |
| Stored? | §6.4 `query_exemplars` | If buffer full, raise `--storage.exemplars.exemplars-limit`. |

```console
$ curl -s http://localhost:9090/api/v1/status/flags | jq '."enable-feature", ."storage.exemplars.exemplars-limit"'
"exemplar-storage"
"100000"
```

### 7.5 Clock skew corrupts the waterfall

**Symptom:** child span appears to *start before its parent*, or shows negative duration.

**Cause:** span timestamps are set on each host's local clock; a node with drifting time skews the waterfall. **Diagnosis and fix live in NTP, not the tracing stack:**

```console
$ kubectl get nodes -o name | while read n; do
    echo "== $n =="; kubectl debug $n -it --image=busybox -- date -u 2>/dev/null; done
== node/worker-1 == Sat Aug  8 14:03:07 UTC 2026
== node/worker-2 == Sat Aug  8 14:03:11 UTC 2026   # ← 4s ahead; enforce chrony/NTP
```
Tracing exposes clock skew ruthlessly; treat sub-second NTP sync as a prerequisite for trustworthy traces.

### 7.6 Sanity checklist

- [ ] `otelcol_receiver_accepted_spans` increasing, `otelcol_exporter_send_failed_spans` flat at 0.
- [ ] A known `trace_id` retrievable from the backend (§6.5) and shows **one** connected tree.
- [ ] `traceparent` observed intact on the last hop of the chain.
- [ ] Exemplar visible in OpenMetrics (§6.3) **and** stored in Prometheus (§6.4).
- [ ] `--enable-feature=exemplar-storage` present in Prometheus flags.
- [ ] Node clocks within sub-second of each other.

---

## 8. References

- Prometheus — Exemplars (feature, storage, API): https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- Prometheus — Querying exemplars (`/api/v1/query_exemplars`): https://prometheus.io/docs/prometheus/latest/querying/api/#querying-exemplars
- OpenMetrics specification (exemplar exposition format): https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md#exemplars
- W3C Trace Context (Recommendation — `traceparent`/`tracestate`): https://www.w3.org/TR/trace-context/
- OpenTelemetry — Traces / spans data model & specification: https://opentelemetry.io/docs/concepts/signals/traces/
- OpenTelemetry — Context propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- OpenTelemetry — Sampling (head vs tail): https://opentelemetry.io/docs/concepts/sampling/
- OpenTelemetry Collector — configuration & tail-sampling processor: https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry Operator — auto-instrumentation (`Instrumentation` CR): https://github.com/open-telemetry/opentelemetry-operator
- Grafana Tempo — architecture & configuration: https://grafana.com/docs/tempo/latest/
- Grafana Tempo — TraceQL: https://grafana.com/docs/tempo/latest/traceql/
- Jaeger (CNCF) — architecture: https://www.jaegertracing.io/docs/latest/architecture/
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf