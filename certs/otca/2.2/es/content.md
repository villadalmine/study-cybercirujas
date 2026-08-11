# 2.2 — Componibilidad y extensión

> **OTCA Dominio 2 — La API y el SDK de OpenTelemetry · Subcompetencia 2.2 · Peso en el examen ≈ 6,57 %**
> Nivel: Principal Platform Architect / Senior SRE. Este capítulo trata la *componibilidad* (ensamblar pipelines de telemetría a partir de componentes independientes e intercambiables) y la *extensión* (implementar las interfaces del proyecto para agregar componentes que no vienen incluidos de fábrica). Ambas son la misma apuesta arquitectónica, aplicada una vez dentro del proceso (API/SDK) y otra vez fuera de él (el Collector).

---

## 1. Motivación: el problema arquitectónico en producción

### 1.1 La trampa de la integración N×M

Antes de OpenTelemetry, cada integración de observabilidad era un acoplamiento punto a punto. Si corrías `N` lenguajes/frameworks y enviabas a `M` backends (Jaeger, Zipkin, Prometheus, un APM SaaS, un almacén de logs), eras dueño de hasta `N×M` agentes de instrumentación, cada uno con su propio formato de cable, su propia superficie de configuración y su propia cadencia de actualización. Cambiar un backend significaba recompilar y redesplegar cada servicio. Esto es *vendor lock-in expresado como una dependencia de build*.

OpenTelemetry colapsa `N×M` en `N+M` insertando dos costuras de componibilidad:

1. **Separación API ⟂ SDK** dentro del proceso — la instrumentación depende de la *API únicamente*; el SDK (las partes móviles) se elige en el borde, por el dueño de la aplicación.
2. **El Collector** fuera del proceso — un broker agnóstico del proveedor donde receivers, processors y exporters se cablean en pipelines en tiempo de *configuración*, no en tiempo de compilación.

La decisión que sostiene todo es la primera. Como la API embarca una **implementación no-op** por defecto, un autor de biblioteca (digamos, un driver de base de datos) puede llamar a `tracer.Start(...)` incondicionalmente. Si no hay un SDK instalado, las llamadas no cuestan nada y no producen nada; si *sí* hay un SDK instalado, las mismas llamadas se encienden. La instrumentación queda así **desacoplada de la configuración** — la persona que escribe el span no es la persona que decide a dónde va, cómo se muestrea, o si siquiera se registra.

### 1.2 Qué significa "componible" con precisión

El SDK no es un monolito. Es un pequeño conjunto de objetos **provider**, cada uno sosteniendo un grafo de partes enchufables que ensamblás:

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

Cada ranura entre corchetes acepta una **lista**, y cada elemento de cada lista es una **interfaz**. Eso es componibilidad: hacé fan-out hacia dos exporters agregando un segundo processor; agregá redacción de PII insertando un processor antes del exporter; cambiá la política de sampling sin tocar una sola línea instrumentada.

### 1.3 Qué significa "extensible" con precisión

La componibilidad te deja *organizar* los componentes que embarca el SDK. La extensión te deja *agregar los tuyos* satisfaciendo las mismas interfaces que satisfacen los built-ins — no hay ningún built-in privilegiado. Un `Sampler`, `SpanProcessor`, `SpanExporter`, `MetricReader` o `TextMapPropagator` personalizado es un ciudadano de primera clase en el momento en que implementa el contrato.

Fuera del proceso, el mismo principio produce el **OpenTelemetry Collector Builder (`ocb`)**: el Collector es un núcleo delgado más un conjunto de componentes elegidos en tiempo de *build* a partir de un manifiesto. Un componente que no está compilado dentro de tu distribución no puede ser referenciado en la configuración — esta es la sorpresa de producción más común, cubierta en §5.

---

## 2. Comparaciones técnicas y trade-offs

### 2.1 API vs SDK — la costura que hace posible todo lo demás

| Aspecto | API | SDK |
|---|---|---|
| Propósito | Contrato contra el que se escribe la instrumentación | Implementación que registra, muestrea, exporta |
| Comportamiento por defecto sin configuración | **No-op** (costo cero, sin salida) | N/A — lo instalás deliberadamente |
| Quién depende de él | Autores de bibliotecas, autores de frameworks | Dueño de la aplicación (el `main` del binario) |
| Garantía de estabilidad | Fuerte — romperla rompe cada biblioteca | Más laxa — los internos pueden evolucionar |
| Intercambiable en | Tiempo de compilación (rara vez cambiado) | Tiempo de configuración/arranque (cambiado libremente) |
| Analogía | Interfaz `slf4j` / `log/slog` | `logback` / un handler concreto |

**Regla práctica:** una biblioteca **nunca** debe depender del SDK. Si encontrás `opentelemetry-sdk` en el grafo de dependencias de una *biblioteca*, esa biblioteca fuerza un SDK global sobre cada consumidor — un anti-patrón.

### 2.2 Estrategias de SpanProcessor

| | `SimpleSpanProcessor` | `BatchSpanProcessor` (BSP) |
|---|---|---|
| Momento de exportación | Síncrono, un span por exportación | Bufferizado, vaciado por timer o tamaño de lote |
| Bloqueo | Bloquea `span.End()` | No bloqueante (worker en segundo plano) |
| Throughput | Bajo; un RPC por span | Alto; RPCs amortizados |
| Ventana de pérdida de datos | Ninguna hasta el intento de exportación | Hasta `max_queue_size` en caso de crash |
| Uso en producción | Solo tests, debugging | **Por defecto para toda producción** |
| Perillas clave | — | `schedule_delay`, `max_queue_size`, `max_export_batch_size`, `export_timeout` |

### 2.3 Samplers

| Sampler | Base de decisión | Determinismo | Uso típico |
|---|---|---|---|
| `AlwaysOn` | Siempre registra | Sí | Dev, bajo volumen |
| `AlwaysOff` | Nunca registra | Sí | Kill switch |
| `TraceIdRatioBased(p)` | Hash del trace ID vs `p` | Sí, consistente entre servicios *si* se usa el mismo `p` | Head sampling |
| `ParentBased(root=…)` | Honra el flag sampled del padre; usa el sampler `root` cuando no hay padre | Sí | **Por defecto** — mantiene los traces completos |
| Custom (interfaz `Sampler`) | Cualquier cosa (enrutar por atributo, tenant, rate-limit) | Tu elección | Consciente del tenant, control de costos |

> **Head vs tail:** los samplers del SDK son samplers *head* — deciden al inicio del span, antes de conocer el resultado, así que no pueden "quedarse con todos los errores". El tail sampling (decidir después de que el trace se completa) vive en el **Collector** (`tailsamplingprocessor`), una razón de componibilidad para empujar la política fuera del proceso.

### 2.4 Taxonomía de componentes del Collector (la superficie de extensión)

| Componente | Rol | Posición en el pipeline | Ejemplos |
|---|---|---|---|
| **Receiver** | Ingesta de datos hacia adentro | Entrada | `otlp`, `prometheus`, `filelog`, `kafka` |
| **Processor** | Transformar/limitar/filtrar | Medio (ordenado) | `batch`, `memory_limiter`, `transform`, `tail_sampling`, `k8sattributes` |
| **Exporter** | Emitir datos hacia afuera | Salida | `otlp`, `prometheus`, `debug`, `loadbalancing` |
| **Connector** | Salida de un pipeline → entrada de otro | Puente | `spanmetrics`, `count`, `routing`, `forward` |
| **Extension** | Capacidad a nivel de proceso, no en la ruta de datos | Sidecar | `health_check`, `pprof`, `zpages`, `oauth2client`, `file_storage` |

**Los connectors** son la primitiva de componibilidad que la mayoría pasa por alto: permiten que una señal *se convierta* en otra (traces → métricas RED vía `spanmetrics`) o que se enrute por contenido, sin ningún salto externo.

### 2.5 Distribuciones del Collector

| Distribución | Contenido | Trade-off |
|---|---|---|
| **Core** (`otelcol`) | Mínimo, solo componentes críticos según la spec | Diminuto, seguro; a menudo le falta lo que necesitás |
| **Contrib** (`otelcol-contrib`) | ~todo lo del registry | Binario/superficie de ataque enorme; excelente para prototipado |
| **Custom** (construido con `ocb`) | Exactamente los componentes que listás | La menor huella, la menor superficie de CVE; **el build es tuyo** |

Producción ≠ contrib. Contrib es la imagen de "prototipado con las pilas incluidas"; producción debería ser un **build custom con `ocb`** fijado a los componentes de tu configuración.

### 2.6 Mecanismos de configuración del SDK (una capa de componibilidad en sí misma)

| Mecanismo | Formato | Cobertura | Mejor para |
|---|---|---|---|
| Programático | Código (Go/Java/Python/…) | Completa, incl. componentes custom | Extensiones custom, cableado dinámico |
| Variables de entorno (autoconfig) | `OTEL_*` | Solo built-ins comunes | Despliegues 12-factor, contenedores |
| Configuración declarativa por archivo | YAML (esquema `opentelemetry-configuration`) | Grafo completo de built-ins, agnóstico del lenguaje | Config como dato, GitOps, un archivo para todos los lenguajes |

---

## 3. Manifiestos completos e infraestructura

### 3.1 Un pipeline de Collector compuesto: OTLP entra → métricas RED vía un connector → dos backends

Esta configuración demuestra todas las primitivas de componibilidad a la vez: dos receivers, una cadena ordenada de processors, un **connector** que fabrica métricas a partir de spans, tres exporters y tres extensions.

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

**Puntos destacados de componibilidad.** El orden de los processors es semántico, no cosmético: `memory_limiter` primero (aplica backpressure), `batch` último (amortiza después de todo el shaping). El connector `spanmetrics` aparece una vez como *exporter* y una vez como *receiver* — esa referencia dual es lo que cablea dos pipelines juntos. Quitá cualquiera de las dos referencias y el arranque falla (§5).

### 3.2 El manifiesto de build de `ocb` — extensión por construcción

No embarcás la configuración de arriba sobre `otelcol-contrib`. Compilás una distribución que contiene *exactamente* sus componentes.

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

> Los componentes core viven bajo `go.opentelemetry.io/collector/…`; los componentes de la comunidad bajo `github.com/open-telemetry/opentelemetry-collector-contrib/…`. Cada línea `gomod` debe compartir el mismo tag `v0.116.0` que `otelcol_version`, o el build falla por APIs de módulos incompatibles.

### 3.3 Configuración declarativa del SDK — un archivo, todos los lenguajes

El equivalente in-process de una configuración de Collector: el esquema **`opentelemetry-configuration`** describe por completo el grafo de providers del SDK como dato. El mismo archivo configura el SDK de Java, Go, Python o .NET.

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

Activalo con una sola variable de entorno (autoconfig cede ante el archivo):

```
OTEL_EXPERIMENTAL_CONFIG_FILE=/etc/otel/sdk-config.yaml
```

### 3.4 Extensión en código: un `SpanProcessor` (Python) y un `Sampler` (Go) personalizados

El SDK no te da ganchos especiales — implementás la *misma* interfaz que los built-ins. Un processor de redacción:

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

Un head sampler consciente del tenant y con rate-limit en Go — de nuevo, solo la interfaz `Sampler`:

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

### 3.5 Kubernetes: componer agent + gateway con el Operator, e inyección zero-code

El **OpenTelemetry Operator** convierte al Collector en una unidad componible nativa de Kubernetes (`OpenTelemetryCollector`) e inyecta auto-instrumentación (`Instrumentation`) sin tocar las imágenes de la app.

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

Una carga de trabajo se suscribe con una sola anotación — cero código, cero rebuild:

```yaml
# in the Pod template of any Deployment in namespace "apps"
metadata:
  annotations:
    instrumentation.opentelemetry.io/inject-python: "acme-default"
```

---

## 4. Comandos de CLI y salida real de terminal

### 4.1 Construir una distribución custom con `ocb`

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

### 4.2 Listar los componentes realmente compilados dentro

Este es el primer diagnóstico cuando una configuración es rechazada — te dice qué *puede* referenciar tu binario.

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

### 4.3 Validar antes de correr

```
$ ./_build/otelcol-acme validate --config otelcol.yaml
$ echo $?
0
```

### 4.4 Arrancarlo, y leer la composición que se está ensamblando

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

### 4.5 Composición del SDK por variables de entorno (autoconfig)

Sin archivo, sin código — el SDK de la app se ensambla a sí mismo a partir del entorno:

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

## 5. Verificación y diagnóstico de fallas

### 5.1 Liveness y el grafo de servicio ensamblado

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

### 5.2 Auto-observabilidad — los números que prueban que los datos fluyen

El Collector emite sus propias métricas en `:8888`. Estas son tu verdad fundamental.

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

Leélas como una ecuación de balance de masa: `accepted − refused ≈ sent + queued`. Una brecha que se ensancha entre `accepted` y `sent`, con `queue_size → queue_capacity`, es una pérdida de datos inminente.

### 5.3 Ver el payload real con el exporter `debug`

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

El `token=REDACTED` redactado y la *ausencia* de `user.email` verifican que el processor personalizado se ejecutó **antes** de la exportación — orden de composición confirmado empíricamente.

### 5.4 Catálogo de fallas

| Síntoma | Log / métrica | Causa raíz | Solución |
|---|---|---|---|
| El arranque aborta: `error decoding 'exporters': unknown type: "prometheus"` | fatal al bootear | La configuración referencia un componente **no compilado dentro de la distribución** | Agregá su `gomod` a `builder-config.yaml`, reconstruí; o corré `components` para confirmar qué está presente |
| El arranque aborta: `connector "spanmetrics" used as exporter in pipeline "traces" but not used as receiver in any pipeline` | fatal al bootear | Connector cableado de un solo lado | Referencialo como receiver en `metrics` **y** como exporter en `traces` |
| `data refused due to high memory usage` | `otelcol_processor_refused_spans{processor="memory_limiter"}` en aumento | `memory_limiter` descartando carga (funcionando según lo diseñado) | Escalá horizontalmente, subí los límites, o reducí el volumen upstream |
| `sending queue is full` | `otelcol_exporter_queue_size == queue_capacity` | Backend más lento que la ingesta | Aumentá `sending_queue.num_consumers`/`queue_size`, o arreglá el backend |
| Traces partidos en fragmentos | Padre/hijo roto entre servicios | Desajuste de propagadores (p. ej. un servicio `b3`, otro `tracecontext`) | Estandarizá `OTEL_PROPAGATORS` / `propagator.composite` en toda la flota |
| Biblioteca instrumentada no emite nada, sin errores del SDK | silencio | No hay SDK instalado → la API es no-op (por diseño) | Instalá y registrá un provider del SDK en el `main` del binario |
| El processor personalizado nunca corre | datos sin redactar | Registrado *después* del processor que exporta, o el provider no es global | Agregá el processor personalizado **antes** del processor `Batch`; usá el provider configurado |

### 5.5 Perfilar una extensión bajo carga

```
$ curl -s "http://localhost:1777/debug/pprof/heap" -o heap.out
$ go tool pprof -top heap.out | head
Showing nodes accounting for 128.04MB, 96.31% of 132.94MB total
      flat  flat%   sum%        cum   cum%
   64.50MB 48.52% 48.52%    64.50MB 48.52%  .../spanmetricsconnector.(*connectorImp).aggregateMetrics
```

Un componente personalizado o connector con fuga de memoria aparece acá como cardinalidad no acotada (clásico con `spanmetrics` cuando un atributo no acotado como `http.url` se agrega a `dimensions` — acotá tus dimensiones).

---

## 6. Referencias

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