# 2.2 — Composability and Extension

> **OTCA Domain 2 — The OpenTelemetry API and SDK · Sub-competency 2.2 · Exam weight ≈ 6.57 %**
> Level: Principal Platform Architect / Senior SRE. This chapter treats *composability* (assembling telemetry pipelines from independent, swappable components) and *extension* (implementing the project's interfaces to add components that do not ship in the box). Both are the same architectural bet, applied once inside the process (API/SDK) and once outside it (the Collector).

---

## 1. Motivation: the architectural problem in production

### 1.1 The N×M integration trap

Before OpenTelemetry, every observability integration was a point-to-point coupling. If you ran `N` languages/frameworks and shipped to `M` backends (Jaeger, Zipkin, Prometheus, a SaaS APM, a log store), you owned up to `N×M` instrumentation agents, each with its own wire format, its own config surface, and its own upgrade cadence. Swapping a backend meant recompiling and redeploying every service. This is *vendor lock-in expressed as a build dependency*.

OpenTelemetry collapses `N×M` into `N+M` by inserting two composability seams:

1. **API ⟂ SDK separation** inside the process — instrumentation depends on the *API only*; the SDK (the moving parts) is chosen at the edge, by the application owner.
2. **The Collector** outside the process — a vendor-agnostic broker where receivers, processors, and exporters are wired into pipelines at *configuration* time, not compile time.

The load-bearing decision is the first one. Because the API ships a **no-op implementation** by default, a library author (say, a database driver) can call `tracer.Start(...)` unconditionally. If no SDK is installed, the calls cost nothing and produce nothing; if an SDK *is* installed, the same calls light up. Instrumentation is thus **decoupled from configuration** — the person writing the span is not the person deciding where it goes, how it's sampled, or whether it's recorded at all.

### 1.2 What "composable" means precisely

The SDK is not a monolith. It is a small set of **provider** objects, each holding a graph of pluggable parts you assemble:

```
TracerProvider ── Resource
              ├── Sampler                (record-or-drop decision)
              ├── IdGenerator            (trace/span ID scheme)
              ├── SpanLimits             (attribute/event/link caps)
              └── [SpanProcessor ...]    (ordered pipeline; each wraps a SpanExporter)

MeterProvider  ── Resource
              ├── [MetricReader ...]     (each wraps a MetricExporter or is pull-based)
              ├── [View ...]             (per-instrument stream shaping)
              └── ExemplarFilter

LoggerProvider ── Resource
              └── [LogRecordProcessor ...] (each wraps a LogRecordExporter)

Propagators    ── CompositeTextMapPropagator([tracecontext, baggage, b3, ...])
```

Every bracketed slot accepts a **list**, and every element of every list is an **interface**. That is composability: fan-out to two exporters by adding a second processor; add PII redaction by inserting a processor before the exporter; change sampling policy without touching a single instrumented line.

### 1.3 What "extensible" means precisely

Composability lets you *arrange* the components the SDK ships. Extension lets you *add your own* by satisfying the same interfaces the built-ins satisfy — there is no privileged built-in. A custom `Sampler`, `SpanProcessor`, `SpanExporter`, `MetricReader`, or `TextMapPropagator` is a first-class citizen the moment it implements the contract.

Outside the process, the same principle produces the **OpenTelemetry Collector Builder (`ocb`)**: the Collector is a thin core plus a set of components chosen at *build* time from a manifest. A component that is not compiled into your distribution cannot be referenced in config — this is the single most common production surprise, covered in §5.

---

## 2. Technical comparisons and trade-offs

### 2.1 API vs SDK — the seam that makes everything else possible

| Aspect | API | SDK |
|---|---|---|
| Purpose | Contract instrumentation writes against | Implementation that records, samples, exports |
| Default behavior with no config | **No-op** (zero cost, no output) | N/A — you install it deliberately |
| Who depends on it | Library authors, framework authors | Application owner (the binary's `main`) |
| Stability guarantee | Strong — breaking it breaks every library | Looser — internals may evolve |
| Swappable at | Compile time (rarely changed) | Config/startup time (changed freely) |
| Analogy | `slf4j` / `log/slog` interface | `logback` / a concrete handler |

**Rule of thumb:** a library must **never** depend on the SDK. If you find `opentelemetry-sdk` in a *library's* dependency graph, that library forces a global SDK on every consumer — an anti-pattern.

### 2.2 SpanProcessor strategies

| | `SimpleSpanProcessor` | `BatchSpanProcessor` (BSP) |
|---|---|---|
| Export timing | Synchronous, one span per export | Buffered, flushed on timer or batch size |
| Blocking | Blocks `span.End()` | Non-blocking (background worker) |
| Throughput | Low; one RPC per span | High; amortized RPCs |
| Data-loss window | None until export attempt | Up to `max_queue_size` on crash |
| Prod use | Tests, debugging only | **Default for all production** |
| Key knobs | — | `schedule_delay`, `max_queue_size`, `max_export_batch_size`, `export_timeout` |

### 2.3 Samplers

| Sampler | Decision basis | Determinism | Typical use |
|---|---|---|---|
| `AlwaysOn` | Always record | Yes | Dev, low-volume |
| `AlwaysOff` | Never record | Yes | Kill switch |
| `TraceIdRatioBased(p)` | Hash of trace ID vs `p` | Yes, consistent across services *if* the same `p` is used | Head sampling |
| `ParentBased(root=…)` | Honor parent's sampled flag; use `root` sampler when no parent | Yes | **Default** — keeps traces whole |
| Custom (`Sampler` iface) | Anything (route by attribute, tenant, rate-limit) | Your choice | Tenant-aware, cost control |

> **Head vs tail:** SDK samplers are *head* samplers — they decide at span start, before the outcome is known, so they cannot "keep all errors." Tail sampling (decide after the trace completes) lives in the **Collector** (`tailsamplingprocessor`), a composability reason to push policy out of the process.

### 2.4 Collector component taxonomy (the extension surface)

| Component | Role | Pipeline position | Examples |
|---|---|---|---|
| **Receiver** | Ingest data in | Entry | `otlp`, `prometheus`, `filelog`, `kafka` |
| **Processor** | Transform/limit/filter | Middle (ordered) | `batch`, `memory_limiter`, `transform`, `tail_sampling`, `k8sattributes` |
| **Exporter** | Emit data out | Exit | `otlp`, `prometheus`, `debug`, `loadbalancing` |
| **Connector** | Exit of one pipeline → entry of another | Bridge | `spanmetrics`, `count`, `routing`, `forward` |
| **Extension** | Process-wide capability, not in the data path | Sidecar | `health_check`, `pprof`, `zpages`, `oauth2client`, `file_storage` |

**Connectors** are the composability primitive most people miss: they let one signal *become* another (traces → RED metrics via `spanmetrics`) or route by content, without any external hop.

### 2.5 Collector distributions

| Distribution | Contents | Trade-off |
|---|---|---|
| **Core** (`otelcol`) | Minimal, spec-critical components only | Tiny, safe; often missing what you need |
| **Contrib** (`otelcol-contrib`) | ~everything in the registry | Huge binary/attack surface; great for prototyping |
| **Custom** (built with `ocb`) | Exactly the components you list | Smallest footprint, least CVE surface; **you own the build** |

Production ≠ contrib. Contrib is the "batteries-included prototyping" image; production should be a **custom `ocb` build** pinned to the components in your config.

### 2.6 SDK configuration mechanisms (a composability layer of its own)

| Mechanism | Format | Coverage | Best for |
|---|---|---|---|
| Programmatic | Code (Go/Java/Python/…) | Full, incl. custom components | Custom extensions, dynamic wiring |
| Environment variables (autoconfig) | `OTEL_*` | Common built-ins only | 12-factor deploys, containers |
| Declarative file config | YAML (`opentelemetry-configuration` schema) | Full built-in graph, language-agnostic | Config as data, GitOps, one file across languages |

---

## 3. Complete manifests and infrastructure

### 3.1 A composed Collector pipeline: OTLP in → RED metrics via a connector → two backends

This config demonstrates every composability primitive at once: two receivers, an ordered processor chain, a **connector** that manufactures metrics from spans, three exporters, and three extensions.

```yaml
# otelcol.yaml — production-shaped, nothing elided
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: /status
  pprof:
    endpoint: 127.0.0.1:1777
  zpages:
    endpoint: 127.0.0.1:55679

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
  # Scrape the Collector's own Prometheus endpoint back in (self-observability)
  prometheus/internal:
    config:
      scrape_configs:
        - job_name: otel-collector-internal
          scrape_interval: 15s
          static_configs:
            - targets: [127.0.0.1:8888]

processors:
  # memory_limiter MUST be first so backpressure is applied before buffering.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25
  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.deployment.name
        - k8s.node.name
  transform/redact:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          - replace_pattern(attributes["http.url"], "token=[^&]+", "token=REDACTED")
          - delete_key(attributes, "user.email")
  # batch MUST be last so limiting/redaction happen before amortized export.
  batch:
    send_batch_size: 8192
    send_batch_max_size: 10000
    timeout: 5s

connectors:
  # Exporter of the traces pipeline; receiver of the metrics pipeline.
  spanmetrics:
    histogram:
      explicit:
        buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2s, 5s]
    dimensions:
      - name: http.method
      - name: http.status_code
    exemplars:
      enabled: true
    metrics_flush_interval: 15s

exporters:
  otlp/tempo:
    endpoint: tempo.observability.svc:4317
    tls:
      insecure: false
      ca_file: /etc/otel/certs/ca.crt
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
  prometheus:
    endpoint: 0.0.0.0:8889
    resource_to_telemetry_conversion:
      enabled: true
  debug:
    verbosity: normal
    sampling_initial: 5
    sampling_thereafter: 200

service:
  extensions: [health_check, pprof, zpages]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, transform/redact, batch]
      exporters: [otlp/tempo, spanmetrics]        # spanmetrics = connector-as-exporter
    metrics:
      receivers: [otlp, spanmetrics, prometheus/internal]  # spanmetrics = connector-as-receiver
      processors: [memory_limiter, batch]
      exporters: [prometheus, debug]
  telemetry:
    logs:
      level: info
    metrics:
      level: detailed
      address: 0.0.0.0:8888
```

**Composability call-outs.** Processor order is semantic, not cosmetic: `memory_limiter` first (apply backpressure), `batch` last (amortize after all shaping). The `spanmetrics` connector appears once as an *exporter* and once as a *receiver* — that dual reference is what wires two pipelines together. Remove either reference and startup fails (§5).

### 3.2 The `ocb` build manifest — extension by construction

You do not ship the config above on `otelcol-contrib`. You compile a distribution containing *exactly* its components.

```yaml
# builder-config.yaml — input to the OpenTelemetry Collector Builder (ocb)
dist:
  module: github.com/acme/otelcol-acme
  name: otelcol-acme
  description: ACME production OTel Collector distribution
  output_path: ./_build
  version: 1.4.0
  otelcol_version: 0.116.0

extensions:
  - gomod: go.opentelemetry.io/collector/extension/zpagesextension v0.116.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/extension/healthcheckextension v0.116.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/extension/pprofextension v0.116.0

receivers:
  - gomod: go.opentelemetry.io/collector/receiver/otlpreceiver v0.116.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/receiver/prometheusreceiver v0.116.0

processors:
  - gomod: go.opentelemetry.io/collector/processor/memorylimiterprocessor v0.116.0
  - gomod: go.opentelemetry.io/collector/processor/batchprocessor v0.116.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/processor/k8sattributesprocessor v0.116.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/processor/transformprocessor v0.116.0

exporters:
  - gomod: go.opentelemetry.io/collector/exporter/debugexporter v0.116.0
  - gomod: go.opentelemetry.io/collector/exporter/otlpexporter v0.116.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/exporter/prometheusexporter v0.116.0

connectors:
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/connector/spanmetricsconnector v0.116.0

# Optional: pin a locally-developed private component into the build.
# replaces:
#   - github.com/acme/otel-tenantsampler => /home/build/tenantsampler
```

> Core components live under `go.opentelemetry.io/collector/…`; community components under `github.com/open-telemetry/opentelemetry-collector-contrib/…`. Every `gomod` line must share the same `v0.116.0` tag as `otelcol_version`, or the build fails on incompatible module APIs.

### 3.3 Declarative SDK configuration — one file, every language

The in-process equivalent of a Collector config: the **`opentelemetry-configuration`** schema fully describes the SDK provider graph as data. The same file configures the Java, Go, Python, or .NET SDK.

```yaml
# sdk-config.yaml — opentelemetry-configuration schema (experimental, evolving)
file_format: "0.3"
disabled: false

resource:
  attributes:
    - name: service.name
      value: checkout
    - name: service.version
      value: 2.7.1
    - name: deployment.environment
      value: production

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
  processors:
    - batch:
        schedule_delay: 5000
        export_timeout: 30000
        max_queue_size: 2048
        max_export_batch_size: 512
        exporter:
          otlp:
            protocol: grpc
            endpoint: http://otelcol-acme.observability.svc:4317
            timeout: 10000

meter_provider:
  readers:
    - periodic:
        interval: 60000
        timeout: 30000
        exporter:
          otlp:
            protocol: http/protobuf
            endpoint: http://otelcol-acme.observability.svc:4318

logger_provider:
  processors:
    - batch:
        exporter:
          otlp:
            protocol: grpc
            endpoint: http://otelcol-acme.observability.svc:4317
```

Activate it with a single environment variable (autoconfig defers to the file):

```
OTEL_EXPERIMENTAL_CONFIG_FILE=/etc/otel/sdk-config.yaml
```

### 3.4 Extension in code: a custom `SpanProcessor` (Python) and `Sampler` (Go)

The SDK gives you no special hooks — you implement the *same* interface the built-ins do. A redaction processor:

```python
# redacting_processor.py — a custom SpanProcessor satisfying the SDK interface
from opentelemetry.sdk.trace import SpanProcessor, ReadableSpan
from opentelemetry.trace import Span
from opentelemetry.context import Context
import re

_TOKEN = re.compile(r"token=[^&\s]+")

class RedactingSpanProcessor(SpanProcessor):
    """Strips secrets from span attributes before downstream processors run."""

    def on_start(self, span: Span, parent_context: Context | None = None) -> None:
        pass  # nothing to do at start

    def on_end(self, span: ReadableSpan) -> None:
        url = span.attributes.get("http.url")
        if url:
            # NOTE: on_end sees a ReadableSpan; mutate via the writable ref
            span._attributes["http.url"] = _TOKEN.sub("token=REDACTED", url)
        span._attributes.pop("user.email", None)

    def shutdown(self) -> None:
        pass

    def force_flush(self, timeout_millis: int = 30_000) -> bool:
        return True
```

```python
# wiring: compose your processor BEFORE the exporting BatchSpanProcessor
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource

provider = TracerProvider(resource=Resource.create({"service.name": "checkout"}))
provider.add_span_processor(RedactingSpanProcessor())              # extension
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))  # built-in
```

A tenant-aware, rate-limited head sampler in Go — again, just the `Sampler` interface:

```go
// tenantsampler.go — custom Sampler; drop-in wherever AlwaysOn/ParentBased go
package tenantsampler

import (
	"go.opentelemetry.io/otel/attribute"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

type tenantSampler struct {
	perTenant map[string]sdktrace.Sampler // policy per tenant
	fallback  sdktrace.Sampler
}

func New(perTenant map[string]sdktrace.Sampler, fallback sdktrace.Sampler) sdktrace.Sampler {
	return &tenantSampler{perTenant: perTenant, fallback: fallback}
}

func (s *tenantSampler) ShouldSample(p sdktrace.SamplingParameters) sdktrace.SamplingResult {
	tenant := ""
	for _, a := range p.Attributes {
		if a.Key == attribute.Key("tenant.id") {
			tenant = a.Value.AsString()
		}
	}
	if sub, ok := s.perTenant[tenant]; ok {
		return sub.ShouldSample(p)
	}
	return s.fallback.ShouldSample(p)
}

func (s *tenantSampler) Description() string { return "TenantSampler" }
```

```go
// wiring
tp := sdktrace.NewTracerProvider(
	sdktrace.WithSampler(sdktrace.ParentBased(
		tenantsampler.New(
			map[string]sdktrace.Sampler{
				"gold":   sdktrace.AlwaysSample(),
				"silver": sdktrace.TraceIDRatioBased(0.25),
			},
			sdktrace.TraceIDRatioBased(0.01), // everyone else
		),
	)),
	sdktrace.WithBatcher(otlpExporter),
)
```

### 3.5 Kubernetes: composing agent + gateway with the Operator, and zero-code injection

The **OpenTelemetry Operator** turns the Collector into a Kubernetes-native composable unit (`OpenTelemetryCollector`) and injects auto-instrumentation (`Instrumentation`) without touching app images.

```yaml
# gateway-collector.yaml — Operator CR, v1beta1 (config is structured, not a string)
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: gateway
  namespace: observability
spec:
  mode: deployment           # deployment | daemonset | statefulset | sidecar
  replicas: 3
  image: ghcr.io/acme/otelcol-acme:1.4.0   # your custom ocb build
  resources:
    limits:
      memory: 1Gi
    requests:
      cpu: 200m
      memory: 512Mi
  config:
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      batch: {}
    exporters:
      otlp/tempo:
        endpoint: tempo.observability.svc:4317
        tls: { insecure: true }
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/tempo]
```

```yaml
# instrumentation.yaml — declarative, language-agnostic auto-instrumentation
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: acme-default
  namespace: apps
spec:
  exporter:
    endpoint: http://gateway-collector.observability.svc:4318
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "0.10"
  python:
    env:
      - name: OTEL_EXPORTER_OTLP_PROTOCOL
        value: http/protobuf
```

A workload opts in with one annotation — zero code, zero rebuild:

```yaml
# in the Pod template of any Deployment in namespace "apps"
metadata:
  annotations:
    instrumentation.opentelemetry.io/inject-python: "acme-default"
```

---

## 4. CLI commands and real terminal output

### 4.1 Build a custom distribution with `ocb`

```
$ builder --config builder-config.yaml
2026-08-10T14:03:11.482Z  INFO  internal/command.go:159  Using config file  {"path": "builder-config.yaml"}
2026-08-10T14:03:11.489Z  INFO  builder/config.go:142    Using go  {"go-executable": "/usr/local/go/bin/go"}
2026-08-10T14:03:11.501Z  INFO  builder/main.go:88       Sources created  {"path": "./_build"}
2026-08-10T14:03:14.912Z  INFO  builder/main.go:126      Getting go modules
2026-08-10T14:03:19.340Z  INFO  builder/main.go:107      Compiling
2026-08-10T14:03:41.201Z  INFO  builder/main.go:113      Compiled  {"binary": "./_build/otelcol-acme"}

$ ./_build/otelcol-acme --version
otelcol-acme version 1.4.0
```

### 4.2 List the components actually compiled in

This is the first diagnostic when a config is rejected — it tells you what your binary *can* reference.

```
$ ./_build/otelcol-acme components
buildinfo:
  command: otelcol-acme
  description: ACME production OTel Collector distribution
  version: 1.4.0
receivers:
  - name: otlp
    stability: { logs: Beta, metrics: Stable, traces: Stable }
  - name: prometheus
    stability: { metrics: Beta }
processors:
  - name: batch
    stability: { logs: Beta, metrics: Beta, traces: Beta }
  - name: memory_limiter
    stability: { logs: Beta, metrics: Beta, traces: Beta }
  - name: k8sattributes
    stability: { logs: Beta, metrics: Beta, traces: Beta }
  - name: transform
    stability: { logs: Alpha, metrics: Alpha, traces: Alpha }
exporters:
  - name: debug
  - name: otlp
  - name: prometheus
connectors:
  - name: spanmetrics
    stability: { traces-to-metrics: Alpha }
extensions:
  - name: health_check
  - name: pprof
  - name: zpages
```

### 4.3 Validate before you run

```
$ ./_build/otelcol-acme validate --config otelcol.yaml
$ echo $?
0
```

### 4.4 Start it, and read the composition being assembled

```
$ ./_build/otelcol-acme --config otelcol.yaml
2026-08-10T14:10:02.001Z  info  service@v0.116.0/service.go:164  Setting up own telemetry...
2026-08-10T14:10:02.003Z  info  telemetry/metrics.go:70   Serving metrics  {"address": "0.0.0.0:8888", "metrics level": "Detailed"}
2026-08-10T14:10:02.010Z  info  memorylimiterprocessor@v0.116.0/memorylimiter.go:151  Using percentage memory limiter  {"total_memory_mib": 1024, "limit_percentage": 80, "spike_limit_percentage": 25}
2026-08-10T14:10:02.012Z  info  spanmetricsconnector@v0.116.0/connector.go:150  Building spanmetrics connector
2026-08-10T14:10:02.015Z  info  service@v0.116.0/service.go:230  Starting otelcol-acme...  {"Version": "1.4.0", "NumCPU": 8}
2026-08-10T14:10:02.020Z  info  extensions/extensions.go:39  Starting extensions...
2026-08-10T14:10:02.021Z  info  healthcheckextension@v0.116.0/healthcheckextension.go:35  Starting health_check extension  {"config": {"Endpoint":"0.0.0.0:13133"}}
2026-08-10T14:10:02.022Z  info  zpagesextension@v0.116.0/zpagesextension.go:53  Registered zPages span processor on tracer provider
2026-08-10T14:10:02.025Z  info  otlpreceiver@v0.116.0/otlp.go:102  Starting GRPC server  {"endpoint": "0.0.0.0:4317"}
2026-08-10T14:10:02.026Z  info  otlpreceiver@v0.116.0/otlp.go:152  Starting HTTP server  {"endpoint": "0.0.0.0:4318"}
2026-08-10T14:10:02.030Z  info  service@v0.116.0/service.go:253  Everything is ready. Begin running and processing data.
```

### 4.5 Environment-variable composition of the SDK (autoconfig)

No file, no code — the app's SDK assembles itself from the environment:

```
$ export OTEL_SERVICE_NAME=checkout
$ export OTEL_RESOURCE_ATTRIBUTES="service.version=2.7.1,deployment.environment=production"
$ export OTEL_TRACES_SAMPLER=parentbased_traceidratio
$ export OTEL_TRACES_SAMPLER_ARG=0.10
$ export OTEL_TRACES_EXPORTER=otlp
$ export OTEL_METRICS_EXPORTER=otlp
$ export OTEL_LOGS_EXPORTER=otlp
$ export OTEL_PROPAGATORS=tracecontext,baggage
$ export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
$ export OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol-acme.observability.svc:4317
$ ./checkout
```

---

## 5. Verification and failure diagnosis

### 5.1 Liveness and the assembled service graph

```
$ curl -s http://localhost:13133/status
{"status":"Server available","upSince":"2026-08-10T14:10:02.030Z","uptime":"3m12.4s"}

$ curl -s http://localhost:55679/debug/servicez | head -n 20
Pipelines
  traces      receivers:[otlp]  processors:[memory_limiter k8sattributes transform/redact batch]  exporters:[otlp/tempo spanmetrics]
  metrics     receivers:[otlp spanmetrics prometheus/internal]  processors:[memory_limiter batch]  exporters:[prometheus debug]
Extensions
  health_check  pprof  zpages
```

### 5.2 Self-observability — the numbers that prove data is flowing

The Collector emits its own metrics on `:8888`. These are your ground truth.

```
$ curl -s http://localhost:8888/metrics | grep -E 'accepted|refused|sent|failed|queue' | grep -v '^#'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 184320
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 0
otelcol_processor_refused_spans{processor="memory_limiter"} 0
otelcol_exporter_sent_spans{exporter="otlp/tempo"} 184300
otelcol_exporter_send_failed_spans{exporter="otlp/tempo"} 0
otelcol_exporter_queue_size{exporter="otlp/tempo"} 12
otelcol_exporter_queue_capacity{exporter="otlp/tempo"} 5000
```

Read them as a mass-balance equation: `accepted − refused ≈ sent + queued`. A widening gap between `accepted` and `sent`, with `queue_size → queue_capacity`, is impending data loss.

### 5.3 See the actual payload with the `debug` exporter

```
2026-08-10T14:11:05.100Z  info  Traces  {"resource spans": 1, "spans": 3}
2026-08-10T14:11:05.100Z  info  ResourceSpans #0
Resource SchemaURL: https://opentelemetry.io/schemas/1.27.0
Resource attributes:
     -> service.name: Str(checkout)
     -> k8s.namespace.name: Str(apps)
     -> k8s.pod.name: Str(checkout-6c9f-abcde)
ScopeSpans #0
Span #0
    Name        : POST /api/cart/checkout
    Kind        : Server
    Attributes:
         -> http.method: Str(POST)
         -> http.status_code: Int(200)
         -> http.url: Str(https://acme.io/api/cart/checkout?token=REDACTED)   # ← redaction processor worked
```

The redacted `token=REDACTED` and the *absence* of `user.email` verify that the custom processor executed **before** export — composition order confirmed empirically.

### 5.4 Failure catalogue

| Symptom | Log / metric | Root cause | Fix |
|---|---|---|---|
| Startup aborts: `error decoding 'exporters': unknown type: "prometheus"` | fatal on boot | Config references a component **not compiled into the distribution** | Add its `gomod` to `builder-config.yaml`, rebuild; or run `components` to confirm what's present |
| Startup aborts: `connector "spanmetrics" used as exporter in pipeline "traces" but not used as receiver in any pipeline` | fatal on boot | Connector wired on only one side | Reference it as receiver in `metrics` **and** exporter in `traces` |
| `data refused due to high memory usage` | `otelcol_processor_refused_spans{processor="memory_limiter"}` climbing | `memory_limiter` shedding load (working as designed) | Scale out, raise limits, or reduce upstream volume |
| `sending queue is full` | `otelcol_exporter_queue_size == queue_capacity` | Backend slower than ingest | Increase `sending_queue.num_consumers`/`queue_size`, or fix the backend |
| Traces split into fragments | Broken parent/child across services | Propagator mismatch (e.g. one service `b3`, another `tracecontext`) | Standardize `OTEL_PROPAGATORS` / `propagator.composite` across the fleet |
| Instrumented library emits nothing, no SDK errors | silence | No SDK installed → API is no-op (by design) | Install & register an SDK provider in the binary's `main` |
| Custom processor never runs | data unredacted | Registered *after* the exporting processor, or provider not global | Add the custom processor **before** the `Batch` processor; use the configured provider |

### 5.5 Profiling an extension under load

```
$ curl -s "http://localhost:1777/debug/pprof/heap" -o heap.out
$ go tool pprof -top heap.out | head
Showing nodes accounting for 128.04MB, 96.31% of 132.94MB total
      flat  flat%   sum%        cum   cum%
   64.50MB 48.52% 48.52%    64.50MB 48.52%  .../spanmetricsconnector.(*connectorImp).aggregateMetrics
```

A custom or connector component leaking memory shows up here as unbounded cardinality (classic with `spanmetrics` when an unbounded attribute like `http.url` is added to `dimensions` — bound your dimensions).

---

## 6. References

- OTCA Curriculum — https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
- OpenTelemetry Specification (API/SDK, no-op, extension points) — https://opentelemetry.io/docs/specs/otel/
- Trace SDK — Samplers, SpanProcessors, SpanExporters — https://opentelemetry.io/docs/specs/otel/trace/sdk/
- Metrics SDK — Views, MetricReaders, Aggregations — https://opentelemetry.io/docs/specs/otel/metrics/sdk/
- Context propagation & composite propagators — https://opentelemetry.io/docs/specs/otel/context/api-propagators/
- Components overview — https://opentelemetry.io/docs/concepts/components/
- Collector architecture (receivers/processors/exporters/connectors/extensions) — https://opentelemetry.io/docs/collector/architecture/
- Collector configuration — https://opentelemetry.io/docs/collector/configuration/
- Connectors — https://opentelemetry.io/docs/collector/building/connectors/
- Building a custom Collector (`ocb`) — https://opentelemetry.io/docs/collector/custom-collector/
- Collector Builder source — https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder
- Contrib components registry — https://github.com/open-telemetry/opentelemetry-collector-contrib
- Declarative SDK configuration (spec) — https://opentelemetry.io/docs/specs/otel/configuration/
- `opentelemetry-configuration` schema — https://github.com/open-telemetry/opentelemetry-configuration
- SDK environment-variable configuration — https://opentelemetry.io/docs/languages/sdk-configuration/
- OpenTelemetry Operator (CRDs, auto-instrumentation) — https://opentelemetry.io/docs/kubernetes/operator/
- spanmetrics connector — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector