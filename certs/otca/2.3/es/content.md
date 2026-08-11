# 2.3 Configuración

> OTCA — Dominio 2 (*The OpenTelemetry API and SDK*). Peso en el examen ≈ 6.57%.
> Enfoque: cómo se configura un SDK de OpenTelemetry a través de variables de entorno, builders programáticos (en el código) y configuración declarativa por archivo; ajustes de resource, exporter, processor, sampler, propagator y límites; precedencia y diagnóstico.

---

## 1. El problema de producción: la configuración es el límite de acoplamiento

El código de instrumentación responde *qué* telemetría emite un servicio. La configuración responde *todo lo demás que al operador realmente le importa en producción*: adónde van los datos, cuántos sobreviven, cómo se agrupan en lotes, cómo cruza el trace context los límites entre procesos, y cuánta memoria se le permite consumir al pipeline antes de empezar a descartar.

La restricción arquitectónica que OpenTelemetry resuelve aquí es la **separación de la instrumentación respecto del cableado**. El autor de una librería instrumenta con la *API* y no sabe nada sobre tu backend. El *SDK* es la implementación concreta que lee la configuración al arrancar el proceso y decide el comportamiento en tiempo de ejecución. Si esos dos estuvieran acoplados, cada actualización de dependencia a Jaeger, Tempo o un gateway OTLP se propagaría hasta el código de la aplicación. Como están desacoplados, el mismo binario se despacha a dev, staging y prod, y solo cambia la **configuración**.

Ese desacoplamiento crea el modo de fallo que este tema existe para prevenir: un servicio que está *perfectamente instrumentado y completamente silencioso* porque `OTEL_EXPORTER_OTLP_ENDPOINT` apunta a un Collector que no está ahí, o porque `OTEL_TRACES_SAMPLER=always_off` quedó olvidado en una imagen base. Los bugs de configuración no lanzan excepciones — producen **ausencia de datos**, que es la señal más difícil de notar. Toda la disciplina de esta sección consiste en hacer observable esa ausencia.

Tres preguntas definen cada despliegue de OpenTelemetry, y las tres son pura configuración:

1. **Identidad** — ¿quién está emitiendo esto? (el `Resource`)
2. **Destino y forma** — ¿adónde va, sobre qué protocolo, agrupado cómo? (exporters + processors/readers)
3. **Volumen y fidelidad** — ¿cuánto se conserva, y cómo se transporta el context? (samplers + propagators + límites)

---

## 2. Las tres superficies de configuración y su precedencia

Los SDKs de OpenTelemetry exponen tres formas de configurar las mismas perillas. No son alternativas que elegís una sola vez; se **superponen en capas**, y el orden de esa superposición es la fuente más común de tickets de "¿por qué está siendo ignorado mi ajuste?".

| Superficie | Mecanismo | Alcance | Cuándo gana |
|---|---|---|---|
| **Variables de entorno** | `OTEL_*` leídas al inicializar el SDK | A nivel de proceso, agnóstica al lenguaje | Línea base; sobrescrita por config explícita en el código |
| **Programática** | Builders del SDK (`SdkTracerProvider.builder()…`, `TracerProvider(...)`) | Lo que el código establezca | Gana sobre las variables de entorno para la perilla específica que establece |
| **Declarativa (archivo)** | Archivo YAML vía `OTEL_EXPERIMENTAL_CONFIG_FILE` | Todo el SDK descrito en un solo documento | Cuando está presente, **toma el control** — la mayoría de las variables `OTEL_*` se ignoran |

### Reglas de precedencia que debés internalizar

- **Programática sobre entorno.** Si el código llama a `.setSampler(alwaysOn())`, entonces `OTEL_TRACES_SAMPLER=always_off` no tiene efecto. El SDK lee las variables de entorno solo para las perillas que el código no estableció explícitamente. Por eso una variable de entorno de "deshabilitar tracing en prod" falla silenciosamente frente a un provider hardcodeado.
- **La config declarativa es una toma de control de todo o nada.** Cuando `OTEL_EXPERIMENTAL_CONFIG_FILE` está establecida, el SDK se construye a sí mismo a partir de ese archivo. Según la especificación, las demás variables de entorno `OTEL_*` entonces se **ignoran** (con la estrecha excepción de las variables *referenciadas desde dentro del archivo* vía sustitución `${ENV}`). No podés configurar la mitad con un archivo y la otra mitad con variables de entorno.
- **Los agentes de zero-code (auto-instrumentación)** se configuran *enteramente* a través de variables de entorno (y, cada vez más, del archivo), porque no hay código de usuario que llame a un builder. Este es el caso común de Kubernetes.

> **Resumen de compromisos**
>
> | Preocupación | Variables de entorno | Programática | Archivo declarativo |
> |---|---|---|---|
> | Portabilidad entre lenguajes | ✅ claves idénticas en todas partes | ❌ API por lenguaje | ✅ un esquema para todos los SDKs |
> | Expresividad (views, múltiples pipelines) | ❌ limitada a claves planas | ✅ completa | ✅ completa |
> | Auditabilidad / GitOps | ⚠️ dispersa por los manifests | ❌ enterrada en el código | ✅ un documento revisable |
> | Cambio sin redesplegar la imagen | ✅ (ConfigMap/env) | ❌ necesita rebuild | ✅ (archivo montado) |
> | Madurez | ✅ estable | ✅ estable | ⚠️ aún estabilizándose (esquema versionado) |

---

## 3. Configuración del Resource

Un `Resource` es el conjunto inmutable de atributos que describen a la entidad que produce telemetría — es lo que le permite a un backend responder "qué servicio, qué versión, qué pod, qué región". Se adjunta a cada span, métrica y log record. Equivocarse no es cosmético: `service.name` es la clave de agrupación primaria en casi todos los backends, y las [semantic conventions](https://opentelemetry.io/docs/specs/semconv/resource/) lo exigen.

Se configura vía dos variables de entorno:

```bash
# The single most important attribute. If unset, SDKs fall back to
# "unknown_service" (often suffixed with the process name), which collapses
# every unnamed service into one blob in the backend.
export OTEL_SERVICE_NAME="checkout-api"

# Arbitrary key=value pairs, W3C Baggage syntax (comma-separated, URL-encoded values).
export OTEL_RESOURCE_ATTRIBUTES="service.namespace=shop,service.version=2.14.3,deployment.environment=production"
```

`OTEL_SERVICE_NAME` es una comodidad que se mapea al atributo de resource `service.name` y **tiene precedencia** sobre un `service.name` establecido dentro de `OTEL_RESOURCE_ATTRIBUTES`.

**Los resource detectors** fusionan automáticamente atributos derivados del entorno (host, OS, process, container, Kubernetes, cloud). Precedencia cuando la misma clave es producida por múltiples fuentes: `OTEL_RESOURCE_ATTRIBUTES`/`OTEL_SERVICE_NAME` explícitas > detectors > valores por defecto del SDK. Podés deshabilitar/habilitar conjuntos de detectors en algunos SDKs vía toggles `OTEL_*_RESOURCE_ATTRIBUTES` o `OTEL_EXPERIMENTAL_RESOURCE_DISABLED_KEYS`.

---

## 4. Configuración del pipeline de señales: exporters, processors, readers

Cada señal (traces, metrics, logs) tiene su propio pipeline. La forma es:

```
Instrumentation → (SpanProcessor | LogRecordProcessor | MetricReader) → Exporter → wire
```

### 4.1 Elección de exporters

```bash
# Signal-specific exporter selection. "otlp" is the default and correct answer for prod.
export OTEL_TRACES_EXPORTER=otlp        # otlp | console | none | zipkin | jaeger(deprecated)
export OTEL_METRICS_EXPORTER=otlp       # otlp | console | none | prometheus
export OTEL_LOGS_EXPORTER=otlp          # otlp | console | none
```

`none` deshabilita por completo la exportación de esa señal (útil para silenciar métricas mientras se mantienen los traces). `console` es un exporter de depuración — nunca en prod, serializa cada span a stdout.

### 4.2 Exporter OTLP: configuración del transporte

OTLP es el protocolo nativo. Dos transportes, y elegir mal es una causa frecuente de caídas.

| Aspecto | gRPC | HTTP/protobuf |
|---|---|---|
| Valor de `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | `http/protobuf` (también `http/json`) |
| Puerto por defecto | `4317` | `4318` |
| Endpoint por defecto | `http://localhost:4317` | `http://localhost:4318` |
| Manejo de path (endpoint agnóstico a la señal) | ninguno — usado como base | el SDK **agrega** `/v1/traces`, `/v1/metrics`, `/v1/logs` |
| Manejo de path (endpoint por señal) | usado **tal cual**, sin agregar path | usado **tal cual**, sin agregar path |
| Multiplexación / streaming | ✅ streams HTTP/2 | ❌ request/response |
| Amabilidad con proxy / gateway L7 | ⚠️ necesita un LB consciente de gRPC | ✅ HTTP plano |
| Protocolo por defecto según la spec | \(los SDKs DEBERÍAN usar por defecto\) `http/protobuf` | — |

> **El clásico 404.** Con `http/protobuf` y el `OTEL_EXPORTER_OTLP_ENDPOINT` *agnóstico a la señal*, el SDK agrega `/v1/traces`. Si en cambio establecés el `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` *por señal*, se usa literalmente — así que `…:4318` (sin path) produce `404 Not Found` porque debés escribir vos mismo el `…:4318/v1/traces` completo.

Superficie completa de variables de entorno de OTLP:

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

El processor decide *cuándo* dejan los spans el proceso. Este es un compromiso entre throughput/latencia/memoria, y la elección equivocada o bien agrega latencia a cada request o bien provoca OOM en el pod.

| | `SimpleSpanProcessor` | `BatchSpanProcessor` (BSP) |
|---|---|---|
| Disparador de export | Sincrónicamente en **cada fin de span** | Al llenarse la cola, al tick del temporizador o al umbral de tamaño de lote |
| Impacto en latencia | Bloquea el hilo que termina hasta el export | Ninguno en el hot path (worker asíncrono) |
| Throughput | Pobre (un RPC por span) | Alto (RPCs por lotes) |
| Memoria | ~cero buffering | Cola acotada (descarta al desbordarse) |
| Pérdida de datos al desbordar | N/A | Descarta silenciosamente cuando la cola está llena |
| Caso de uso | Tests, depuración | **Todo en producción** |

Variables de entorno de ajuste del BSP (estas son las palancas que tocás bajo carga):

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

> **Aritmética del desbordamiento.** Si un servicio produce spans más rápido que `MAX_QUEUE_SIZE / SCHEDULE_DELAY` de forma sostenida, la cola se llena y el BSP descarta spans sin excepción — solo un log de debug y (en SDKs más nuevos) una self-metric `otel.bsp.dropped_spans`. El arreglo *no* es una cola más grande (eso solo retrasa el OOM); es o más `MAX_EXPORT_BATCH_SIZE`, un `SCHEDULE_DELAY` más corto, o **head sampling** (§5).

### 4.4 Metric readers e intervalo de export

Las métricas usan un `MetricReader` (push periódico, o pull para Prometheus) en lugar de un processor:

```bash
export OTEL_METRIC_EXPORT_INTERVAL=60000      # ms between metric collect+export, default 60000
export OTEL_METRIC_EXPORT_TIMEOUT=30000       # ms, default 30000
```

**La temporality** es una configuración exclusiva de métricas con consecuencias reales en el backend: `cumulative` (nativa de Prometheus, monótona desde el inicio) vs `delta` (por intervalo, más barata para gateways sin estado como algunos backends de proveedores). Se establece vía `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE`. Elegir la equivocada produce consultas `rate()` rotas o counters contados doble.

---

## 5. Configuración del sampling

El sampling es la palanca de volumen/costo. **Head sampling** es una configuración del SDK (decisión tomada al inicio del span, barata, sin garantía de traza completa salvo que sea parent-based). **Tail sampling** vive en el Collector, no en el SDK — no los confundas en el examen.

```bash
export OTEL_TRACES_SAMPLER="parentbased_traceidratio"   # default: parentbased_always_on
export OTEL_TRACES_SAMPLER_ARG="0.1"                     # 10% for ratio-based samplers
```

| Sampler | Valor de `OTEL_TRACES_SAMPLER` | `SAMPLER_ARG` | Comportamiento |
|---|---|---|---|
| Always On | `always_on` | — | Muestrea cada span |
| Always Off | `always_off` | — | No muestrea nada (⚠️ agujero negro silencioso si queda en una imagen) |
| TraceID Ratio | `traceidratio` | float `0..1` | % determinístico basado en el hash del trace ID |
| Parent-based (por defecto) | `parentbased_always_on` | — | Respeta la decisión upstream; root = siempre on |
| Parent-based ratio | `parentbased_traceidratio` | float `0..1` | Respeta el parent; root muestreado según el ratio |
| Jaeger remote | `jaeger_remote` | `endpoint=…,pollingIntervalMs=…,initialSamplingRate=…` | Rate empujado desde un plano de control |

> **Por qué parent-based es el default y usualmente el correcto.** Con un `traceidratio` simple a 0.1, cada servicio tira los dados de forma independiente, así que una traza está completa solo si *cada* salto llega a muestrear — probabilidad `0.1^N` para N saltos. `parentbased_traceidratio` hace que el root decida una vez y cada servicio downstream **honre** la decisión (vía el flag `sampled` en el `traceparent` propagado), rindiendo trazas completas. Como la decisión es un hash determinístico del trace ID, todos los SDKs coinciden sin coordinación.

---

## 6. Configuración de la propagación de context

Los propagators serializan el trace context dentro y fuera de los carriers (headers HTTP, metadata de mensajería). Propagators desajustados a lo largo de un service mesh son *la* razón por la que las trazas se "rompen" en un límite.

```bash
# Default is "tracecontext,baggage" (W3C). Order = injection order; all listed are extracted.
export OTEL_PROPAGATORS="tracecontext,baggage,b3multi"
```

| Valor | Header(s) | Notas |
|---|---|---|
| `tracecontext` | `traceparent`, `tracestate` | Estándar W3C, el default, incluilo siempre |
| `baggage` | `baggage` | Propaga clave/valores definidos por el usuario, on por defecto |
| `b3` | `b3` (single header) | Forma de header único de Zipkin |
| `b3multi` | `X-B3-TraceId`, `X-B3-SpanId`, … | Multi-header legacy de Zipkin |
| `jaeger` | `uber-trace-id` | Clientes legacy de Jaeger |
| `xray` | `X-Amzn-Trace-Id` | AWS X-Ray |
| `none` | — | Deshabilita la propagación (rompe las trazas distribuidas — rara vez correcto) |

> **Patrón de migración.** Para mover una flota de Zipkin/B3 a W3C sin perder trazas a mitad de camino, establecé `OTEL_PROPAGATORS="tracecontext,baggage,b3multi"` en todas partes. Los servicios **extraen** las tres (así entienden a los llamadores viejos) pero **inyectan** en el orden de la lista. Una vez que cada servicio está actualizado, quitá `b3multi`.

---

## 7. Límites y válvulas de seguridad

Los límites de atributos/eventos/links son la defensa contra una llamada de instrumentación descontrolada que infla un único span a megabytes y provoca OOM en la cola del exporter. Todos son variables de entorno `OTEL_*` con valores por defecto de la spec:

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

`OTEL_SDK_DISABLED=true` es la forma correcta y mandada por la spec de deshabilitar OpenTelemetry por completo para un proceso — más limpia que el sampling `always_off` porque también detiene las métricas y los logs, no solo los traces.

---

## 8. Configuración programática — manifiesto completo (Python)

Cuando sos dueño del entry point, el código te da lo que las variables de entorno no pueden: múltiples pipelines, samplers personalizados y views. Este es un bootstrap completo, sintácticamente válido, que un servicio Python de producción importaría primero.

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

## 9. Configuración declarativa / basada en archivo — manifiesto completo

La configuración declarativa (el esquema `opentelemetry-configuration`) describe el SDK *entero* en un único documento YAML agnóstico al lenguaje. Es la respuesta amigable con GitOps: revisable, diffeable, idéntica en Java/Go/Python/.NET. Se activa apuntando una variable de entorno al archivo; cuando está establecida, las demás variables `OTEL_*` se ignoran.

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

> El valor de `file_format` es un umbral estricto: un SDK que soporta el esquema `0.3` rechazará un documento `0.4` en lugar de parsearlo mal silenciosamente. Fijá la versión y subila deliberadamente.

---

## 10. Kubernetes: inyectando configuración a escala

En la práctica rara vez establecés variables de entorno a mano — las inyectás. Dos patrones de producción.

### 10.1 env plano + ConfigMap

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

### 10.2 OpenTelemetry Operator — inyección zero-code vía la CRD `Instrumentation`

Para auto-instrumentación, el Operator inyecta el SDK y *toda* la configuración `OTEL_*` a través de una anotación. La configuración se centraliza en un único CR con alcance de clúster.

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

Incorporá un workload con una única anotación en el pod-template — sin rebuild de imagen:

```yaml
      annotations:
        instrumentation.opentelemetry.io/inject-python: "shop-instrumentation"
```

---

## 11. Verificación y diagnóstico de fallos

Los bugs de configuración se manifiestan como *silencio*, así que verificás haciendo que el pipeline hable antes de confiar en él.

### Paso 1 — volcá el entorno efectivo

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

### Paso 2 — activá los diagnósticos propios del SDK

```console
$ kubectl set env deploy/checkout-api -n shop OTEL_LOG_LEVEL=debug
deployment.apps/checkout-api env updated

$ kubectl logs deploy/checkout-api -n shop | grep -i otel
[otel.sdk] Resource attributes: {service.name=checkout-api, service.namespace=shop, ...}
[otel.sdk] BatchSpanProcessor started (queue=4096, batch=1024, delay=2000ms)
[otel.exporter.otlp] Exporting 1024 spans to http://otel-collector...svc:4318/v1/traces
[otel.exporter.otlp] Export SUCCESS: 1024 spans, HTTP 200, 41ms
```

### Paso 3 — probá la alcanzabilidad desde el pod (aísla la red de la config)

```console
$ kubectl exec deploy/checkout-api -n shop -- \
    curl -s -o /dev/null -w "%{http_code}\n" \
    http://otel-collector.observability.svc:4318/v1/traces -X POST \
    -H "Content-Type: application/x-protobuf" --data-binary ""
400
```

> `400` (bad request, porque enviamos un body vacío) es *buena noticia* — el endpoint existe y habla OTLP/HTTP. `404` significa path equivocado (`/v1/traces` faltante en un endpoint por señal). `Connection refused` / timeout significa que el Collector o su Service es el problema, no tu config.

### Paso 4 — confirmá en el Collector

```console
$ kubectl logs deploy/otel-collector -n observability | grep checkout-api
2026-08-10T14:02:11Z info  TracesExporter  {"resource": "checkout-api", "#spans": 1024}
```

### Paso 5 — un exporter `debug` en el Collector como prueba de humo

Enrutá temporalmente todo a stdout para probar que los datos *llegan*:

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

### Catálogo de fallos

| Síntoma | Causa probable de configuración | Arreglo |
|---|---|---|
| Ningún dato en absoluto, sin errores en la app | `OTEL_SDK_DISABLED=true` o `*_EXPORTER=none` | Desestablecelo; usá `console` para confirmar la generación |
| Sin traces, métricas bien | `OTEL_TRACES_SAMPLER=always_off` o ratio `0` | Establecé `parentbased_always_on` para probar |
| Exporter `404 Not Found` | Endpoint HTTP por señal sin `/v1/traces` | Agregá el path de la señal, o usá el endpoint agnóstico a la señal |
| Exporter `connection refused` | Puerto equivocado (4317 vs 4318) / protocolo desajustado | Alineá `OTEL_EXPORTER_OTLP_PROTOCOL` con el puerto |
| Las trazas se rompen en un límite de servicio | Propagator desajustado (`b3` de un lado, `tracecontext` del otro) | Agregá ambos a `OTEL_PROPAGATORS` en toda la flota |
| Todo agrupado como `unknown_service` | `OTEL_SERVICE_NAME` sin establecer | Establecelo (o vía `OTEL_RESOURCE_ATTRIBUTES`) |
| Spans faltantes intermitentes bajo carga | Desbordamiento de la cola del BSP | Subí `OTEL_BSP_MAX_QUEUE_SIZE` / tamaño de lote, o muestreá |
| Un ajuste en el código sobrescribe una variable de entorno | La config programática gana sobre env | Quitá la llamada al builder hardcodeada |
| Variables de entorno "ignoradas" por completo | `OTEL_EXPERIMENTAL_CONFIG_FILE` está establecida — el archivo toma el control | Movés el ajuste al YAML, o desestablecés la variable del archivo |
| Fallos de handshake `gzip`/TLS | `OTEL_EXPORTER_OTLP_COMPRESSION` / paths de certificados equivocados | Verificá las variables de CA/cert y el TLS del Collector |

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