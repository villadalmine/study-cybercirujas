# 2.4 Signals: Tracing, Metrics, Logs

> **Dominio 2 del examen — OpenTelemetry Signals · peso 6.57 %**
> Este capítulo trata las tres señales de telemetría tal como las define OpenTelemetry, no como genéricos "pilares de la observabilidad". La distinción importa: la contribución de OTel no es que existan traces, metrics y logs — lo preceden por una década — sino que las tres comparten un mismo **modelo de datos**, un mismo **protocolo de transporte (OTLP)**, un mismo **Resource** y un mismo mecanismo de **propagación de contexto**, de modo que un único `trace_id` las cose entre sí. Esa es toda la apuesta arquitectónica, y es lo que el examen evalúa.

---

## 1. El problema en producción: tres señales, un incidente

Una petición entra por un ingress gateway, se abre en abanico hacia `checkout`, que llama a `payments`, que llama a una API de terceros y escribe en Postgres. La latencia se dispara a p99 = 4 s. Tenés:

- **Metrics** desde Prometheus: `http_request_duration_seconds` está alto en `payments`. Sabés *que* es lento y *con qué frecuencia*, de forma barata, para siempre. **No** sabés *qué* peticiones ni *por qué*.
- **Logs** desde Loki: miles de líneas de `payments`, ninguna de las cuales puede vincularse a las peticiones lentas específicas, porque las líneas de log y las series de métrica fueron producidas por dos librerías no relacionadas con dos nociones no relacionadas de "petición".
- **Traces** desde Jaeger: podés ver un trace lento de punta a punta — pero el SDK de tracing, el cliente de métricas y el framework de logging se configuraron de forma independiente, así que el trace que estás mirando no puede cruzarse contra el pico de la métrica ni contra los logs de error.

Este es el **problema de los tres silos**. Cada señal fue históricamente producida por un SDK distinto, etiquetada con un conjunto de labels distinto e incompatible, exportada por un protocolo distinto, y correlacionada a mano a las 3 de la mañana. El costo no es el almacenamiento — es el **mean time to correlation**.

La respuesta de OpenTelemetry es estructural, no un dashboard:

| Componente compartido | Qué unifica |
|---|---|
| **Resource** | Cada señal del mismo proceso lleva el `Resource` *idéntico* (`service.name`, `k8s.pod.name`, `deployment.environment`, `host.id`). Clave de join entre las tres. |
| **Context / Propagation** | El `SpanContext` activo (`trace_id`, `span_id`) está disponible de forma ambiental, así que un exemplar de métrica y un registro de log pueden estamparse ambos con *el mismo* trace. |
| **Semantic Conventions** | `http.request.method`, `http.response.status_code`, `service.name` significan lo mismo en un atributo de span, un label de métrica y un atributo de log. |
| **OTLP** | Un protocolo, un endpoint (`4317` gRPC / `4318` HTTP), tres mensajes de nivel superior (`ResourceSpans`, `ResourceMetrics`, `ResourceLogs`). |
| **Collector** | Un proceso recibe, procesa y enruta las tres, e incluso puede *derivar* una señal de otra (spans → metrics). |

**Signals vs. cross-cutting concerns.** El examen traza una línea dura: **Traces, Metrics y Logs son señales** — se *emiten y exportan*. **Context** y **Baggage** son *cross-cutting concerns* — se *propagan* y no llevan carga de telemetría propia. Baggage **no** es una cuarta señal; es un mapa clave/valor que viaja en los headers de propagación para que un valor fijado aguas arriba (por ejemplo `enduser.id`) pueda leerse aguas abajo y *adjuntarse* a la señal que elijas. Una respuesta distractora frecuente lista Baggage como una señal — no lo es.

---

## 2. El modelo de datos de OpenTelemetry, señal por señal

### 2.1 Traces

Un **Trace** es un DAG de **Spans** que comparten un único `trace_id` de 128 bits. Cada span es una operación temporizada.

**Estructura de un span (los campos que el examen espera que nombres):**

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

**El span kind no es cosmético.** Le dice al backend cómo construir el grafo de servicios y dónde hay un salto de red:

| Kind | Significado | Ejemplar típico |
|---|---|---|
| `SERVER` | Entrante síncrono; padre remoto | Manejar una petición HTTP |
| `CLIENT` | Saliente síncrono; hijo remoto | Llamar a una API / DB aguas abajo |
| `PRODUCER` | Envío asíncrono; el hijo puede ejecutarse más tarde | Publicar en Kafka |
| `CONSUMER` | Recepción asíncrona; el padre puede haber terminado | Procesar un mensaje de Kafka (usa `links`) |
| `INTERNAL` | Trabajo dentro del proceso | Una función que elegiste instrumentar |

**Propagación — W3C Trace Context.** El `SpanContext` cruza los límites de proceso como dos headers HTTP. Este es el propagador por defecto de OTel y el formato canónico del examen:

```text
traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
             │  │                                │                │
             │  └ trace-id (32 hex)              └ parent-id      └ trace-flags
             └ version                             (this span_id)   01 = sampled

tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
            └ vendor-specific, ordered, mutable (max 32 entries)
```

El bit 0 de `trace-flags` es la flag **sampled**. Si es `00`, un sampler `parentbased` aguas abajo *no* registrará el span — así es como una decisión de head-sampling tomada en el borde se propaga por todo el trace de modo que esté o completamente presente o completamente ausente, nunca a medias.

**Sampling** es la palanca de costo específica de traces (metrics y logs no se "samplean" de esta manera).

| Estrategia | Dónde | Entrada de decisión | Trade-off |
|---|---|---|---|
| `AlwaysOn` / `AlwaysOff` | SDK (head) | ninguna | Solo dev / mata el tracing |
| `TraceIdRatioBased(0.1)` | SDK (head) | hash de `trace_id` | Barato, determinista, pero ciego — descarta el único trace lento con la misma facilidad que uno rápido |
| `ParentBased(root=…)` | SDK (head) | flag `sampled` aguas arriba | Mantiene un trace entero entre servicios; el default estándar en producción |
| **Tail sampling** | **Collector** | el trace *completo* (latencia, error, atributos) | Mantiene todo trace con error/lento, descarta los aburridos — pero el Collector debe **bufferear en memoria todos los spans de un trace** hasta que termine el root, y enrutar todos los spans de un mismo `trace_id` a la *misma* instancia de Collector (exporter `loadbalancing`) |

El **SpanProcessor** gobierna la exportación:

- `SimpleSpanProcessor` — exporta cada span de forma síncrona, una llamada de red por span. Correcto para tests, catastrófico en producción (bloquea la ruta de la petición).
- `BatchSpanProcessor` — bufferea spans y los descarga por tamaño/timeout. El default de producción. Se ajusta con `OTEL_BSP_MAX_QUEUE_SIZE`, `OTEL_BSP_SCHEDULE_DELAY`, `OTEL_BSP_MAX_EXPORT_BATCH_SIZE`. Cuando la cola se desborda, los spans se **descartan silenciosamente** — un modo de fallo real cubierto en §7.

### 2.2 Metrics

Una **Metric** es una agregación de mediciones a lo largo del tiempo. El modelo de OTel se define por el **instrument** que elijas; la elección del instrument fija la semántica para todo el pipeline.

**Los seis instruments** (síncrono = llamás `.Add()`/`.Record()` en línea; asíncrono = registrás un *callback* que el SDK invoca en el momento de la colección):

| Instrument | Sync/Async | ¿Monotónico? | Agrega a | Usar para |
|---|---|---|---|---|
| `Counter` | sync | sí (solo ↑) | Sum | Peticiones servidas, bytes enviados |
| `UpDownCounter` | sync | no (± ) | Sum | Profundidad de cola, conexiones activas |
| `Histogram` | sync | — | Histogram (buckets) | Duración de la petición, tamaño de payload |
| `Gauge` | sync* | no | último valor | Temperatura actual (el sync gauge es más nuevo) |
| `ObservableCounter` | async | sí | Sum | Segundos totales de CPU (leídos de `/proc`) |
| `ObservableUpDownCounter` | async | no | Sum | Memoria en uso |
| `ObservableGauge` | async | no | último valor | Límite dirigido por config, heap actual |

La **aggregation temporality** es el concepto de metrics más relevante para el examen, porque es donde OTel y Prometheus discrepan:

| | **Cumulative** | **Delta** |
|---|---|---|
| Valor reportado | total acumulado desde el arranque del proceso | cambio desde la *última* exportación |
| Comportamiento en reinicio | se resetea a 0 (el backend debe detectar el reset) | naturalmente basado en 0 en cada intervalo |
| Componente con estado | el **backend** | el **SDK/Collector** |
| Encaje nativo | **Prometheus** (`rate()` espera monotónico cumulative) | estilo statsd, serverless/Lambda (sin proceso de larga vida que sostenga un total acumulado) |

Lo seleccionás por exporter. El exporter de Prometheus *fuerza* cumulative; un exporter OTLP hacia un backend delta-native fija `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta`. Enviar puntos **delta** a un backend Prometheus, o puntos **cumulative** a un backend delta, produce gráficos `rate()` silenciosamente incorrectos — sin error, solo números malos.

Las **Views** remodelan el flujo de la métrica en el SDK sin tocar el código del instrument — renombrar, cambiar los límites de los buckets, descartar un atributo de alta cardinalidad, o cambiar la agregación:

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

Los **Exemplars** son el puente metrics→traces. Cuando un `Histogram` registra una medición *dentro de un span activo*, el SDK puede adjuntar el `{trace_id, span_id}` de ese span al bucket como un exemplar. El resultado: hacé clic en el pico de p99 de un heatmap de Grafana, salta directo *al trace exacto* que produjo ese punto de datos. Esto solo es posible porque ambas señales comparten el mismo contexto ambiental (§1).

**MetricReader**: `PeriodicExportingMetricReader` extrae del SDK en `OTEL_METRIC_EXPORT_INTERVAL` (default 60 s) y empuja vía el exporter — el análogo en metrics del `BatchSpanProcessor`.

### 2.3 Logs

Los logs son la señal más reciente en ser modelada y la de diseño más distintivo: OTel deliberadamente **no** es una API de logging para que los desarrolladores la llamen. En cambio define un modelo de datos **LogRecord** y una **Logs Bridge API** en la que las librerías de logging *existentes* (Logback, Log4j, `logging`, zap, Serilog) se enchufan vía un **appender/handler**. Seguís escribiendo `log.info(...)`; el appender traduce cada línea a un `LogRecord` OTLP.

**Estructura de LogRecord:**

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

**Normalización del severity number** — al examen le gusta esta tabla porque permite a un backend comparar "ERROR" de un lenguaje contra "SEVERE" de otro:

| Rango | Nivel |
|---|---|
| 1–4 | TRACE |
| 5–8 | DEBUG |
| 9–12 | INFO |
| 13–16 | WARN |
| 17–20 | ERROR |
| 21–24 | FATAL |

**Dos formas en que los logs llegan a OTLP:**

1. **Bridge en el proceso** — el appender del SDK captura `trace_id`/`span_id` *en el momento de la emisión*, así que la correlación es exacta y gratuita. Requiere cableado a nivel de aplicación.
2. **Scraping del lado del Collector** — `filelogreceiver` sigue `stdout`/`/var/log/pods`, parsea, y (best-effort) extrae `trace_id` del texto. Cero cambios en la app, pero la correlación depende de que la app haya *impreso* el trace id, y los timestamps se convierten en `observed_timestamp`. Esta es la ruta por defecto en Kubernetes.

`BatchLogRecordProcessor` agrupa las exportaciones de log exactamente como lo hacen sus hermanos de trace y metric.

---

## 3. Trade-offs comparativos entre señales

| Dimensión | **Traces** | **Metrics** | **Logs** |
|---|---|---|---|
| Pregunta que responde | *¿Por qué* es lenta esta petición en concreto? | *¿Cuánto / con qué frecuencia*, a lo largo del tiempo? | *¿Qué exactamente* pasó acá? |
| Tolerancia a la cardinalidad | alta (por petición) | **baja** — cada combinación de labels es una nueva time series ($$$) | alta (por evento) |
| Factor de costo | volumen × tasa de sampling | cantidad de series activas | volumen × retención |
| Control de costo | **sampling** (head/tail) | poda de atributos vía **Views** | filtrado de nivel, sampling |
| Retención (típica) | días | meses–años | días–semanas |
| ¿Agregable? | no (individual) | sí (ese es el punto) | no (individual) |
| SpanProcessor/Reader por defecto | `BatchSpanProcessor` | `PeriodicExportingMetricReader` | `BatchLogRecordProcessor` |
| Clave de correlación producida | es el `trace_id` | lleva el exemplar `trace_id` | lleva `trace_id` + `span_id` |
| Mensaje OTLP | `ResourceSpans` | `ResourceMetrics` | `ResourceLogs` |
| Fallo por backpressure | spans descartados (silencioso) | series obsoletas/con huecos | registros descartados (silencioso) |

**El punto de síntesis (un encuadre favorito del examen):** ninguna señal por sí sola es suficiente. Las metrics detectan *y alertan de forma barata* pero no pueden explicar. Los traces explican una *única* petición pero son demasiado caros para conservarlos todos. Los logs registran la verdad de campo pero te ahogan. La propuesta de valor de OTel es la **navegación entre ellos** vía un `trace_id` compartido — alertar sobre una métrica, pivotar vía exemplar a un trace, pivotar vía `trace_id` a los logs exactos.

**Señal-derivada-de-señal (Collector connectors).** En lugar de instrumentar tres veces, podés computar una señal a partir de otra *dentro del Collector*:

- **connector `spanmetrics`** — consume el pipeline de `traces`, emite métricas R.E.D. (`calls_total`, `duration`) hacia el pipeline de `metrics`. Obtenés métricas de request-rate/error/duration **gratis** a partir de los spans, con exemplars de vuelta a esos spans.
- **connector `servicegraph`** — spans → una métrica de latencia/error de las aristas servicio-a-servicio.

Esta es la expresión más profunda de "un solo modelo de datos": una señal transformada en otra señal, en vuelo, sin reinstrumentar la app.

---

## 4. Infraestructura completa: manifiestos

### 4.1 OpenTelemetry Collector — los tres pipelines + connector spanmetrics

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

### 4.2 El Collector como un Deployment de Kubernetes (vía el CR del OpenTelemetry Operator)

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

### 4.3 Auto-instrumentación de una carga de trabajo — cero cambios de código

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

### 4.4 La configuración del SDK es 100 % variables de entorno (la superficie de la spec OTLP)

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

## 5. CLI y verificación por terminal

### 5.1 Generar las tres señales con `telemetrygen`

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

### 5.2 Enviar un trace OTLP/HTTP en crudo a mano (prueba el endpoint, sin SDK)

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

Un `200` con body vacío es éxito para OTLP/HTTP. Un body `partial_success` significa que *algunos* ítems fueron rechazados — nunca lo ignores (§7).

### 5.3 El exporter `debug` del Collector — ver cada señal a medida que aterriza

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

Fijate en las tres señales en un único stream de log, todas llevando `Trace ID 0af76519…` — la métrica vía un **exemplar**, el log vía sus campos `Trace ID`/`Span ID`. Ese id compartido **es** el entregable.

### 5.4 Confirmar las métricas derivadas de spans y sus exemplars

```console
$ curl -s http://gateway-collector.observability.svc:8889/metrics | grep -A1 '^calls_total'
calls_total{http_request_method="POST",http_response_status_code="200",service_name="checkout"} 42 # {trace_id="0af7651916cd43dd8448eb211c80319c",span_id="b7ad6b7169203331"} 1.0 1754845445.120
```

El `# {trace_id=…}` al final es el exemplar OpenMetrics — prueba de que el connector `spanmetrics` produjo métricas de petición *y* las vinculó de vuelta al trace originante.

---

## 6. Verificación y diagnóstico de fallos

### 6.1 La propia telemetría del Collector — el primer lugar donde mirar

El Collector expone sus métricas internas en `:8888`. Estas son tu verdad de campo para "¿está fluyendo la data y se está descartando algo?"

```console
$ curl -s http://gateway-collector.observability.svc:8888/metrics \
  | grep -E 'otelcol_(receiver_accepted|exporter_sent|exporter_send_failed|processor_dropped)'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 15832
otelcol_exporter_sent_spans{exporter="otlphttp/traces"} 15788
otelcol_exporter_send_failed_spans{exporter="otlphttp/traces"} 44
otelcol_processor_dropped_metric_points{processor="memory_limiter"} 0
```

`accepted` ≫ `sent` con `send_failed` en ascenso = el problema es el **backend**, no la app. `dropped` en `memory_limiter` = el Collector está subaprovisionado (§6.3).

### 6.2 Tabla de decisión para diagnóstico

| Síntoma | Causa probable | Confirmar | Arreglo |
|---|---|---|---|
| Sin spans en el backend, pero `receiver_accepted_spans` sube | la exportación falla aguas abajo | `otelcol_exporter_send_failed_spans` > 0; revisá el endpoint/TLS del exporter | arreglar el endpoint / cert del backend |
| Sin spans, `receiver_accepted_spans` = 0 | la app no está enviando | `OTEL_EXPORTER_OTLP_ENDPOINT` del SDK incorrecto, o protocolo/puerto equivocado | 4317=gRPC, 4318=HTTP — el puerto no coincidente es la causa #1 |
| El trace existe pero está **partido en fragmentos** | contexto no propagado | el span aguas abajo tiene `Parent ID` vacío | asegurá el propagador `tracecontext` en *ambos* servicios; revisá si un proxy está quitando `traceparent` |
| Solo ~la mitad de los traces esperados | sampling | `OTEL_TRACES_SAMPLER_ARG` < 1 | intencional; subilo para debugging con `parentbased_always_on` |
| El gráfico de métricas parece un diente de sierra / `rate()` negativo | desajuste de temporality | el debug exporter muestra `AggregationTemporality: Delta` hacia Prometheus | fijar `TEMPORALITY_PREFERENCE=cumulative` |
| `rate()` de Prometheus no devuelve nada | la métrica es un Gauge, no un Counter | `DataType` del debug exporter | usar un instrument `Counter` para tasas |
| Los logs llegan **sin** `Trace ID` | correlación rota | `Trace ID:` del LogRecord vacío | log emitido *fuera* de un span activo, O el file-scraper no pudo parsear el id → usá el bridge en el proceso |
| Los spans desaparecen silenciosamente bajo carga | desborde de la cola de `BatchSpanProcessor` | logs de debug del SDK "queue is full"; `otelcol_processor_dropped` | subir `OTEL_BSP_MAX_QUEUE_SIZE`, escalar el Collector |
| Collector OOMKilled | sin `memory_limiter`, o límite por encima del límite del pod | `Last State: OOMKilled` del pod | agregar `memory_limiter` como PRIMER processor, fijarlo por debajo del límite de memoria de k8s |

### 6.3 Confirmar que el backpressure de memoria está funcionando, no descartando silenciosamente

```console
$ kubectl -n observability describe pod gateway-collector-7d9f | grep -A3 'Last State'
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

`OOMKilled` (exit 137) en un Collector casi siempre significa que falta `memory_limiter` o está fijado *por encima* del `resources.limits.memory` del contenedor. El processor debe poder rechazar data *antes* de que el kernel mate al proceso — por eso §4.1 lo pone primero en cada pipeline.

### 6.4 Validar la config antes de que se ejecute

```console
$ otelcol-contrib validate --config=otelcol-config.yaml
Error: failed to build pipelines: pipeline "metrics": exporter "prometheusremotewrite" is not configured

$ # fix the typo, re-run:
$ otelcol-contrib validate --config=otelcol-config.yaml && echo OK
OK
```

### 6.5 Prueba de humo de correlación de punta a punta (el criterio de aceptación)

El sistema funciona cuando un **único `trace_id` recupera las tres señales**:

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

Tres resultados distintos de cero de un mismo id = el problema de los tres silos está resuelto para esa ruta de petición.

---

## 7. Trampas comunes del examen (referencia rápida)

- **Baggage no es una señal.** Traces, Metrics, Logs son las tres señales; Context y Baggage son cross-cutting concerns.
- **`4317` es gRPC, `4318` es HTTP.** La constante más frecuentemente evaluada.
- **`SimpleSpanProcessor` no es para producción** — bloquea por span; usá `BatchSpanProcessor`.
- **Delta vs Cumulative se elige en la exportación**, y Prometheus requiere cumulative.
- **El tail sampling vive en el Collector, el head sampling en el SDK** — y el tail sampling necesita que todos los spans de un trace se enruten a una sola instancia de Collector.
- **`memory_limiter` va primero** en cada pipeline.
- **Los logs correlacionan vía los campos `trace_id` + `span_id`; las metrics correlacionan vía exemplars.**
- **Las respuestas `--lang` / OTLP `partial_success`** significan rechazo parcial — un `200`/`2xx` por sí solo no es prueba de que cada ítem fue aceptado.

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