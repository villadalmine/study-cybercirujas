# OTCA 2.5 — SDK Pipelines

> **Signal path in one sentence:** the OpenTelemetry **API** produces telemetry, the **SDK pipeline** decides *whether to keep it, how to shape it, how to batch it, and where to ship it*, and the **exporter** hands it to a backend or the Collector. Topic 2.5 is about everything between the instrument and the wire.

---

## 1. Motivation: the production problem the SDK pipeline solves

The OTel **API** is deliberately dumb. When you call `tracer.Start(ctx, "GET /checkout")` or `counter.Add(ctx, 1)`, the API records an intent. It has *no* opinion about sampling, batching, retries, backpressure, cardinality, or transport. If the API did all that, every language binding would reimplement it, and you could not swap a no-op implementation into a library without dragging a network stack behind it.

The **SDK** is where those opinions live, and in production they are load-bearing decisions:

- **Throughput vs. loss.** A busy service emits tens of thousands of spans/sec. Exporting each one synchronously on span end (`SimpleSpanProcessor`) blocks the request path on network latency and collapses under load. You need a bounded, asynchronous, batched pipeline — and a bounded queue *will* drop data when the exporter stalls. The pipeline is where you choose *how* it degrades.
- **Cost vs. fidelity.** Head sampling at 100% is unaffordable at scale and useless without it. The **Sampler** sits at the front of the trace pipeline and its decision must propagate to children via `traceparent`, or you get broken traces where a parent is sampled and children are not.
- **Cardinality vs. resolution.** In metrics, a `Histogram` keyed on `http.route` is fine; keyed on `user.id` it is a memory bomb and a bill from your TSDB. **Views** and attribute filtering in the metrics pipeline are the only in-process guardrail.
- **Memory vs. semantics.** Delta vs. cumulative **temporality** is not a preference — Prometheus wants cumulative, many push systems want delta, and choosing wrong means either wrong rates or unbounded SDK memory.
- **Reproducibility.** Everything above must be configurable from **environment variables or declarative config**, so the same image behaves differently in dev, staging, and prod without a rebuild.

The pipeline is the same shape for all three signals — **Provider → (Sampler for traces / View for metrics) → Processor/Reader → Exporter → Resource-stamped OTLP** — but the moving parts differ per signal. Master the shape once; specialize three times.

```
                          ┌──────────────── Resource (service.name, k8s.*, host.*) ─── stamped on all ──┐
                          │                                                                              │
  API (Tracer)  ──span──▶ TracerProvider ─▶ Sampler ─▶ SpanProcessor(s) ─▶ SpanExporter ─▶ OTLP ─▶ Collector/Backend
  API (Meter)   ──meas──▶ MeterProvider  ─▶ View ────▶ MetricReader ─────▶ MetricExporter ─▶ OTLP ─┘
  API (Logger)  ──rec───▶ LoggerProvider ─────────────▶ LogRecordProcessor ▶ LogRecordExporter ▶ OTLP
```

---

## 2. Anatomy of each pipeline

### 2.1 Trace pipeline components

| Stage | Contract | Notes for production |
|---|---|---|
| **TracerProvider** | Holds Resource, Sampler, SpanProcessors, SpanLimits, IdGenerator. Root of the pipeline. | One per process. Must be **shut down** on exit to flush. A no-op provider is installed until you set one. |
| **Sampler** | `ShouldSample(ctx, traceID, name, kind, attrs, links) -> Decision` returning `DROP`, `RECORD_ONLY`, or `RECORD_AND_SAMPLE`. | Called **once, at span start**, on the *root* decision path. `RECORD_ONLY` keeps the span in-process (visible to `IsRecording()`) but sets `sampled=0` so it is not exported. |
| **SpanProcessor** | Hooks `OnStart(span, parentCtx)` and `OnEnd(readableSpan)`. Also `ForceFlush()` and `Shutdown()`. | Multiple processors run in registration order. `OnEnd` only fires for spans that are `RECORD_AND_SAMPLE` or `RECORD_ONLY`. |
| **SpanExporter** | `Export(batch) -> SUCCESS|FAILURE`, plus `Shutdown()`. | Stateless w.r.t. the pipeline; the processor owns batching/retry. Exporter must be **non-blocking-safe** to call from a background thread. |
| **SpanLimits** | Caps attribute count/length, events, links. | Prevents a single pathological span from OOMing the exporter. |

### 2.2 Metric pipeline components

| Stage | Contract | Notes for production |
|---|---|---|
| **MeterProvider** | Holds Resource, Views, MetricReaders. | Instruments are created via `Meter`; the provider wires them to readers. |
| **View** | Selects instruments (by name/kind/meter) and rewrites: name, description, **aggregation**, **attribute allow-list**, or drops them. | The one place to fix cardinality and pick explicit-bucket vs. exponential histograms *without touching code*. |
| **Aggregation** | `Sum`, `LastValue`, `ExplicitBucketHistogram`, `ExponentialHistogram`, `Drop`, `Default`. | Default is instrument-dependent (Counter→Sum, Gauge→LastValue, Histogram→ExplicitBucketHistogram). |
| **MetricReader** | Pulls aggregated points from the SDK. `PeriodicExportingMetricReader` (push, on a timer) or a pull reader (e.g. Prometheus scrape). | Owns **temporality** and interval. Each reader gets its own aggregation state. |
| **MetricExporter** | `Export(resourceMetrics)`, declares preferred **temporality** and **aggregation** per instrument kind. | OTLP exporter defaults to cumulative unless `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta`. |

### 2.3 Log pipeline components

The Logs SDK is intentionally the thinnest. The design assumption is that you route existing logging frameworks (log4j, logback, Python `logging`, zap/logrus) into the OTel `LoggerProvider` via a bridge/appender — you rarely call the Logs API directly in application code.

| Stage | Contract |
|---|---|
| **LoggerProvider** | Holds Resource and LogRecordProcessors. |
| **LogRecordProcessor** | `OnEmit(record, ctx)`, `ForceFlush`, `Shutdown`. Simple or Batch, same semantics as spans. |
| **LogRecordExporter** | `Export(batch)`, `Shutdown`. OTLP is the standard. |

---

## 3. Comparative trade-off tables

### 3.1 SimpleSpanProcessor vs. BatchSpanProcessor

| Dimension | SimpleSpanProcessor | BatchSpanProcessor (BSP) |
|---|---|---|
| Export trigger | Synchronously on **every** `OnEnd` | On timer (`scheduleDelay`) **or** when batch hits `maxExportBatchSize` |
| Thread model | Exports on the ending thread (often the request thread) | Dedicated background worker drains a bounded queue |
| Latency impact | Adds exporter RTT to the request path | ≈ zero on request path (enqueue only) |
| Data loss mode | Loses data only if export fails | **Drops on full queue** (`maxQueueSize`) when exporter can't keep up |
| Ordering | Strict | Batched, order within batch preserved |
| Memory | Minimal | Up to `maxQueueSize` spans buffered |
| When to use | Tests, short-lived CLIs, `ConsoleExporter` debugging | **Everything in production** |
| Governing env vars | — | `OTEL_BSP_SCHEDULE_DELAY`, `OTEL_BSP_EXPORT_TIMEOUT`, `OTEL_BSP_MAX_QUEUE_SIZE`, `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` |

**BSP defaults (spec):** `scheduleDelay=5000ms`, `exportTimeout=30000ms`, `maxQueueSize=2048`, `maxExportBatchSize=512`. Invariant to respect: `maxExportBatchSize ≤ maxQueueSize`.

### 3.2 Samplers

| Sampler | Decision basis | Parent-aware? | Typical use |
|---|---|---|---|
| `AlwaysOn` | Sample everything | No | Dev; low-volume services |
| `AlwaysOff` | Drop everything | No | Kill switch |
| `TraceIdRatioBased(p)` | Deterministic hash of traceID < p | No | Uniform head sampling |
| **`ParentBased(root=…)`** | Respect incoming `sampled` flag; use `root` sampler only when there is no parent | **Yes** | **Production default** — keeps traces whole |
| Custom / composite | Rule-based (by name, attribute, rate limit) | Depends | Tail-ish head logic; SLO-driven |

> **Trap:** using a bare `TraceIdRatioBased` (not wrapped in `ParentBased`) means each service re-rolls the dice, producing partial traces. Head sampling belongs in `ParentBased(root=TraceIdRatioBased(p))`; true **tail sampling** is not an SDK feature — it lives in the Collector's `tail_sampling` processor because it needs the whole trace assembled first.

### 3.3 Metric temporality

| Aspect | Cumulative | Delta |
|---|---|---|
| Point value | Running total since process start | Change since last export |
| SDK memory | Holds state for the life of the series | Can reset/forget series after export |
| Restart behavior | Counter resets → consumer must detect drop | Naturally resets each interval |
| Preferred backend | Prometheus, anything doing `rate()` | Statsd-style, some SaaS ingesters |
| OTLP default | **Cumulative** | Opt-in via `…_TEMPORALITY_PREFERENCE=delta` |
| Cardinality churn | Worse (must retain all series) | Better (can drop idle series) |

### 3.4 OTLP transport

| | gRPC (`grpc`) | HTTP/protobuf (`http/protobuf`) | HTTP/JSON (`http/json`) |
|---|---|---|---|
| Default port | 4317 | 4318 | 4318 |
| Framing | HTTP/2 streams | POST per batch | POST per batch |
| Compression | gzip | gzip | gzip |
| Proxy/L7 friendliness | Needs HTTP/2-aware LB | Works through any HTTP proxy | Works, largest payloads |
| Env value | `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` | `=http/protobuf` | `=http/json` |
| Signal-specific path | — | `/v1/traces`, `/v1/metrics`, `/v1/logs` | same |

---

## 4. Full manifests and code — nothing trimmed

### 4.1 Go SDK — complete three-signal pipeline bootstrap

This is the canonical, production-shaped setup: OTLP/gRPC exporters, `ParentBased` ratio sampler, `BatchSpanProcessor`, a `PeriodicExportingMetricReader` with a cardinality-limiting View, W3C propagators, and a clean shutdown that flushes.

```go
// otel.go — call setupOTel(ctx) from main, defer the returned shutdown.
package main

import (
	"context"
	"errors"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

func setupOTel(ctx context.Context) (shutdown func(context.Context) error, err error) {
	var shutdownFuncs []func(context.Context) error
	shutdown = func(ctx context.Context) error {
		var e error
		for _, fn := range shutdownFuncs {
			e = errors.Join(e, fn(ctx))
		}
		shutdownFuncs = nil
		return e
	}

	// ---- Resource: identity stamped on every span/metric/log ----
	res, err := resource.New(ctx,
		resource.WithFromEnv(),   // absorbs OTEL_RESOURCE_ATTRIBUTES / OTEL_SERVICE_NAME
		resource.WithHost(),
		resource.WithAttributes(
			semconv.ServiceName("checkout"),
			semconv.ServiceVersion("2.4.1"),
			semconv.DeploymentEnvironment("prod"),
			attribute.String("service.namespace", "shop"),
		),
	)
	if err != nil {
		return nil, err
	}

	// ---- W3C context propagation (traceparent + baggage) ----
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	// ================= TRACE pipeline =================
	traceExp, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint("otel-collector.observability.svc:4317"),
		otlptracegrpc.WithInsecure(), // in-cluster; use TLS at the mesh edge
	)
	if err != nil {
		return nil, err
	}
	tp := trace.NewTracerProvider(
		trace.WithResource(res),
		trace.WithSampler(
			trace.ParentBased(trace.TraceIDRatioBased(0.10)), // 10% head sampling, parent wins
		),
		trace.WithBatcher(traceExp, // BatchSpanProcessor with explicit tuning
			trace.WithMaxQueueSize(4096),
			trace.WithMaxExportBatchSize(512),
			trace.WithBatchTimeout(3*time.Second),
			trace.WithExportTimeout(30*time.Second),
		),
		trace.WithRawSpanLimits(trace.SpanLimits{
			AttributeCountLimit: 128,
			EventCountLimit:     128,
			LinkCountLimit:      128,
		}),
	)
	otel.SetTracerProvider(tp)
	shutdownFuncs = append(shutdownFuncs, tp.Shutdown)

	// ================= METRIC pipeline =================
	metricExp, err := otlpmetricgrpc.New(ctx,
		otlpmetricgrpc.WithEndpoint("otel-collector.observability.svc:4317"),
		otlpmetricgrpc.WithInsecure(),
	)
	if err != nil {
		return nil, err
	}

	// View: bound latency histogram cardinality by keeping only route + status.
	latencyView := metric.NewView(
		metric.Instrument{Name: "http.server.duration"},
		metric.Stream{
			Aggregation: metric.AggregationExplicitBucketHistogram{
				Boundaries: []float64{5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000},
			},
			AttributeFilter: attribute.NewAllowKeysFilter(
				"http.route", "http.response.status_code",
			),
		},
	)

	mp := metric.NewMeterProvider(
		metric.WithResource(res),
		metric.WithView(latencyView),
		metric.WithReader(metric.NewPeriodicReader(metricExp,
			metric.WithInterval(30*time.Second),
			metric.WithTimeout(15*time.Second),
		)),
	)
	otel.SetMeterProvider(mp)
	shutdownFuncs = append(shutdownFuncs, mp.Shutdown)

	return shutdown, nil
}
```

Wiring it in `main`:

```go
func main() {
	ctx := context.Background()
	shutdown, err := setupOTel(ctx)
	if err != nil {
		log.Fatalf("otel init: %v", err)
	}
	// Critical: flush the BSP queue + last metric collection on the way out.
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := shutdown(ctx); err != nil {
			log.Printf("otel shutdown: %v", err)
		}
	}()
	runServer(ctx)
}
```

### 4.2 Python SDK — equivalent pipeline (traces + metrics)

```python
# otel_setup.py
from opentelemetry import trace, metrics
from opentelemetry.sdk.resources import Resource, SERVICE_NAME, SERVICE_VERSION
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

ENDPOINT = "otel-collector.observability.svc:4317"

def setup_otel() -> None:
    resource = Resource.create({
        SERVICE_NAME: "checkout",
        SERVICE_VERSION: "2.4.1",
        "deployment.environment": "prod",
        "service.namespace": "shop",
    })

    set_global_textmap(CompositePropagator([
        TraceContextTextMapPropagator(),
        W3CBaggagePropagator(),
    ]))

    # ---- TRACES ----
    tp = TracerProvider(
        resource=resource,
        sampler=ParentBased(root=TraceIdRatioBased(0.10)),
    )
    tp.add_span_processor(BatchSpanProcessor(
        OTLPSpanExporter(endpoint=ENDPOINT, insecure=True),
        max_queue_size=4096,
        max_export_batch_size=512,
        schedule_delay_millis=3000,
        export_timeout_millis=30000,
    ))
    trace.set_tracer_provider(tp)

    # ---- METRICS ----
    latency_view = View(
        instrument_name="http.server.duration",
        aggregation=ExplicitBucketHistogramAggregation(
            boundaries=[5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]),
        attribute_keys={"http.route", "http.response.status_code"},
    )
    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=ENDPOINT, insecure=True),
        export_interval_millis=30000,
        export_timeout_millis=15000,
    )
    metrics.set_meter_provider(MeterProvider(
        resource=resource, metric_readers=[reader], views=[latency_view],
    ))
```

### 4.3 Declarative file configuration (config-first, zero code changes)

Since OTel v1.x the SDK ships **declarative configuration**: point `OTEL_EXPERIMENTAL_CONFIG_FILE` at a YAML file and the SDK builds the exact same pipeline objects. This is the GitOps-friendly path — the pipeline lives in a ConfigMap, not a compiled binary.

```yaml
# otel-sdk-config.yaml  — consumed via OTEL_EXPERIMENTAL_CONFIG_FILE
file_format: "0.4"

resource:
  attributes:
    - name: service.name
      value: checkout
    - name: service.version
      value: "2.4.1"
    - name: deployment.environment
      value: prod

propagator:
  composite: [tracecontext, baggage]

tracer_provider:
  sampler:
    parent_based:
      root:
        trace_id_ratio_based:
          ratio: 0.10
  span_limits:
    attribute_count_limit: 128
    event_count_limit: 128
    link_count_limit: 128
  processors:
    - batch:
        schedule_delay: 3000
        export_timeout: 30000
        max_queue_size: 4096
        max_export_batch_size: 512
        exporter:
          otlp:
            protocol: grpc
            endpoint: http://otel-collector.observability.svc:4317
            insecure: true

meter_provider:
  views:
    - selector:
        instrument_name: http.server.duration
      stream:
        aggregation:
          explicit_bucket_histogram:
            boundaries: [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]
        attribute_keys: [http.route, http.response.status_code]
  readers:
    - periodic:
        interval: 30000
        timeout: 15000
        exporter:
          otlp:
            protocol: grpc
            endpoint: http://otel-collector.observability.svc:4317
            temporality_preference: cumulative
            insecure: true

logger_provider:
  processors:
    - batch:
        exporter:
          otlp:
            protocol: grpc
            endpoint: http://otel-collector.observability.svc:4317
            insecure: true
```

### 4.4 Kubernetes wiring — env-var configuration of the same pipeline

For SDKs where you have *not* adopted declarative config, the pipeline is driven entirely by environment variables. Here the full set as a Deployment overlay, plus the config file mounted for the declarative path.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
spec:
  replicas: 3
  selector:
    matchLabels: { app: checkout }
  template:
    metadata:
      labels: { app: checkout }
    spec:
      containers:
        - name: checkout
          image: registry.example.com/checkout:2.4.1
          env:
            # --- identity ---
            - name: OTEL_SERVICE_NAME
              value: "checkout"
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.version=2.4.1,deployment.environment=prod,k8s.pod.name=$(POD_NAME),k8s.node.name=$(NODE_NAME)"
            # --- transport (shared) ---
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc:4317"
            - name: OTEL_EXPORTER_OTLP_PROTOCOL
              value: "grpc"
            # --- trace pipeline ---
            - name: OTEL_TRACES_SAMPLER
              value: "parentbased_traceidratio"
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "0.10"
            - name: OTEL_BSP_SCHEDULE_DELAY
              value: "3000"
            - name: OTEL_BSP_MAX_QUEUE_SIZE
              value: "4096"
            - name: OTEL_BSP_MAX_EXPORT_BATCH_SIZE
              value: "512"
            - name: OTEL_BSP_EXPORT_TIMEOUT
              value: "30000"
            # --- metric pipeline ---
            - name: OTEL_METRIC_EXPORT_INTERVAL
              value: "30000"
            - name: OTEL_METRIC_EXPORT_TIMEOUT
              value: "15000"
            - name: OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE
              value: "cumulative"
            # --- propagation ---
            - name: OTEL_PROPAGATORS
              value: "tracecontext,baggage"
          # Declarative-config path (mutually exclusive with the vars above):
          # - name: OTEL_EXPERIMENTAL_CONFIG_FILE
          #   value: /etc/otel/otel-sdk-config.yaml
          volumeMounts:
            - name: otel-config
              mountPath: /etc/otel
              readOnly: true
      volumes:
        - name: otel-config
          configMap:
            name: otel-sdk-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-sdk-config
  namespace: shop
data:
  otel-sdk-config.yaml: |
    file_format: "0.4"
    resource:
      attributes:
        - { name: service.name, value: checkout }
    tracer_provider:
      processors:
        - batch:
            exporter:
              otlp: { protocol: grpc, endpoint: http://otel-collector.observability.svc:4317, insecure: true }
```

---

## 5. CLI commands and real terminal output

### 5.1 Inspect the effective environment (what the SDK actually reads)

```console
$ env | grep -E '^OTEL_' | sort
OTEL_BSP_MAX_EXPORT_BATCH_SIZE=512
OTEL_BSP_MAX_QUEUE_SIZE=4096
OTEL_BSP_SCHEDULE_DELAY=3000
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_METRIC_EXPORT_INTERVAL=30000
OTEL_PROPAGATORS=tracecontext,baggage
OTEL_RESOURCE_ATTRIBUTES=service.version=2.4.1,deployment.environment=prod
OTEL_SERVICE_NAME=checkout
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.10
```

### 5.2 Prove the pipeline end-to-end with the console exporter (no backend needed)

Swap the OTLP endpoint for stdout to see exactly what the processor emits. In Python:

```console
$ export OTEL_TRACES_EXPORTER=console
$ export OTEL_TRACES_SAMPLER=always_on
$ opentelemetry-instrument python app.py
{
    "name": "GET /checkout",
    "context": {
        "trace_id": "0x7b5e3f9c2a1d4e8f0b6c9a2d5e8f1b3c",
        "span_id": "0x1a2b3c4d5e6f7a8b",
        "trace_state": "[]"
    },
    "kind": "SpanKind.SERVER",
    "parent_id": null,
    "start_time": "2026-08-10T12:04:33.129482Z",
    "end_time":   "2026-08-10T12:04:33.171904Z",
    "status": { "status_code": "OK" },
    "attributes": {
        "http.request.method": "GET",
        "http.route": "/checkout",
        "http.response.status_code": 200
    },
    "resource": {
        "attributes": {
            "service.name": "checkout",
            "service.version": "2.4.1",
            "deployment.environment": "prod"
        }
    }
}
```

Key things this output *verifies*: the **Resource** is stamped (bottom block), the **Sampler** kept the span (it printed), and the span carries `trace_id` for propagation. Setting `OTEL_TRACES_SAMPLER=always_off` and rerunning prints **nothing** — that is the sampler stage doing its job at the front of the pipeline.

### 5.3 Confirm bytes leave the process (transport layer)

```console
$ export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
$ export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
$ curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST http://localhost:4318/v1/traces \
    -H "Content-Type: application/x-protobuf" --data-binary @/dev/null
200
```

A `200` on an empty POST proves the OTLP/HTTP receiver is up and the path (`/v1/traces`) is correct — isolating "SDK not exporting" from "collector not listening."

### 5.4 Emit a synthetic span with `otel-cli` to test the collector independent of the app

```console
$ otel-cli span \
    --service checkout \
    --name "manual smoke" \
    --endpoint localhost:4317 \
    --protocol grpc \
    --verbose
# trace_id: 4f2c8b1e9d3a5c7f0e2b4d6a8c1f3e5b
# span_id:  9a1b2c3d4e5f6a7b
# sent OTLP span to localhost:4317 (grpc) in 8ms
```

### 5.5 Watch the collector confirm receipt (debug exporter on the Collector side)

```console
$ kubectl -n observability logs deploy/otel-collector | tail -n 20
2026-08-10T12:05:02.744Z  info  TracesExporter  {"kind": "exporter",
  "data_type": "traces", "name": "debug", "resource spans": 1, "spans": 1}
2026-08-10T12:05:02.744Z  info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
     -> service.version: Str(2.4.1)
     -> deployment.environment: Str(prod)
ScopeSpans #0
Span #0
    Trace ID       : 4f2c8b1e9d3a5c7f0e2b4d6a8c1f3e5b
    Name           : manual smoke
    Kind           : Internal
    Status code    : Unset
```

The match between the `otel-cli` trace_id (5.4) and the collector log (5.5) is the definitive end-to-end proof that the pipeline is intact.

---

## 6. Verification and failure diagnosis

### 6.1 A layered diagnostic ladder (isolate the failing stage)

| Symptom | Likely stage | Check | Fix |
|---|---|---|---|
| No spans anywhere | Provider not installed / no-op | Console exporter prints nothing even with `always_on` | Ensure `SetTracerProvider`/instrumentation ran before first span |
| Console prints, collector empty | Exporter/transport | `curl /v1/traces` → non-200, or TLS handshake error | Fix endpoint, protocol (`grpc` vs `http/protobuf`), `insecure`, port 4317 vs 4318 |
| Some services missing from a trace | Sampler | Child `sampled=0` while parent `sampled=1` | Wrap ratio sampler in `ParentBased`; verify `OTEL_PROPAGATORS=tracepcontext` |
| Spans arrive but lag/burst then stop | BSP queue overflow | SDK self-logs "dropped spans"; queue full | Raise `MAX_QUEUE_SIZE`, lower `SCHEDULE_DELAY`, or scale collector |
| Data lost on pod exit | No shutdown/flush | Last batch missing on SIGTERM | Call `provider.Shutdown()`/`ForceFlush()`; set `terminationGracePeriodSeconds` ≥ export timeout |
| Metric cardinality explosion / OOM | Missing View | Series count per instrument huge | Add View with `attribute_keys` allow-list or `Drop` aggregation |
| Rates look wrong in Prometheus | Temporality mismatch | Exporter sending delta to a cumulative store | Set `…_TEMPORALITY_PREFERENCE=cumulative` |
| Latency histogram unusable | Bucket boundaries | Everything in one bucket | Tune `ExplicitBucketHistogram` boundaries or switch to exponential |

### 6.2 Turn on the SDK's own self-diagnostics

The pipeline reports its internal errors through the SDK's error handler — enable it before blaming the network.

```console
$ export OTEL_LOG_LEVEL=debug          # supported by several SDKs / autoinstrumentation
$ export OTEL_TRACES_EXPORTER=otlp
$ ./checkout
2026-08-10T12:07:11Z DEBUG bsp: enqueued span (queue=1/4096)
2026-08-10T12:07:14Z DEBUG bsp: export batch size=1 timeout=30s
2026-08-10T12:07:14Z ERROR exporter: rpc error: code = Unavailable
    desc = connection error: desc = "transport: Error while dialing:
    dial tcp 10.96.4.12:4317: connect: connection refused"
2026-08-10T12:07:19Z WARN  bsp: dropped 0 spans (queue not full, retrying)
```

That `connection refused` places the failure squarely at the transport stage, not sampling or batching — no need to touch the app.

### 6.3 Verifying the sampler decision deterministically

`TraceIdRatioBased` is deterministic on the trace ID, so you can prove the rate without statistics:

```console
$ for i in $(seq 1 10000); do otel-cli span --tp-print --name t$i \
    --endpoint /dev/null 2>/dev/null; done | \
  grep -c 'sampled=01'
1004
```

≈1004/10000 sampled confirms the `0.10` ratio is honored by the pipeline within noise.

### 6.4 Backpressure and shutdown — the two production killers

- **Backpressure:** a slow/unavailable collector fills the BSP queue; once full the processor **drops** new spans (it never blocks the app — that is by design). Alert on the SDK's dropped-span counter, and give the collector headroom or a queue of its own. The SDK pipeline is *lossy by contract*; the durability guarantee lives downstream in the Collector's `sending_queue` + persistent storage, not in the SDK.
- **Shutdown:** the last batch lives only in memory. On `SIGTERM`, Kubernetes gives `terminationGracePeriodSeconds`; if `Shutdown()`/`ForceFlush()` isn't wired into your signal handler, or the grace period is shorter than `OTEL_BSP_EXPORT_TIMEOUT`, the final spans of every request in flight are lost. Set the grace period ≥ export timeout and always call shutdown.

---

## 7. References

- OpenTelemetry Trace SDK specification — <https://opentelemetry.io/docs/specs/otel/trace/sdk/>
- OpenTelemetry Metrics SDK specification (Views, Readers, Aggregation, Temporality) — <https://opentelemetry.io/docs/specs/otel/metrics/sdk/>
- OpenTelemetry Logs SDK specification — <https://opentelemetry.io/docs/specs/otel/logs/sdk/>
- SDK configuration & environment variables — <https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/>
- Declarative (file-based) configuration — <https://opentelemetry.io/docs/specs/otel/configuration/>
- Sampling concepts — <https://opentelemetry.io/docs/concepts/sampling/>
- OTLP protocol specification — <https://opentelemetry.io/docs/specs/otlp/>
- OTLP Exporter configuration — <https://opentelemetry.io/docs/specs/otel/protocol/exporter/>
- Language SDK guides (Go/Python/Java setup) — <https://opentelemetry.io/docs/languages/>
- Resource semantic conventions — <https://opentelemetry.io/docs/specs/semconv/resource/>
- Collector `tail_sampling` processor (why tail sampling is not an SDK feature) — <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor>
- `otel-cli` tool — <https://github.com/equinix-labs/otel-cli>
- OTCA curriculum — <https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf>