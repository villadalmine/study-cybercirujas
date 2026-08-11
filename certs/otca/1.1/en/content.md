# 1.1 Telemetry Data

> **Domain:** Fundamentals of Observability · **Exam weight:** 4.5
> **Profile:** This is the conceptual bedrock of the entire OTCA. Everything the SDK, the Collector, and the pipeline domains build on assumes you already carry a precise mental model of *what a signal is*, *how it is shaped on the wire*, and *how the signals correlate*. Get this wrong and every downstream design decision — sampling, cardinality budgets, cost, correlation — inherits the error.

---

## 1. The production problem: why "telemetry data" is a data-modeling problem, not a logging problem

The naïve view is that observability is "add logs, add a metrics library, add a tracer." In production this fails for a specific, structural reason: **three independently-invented data models cannot be correlated after the fact.**

Consider the incident you will actually run: p99 latency on `checkout-api` jumps from 40 ms to 900 ms at 03:14 UTC. You have:

- A **metrics** system (Prometheus) that tells you *that* p99 rose, aggregated per `pod`, with no way to reach an individual slow request.
- A **logs** system (Loki/ELK) with millions of lines, where the slow requests are indistinguishable from fast ones because the log line never recorded a request identifier that matches anything in the trace.
- A **traces** system (Jaeger) that has spans, but the spans were emitted by a *different* instrumentation library that stamped `service` = `checkout` while the metrics stamped `service_name` = `checkout-api`, so no join key exists.

The three pillars are three data silos with **no shared identity, no shared timestamp semantics, and no shared attribute vocabulary.** OpenTelemetry's central thesis is that this is a *data model* problem. The fix is not a better logger — it is:

1. **A unified data model** for all signals (traces, metrics, logs, baggage, and now profiles), each with a formally specified schema.
2. **A shared `Resource`** — the same immutable identity attached to every signal a process emits.
3. **A shared `Context`** carrying `trace_id`/`span_id`, so a log line, a metric exemplar, and a span can all point back to the same request.
4. **Semantic Conventions** — one canonical spelling for every attribute (`service.name`, `http.request.method`, `k8s.pod.name`), so the join key is identical across signals and across vendors.
5. **OTLP** — one wire protocol so the producer never needs to know what backend will store the data.

That is the whole architectural argument for OpenTelemetry, and Topic 1.1 is the vocabulary for it. The rest of this document is the precise data model of each signal, the wire representation, and how you *verify* that the model is being honored in a live pipeline.

---

## 2. Signals: the taxonomy

A **signal** in OpenTelemetry is a category of telemetry with its own data model, API, SDK, and OTLP service. As of the current spec the signals are:

| Signal | Stability | Answers the question | Cardinality profile | Cost driver |
|---|---|---|---|---|
| **Traces** | Stable | *Where* did time go in this one request, across services? | High (per-span attributes) | Span volume × sampling rate |
| **Metrics** | Stable | *How many / how much / how fast*, aggregated over time? | Bounded by attribute cardinality | Active time series (cardinality) |
| **Logs** | Stable | *What exactly happened* at this instant, with detail? | Very high (unbounded body) | Bytes ingested + index |
| **Baggage** | Stable | *What contextual key-values* should ride along the request? | N/A (propagation, not stored) | Header size / propagation overhead |
| **Profiles** | Development/Experimental | *Which line of code / stack frame* burned CPU/memory? | Very high (stack aggregation) | Sample volume |

Two things trip up candidates:

- **Baggage is a signal but not a telemetry-*storage* signal.** It is a propagation mechanism: a set of key-value pairs carried in `Context` and across process boundaries via the W3C `baggage` header. It is *not* automatically written into spans or metrics (doing so is an explicit, deliberate processor step, because copying baggage onto every span is a cardinality and a PII footgun).
- **Profiles** is the fourth "real" signal (continuous profiling) and is being standardized with its own OTLP message. Expect it to appear in newer exam material as "emerging/experimental." Do not treat it as stable.

### 2.1 The anatomy shared by every signal

Every signal item that leaves a process is a tuple of:

```
(Resource, InstrumentationScope, <signal-specific payload>)
```

- **`Resource`** — immutable attributes identifying the *entity* that produced the telemetry (the service instance, the host, the pod). Same for every span/metric/log the process emits during its lifetime.
- **`InstrumentationScope`** (formerly "InstrumentationLibrary") — the `name` and `version` of the instrumentation that produced this item, e.g. `io.opentelemetry.okhttp-3.0` version `1.32.0`. Lets you attribute a bad span to a specific library.
- **Payload** — the span, the metric data point, or the log record.

This three-part envelope is why OTLP messages are nested `resource → scope → data`. Internalize that shape; it is the structure you will read in every debug exporter dump and every OTLP capture.

---

## 3. Traces in depth

### 3.1 Data model

A **trace** is a directed acyclic graph (DAG) of **spans** sharing one `trace_id`. A **span** is a single named, timed operation. Its fields (OTLP `Span` message):

| Field | Type / size | Notes |
|---|---|---|
| `trace_id` | 16 bytes (128-bit) | Globally unique per trace. Hex-encoded on the wire as 32 chars. |
| `span_id` | 8 bytes (64-bit) | Unique within the trace. 16 hex chars. |
| `parent_span_id` | 8 bytes | Empty ⇒ this is a **root span**. |
| `name` | string | Low-cardinality operation name (`GET /orders/{id}`, not `GET /orders/42`). |
| `kind` | enum | `INTERNAL`, `SERVER`, `CLIENT`, `PRODUCER`, `CONSUMER`. |
| `start_time_unix_nano` / `end_time_unix_nano` | uint64 | Nanoseconds since Unix epoch. Duration = end − start. |
| `attributes` | key-value list | Dimensions (`http.response.status_code`, `db.system`). |
| `events` | list of `(time, name, attributes)` | Point-in-time markers *inside* the span (e.g. `exception`). |
| `links` | list of `(SpanContext, attributes)` | References to *other* traces/spans (fan-in, batching). |
| `status` | `{code, message}` | `UNSET` (default), `OK`, `ERROR`. |
| `trace_state` | string | W3C `tracestate`, vendor routing/sampling hints. |

**`SpanKind` matters for topology and for backend semantics.** A `CLIENT`+`SERVER` pair across a network boundary is how a backend reconstructs "service A called service B." Getting kind wrong breaks service maps and RED-metric derivation.

| Kind | Emitted by | Typical peer field |
|---|---|---|
| `SERVER` | The receiver of a synchronous inbound request | `client.address` |
| `CLIENT` | The initiator of a synchronous outbound request | `server.address` |
| `PRODUCER` | Enqueues an async message | `messaging.destination.name` |
| `CONSUMER` | Processes an async message | linked to producer via `links` |
| `INTERNAL` | Purely in-process work | — |

**`Status` semantics** are subtle and examined: `UNSET` is the default and means "no explicit judgment." A span is only `ERROR` when the instrumentation (or you) decides the operation failed. Notably, per HTTP semantic conventions, a `SERVER` span with a `4xx` status is **not** automatically `ERROR` (a 404 is the client's problem), whereas `5xx` is. `OK` is reserved for an explicit developer override and should be rare.

### 3.2 SpanContext and propagation — the W3C Trace Context wire format

The **`SpanContext`** is the immutable, serializable identity of a span that crosses the wire: `{trace_id, span_id, trace_flags, trace_state, is_remote}`. It is *not* the span — it carries no attributes, no timing. It is exactly what is needed to make the *next* service's spans children of this one.

Propagation across HTTP uses the **W3C Trace Context** standard headers:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
          version    trace-id (16B)         parent-id (8B)    trace-flags
```

- `version` = `00`.
- `trace-id` = 32 lowercase hex (all-zero is invalid).
- `parent-id` = the caller's `span_id` (becomes `parent_span_id` downstream).
- `trace-flags` = 8-bit bitfield; bit 0 (`01`) is the **sampled** flag.

```
tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

Vendor-specific, ordered (left = most recent), size-limited. This is how a sampling decision or a vendor's routing key survives across a heterogeneous mesh.

> **Production failure mode:** a proxy or gateway that strips unknown headers will delete `traceparent`, silently breaking traces into disconnected fragments. Every downstream service becomes a new *root* span. You will see "orphan" traces of depth 1. The diagnosis is in §8.

### 3.3 Sampling — the first real trade-off

You cannot store every span in a high-QPS system. Sampling is where cost meets fidelity.

| Strategy | Where decided | Sees full trace? | Storage cost | Catches rare errors? | Consistency |
|---|---|---|---|---|---|
| **Head sampling** (`TraceIdRatioBased`, `ParentBased`) | At the root, at span start | No | Low, predictable | Poorly (decision made before outcome known) | Consistent if `ParentBased` + propagated flag |
| **Tail sampling** (Collector `tail_sampling` processor) | After the whole trace is assembled | Yes | High (must buffer all spans until decision) | Yes (can key on `status=ERROR`, latency) | Requires all spans of a trace at one Collector instance |
| **Remote / adaptive** | Central control plane pushes rates | No | Tunable | Medium | Coordinated |

**Head sampling** is a per-request coin flip made at the root and *propagated* via the `sampled` bit so the whole trace agrees. Cheap and deterministic, but you decide to keep a trace before you know it errored. **Tail sampling** buffers spans in the Collector and decides once the trace is complete — so you can keep *all errors and all slow traces* and drop the boring 200s — at the cost of memory and the hard requirement that every span of a given `trace_id` reaches the *same* Collector instance (this forces `trace_id`-aware load balancing via the `loadbalancing` exporter). This is Collector-domain material, but the *reason* it exists is a Topic-1.1 fact: the sampling decision quality is bounded by how much of the trace you can see when you make it.

---

## 4. Metrics in depth

### 4.1 The instrument → stream → point pipeline

OpenTelemetry metrics separate the **API instrument** you call in code from the **aggregated stream** that ships. The View/Aggregation layer sits between them.

```
Instrument (Counter/Histogram/…)  →  Measurement (value + attributes)
        →  View + Aggregation  →  Metric Stream  →  DataPoint(s)  →  OTLP
```

### 4.2 Instruments

| Instrument | Sync/Async | Monotonic? | Typical use | OTLP aggregation |
|---|---|---|---|---|
| `Counter` | Sync | Yes (add ≥ 0) | requests served, bytes sent | `Sum` |
| `UpDownCounter` | Sync | No | queue depth, active connections | `Sum` |
| `Histogram` | Sync | — | request duration, payload size | `Histogram` / `ExponentialHistogram` |
| `Gauge` (sync) | Sync | No | current temperature, last value | `Gauge` |
| `ObservableCounter` | Async (callback) | Yes | CPU seconds from `/proc` | `Sum` |
| `ObservableUpDownCounter` | Async | No | memory in use | `Sum` |
| `ObservableGauge` | Async | No | current heap size sampled on collect | `Gauge` |

**Sync vs async** is a real design decision: synchronous instruments are called *inline* on the hot path at the moment the event happens (and can attach request-scoped attributes and exemplars). Asynchronous instruments register a **callback** invoked only at collection time — correct for values you *read* (a gauge from the OS) rather than *count*, and cheaper because they fire once per export interval regardless of QPS.

### 4.3 Aggregation temporality — the single most-tested metrics concept

A `Sum` (and `Histogram`) has an **aggregation temporality**:

| | **Cumulative** | **Delta** |
|---|---|---|
| Each point reports | Running total since a fixed `start_time` | Change since the *previous* point |
| `start_time` | Fixed at process start | Moves forward each interval |
| Restart behavior | Total resets to 0 — backend must detect the drop | Naturally handles restarts (each delta stands alone) |
| Memory at SDK | Must retain running state | Can forget after export |
| Backend fit | **Prometheus** (native, `rate()` expects monotonic cumulative) | **StatsD/Datadog-style**, stateless pipelines |
| Loss of one export | Recoverable (next cumulative point still has the total) | **Permanent gap** (that delta is gone forever) |

This is the classic exam trap: **Prometheus is cumulative; Delta is not directly ingestible by Prometheus** without the Collector's `cumulativetodelta`/`deltatocumulative` conversion. Choose temporality to match the *backend*, and set it via the exporter (`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta|cumulative|lowmemory`).

### 4.4 Cardinality — the cost model of metrics

A **time series** is a unique `(metric name, attribute set, resource)` tuple. Cost and memory in every metrics backend scale with the number of *active* time series, i.e. **cardinality**. High-cardinality attributes (`user.id`, `request.id`, raw URLs with IDs) multiply series combinatorially and are the number-one cause of a metrics bill or an OOM.

```
series ≈ (# distinct http.route) × (# distinct http.response.status_code)
         × (# distinct http.request.method) × (# pods)
```

Ten routes × 15 status codes × 5 methods × 200 pods = 150,000 series for *one* histogram. Add `user.id` (1M users) and you have a self-inflicted outage. The mitigation is the **exemplar**: keep the metric low-cardinality and attach a *sample* of `trace_id`s to specific buckets so you can still jump from "the p99 bucket" to "an actual slow trace."

### 4.5 Exemplars — the metrics↔traces bridge

An **exemplar** is a `(value, timestamp, trace_id, span_id, filtered_attributes)` sample recorded on a histogram bucket or sum. It is the correlation join key that lets a dashboard's "p99 latency" panel deep-link to a representative slow trace *without* raising cardinality. Exemplars are only meaningfully recorded when there is an active *sampled* span in context at measurement time — another reason traces and metrics must share `Context`.

---

## 5. Logs in depth

OpenTelemetry treats logs differently from traces and metrics: rather than a brand-new logging API for you to adopt, it defines a **LogRecord data model** and a **bridge/appender** that adapts existing loggers (Logback, log4j, `structlog`, zap) into OTLP. The point is correlation, not replacement.

### 5.1 LogRecord data model

| Field | Notes |
|---|---|
| `time_unix_nano` | When the event occurred (may be unknown). |
| `observed_time_unix_nano` | When the collector/SDK observed it (always known — fallback for ordering). |
| `severity_number` | 1–24 numeric scale (see below) — machine-comparable. |
| `severity_text` | Original level string (`WARN`, `error`). |
| `body` | The message; string **or** structured (map/array). |
| `attributes` | Structured key-values (the modern replacement for regex-parsing a string). |
| `trace_id`, `span_id`, `trace_flags` | **The correlation fields** — populated from active `Context`. |
| `Resource`, `InstrumentationScope` | Same envelope as every signal. |

**`severity_number` ranges** (examined):

| Range | Level |
|---|---|
| 1–4 | TRACE |
| 5–8 | DEBUG |
| 9–12 | INFO |
| 13–16 | WARN |
| 17–20 | ERROR |
| 21–24 | FATAL |

The numeric scale exists so a backend can filter "≥ WARN" uniformly across services that use different level *strings* (`WARNING` vs `warn` vs `W`).

### 5.2 Why the trace-context fields are the whole point

A log line carrying `trace_id`/`span_id` is one that can be pivoted to and from the exact span it happened inside. This is set automatically when the log bridge reads the active `Context`. Without it you are back to `grep` and guesswork. The design lets you *reduce* logging volume (logs are the most expensive signal per byte) because the trace carries the structure and the log carries only the irreducible detail.

| Signal | Best for | Worst for | Per-item cost |
|---|---|---|---|
| Metric | Trend, alert threshold, SLO | Explaining one request | Cheapest (aggregated) |
| Trace | Latency breakdown, dependency map | Long-term trend (sampled) | Medium (sampled) |
| Log | Exact error detail, audit | Aggregation, alerting on rate | Most expensive (bytes) |

---

## 6. Baggage, Resource, and Semantic Conventions — the correlation substrate

### 6.1 Baggage

**Baggage** is a set of key-value pairs stored in `Context` and propagated across service boundaries via the W3C `baggage` header:

```
baggage: userId=alice,serverNode=DF%2028,isProduction=false
```

Use it to carry request-scoped facts (tenant id, experiment cohort) that a *downstream* service needs to enrich *its own* telemetry. **Baggage is not automatically attached to spans** — you opt in (e.g. the Collector's `baggage`-copy or the SDK span processor). Two hard rules from production:

1. **Never put secrets or PII in baggage** — it travels in cleartext headers to every downstream, including third parties.
2. **Baggage grows the request header on every hop** — keep it tiny; some gateways cap header size and will drop the request.

### 6.2 Resource

The **`Resource`** is the immutable identity of the producer. Minimum viable resource in production:

```
service.name        = checkout-api        # REQUIRED; if unset, SDK uses "unknown_service"
service.namespace   = shop
service.version     = 1.8.3
service.instance.id = 7f3c…               # unique per replica
```

Enriched automatically by **resource detectors** (host, process, container, k8s, cloud). `service.name` is *required*; when missing, the SDK stamps `unknown_service:<process>` — a value you will learn to recognize as "someone forgot to configure the SDK."

### 6.3 Semantic Conventions — the shared vocabulary

**Semantic Conventions** are the standardized, versioned attribute names that make cross-signal, cross-vendor joins possible. They are what guarantees the *metric*'s `http.response.status_code` and the *span*'s `http.response.status_code` are literally the same key.

| Legacy (pre-stabilization) | Stable |
|---|---|
| `http.method` | `http.request.method` |
| `http.status_code` | `http.response.status_code` |
| `net.peer.name` | `server.address` |
| `http.url` | `url.full` |

Because these evolved, telemetry carries a **`schema_url`** so a backend knows which convention version an item follows, and the Collector's `schemaprocessor` can transform between versions. **Do not invent attribute names when a convention exists** — a bespoke `status` attribute is invisible to every convention-aware dashboard.

---

## 7. OTLP — the wire format that ties it together

**OTLP (OpenTelemetry Protocol)** is the single protocol all signals ship over. Transports:

| Transport | Port (default) | Encoding | HTTP path (per signal) |
|---|---|---|---|
| gRPC | `4317` | Protobuf | n/a (service methods) |
| HTTP | `4318` | Protobuf **or** JSON | `/v1/traces`, `/v1/metrics`, `/v1/logs`, `/v1/profiles` |

| | gRPC (`4317`) | HTTP/protobuf (`4318`) | HTTP/JSON (`4318`) |
|---|---|---|---|
| Throughput | Highest (HTTP/2 multiplexing, streaming) | High | Lower (JSON parse cost) |
| Browser-friendly | No | Yes (with CORS) | Yes |
| Debuggability | Needs `grpcurl` | `curl` + protobuf | `curl` readable |
| Proxy/LB friendliness | Needs HTTP/2-aware LB | Trivial | Trivial |
| Default when unset | `grpc` | — | — |

The message shape mirrors the shared envelope: `ExportTraceServiceRequest → resource_spans[] → { resource, scope_spans[] → { scope, spans[] } }`. OTLP also defines **partial success** (`rejected_spans` + `error_message`) and a **retryable vs non-retryable** error split so exporters back off correctly. The exporter's env config:

```
OTEL_EXPORTER_OTLP_ENDPOINT=https://collector.obs.svc:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc          # or http/protobuf, http/json
OTEL_EXPORTER_OTLP_HEADERS=authorization=Bearer%20<token>
OTEL_EXPORTER_OTLP_COMPRESSION=gzip
```

---

## 8. Complete, production infrastructure

The following stack is a self-consistent, deployable example: an app configured entirely by OTEL env vars, a Collector that receives all three signals, and the Kubernetes wiring. Nothing here is truncated.

### 8.1 OpenTelemetry Collector configuration (all three signals)

```yaml
# otelcol-config.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # ALWAYS first: reject work before the process OOMs.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25

  # Attach infrastructure identity as Resource attributes.
  resourcedetection:
    detectors: [env, system, k8snode]
    timeout: 5s
    override: false

  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.deployment.name
        - k8s.pod.name
        - k8s.pod.uid
        - k8s.node.name

  # Batching amortizes export cost. ALWAYS last before the exporter.
  batch:
    send_batch_size: 8192
    send_batch_max_size: 16384
    timeout: 5s

exporters:
  # Console dump for verification/diagnosis. Not for production volume.
  debug:
    verbosity: detailed
    sampling_initial: 5
    sampling_thereafter: 200

  # Traces → an OTLP-native backend (Jaeger, Tempo).
  otlp/traces:
    endpoint: tempo.obs.svc:4317
    tls:
      insecure: false
      ca_file: /etc/otel/certs/ca.crt
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000

  # Metrics → Prometheus (cumulative, remote-write style scrape endpoint).
  prometheus:
    endpoint: 0.0.0.0:8889
    resource_to_telemetry_conversion:
      enabled: true

  # Logs → an OTLP log backend.
  otlp/logs:
    endpoint: loki-otlp.obs.svc:4317
    tls:
      insecure: false
      ca_file: /etc/otel/certs/ca.crt

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  zpages:
    endpoint: 0.0.0.0:55679
  pprof:
    endpoint: 0.0.0.0:1777

service:
  extensions: [health_check, zpages, pprof]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, resourcedetection, batch]
      exporters: [otlp/traces, debug]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, resourcedetection, batch]
      exporters: [prometheus, debug]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, resourcedetection, batch]
      exporters: [otlp/logs, debug]
  telemetry:
    logs:
      level: info
    metrics:
      level: detailed
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
```

### 8.2 Kubernetes deployment: Collector + an instrumented app

```yaml
# collector.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otelcol-config
  namespace: obs
data:
  otelcol-config.yaml: |
    # (contents of §8.1 inlined here)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: obs
  labels: {app: otel-collector}
spec:
  replicas: 2
  selector:
    matchLabels: {app: otel-collector}
  template:
    metadata:
      labels: {app: otel-collector}
    spec:
      serviceAccountName: otel-collector
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.116.0
          args: ["--config=/conf/otelcol-config.yaml"]
          ports:
            - {name: otlp-grpc, containerPort: 4317}
            - {name: otlp-http, containerPort: 4318}
            - {name: prometheus, containerPort: 8889}
            - {name: metrics,    containerPort: 8888}
            - {name: zpages,     containerPort: 55679}
            - {name: healthz,    containerPort: 13133}
          resources:
            requests: {cpu: "200m", memory: "400Mi"}
            limits:   {cpu: "1",    memory: "1Gi"}
          livenessProbe:
            httpGet: {path: /, port: 13133}
            initialDelaySeconds: 10
          readinessProbe:
            httpGet: {path: /, port: 13133}
          volumeMounts:
            - {name: config, mountPath: /conf}
      volumes:
        - name: config
          configMap: {name: otelcol-config}
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: obs
spec:
  selector: {app: otel-collector}
  ports:
    - {name: otlp-grpc, port: 4317, targetPort: 4317, protocol: TCP}
    - {name: otlp-http, port: 4318, targetPort: 4318, protocol: TCP}
```

### 8.3 App-side configuration — zero code, pure environment

The app process is instrumented by the SDK; the entire telemetry behavior is env-driven so the same image ships to every environment:

```yaml
# app-deployment.yaml (excerpt)
env:
  - name: OTEL_SERVICE_NAME
    value: "checkout-api"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "service.namespace=shop,service.version=1.8.3,deployment.environment.name=prod"
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector.obs.svc:4317"
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "grpc"
  - name: OTEL_TRACES_SAMPLER
    value: "parentbased_traceidratio"
  - name: OTEL_TRACES_SAMPLER_ARG
    value: "0.1"                       # keep 10% of root traces; children inherit via the sampled bit
  - name: OTEL_METRIC_EXPORT_INTERVAL
    value: "15000"                     # ms; align with your scrape interval
  - name: OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE
    value: "cumulative"               # match the Prometheus backend
  - name: OTEL_PROPAGATORS
    value: "tracecontext,baggage"     # W3C traceparent + baggage
  - name: OTEL_INSTANCE_ID
    valueFrom:
      fieldRef: {fieldPath: metadata.uid}
```

---

## 9. Hands-on verification and failure diagnosis

You verify a telemetry pipeline the same way you verify any data pipeline: inject a known input, observe it at each hop, and confirm the schema survived. `telemetrygen` (from the Collector-contrib repo) is the canonical synthetic emitter.

### 9.1 Emit a known trace and watch it land

```console
$ telemetrygen traces \
    --otlp-endpoint otel-collector.obs.svc:4317 \
    --otlp-insecure \
    --traces 1 --child-spans 2 \
    --service checkout-api
2026-08-10T14:22:07.114Z  info  traces/traces.go:58  generation of traces isn't finished, current: 1
2026-08-10T14:22:07.118Z  info  traces/worker.go:96  traces generated  {"worker": 0, "traces": 1}
2026-08-10T14:22:07.118Z  info  traces/traces.go:83  stopping the exporter
```

In the Collector's `debug` exporter output (`kubectl logs`), you should see the shared envelope — Resource, Scope, then the span, with a valid non-zero `Trace ID`:

```console
$ kubectl -n obs logs deploy/otel-collector | grep -A18 "ResourceSpans"
2026-08-10T14:22:07.201Z  info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout-api)
     -> k8s.pod.name: Str(otel-collector-7c9f4d8b6-2xk7q)
     -> k8s.namespace.name: Str(obs)
ScopeSpans #0
ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.27.0
InstrumentationScope telemetrygen 
Span #0
    Trace ID       : 6ff...a1c9  (32 hex chars)
    Parent ID      : 
    ID             : 4d2...b7e0
    Name           : lets-go
    Kind           : Server
    Start time     : 2026-08-10 14:22:07.11 +0000 UTC
    End time       : 2026-08-10 14:22:07.11 +0000 UTC
    Status code    : Unset
```

**Pass criteria:** non-zero `Trace ID`, a root span (`Parent ID` empty) with two children sharing the same `Trace ID`, and the Resource carries `service.name`.

### 9.2 Poke OTLP/HTTP directly with `curl` (JSON)

Isolates "is the receiver up and accepting" from any SDK question:

```console
$ curl -s -i http://otel-collector.obs.svc:4318/v1/traces \
    -H 'Content-Type: application/json' \
    -d '{"resourceSpans":[{"resource":{"attributes":[
         {"key":"service.name","value":{"stringValue":"smoke-test"}}]},
         "scopeSpans":[{"spans":[{
           "traceId":"5b8aa5a2d2c872e8321cf37308d69df2",
           "spanId":"051581bf3cb55c13",
           "name":"probe","kind":2,
           "startTimeUnixNano":"1754835727000000000",
           "endTimeUnixNano":"1754835727100000000"}]}]}]}'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 21

{"partialSuccess":{}}
```

An empty `partialSuccess` = fully accepted. A populated one tells you exactly what was rejected:

```json
{"partialSuccess":{"rejectedSpans":"1","errorMessage":"invalid trace id"}}
```

### 9.3 Confirm the receiver over gRPC with `grpcurl`

```console
$ grpcurl -plaintext otel-collector.obs.svc:4317 list
grpc.reflection.v1alpha.ServerReflection
opentelemetry.proto.collector.logs.v1.LogsService
opentelemetry.proto.collector.metrics.v1.MetricsService
opentelemetry.proto.collector.trace.v1.TraceService
```

Seeing all three services = all three pipelines are wired on the receiver.

### 9.4 Read the Collector's own metrics (the pipeline's telemetry)

The Collector exports its self-telemetry on `:8888`. These are your pipeline SLIs:

```console
$ kubectl -n obs port-forward deploy/otel-collector 8888:8888 &
$ curl -s localhost:8888/metrics | grep -E 'receiver_accepted|exporter_sent|exporter_send_failed|refused'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 31402
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 0
otelcol_exporter_sent_spans{exporter="otlp/traces"} 31402
otelcol_exporter_send_failed_spans{exporter="otlp/traces"} 0
otelcol_processor_dropped_spans{processor="memory_limiter"} 0
```

**The diagnostic identity to memorize:**
`accepted − (sent + send_failed + dropped + queued)` should trend to zero. Divergence tells you *where* data dies:

| Symptom | Meaning | Fix |
|---|---|---|
| `receiver_refused_spans` > 0 | `memory_limiter` is shedding load | Raise limits / add replicas / shrink batch |
| `exporter_send_failed_spans` > 0 | Backend unreachable or rejecting | Check backend TLS/auth/health; watch `retry` |
| `exporter_queue_size` climbing to `queue_size` | Backend slower than intake | Scale backend; raise `num_consumers`; risk of drop |
| `accepted` = 0 despite traffic | Wrong port/protocol/endpoint at the app | Verify `OTEL_EXPORTER_OTLP_ENDPOINT` and `PROTOCOL` |

### 9.5 Inspect live pipelines with zPages

```console
$ kubectl -n obs port-forward deploy/otel-collector 55679:55679 &
$ curl -s "localhost:55679/debug/tracez" | head -20
# TraceZ: per-operation latency buckets and recent error samples for the
# Collector's own spans — confirms internal span flow and surfaces stuck ops.

$ curl -s "localhost:55679/debug/pipelinez"
# Renders each configured pipeline (traces/metrics/logs) with its
# receiver → processor → exporter chain, mutating vs read-only processors.
```

### 9.6 Diagnosing broken context propagation (the §3.2 failure)

Symptom: every service produces depth-1 "root only" traces; the service map shows no edges.

```console
# 1. Confirm the caller emits traceparent (capture at the receiver / a debug proxy):
$ kubectl -n shop exec deploy/checkout-api -- \
    curl -s -D - http://orders-api.shop.svc/health -o /dev/null | grep -i traceparent
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01

# 2. Confirm the callee RECEIVES it (if the header is gone here, a proxy stripped it):
$ kubectl -n shop logs deploy/orders-api | grep -i "incoming traceparent"
(no output)   ← header was stripped between the two services
```

Root causes, in order of frequency: (a) `OTEL_PROPAGATORS` misconfigured or mismatched between services (e.g. one speaks `b3`, the other `tracecontext`); (b) an ingress/service-mesh/proxy hop that drops unknown headers; (c) a client library not instrumented, so it never injects `traceparent`. Fix (a) by standardizing on `tracecontext,baggage` fleet-wide; fix (b) by allow-listing `traceparent`/`tracestate`/`baggage` in the proxy; fix (c) by adding the missing instrumentation.

### 9.7 The `unknown_service` smell test

```console
$ kubectl -n obs logs deploy/otel-collector | grep 'service.name' | sort -u
     -> service.name: Str(checkout-api)
     -> service.name: Str(unknown_service:python)   ← someone forgot OTEL_SERVICE_NAME
```

Any `unknown_service:*` in production Resource attributes means a workload shipped without `OTEL_SERVICE_NAME`/`service.name` set. It is un-joinable, un-dashboardable telemetry. Treat it as a failed rollout.

---

## 10. Consolidated trade-off summary (exam-focused recall)

| Decision | Option A | Option B | Choose A when… |
|---|---|---|---|
| Signal for alerting | Metrics | Logs | Always — logs are for detail, metrics for rate/threshold |
| Metric temporality | Cumulative | Delta | Backend is Prometheus / you tolerate one lost export |
| Sampling | Head | Tail | Cost/predictability matters more than keeping every error |
| OTLP transport | gRPC (4317) | HTTP (4318) | Server-to-server, max throughput (use HTTP for browsers) |
| Correlate metric→trace | Exemplar | High-cardinality label | Always exemplar — labels blow up cardinality |
| Cross-service context | `tracecontext` | `b3` | Greenfield / vendor-neutral (b3 only for Zipkin interop) |
| Carry request facts downstream | Baggage | Stuff into headers ad hoc | Standard propagation, but never for PII/secrets |

**Three facts most likely to be tested cold:**
1. `trace_id` is 16 bytes (128-bit); `span_id` is 8 bytes (64-bit); `traceparent` version is `00`; sampled flag is `01`.
2. Prometheus is **cumulative**; OTLP defaults matter, and Delta needs conversion to reach Prometheus.
3. `service.name` is a **required** Resource attribute; its absence yields `unknown_service`.

---

## Referencias

- OTCA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
- OpenTelemetry — Observability primer / signals overview: https://opentelemetry.io/docs/concepts/observability-primer/
- OpenTelemetry — Signals (traces, metrics, logs, baggage): https://opentelemetry.io/docs/concepts/signals/
- Traces data model & SpanKind/Status: https://opentelemetry.io/docs/concepts/signals/traces/
- Metrics data model (instruments, temporality, exemplars): https://opentelemetry.io/docs/specs/otel/metrics/data-model/
- Logs data model & severity numbers: https://opentelemetry.io/docs/specs/otel/logs/data-model/
- Baggage specification: https://opentelemetry.io/docs/specs/otel/baggage/api/
- Context & propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- Resource semantic conventions: https://opentelemetry.io/docs/specs/semconv/resource/
- Semantic Conventions (general): https://opentelemetry.io/docs/specs/semconv/
- OTLP specification (transports, ports, partial success): https://opentelemetry.io/docs/specs/otlp/
- OTel environment variable configuration (SDK): https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- OpenTelemetry Collector configuration: https://opentelemetry.io/docs/collector/configuration/
- Collector internal telemetry & zPages: https://opentelemetry.io/docs/collector/internal-telemetry/
- W3C Trace Context (traceparent/tracestate): https://www.w3.org/TR/trace-context/
- W3C Baggage: https://www.w3.org/TR/baggage/
- `telemetrygen` utility (Collector-contrib): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
- Sampling concepts (head vs tail): https://opentelemetry.io/docs/concepts/sampling/