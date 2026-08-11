# 2.3 Configuration

> OTCA — Domain 2 (*The OpenTelemetry API and SDK*). Exam weight ≈ 6.57%.
> Focus: how an OpenTelemetry SDK is configured across environment variables, programmatic (in-code) builders, and declarative file configuration; resource, exporter, processor, sampler, propagator, and limit settings; precedence and diagnosis.

---

## 1. The production problem: configuration is the coupling boundary

Instrumentation code answers *what* telemetry a service emits. Configuration answers *everything else the operator actually cares about in production*: where the data goes, how much of it survives, how it is batched, how trace context crosses process boundaries, and how much memory the pipeline is allowed to consume before it starts dropping.

The architectural constraint OpenTelemetry solves here is **separation of instrumentation from wiring**. A library author instruments with the *API* and knows nothing about your backend. The *SDK* is the concrete implementation that reads configuration at process start and decides the runtime behavior. If those two were coupled, every dependency upgrade to Jaeger, Tempo, or an OTLP gateway would ripple into application code. Because they are decoupled, the same binary ships to dev, staging, and prod, and only the **configuration** changes.

That decoupling creates the failure mode this topic exists to prevent: a service that is *perfectly instrumented and completely silent* because `OTEL_EXPORTER_OTLP_ENDPOINT` points at a Collector that isn't there, or because `OTEL_TRACES_SAMPLER=always_off` was left in a base image. Configuration bugs do not throw — they produce **absence of data**, which is the hardest signal to notice. The whole discipline of this section is making that absence observable.

Three questions define every OpenTelemetry deployment, and all three are pure configuration:

1. **Identity** — who is emitting this? (the `Resource`)
2. **Destination and shape** — where does it go, over what protocol, batched how? (exporters + processors/readers)
3. **Volume and fidelity** — how much is kept, and how is context carried? (samplers + propagators + limits)

---

## 2. The three configuration surfaces and their precedence

OpenTelemetry SDKs expose three ways to configure the same knobs. They are not alternatives you pick once; they **layer**, and the layering order is the single most common source of "why is my setting being ignored" tickets.

| Surface | Mechanism | Scope | When it wins |
|---|---|---|---|
| **Environment variables** | `OTEL_*` read at SDK init | Process-wide, language-agnostic | Baseline; overridden by explicit in-code config |
| **Programmatic** | SDK builders (`SdkTracerProvider.builder()…`, `TracerProvider(...)`) | Whatever the code sets | Wins over env vars for the specific knob it sets |
| **Declarative (file)** | YAML file via `OTEL_EXPERIMENTAL_CONFIG_FILE` | Whole SDK described in one document | When present, **takes over** — most `OTEL_*` vars are ignored |

### Precedence rules you must internalize

- **Programmatic over environment.** If code calls `.setSampler(alwaysOn())`, then `OTEL_TRACES_SAMPLER=always_off` has no effect. The SDK reads env vars only for knobs the code did not explicitly set. This is why a "disable tracing in prod" env var silently fails against a hardcoded provider.
- **Declarative config is an all-or-nothing takeover.** When `OTEL_EXPERIMENTAL_CONFIG_FILE` is set, the SDK builds itself from that file. Per the spec, the other `OTEL_*` environment variables are then **ignored** (with the narrow exception of variables *referenced from inside the file* via `${ENV}` substitution). You cannot half-configure with a file and half with env vars.
- **Zero-code (auto-instrumentation) agents** are configured *entirely* through env vars (and, increasingly, the file), because there is no user code to call a builder. This is the common Kubernetes case.

> **Trade-off summary**
>
> | Concern | Env vars | Programmatic | Declarative file |
> |---|---|---|---|
> | Language-portability | ✅ identical keys everywhere | ❌ per-language API | ✅ one schema for all SDKs |
> | Expressiveness (views, multiple pipelines) | ❌ limited to flat keys | ✅ full | ✅ full |
> | Auditability / GitOps | ⚠️ scattered across manifests | ❌ buried in code | ✅ one reviewable document |
> | Change without redeploying image | ✅ (ConfigMap/env) | ❌ needs rebuild | ✅ (mounted file) |
> | Maturity | ✅ stable | ✅ stable | ⚠️ still stabilizing (schema versioned) |

---

## 3. Resource configuration

A `Resource` is the immutable set of attributes describing the entity producing telemetry — it is what lets a backend answer "which service, which version, which pod, which region." It is attached to every span, metric, and log record. Getting it wrong is not cosmetic: `service.name` is the primary grouping key in almost every backend, and the [semantic conventions](https://opentelemetry.io/docs/specs/semconv/resource/) mandate it.

Configured via two env vars:

```bash
# The single most important attribute. If unset, SDKs fall back to
# "unknown_service" (often suffixed with the process name), which collapses
# every unnamed service into one blob in the backend.
export OTEL_SERVICE_NAME="checkout-api"

# Arbitrary key=value pairs, W3C Baggage syntax (comma-separated, URL-encoded values).
export OTEL_RESOURCE_ATTRIBUTES="service.namespace=shop,service.version=2.14.3,deployment.environment=production"
```

`OTEL_SERVICE_NAME` is a convenience that maps to the `service.name` resource attribute and **takes precedence** over a `service.name` set inside `OTEL_RESOURCE_ATTRIBUTES`.

**Resource detectors** merge in environment-derived attributes automatically (host, OS, process, container, Kubernetes, cloud). Precedence when the same key is produced by multiple sources: explicit `OTEL_RESOURCE_ATTRIBUTES`/`OTEL_SERVICE_NAME` > detectors > SDK defaults. You can disable/enable detector sets in some SDKs via `OTEL_*_RESOURCE_ATTRIBUTES` toggles or `OTEL_EXPERIMENTAL_RESOURCE_DISABLED_KEYS`.

---

## 4. Signal pipeline configuration: exporters, processors, readers

Each signal (traces, metrics, logs) has its own pipeline. The shape is:

```
Instrumentation → (SpanProcessor | LogRecordProcessor | MetricReader) → Exporter → wire
```

### 4.1 Choosing exporters

```bash
# Signal-specific exporter selection. "otlp" is the default and correct answer for prod.
export OTEL_TRACES_EXPORTER=otlp        # otlp | console | none | zipkin | jaeger(deprecated)
export OTEL_METRICS_EXPORTER=otlp       # otlp | console | none | prometheus
export OTEL_LOGS_EXPORTER=otlp          # otlp | console | none
```

`none` fully disables that signal's export (useful to silence metrics while keeping traces). `console` is a debugging exporter — never in prod, it serializes every span to stdout.

### 4.2 OTLP exporter: transport configuration

OTLP is the native protocol. Two transports, and picking wrong is a frequent outage cause.

| Aspect | gRPC | HTTP/protobuf |
|---|---|---|
| `OTEL_EXPORTER_OTLP_PROTOCOL` value | `grpc` | `http/protobuf` (also `http/json`) |
| Default port | `4317` | `4318` |
| Default endpoint | `http://localhost:4317` | `http://localhost:4318` |
| Path handling (signal-agnostic endpoint) | none — used as base | SDK **appends** `/v1/traces`, `/v1/metrics`, `/v1/logs` |
| Path handling (per-signal endpoint) | used **as-is**, no path added | used **as-is**, no path added |
| Multiplexing / streaming | ✅ HTTP/2 streams | ❌ request/response |
| Proxy / L7 gateway friendliness | ⚠️ needs gRPC-aware LB | ✅ plain HTTP |
| Spec default protocol | \(SDKs SHOULD default to\) `http/protobuf` | — |

> **The classic 404.** With `http/protobuf` and the *signal-agnostic* `OTEL_EXPORTER_OTLP_ENDPOINT`, the SDK appends `/v1/traces`. If you instead set the *per-signal* `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, it is used verbatim — so `…:4318` (no path) yields `404 Not Found` because you must write the full `…:4318/v1/traces` yourself.

Full OTLP env surface:

```bash
# Signal-agnostic (applies to all three signals unless a per-signal var overrides it)
export OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector.observability.svc:4318"
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
export OTEL_EXPORTER_OTLP_HEADERS="authorization=Bearer%20abc123,x-tenant=shop"   # W3C Baggage syntax, values URL-encoded
export OTEL_EXPORTER_OTLP_COMPRESSION="gzip"          # gzip | none
export OTEL_EXPORTER_OTLP_TIMEOUT="10000"             # per-export deadline, ms
export OTEL_EXPORTER_OTLP_CERTIFICATE="/etc/otel/certs/ca.crt"                 # server CA for TLS
export OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE="/etc/otel/certs/client.crt"      # mTLS
export OTEL_EXPORTER_OTLP_CLIENT_KEY="/etc/otel/certs/client.key"              # mTLS

# Per-signal overrides (endpoint here is used AS-IS — include the /v1/... path for HTTP)
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="http://collector:4318/v1/traces"
export OTEL_EXPORTER_OTLP_METRICS_ENDPOINT="http://collector:4318/v1/metrics"
export OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE="delta"   # cumulative | delta | lowmemory
```

### 4.3 Span processors: Simple vs Batch

The processor decides *when* spans leave the process. This is a throughput/latency/memory trade, and the wrong choice will either add latency to every request or OOM the pod.

| | `SimpleSpanProcessor` | `BatchSpanProcessor` (BSP) |
|---|---|---|
| Export trigger | Synchronously on **each span end** | On queue-full, timer tick, or batch-size threshold |
| Latency impact | Blocks the ending thread until export | None on the hot path (async worker) |
| Throughput | Poor (one RPC per span) | High (batched RPCs) |
| Memory | ~zero buffering | Bounded queue (drops on overflow) |
| Data loss on overflow | N/A | Silently drops when queue full |
| Use case | Tests, debugging | **Everything in production** |

BSP tuning env vars (these are the levers you touch under load):

```bash
export OTEL_BSP_MAX_QUEUE_SIZE=2048           # default 2048 — raise if you see dropped spans
export OTEL_BSP_SCHEDULE_DELAY=5000           # ms between forced flushes, default 5000
export OTEL_BSP_MAX_EXPORT_BATCH_SIZE=512     # default 512 — must be ≤ queue size
export OTEL_BSP_EXPORT_TIMEOUT=30000          # ms, default 30000

# Batch Log Record Processor (BLRP) — same knobs for logs
export OTEL_BLRP_MAX_QUEUE_SIZE=2048
export OTEL_BLRP_SCHEDULE_DELAY=1000
export OTEL_BLRP_MAX_EXPORT_BATCH_SIZE=512
export OTEL_BLRP_EXPORT_TIMEOUT=30000
```

> **Overflow arithmetic.** If a service produces spans faster than `MAX_QUEUE_SIZE / SCHEDULE_DELAY` sustained, the queue fills and BSP drops spans with no exception — only a debug log and (in newer SDKs) a `otel.bsp.dropped_spans` self-metric. The fix is *not* a bigger queue (that just delays the OOM); it is either more `MAX_EXPORT_BATCH_SIZE`, a shorter `SCHEDULE_DELAY`, or **head sampling** (§5).

### 4.4 Metric readers and export interval

Metrics use a `MetricReader` (periodic push, or pull for Prometheus) instead of a processor:

```bash
export OTEL_METRIC_EXPORT_INTERVAL=60000      # ms between metric collect+export, default 60000
export OTEL_METRIC_EXPORT_TIMEOUT=30000       # ms, default 30000
```

**Temporality** is a metrics-only configuration with real backend consequences: `cumulative` (Prometheus-native, monotonic-from-start) vs `delta` (per-interval, cheaper for stateless gateways like some vendor backends). Set via `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE`. Choosing the wrong one produces broken `rate()` queries or double-counted counters.

---

## 5. Sampling configuration

Sampling is the volume/cost lever. **Head sampling** is an SDK configuration (decision made at span start, cheap, no full trace guarantee unless parent-based). **Tail sampling** lives in the Collector, not the SDK — do not confuse the two on the exam.

```bash
export OTEL_TRACES_SAMPLER="parentbased_traceidratio"   # default: parentbased_always_on
export OTEL_TRACES_SAMPLER_ARG="0.1"                     # 10% for ratio-based samplers
```

| Sampler | `OTEL_TRACES_SAMPLER` value | `SAMPLER_ARG` | Behavior |
|---|---|---|---|
| Always On | `always_on` | — | Sample every span |
| Always Off | `always_off` | — | Sample nothing (⚠️ silent blackhole if left in an image) |
| TraceID Ratio | `traceidratio` | float `0..1` | Deterministic % based on trace ID hash |
| Parent-based (default) | `parentbased_always_on` | — | Respect upstream decision; root = always on |
| Parent-based ratio | `parentbased_traceidratio` | float `0..1` | Respect parent; root sampled at ratio |
| Jaeger remote | `jaeger_remote` | `endpoint=…,pollingIntervalMs=…,initialSamplingRate=…` | Rate pushed from a control plane |

> **Why parent-based is the default and usually right.** With a plain `traceidratio` at 0.1, each service independently rolls the dice, so a trace is complete only if *every* hop happens to sample — probability `0.1^N` for N hops. `parentbased_traceidratio` makes the root decide once and every downstream service **honors** the decision (via the `sampled` flag in the propagated `traceparent`), yielding whole traces. Because the decision is a deterministic hash of the trace ID, all SDKs agree without coordination.

---

## 6. Context propagation configuration

Propagators serialize trace context into and out of carriers (HTTP headers, messaging metadata). Mismatched propagators across a service mesh is *the* reason traces "break" at a boundary.

```bash
# Default is "tracecontext,baggage" (W3C). Order = injection order; all listed are extracted.
export OTEL_PROPAGATORS="tracecontext,baggage,b3multi"
```

| Value | Header(s) | Notes |
|---|---|---|
| `tracecontext` | `traceparent`, `tracestate` | W3C standard, the default, always include it |
| `baggage` | `baggage` | Propagates user-defined key/values, default-on |
| `b3` | `b3` (single header) | Zipkin single-header form |
| `b3multi` | `X-B3-TraceId`, `X-B3-SpanId`, … | Legacy Zipkin multi-header |
| `jaeger` | `uber-trace-id` | Legacy Jaeger clients |
| `xray` | `X-Amzn-Trace-Id` | AWS X-Ray |
| `none` | — | Disable propagation (breaks distributed traces — rarely correct) |

> **Migration pattern.** To move a fleet from Zipkin/B3 to W3C without dropping traces mid-flight, set `OTEL_PROPAGATORS="tracecontext,baggage,b3multi"` everywhere. Services **extract** all three (so they understand old callers) but **inject** in list order. Once every service is upgraded, drop `b3multi`.

---

## 7. Limits and safety valves

Attribute/event/link limits are the defense against a runaway instrumentation call ballooning a single span to megabytes and OOMing the exporter queue. All are `OTEL_*` env vars with spec defaults:

```bash
export OTEL_ATTRIBUTE_COUNT_LIMIT=128                 # max attributes per span/log/resource
export OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT=4096         # truncate string values (default: unlimited)
export OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT=128            # per-span override
export OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT=4096
export OTEL_SPAN_EVENT_COUNT_LIMIT=128
export OTEL_SPAN_LINK_COUNT_LIMIT=128
export OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT=128
export OTEL_LINK_ATTRIBUTE_COUNT_LIMIT=128

# Global kill-switch and diagnostics
export OTEL_SDK_DISABLED=false        # "true" makes the SDK a no-op (all providers become no-op)
export OTEL_LOG_LEVEL=info            # SDK's own internal diagnostic logging: error|warn|info|debug
```

`OTEL_SDK_DISABLED=true` is the correct, spec-mandated way to disable OpenTelemetry entirely for a process — cleaner than `always_off` sampling because it also stops metrics and logs, not just traces.

---

## 8. Programmatic configuration — full manifest (Python)

When you own the entry point, code gives you what env vars can't: multiple pipelines, custom samplers, and views. This is a complete, syntactically valid bootstrap that a production Python service would import first.

```python
# otel_bootstrap.py — import this before any instrumented library.
from opentelemetry import trace, metrics
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.metrics.view import View, ExplicitBucketHistogramAggregation
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.propagate import set_global_textmap
from opentelemetry.propagators.composite import CompositePropagator
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.baggage.propagation import W3CBaggagePropagator

# 1) Identity. Attributes here override auto-detected keys of the same name.
resource = Resource.create({
    "service.name": "checkout-api",
    "service.namespace": "shop",
    "service.version": "2.14.3",
    "deployment.environment": "production",
})

# 2) Trace pipeline: parent-based 10% head sampling + batched OTLP/gRPC export.
tracer_provider = TracerProvider(
    resource=resource,
    sampler=ParentBased(root=TraceIdRatioBased(0.10)),
)
tracer_provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(endpoint="otel-collector.observability.svc:4317", insecure=True),
        max_queue_size=4096,          # raised above the 2048 default for a high-RPS service
        max_export_batch_size=1024,
        schedule_delay_millis=2000,   # flush more often to bound tail latency of loss
    )
)
trace.set_tracer_provider(tracer_provider)

# 3) Metric pipeline: 30s push interval + a custom latency histogram bucketing (a View —
#    impossible to express via env vars, the reason you drop to code).
reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint="otel-collector.observability.svc:4317", insecure=True),
    export_interval_millis=30000,
)
latency_view = View(
    instrument_name="http.server.duration",
    aggregation=ExplicitBucketHistogramAggregation(
        boundaries=[5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]
    ),
)
metrics.set_meter_provider(
    MeterProvider(resource=resource, metric_readers=[reader], views=[latency_view])
)

# 4) Propagation: W3C only, explicit.
set_global_textmap(CompositePropagator([
    TraceContextTextMapPropagator(),
    W3CBaggagePropagator(),
]))
```

---

## 9. Declarative / file-based configuration — full manifest

Declarative configuration (the `opentelemetry-configuration` schema) describes the *entire* SDK in one language-agnostic YAML document. It is the GitOps-friendly answer: reviewable, diffable, identical across Java/Go/Python/.NET. Activated by pointing an env var at the file; when set, other `OTEL_*` vars are ignored.

```bash
export OTEL_EXPERIMENTAL_CONFIG_FILE=/etc/otel/config.yaml
```

```yaml
# /etc/otel/config.yaml — declarative SDK configuration.
# file_format MUST match a schema version the SDK understands; it is still versioned/experimental.
file_format: "0.4"
disabled: false            # equivalent to OTEL_SDK_DISABLED

# ${ENV:default} substitution is the one place env vars still reach a file config.
log_level: ${OTEL_LOG_LEVEL:-info}

resource:
  attributes:
    - name: service.name
      value: checkout-api
    - name: service.namespace
      value: shop
    - name: service.version
      value: ${SERVICE_VERSION:-0.0.0}
    - name: deployment.environment
      value: production
  attributes_list: ${OTEL_RESOURCE_ATTRIBUTES:-}

attribute_limits:
  attribute_count_limit: 128
  attribute_value_length_limit: 4096

propagator:
  composite: [tracecontext, baggage]

tracer_provider:
  sampler:
    parent_based:
      root:
        trace_id_ratio_based:
          ratio: 0.10
  limits:
    event_count_limit: 128
    link_count_limit: 128
  processors:
    - batch:
        schedule_delay: 2000
        export_timeout: 30000
        max_queue_size: 4096
        max_export_batch_size: 1024
        exporter:
          otlp:
            protocol: grpc
            endpoint: http://otel-collector.observability.svc:4317
            compression: gzip
            timeout: 10000
            headers:
              - name: x-tenant
                value: shop

meter_provider:
  readers:
    - periodic:
        interval: 30000
        timeout: 30000
        exporter:
          otlp:
            protocol: http/protobuf
            endpoint: http://otel-collector.observability.svc:4318
            temporality_preference: delta
  views:
    - selector:
        instrument_name: http.server.duration
      stream:
        aggregation:
          explicit_bucket_histogram:
            boundaries: [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]

logger_provider:
  processors:
    - batch:
        exporter:
          otlp:
            protocol: grpc
            endpoint: http://otel-collector.observability.svc:4317
```

> The `file_format` value is a hard gate: an SDK that supports schema `0.3` will refuse a `0.4` document rather than silently mis-parse it. Pin the version and bump it deliberately.

---

## 10. Kubernetes: injecting configuration at scale

In practice you rarely set env vars by hand — you inject them. Two production patterns.

### 10.1 Plain env + ConfigMap

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: shop
spec:
  replicas: 3
  selector:
    matchLabels: { app: checkout-api }
  template:
    metadata:
      labels: { app: checkout-api }
    spec:
      containers:
        - name: app
          image: registry.example.com/checkout-api:2.14.3
          env:
            - name: OTEL_SERVICE_NAME
              value: checkout-api
            # Pull pod identity from the Downward API into the resource.
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=shop,service.version=2.14.3,deployment.environment=production"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc:4318"
            - name: OTEL_EXPORTER_OTLP_PROTOCOL
              value: "http/protobuf"
            - name: OTEL_TRACES_SAMPLER
              value: "parentbased_traceidratio"
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "0.1"
            - name: OTEL_BSP_MAX_QUEUE_SIZE
              value: "4096"
            - name: OTEL_PROPAGATORS
              value: "tracecontext,baggage"
```

### 10.2 OpenTelemetry Operator — zero-code injection via the `Instrumentation` CRD

For auto-instrumentation, the Operator injects the SDK and *all* the `OTEL_*` config through an annotation. Configuration is centralized in one cluster-scoped CR.

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: shop-instrumentation
  namespace: shop
spec:
  exporter:
    endpoint: http://otel-collector.observability.svc:4318
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "0.1"
  resource:
    addK8sUIDAttributes: true
  env:
    - name: OTEL_EXPORTER_OTLP_PROTOCOL
      value: http/protobuf
  python:
    env:
      - name: OTEL_METRIC_EXPORT_INTERVAL
        value: "30000"
```

Opt a workload in with a single pod-template annotation — no image rebuild:

```yaml
      annotations:
        instrumentation.opentelemetry.io/inject-python: "shop-instrumentation"
```

---

## 11. Verification and failure diagnosis

Configuration bugs manifest as *silence*, so you verify by making the pipeline talk before trusting it.

### Step 1 — dump the effective environment

```console
$ kubectl exec deploy/checkout-api -n shop -- env | grep OTEL_ | sort
OTEL_BSP_MAX_QUEUE_SIZE=4096
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_PROPAGATORS=tracecontext,baggage
OTEL_RESOURCE_ATTRIBUTES=service.namespace=shop,service.version=2.14.3,deployment.environment=production
OTEL_SERVICE_NAME=checkout-api
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1
```

### Step 2 — turn on the SDK's own diagnostics

```console
$ kubectl set env deploy/checkout-api -n shop OTEL_LOG_LEVEL=debug
deployment.apps/checkout-api env updated

$ kubectl logs deploy/checkout-api -n shop | grep -i otel
[otel.sdk] Resource attributes: {service.name=checkout-api, service.namespace=shop, ...}
[otel.sdk] BatchSpanProcessor started (queue=4096, batch=1024, delay=2000ms)
[otel.exporter.otlp] Exporting 1024 spans to http://otel-collector...svc:4318/v1/traces
[otel.exporter.otlp] Export SUCCESS: 1024 spans, HTTP 200, 41ms
```

### Step 3 — prove reachability from the pod (isolates network from config)

```console
$ kubectl exec deploy/checkout-api -n shop -- \
    curl -s -o /dev/null -w "%{http_code}\n" \
    http://otel-collector.observability.svc:4318/v1/traces -X POST \
    -H "Content-Type: application/x-protobuf" --data-binary ""
400
```

> `400` (bad request, because we sent an empty body) is *good news* — the endpoint exists and speaks OTLP/HTTP. `404` means wrong path (`/v1/traces` missing on a per-signal endpoint). `Connection refused` / timeout means the Collector or its Service is the problem, not your config.

### Step 4 — confirm at the Collector

```console
$ kubectl logs deploy/otel-collector -n observability | grep checkout-api
2026-08-10T14:02:11Z info  TracesExporter  {"resource": "checkout-api", "#spans": 1024}
```

### Step 5 — a Collector `debug` exporter as a smoke test

Temporarily route everything to stdout to prove data *arrives*:

```yaml
# collector snippet
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
```

### Failure catalogue

| Symptom | Likely configuration cause | Fix |
|---|---|---|
| No data at all, no errors in app | `OTEL_SDK_DISABLED=true` or `*_EXPORTER=none` | Unset; use `console` to confirm generation |
| No traces, metrics fine | `OTEL_TRACES_SAMPLER=always_off` or ratio `0` | Set `parentbased_always_on` to test |
| Exporter `404 Not Found` | Per-signal HTTP endpoint missing `/v1/traces` | Append the signal path, or use signal-agnostic endpoint |
| Exporter `connection refused` | Wrong port (4317 vs 4318) / protocol mismatch | Align `OTEL_EXPORTER_OTLP_PROTOCOL` with the port |
| Traces break at a service boundary | Propagator mismatch (`b3` on one side, `tracecontext` on other) | Add both to `OTEL_PROPAGATORS` fleet-wide |
| Everything grouped as `unknown_service` | `OTEL_SERVICE_NAME` unset | Set it (or via `OTEL_RESOURCE_ATTRIBUTES`) |
| Intermittent missing spans under load | BSP queue overflow | Raise `OTEL_BSP_MAX_QUEUE_SIZE` / batch size, or sample |
| In-code setting overrides env var | Programmatic config wins over env | Remove the hardcoded builder call |
| Env vars "ignored" entirely | `OTEL_EXPERIMENTAL_CONFIG_FILE` is set — file takes over | Move the setting into the YAML, or unset the file var |
| `gzip`/TLS handshake failures | `OTEL_EXPORTER_OTLP_COMPRESSION` / cert paths wrong | Verify CA/cert env vars and Collector TLS |

---

## References

- OpenTelemetry — Configuration (concepts): https://opentelemetry.io/docs/concepts/sdk-configuration/
- OpenTelemetry Specification — Environment Variable configuration: https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- OpenTelemetry Specification — Declarative (file) configuration: https://opentelemetry.io/docs/specs/otel/configuration/
- OpenTelemetry Configuration schema (repository): https://github.com/open-telemetry/opentelemetry-configuration
- OTLP Exporter configuration: https://opentelemetry.io/docs/specs/otel/protocol/exporter/
- OTLP Specification (protocol, ports, transports): https://opentelemetry.io/docs/specs/otlp/
- SDK — Trace, Sampling and SpanProcessor: https://opentelemetry.io/docs/specs/otel/trace/sdk/
- SDK — Span limits / Attribute limits: https://opentelemetry.io/docs/specs/otel/common/#configurable-parameters
- Resource semantic conventions: https://opentelemetry.io/docs/specs/semconv/resource/
- Context propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- OpenTelemetry Operator — `Instrumentation` CRD: https://github.com/open-telemetry/opentelemetry-operator
- OTCA certification / curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf