# 2.4 Signals: Tracing, Metrics, Logs

> **Exam domain 2 — OpenTelemetry Signals · weight 6.57 %**
> This chapter treats the three telemetry signals as OpenTelemetry defines them, not as generic "observability pillars." The distinction matters: OTel's contribution is not that traces, metrics and logs exist — they predate it by a decade — but that all three share one **data model**, one **wire protocol (OTLP)**, one **Resource**, and one **context propagation** mechanism, so a single `trace_id` stitches them together. That is the entire architectural bet, and it is what the exam tests.

---

## 1. The production problem: three signals, one incident

A request enters an ingress gateway, fans out to `checkout`, which calls `payments`, which calls a third-party API and writes to Postgres. Latency spikes to p99 = 4 s. You have:

- **Metrics** from Prometheus: `http_request_duration_seconds` is high on `payments`. You know *that* it is slow and *how often*, cheaply, forever. You do **not** know *which* requests or *why*.
- **Logs** from Loki: thousands of lines from `payments`, none of which can be tied to the specific slow requests, because the log lines and the metric series were produced by two unrelated libraries with two unrelated notions of "request."
- **Traces** from Jaeger: you can see one slow trace end-to-end — but the tracing SDK, the metrics client and the logging framework were configured independently, so the trace you are staring at cannot be cross-referenced against the metric spike or the error logs.

This is the **three-silo problem**. Each signal was historically produced by a different SDK, tagged with a different, incompatible label set, exported over a different protocol, and correlated by hand at 3 a.m. The cost is not storage — it is **mean time to correlation**.

OpenTelemetry's answer is structural, not a dashboard:

| Shared component | What it unifies |
|---|---|
| **Resource** | Every signal from the same process carries the *identical* `Resource` (`service.name`, `k8s.pod.name`, `deployment.environment`, `host.id`). Join key across all three. |
| **Context / Propagation** | The active `SpanContext` (`trace_id`, `span_id`) is ambiently available, so a metric exemplar and a log record can both stamp themselves with *the same* trace. |
| **Semantic Conventions** | `http.request.method`, `http.response.status_code`, `service.name` mean the same thing on a span attribute, a metric label and a log attribute. |
| **OTLP** | One protocol, one endpoint (`4317` gRPC / `4318` HTTP), three top-level messages (`ResourceSpans`, `ResourceMetrics`, `ResourceLogs`). |
| **Collector** | One process receives, processes and routes all three, and can even *derive* one signal from another (spans → metrics). |

**Signals vs. cross-cutting concerns.** The exam draws a hard line: **Traces, Metrics and Logs are signals** — they are *emitted and exported*. **Context** and **Baggage** are *cross-cutting concerns* — they are *propagated* and carry no telemetry payload of their own. Baggage is **not** a fourth signal; it is a key/value map that rides the propagation headers so a value set upstream (e.g. `enduser.id`) can be read downstream and *attached* to whichever signal you choose. A frequent distractor answer lists Baggage as a signal — it is not.

---

## 2. The OpenTelemetry data model, signal by signal

### 2.1 Traces

A **Trace** is a DAG of **Spans** sharing one 128-bit `trace_id`. Each span is a timed operation.

**Span structure (the fields the exam expects you to name):**

```text
Span
├── trace_id        16 bytes / 128 bit   — identifies the whole trace
├── span_id          8 bytes /  64 bit   — identifies this span
├── parent_span_id   8 bytes             — empty on the root span
├── name             low-cardinality operation name ("GET /users/:id", not "/users/42")
├── kind             SERVER | CLIENT | PRODUCER | CONSUMER | INTERNAL
├── start_time       nanosecond wall clock
├── end_time         nanosecond wall clock
├── attributes       key/value (semantic conventions)
├── events           timestamped points-in-time ("exception", "message")
├── links            references to spans in OTHER traces (batch/fan-in)
├── status           UNSET | OK | ERROR (+ message)
└── SpanContext      { trace_id, span_id, trace_flags, trace_state } — the part that PROPAGATES
```

**Span kind is not cosmetic.** It tells the backend how to build the service graph and where a network hop is:

| Kind | Meaning | Typical exemplar |
|---|---|---|
| `SERVER` | Synchronous inbound; remote parent | Handling an HTTP request |
| `CLIENT` | Synchronous outbound; remote child | Calling a downstream API / DB |
| `PRODUCER` | Async send; child may run later | Publishing to Kafka |
| `CONSUMER` | Async receive; parent may be finished | Processing a Kafka message (uses `links`) |
| `INTERNAL` | In-process work | A function you chose to instrument |

**Propagation — W3C Trace Context.** The `SpanContext` crosses process boundaries as two HTTP headers. This is the OTel default propagator and the exam's canonical format:

```text
traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
             │  │                                │                │
             │  └ trace-id (32 hex)              └ parent-id      └ trace-flags
             └ version                             (this span_id)   01 = sampled

tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
            └ vendor-specific, ordered, mutable (max 32 entries)
```

`trace-flags` bit 0 is the **sampled** flag. If it is `00`, a `parentbased` sampler downstream will *not* record the span — this is how a head-sampling decision made at the edge propagates through the whole trace so it is either fully present or fully absent, never half-recorded.

**Sampling** is the trace-specific cost lever (metrics and logs are not "sampled" this way).

| Strategy | Where | Decision input | Trade-off |
|---|---|---|---|
| `AlwaysOn` / `AlwaysOff` | SDK (head) | none | Dev only / kills tracing |
| `TraceIdRatioBased(0.1)` | SDK (head) | hash of `trace_id` | Cheap, deterministic, but blind — drops the one slow trace as readily as a fast one |
| `ParentBased(root=…)` | SDK (head) | upstream `sampled` flag | Keeps a trace whole across services; the standard production default |
| **Tail sampling** | **Collector** | the *complete* trace (latency, error, attributes) | Keeps every error/slow trace, drops boring ones — but the Collector must **buffer all spans of a trace in memory** until the root ends, and route all spans of one `trace_id` to the *same* Collector instance (`loadbalancing` exporter) |

**SpanProcessor** governs export:

- `SimpleSpanProcessor` — exports each span synchronously, one network call per span. Correct for tests, catastrophic in production (blocks the request path).
- `BatchSpanProcessor` — buffers spans and flushes on size/timeout. The production default. Tuned by `OTEL_BSP_MAX_QUEUE_SIZE`, `OTEL_BSP_SCHEDULE_DELAY`, `OTEL_BSP_MAX_EXPORT_BATCH_SIZE`. When the queue overflows, spans are **dropped silently** — a real failure mode covered in §7.

### 2.2 Metrics

A **Metric** is an aggregation of measurements over time. OTel's model is defined by the **instrument** you pick; the instrument choice fixes the semantics for the whole pipeline.

**The six instruments** (synchronous = you call `.Add()`/`.Record()` inline; asynchronous = you register a *callback* the SDK invokes at collection time):

| Instrument | Sync/Async | Monotonic? | Aggregates to | Use for |
|---|---|---|---|---|
| `Counter` | sync | yes (only ↑) | Sum | Requests served, bytes sent |
| `UpDownCounter` | sync | no (± ) | Sum | Queue depth, active connections |
| `Histogram` | sync | — | Histogram (buckets) | Request duration, payload size |
| `Gauge` | sync* | no | last value | Current temperature (sync gauge is newer) |
| `ObservableCounter` | async | yes | Sum | CPU seconds total (read from `/proc`) |
| `ObservableUpDownCounter` | async | no | Sum | Memory in use |
| `ObservableGauge` | async | no | last value | Config-driven limit, current heap |

**Aggregation temporality** is the single most exam-relevant metrics concept, because it is where OTel and Prometheus disagree:

| | **Cumulative** | **Delta** |
|---|---|---|
| Value reported | running total since process start | change since the *last* export |
| Restart behavior | resets to 0 (backend must detect reset) | naturally 0-based every interval |
| Stateful component | the **backend** | the **SDK/Collector** |
| Native fit | **Prometheus** (`rate()` expects monotonic cumulative) | statsd-style, serverless/Lambda (no long-lived process to hold a running sum) |

You select it per exporter. The Prometheus exporter *forces* cumulative; an OTLP exporter to a delta-native backend sets `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta`. Sending **delta** points to a Prometheus backend, or **cumulative** points to a delta backend, produces silently wrong `rate()` graphs — no error, just bad numbers.

**Views** reshape the metric stream in the SDK without touching instrument code — rename, change bucket boundaries, drop a high-cardinality attribute, or change the aggregation:

```python
# Drop the exploding `http.target` attribute and set explicit latency buckets
view = View(
    instrument_name="http.server.request.duration",
    attribute_keys={"http.request.method", "http.response.status_code"},  # keep only these
    aggregation=ExplicitBucketHistogramAggregation(
        boundaries=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
    ),
)
```

**Exemplars** are the metrics→traces bridge. When a `Histogram` records a measurement *inside an active span*, the SDK can attach the `{trace_id, span_id}` of that span to the bucket as an exemplar. The result: click the p99 spike on a Grafana heatmap, jump straight to *the exact trace* that produced that data point. This is only possible because both signals share the same ambient context (§1).

**MetricReader**: `PeriodicExportingMetricReader` pulls from the SDK on `OTEL_METRIC_EXPORT_INTERVAL` (default 60 s) and pushes via the exporter — the metrics analogue of `BatchSpanProcessor`.

### 2.3 Logs

Logs are the newest signal to be modeled and the one with the most distinctive design: OTel is deliberately **not** a logging API for developers to call. Instead it defines a **LogRecord** data model and a **Logs Bridge API** that *existing* logging libraries (Logback, Log4j, `logging`, zap, Serilog) plug into via an **appender/handler**. You keep writing `log.info(...)`; the appender translates each line into an OTLP `LogRecord`.

**LogRecord structure:**

```text
LogRecord
├── timestamp            when the event happened
├── observed_timestamp   when the collector/SDK saw it (differs on file-scraped logs)
├── severity_number      1..24, normalized (see below)
├── severity_text        original level string ("WARN", "warning", "W")
├── body                 the message — string OR structured (map/array)
├── attributes           key/value, semantic conventions
├── resource             SAME Resource as traces & metrics from this process
├── trace_id            ┐ auto-injected from the active SpanContext
├── span_id             � — THIS is what correlates a log line to its trace
└── trace_flags         ┘
```

**Severity number normalization** — the exam likes this table because it lets a backend compare "ERROR" from one language against "SEVERE" from another:

| Range | Level |
|---|---|
| 1–4 | TRACE |
| 5–8 | DEBUG |
| 9–12 | INFO |
| 13–16 | WARN |
| 17–20 | ERROR |
| 21–24 | FATAL |

**Two ways logs reach OTLP:**

1. **In-process bridge** — the SDK appender captures `trace_id`/`span_id` *at emit time*, so correlation is exact and free. Requires app-level wiring.
2. **Collector-side scraping** — `filelogreceiver` tails `stdout`/`/var/log/pods`, parses, and (best-effort) extracts `trace_id` from the text. Zero app changes, but correlation depends on the app having *printed* the trace id, and timestamps become `observed_timestamp`. This is the Kubernetes-default path.

`BatchLogRecordProcessor` batches log exports exactly as its trace and metric siblings do.

---

## 3. Comparative trade-offs across signals

| Dimension | **Traces** | **Metrics** | **Logs** |
|---|---|---|---|
| Question answered | *Why* is this one request slow? | *How much / how often*, over time? | *What exactly* happened here? |
| Cardinality tolerance | high (per-request) | **low** — every label combo is a new time series ($$$) | high (per-event) |
| Cost driver | volume × sampling rate | active series count | volume × retention |
| Cost control | **sampling** (head/tail) | attribute pruning via **Views** | level filtering, sampling |
| Retention (typical) | days | months–years | days–weeks |
| Aggregatable? | no (individual) | yes (that's the point) | no (individual) |
| Default SpanProcessor/Reader | `BatchSpanProcessor` | `PeriodicExportingMetricReader` | `BatchLogRecordProcessor` |
| Correlation key produced | is the `trace_id` | carries exemplar `trace_id` | carries `trace_id` + `span_id` |
| OTLP message | `ResourceSpans` | `ResourceMetrics` | `ResourceLogs` |
| Backpressure failure | dropped spans (silent) | stale/gapped series | dropped records (silent) |

**The synthesis point (a favorite exam framing):** no single signal is sufficient. Metrics detect *and alert cheaply* but cannot explain. Traces explain a *single* request but are too expensive to keep them all. Logs record ground truth but drown you. The OTel value proposition is the **navigation between them** via shared `trace_id` — alert on a metric, pivot via exemplar to a trace, pivot via `trace_id` to the exact logs.

**Signal-derived-from-signal (Collector connectors).** Rather than instrument three times, you can compute one signal from another *inside the Collector*:

- **`spanmetrics` connector** — consumes the `traces` pipeline, emits R.E.D. metrics (`calls_total`, `duration`) into the `metrics` pipeline. You get request-rate/error/duration metrics **for free** from spans, with exemplars back to those spans.
- **`servicegraph` connector** — spans → a metric of service-to-service edge latency/error.

This is the deepest expression of "one data model": a signal transformed into another signal, in-flight, without re-instrumenting the app.

---

## 4. Complete infrastructure: manifests

### 4.1 OpenTelemetry Collector — all three pipelines + spanmetrics connector

```yaml
# otelcol-config.yaml — full three-signal Collector with metrics derived from spans
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # Order matters: memory_limiter FIRST so it can reject before batching allocates.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25
  batch:
    send_batch_size: 8192
    timeout: 5s
  resource:
    attributes:
      - key: deployment.environment
        value: production
        action: upsert
  # Tail sampling: keep every error and every trace slower than 2s, ratio-sample the rest.
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    policies:
      - name: errors
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow
        type: latency
        latency: { threshold_ms: 2000 }
      - name: baseline
        type: probabilistic
        probabilistic: { sampling_percentage: 5 }

connectors:
  # Derives RED metrics FROM the traces pipeline and feeds the metrics pipeline.
  spanmetrics:
    histogram:
      explicit:
        buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2s, 5s]
    dimensions:
      - name: http.request.method
      - name: http.response.status_code
    exemplars:
      enabled: true

exporters:
  otlphttp/traces:
    endpoint: https://tempo.observability.svc:4318
  prometheus:
    endpoint: 0.0.0.0:8889
    enable_open_metrics: true      # emits exemplars in OpenMetrics format
  otlphttp/logs:
    endpoint: https://loki.observability.svc:4318
  debug:
    verbosity: detailed            # human-readable dump for §6 verification

service:
  telemetry:
    metrics:
      address: 0.0.0.0:8888        # the Collector's OWN metrics
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, resource, tail_sampling, batch]
      exporters:  [otlphttp/traces, spanmetrics]   # note: also feeds the connector
    metrics:
      receivers:  [otlp, spanmetrics]              # app metrics + span-derived metrics
      processors: [memory_limiter, resource, batch]
      exporters:  [prometheus]
    logs:
      receivers:  [otlp]
      processors: [memory_limiter, resource, batch]
      exporters:  [otlphttp/logs]
```

### 4.2 Collector as a Kubernetes Deployment (via the OpenTelemetry Operator CR)

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: gateway
  namespace: observability
spec:
  mode: deployment          # deployment | daemonset | statefulset | sidecar
  replicas: 3
  image: otel/opentelemetry-collector-contrib:0.109.0
  resources:
    limits:   { memory: 1Gi, cpu: "1" }
    requests: { memory: 512Mi, cpu: 200m }
  config:                   # inline the config from 4.1 here
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    # ...processors/exporters/service as above...
```

### 4.3 Auto-instrumentation of a workload — zero code change

```yaml
# 1) Define what to inject
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: otel-sdk
  namespace: shop
spec:
  exporter:
    endpoint: http://gateway-collector.observability.svc:4318
  propagators: [tracecontext, baggage]        # W3C trace context + baggage
  sampler:
    type: parentbased_traceidratio            # keep traces whole; 25% of roots
    argument: "0.25"
  python:
    env:
      - name: OTEL_LOGS_EXPORTER
        value: otlp                            # turn on the logs signal too
---
# 2) Opt a Deployment in with one annotation — traces, metrics AND logs, no rebuild
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-python: "otel-sdk"
    spec:
      containers:
        - name: checkout
          image: registry.local/checkout:1.4.2
```

### 4.4 SDK configuration is 100 % environment variables (the OTLP spec surface)

```bash
# Resource — shared by all three signals
export OTEL_SERVICE_NAME=checkout
export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=production,service.version=1.4.2"

# Single endpoint for all signals (or override per-signal)
export OTEL_EXPORTER_OTLP_ENDPOINT=http://gateway-collector.observability.svc:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf   # grpc | http/protobuf | http/json

# Per-signal switches
export OTEL_TRACES_SAMPLER=parentbased_traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.25
export OTEL_METRIC_EXPORT_INTERVAL=15000            # ms
export OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative
export OTEL_LOGS_EXPORTER=otlp
```

---

## 5. CLI and terminal verification

### 5.1 Generate all three signals with `telemetrygen`

```console
$ telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 3 --child-spans 2
2026-08-10T15:04:05.001-0300  INFO  traces/traces.go:58  starting the traces generator with 1 worker(s), each sending 3 traces
2026-08-10T15:04:05.140-0300  INFO  traces/worker.go:96  traces generated  {"worker": 0, "traces": 3}
2026-08-10T15:04:05.140-0300  INFO  traces/traces.go:83  stopping the exporter

$ telemetrygen metrics --otlp-insecure --otlp-endpoint localhost:4317 --metrics 5 --metric-type Sum
2026-08-10T15:04:12.002-0300  INFO  metrics/worker.go:112  metrics generated  {"worker": 0, "metrics": 5}

$ telemetrygen logs --otlp-insecure --otlp-endpoint localhost:4317 --logs 4
2026-08-10T15:04:18.003-0300  INFO  logs/worker.go:100  logs generated  {"worker": 0, "logs": 4}
```

### 5.2 Send a raw OTLP/HTTP trace by hand (proves the endpoint, no SDK)

```console
$ cat span.json
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"curltest"}}]},
"scopeSpans":[{"spans":[{"traceId":"0af7651916cd43dd8448eb211c80319c","spanId":"b7ad6b7169203331",
"name":"manual-span","kind":2,"startTimeUnixNano":"1754845445000000000","endTimeUnixNano":"1754845445120000000"}]}]}]}

$ curl -sS -o /dev/null -w "%{http_code}\n" \
    -X POST http://localhost:4318/v1/traces \
    -H 'Content-Type: application/json' \
    --data @span.json
200
```

A `200` with an empty body is success for OTLP/HTTP. A `partial_success` body means *some* items were rejected — never ignore it (§7).

### 5.3 The Collector's `debug` exporter — see each signal as it lands

```console
$ kubectl -n observability logs deploy/gateway-collector | sed -n '1,40p'
2026-08-10T15:04:05.145Z  info  TracesExporter  {"kind":"exporter","data_type":"traces","name":"debug","resource spans":1,"spans":3}
2026-08-10T15:04:05.145Z  info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
     -> deployment.environment: Str(production)
ScopeSpans #0
InstrumentationScope checkout 1.4.2
Span #0
    Trace ID       : 0af7651916cd43dd8448eb211c80319c
    Parent ID      :
    ID             : b7ad6b7169203331
    Name           : POST /checkout
    Kind           : Server
    Start time     : 2026-08-10 15:04:05 +0000 UTC
    End time       : 2026-08-10 15:04:05.12 +0000 UTC
    Status code    : Ok
Attributes:
     -> http.request.method: Str(POST)
     -> http.response.status_code: Int(200)
     -> http.route: Str(/checkout)

2026-08-10T15:04:12.300Z  info  MetricsExporter {"kind":"exporter","data_type":"metrics","name":"debug","resource metrics":1,"metrics":1,"data points":1}
Metric #0
Descriptor:
     -> Name: http.server.request.duration
     -> Unit: s
     -> DataType: Histogram
     -> AggregationTemporality: Cumulative
HistogramDataPoint #0
     -> Count: 42
     -> Sum: 6.180000
     -> Exemplars: TraceID 0af7651916cd43dd8448eb211c80319c SpanID b7ad6b7169203331 Value 3.900000

2026-08-10T15:04:18.410Z  info  LogsExporter  {"kind":"exporter","data_type":"logs","name":"debug","resource logs":1,"log records":1}
LogRecord #0
     -> ObservedTimestamp: 2026-08-10 15:04:18 +0000 UTC
     -> Severity: Error (17)
     -> Body: Str(payment gateway timeout)
     -> Trace ID: 0af7651916cd43dd8448eb211c80319c
     -> Span ID: b7ad6b7169203331
```

Note the three signals in one log stream, all carrying `Trace ID 0af76519…` — the metric via an **exemplar**, the log via its `Trace ID`/`Span ID` fields. That shared id **is** the deliverable.

### 5.4 Confirm the span-derived metrics and their exemplars

```console
$ curl -s http://gateway-collector.observability.svc:8889/metrics | grep -A1 '^calls_total'
calls_total{http_request_method="POST",http_response_status_code="200",service_name="checkout"} 42 # {trace_id="0af7651916cd43dd8448eb211c80319c",span_id="b7ad6b7169203331"} 1.0 1754845445.120
```

The trailing `# {trace_id=…}` is the OpenMetrics exemplar — proof the `spanmetrics` connector produced request metrics *and* linked them back to the originating trace.

---

## 6. Verification and failure diagnosis

### 6.1 The Collector's own telemetry — the first place to look

The Collector exposes its internal metrics on `:8888`. These are your ground truth for "is data flowing and is anything being dropped?"

```console
$ curl -s http://gateway-collector.observability.svc:8888/metrics \
  | grep -E 'otelcol_(receiver_accepted|exporter_sent|exporter_send_failed|processor_dropped)'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 15832
otelcol_exporter_sent_spans{exporter="otlphttp/traces"} 15788
otelcol_exporter_send_failed_spans{exporter="otlphttp/traces"} 44
otelcol_processor_dropped_metric_points{processor="memory_limiter"} 0
```

`accepted` ≫ `sent` with rising `send_failed` = the **backend** is the problem, not the app. `dropped` on `memory_limiter` = the Collector is under-provisioned (§6.3).

### 6.2 Diagnostic decision table

| Symptom | Likely cause | Confirm | Fix |
|---|---|---|---|
| No spans in backend, but `receiver_accepted_spans` climbs | export failing downstream | `otelcol_exporter_send_failed_spans` > 0; check exporter endpoint/TLS | fix backend endpoint / cert |
| No spans, `receiver_accepted_spans` = 0 | app isn't sending | SDK `OTEL_EXPORTER_OTLP_ENDPOINT` wrong, or wrong protocol/port | 4317=gRPC, 4318=HTTP — mismatched port is the #1 cause |
| Trace exists but is **broken into fragments** | context not propagated | downstream span has empty `Parent ID` | ensure `tracecontext` propagator on *both* services; check a proxy stripping `traceparent` |
| Only ~half of expected traces | sampling | `OTEL_TRACES_SAMPLER_ARG` < 1 | intended; raise for debugging with `parentbased_always_on` |
| Metrics graph looks like a sawtooth / negative `rate()` | temporality mismatch | debug exporter shows `AggregationTemporality: Delta` into Prometheus | set `TEMPORALITY_PREFERENCE=cumulative` |
| Prometheus `rate()` returns nothing | metric is a Gauge, not a Counter | debug exporter `DataType` | use a `Counter` instrument for rates |
| Logs arrive with **no** `Trace ID` | correlation broken | LogRecord `Trace ID:` empty | log emitted *outside* an active span, OR file-scraper couldn't parse the id → use the in-process bridge |
| Spans silently vanish under load | `BatchSpanProcessor` queue overflow | SDK debug logs "queue is full"; `otelcol_processor_dropped` | raise `OTEL_BSP_MAX_QUEUE_SIZE`, scale Collector |
| Collector OOMKilled | no `memory_limiter`, or limit above pod limit | pod `Last State: OOMKilled` | add `memory_limiter` as the FIRST processor, set below the k8s memory limit |

### 6.3 Confirm memory backpressure is working, not silently dropping

```console
$ kubectl -n observability describe pod gateway-collector-7d9f | grep -A3 'Last State'
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

`OOMKilled` (exit 137) on a Collector almost always means `memory_limiter` is missing or is set *above* the container's `resources.limits.memory`. The processor must be able to reject data *before* the kernel kills the process — that is why §4.1 places it first in every pipeline.

### 6.4 Validate the config before it ever runs

```console
$ otelcol-contrib validate --config=otelcol-config.yaml
Error: failed to build pipelines: pipeline "metrics": exporter "prometheusremotewrite" is not configured

$ # fix the typo, re-run:
$ otelcol-contrib validate --config=otelcol-config.yaml && echo OK
OK
```

### 6.5 End-to-end correlation smoke test (the acceptance criterion)

The system works when a **single `trace_id` retrieves all three signals**:

```console
$ TID=0af7651916cd43dd8448eb211c80319c

$ curl -s "http://tempo:3200/api/traces/$TID"        | jq '.batches | length'      # trace present?
1
$ curl -s "http://loki:3100/loki/api/v1/query" \
    --data-urlencode "query={service_name=\"checkout\"} | trace_id=\"$TID\"" \
    | jq '.data.result | length'                                                    # logs joined?
3
$ curl -s http://gateway-collector:8889/metrics | grep -c "trace_id=\"$TID\""       # metric exemplar?
1
```

Three non-zero results from one id = the three-silo problem is solved for that request path.

---

## 7. Common exam traps (quick reference)

- **Baggage is not a signal.** Traces, Metrics, Logs are the three signals; Context and Baggage are cross-cutting concerns.
- **`4317` is gRPC, `4318` is HTTP.** The most frequently tested constant.
- **`SimpleSpanProcessor` is not for production** — it blocks per span; use `BatchSpanProcessor`.
- **Delta vs Cumulative is chosen at export**, and Prometheus requires cumulative.
- **Tail sampling lives in the Collector, head sampling in the SDK** — and tail sampling needs all spans of a trace routed to one Collector instance.
- **`memory_limiter` goes first** in every pipeline.
- **Logs correlate via `trace_id` + `span_id` fields; metrics correlate via exemplars.**
- **`--lang` / OTLP `partial_success`** responses mean partial rejection — a `200`/`2xx` alone is not proof every item was accepted.

---

## 8. Referencias

- OTCA curriculum (official) — https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
- OpenTelemetry — Signals overview — https://opentelemetry.io/docs/concepts/signals/
- Traces — https://opentelemetry.io/docs/concepts/signals/traces/
- Metrics — https://opentelemetry.io/docs/concepts/signals/metrics/
- Logs — https://opentelemetry.io/docs/concepts/signals/logs/
- Baggage (cross-cutting concern) — https://opentelemetry.io/docs/concepts/signals/baggage/
- Context propagation — https://opentelemetry.io/docs/concepts/context-propagation/
- Sampling — https://opentelemetry.io/docs/concepts/sampling/
- OTLP specification — https://opentelemetry.io/docs/specs/otlp/
- Trace data model (spec) — https://opentelemetry.io/docs/specs/otel/trace/api/
- Metrics data model & temporality — https://opentelemetry.io/docs/specs/otel/metrics/data-model/
- Logs data model — https://opentelemetry.io/docs/specs/otel/logs/data-model/
- Semantic Conventions — https://opentelemetry.io/docs/specs/semconv/
- SDK environment variable configuration — https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- Collector configuration — https://opentelemetry.io/docs/collector/configuration/
- `tailsamplingprocessor` — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- `spanmetrics` connector — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector
- `memorylimiterprocessor` — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/memorylimiterprocessor
- Collector internal telemetry — https://opentelemetry.io/docs/collector/internal-telemetry/
- OpenTelemetry Operator (`Instrumentation` CR) — https://github.com/open-telemetry/opentelemetry-operator
- `telemetrygen` — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
- Exemplars (spec) — https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exemplars
- W3C Trace Context — https://www.w3.org/TR/trace-context/