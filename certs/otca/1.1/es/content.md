# 1.1 Datos de Telemetría

> **Dominio:** Fundamentos de la Observabilidad · **Peso en el examen:** 4.5
> **Perfil:** Este es el cimiento conceptual de todo el OTCA. Todo lo que construyen los dominios del SDK, el Collector y el pipeline asume que ya cargás con un modelo mental preciso de *qué es una señal*, *cómo se le da forma en el cable* y *cómo se correlacionan las señales*. Equivocate acá y cada decisión de diseño río abajo — sampling, presupuestos de cardinalidad, costo, correlación — hereda el error.

---

## 1. El problema de producción: por qué los "datos de telemetría" son un problema de modelado de datos, no un problema de logging

La visión ingenua es que la observabilidad es "agregá logs, agregá una librería de métricas, agregá un tracer". En producción esto falla por una razón específica y estructural: **tres modelos de datos inventados de forma independiente no pueden correlacionarse a posteriori.**

Considerá el incidente que realmente vas a atender: la latencia p99 en `checkout-api` salta de 40 ms a 900 ms a las 03:14 UTC. Tenés:

- Un sistema de **métricas** (Prometheus) que te dice *que* el p99 subió, agregado por `pod`, sin forma de llegar a una request lenta individual.
- Un sistema de **logs** (Loki/ELK) con millones de líneas, donde las requests lentas son indistinguibles de las rápidas porque la línea de log nunca registró un identificador de request que coincida con algo en el trace.
- Un sistema de **traces** (Jaeger) que tiene spans, pero los spans fueron emitidos por una librería de instrumentación *diferente* que estampó `service` = `checkout` mientras que las métricas estamparon `service_name` = `checkout-api`, así que no existe ninguna clave de join.

Los tres pilares son tres silos de datos **sin identidad compartida, sin semántica de timestamp compartida y sin vocabulario de atributos compartido.** La tesis central de OpenTelemetry es que esto es un problema de *modelo de datos*. La solución no es un mejor logger — es:

1. **Un modelo de datos unificado** para todas las señales (traces, metrics, logs, baggage y ahora profiles), cada una con un esquema especificado formalmente.
2. **Un `Resource` compartido** — la misma identidad inmutable adjunta a cada señal que emite un proceso.
3. **Un `Context` compartido** que lleva `trace_id`/`span_id`, para que una línea de log, un exemplar de métrica y un span puedan todos apuntar de vuelta a la misma request.
4. **Semantic Conventions** — una única ortografía canónica para cada atributo (`service.name`, `http.request.method`, `k8s.pod.name`), para que la clave de join sea idéntica entre señales y entre vendors.
5. **OTLP** — un único protocolo de cable para que el productor nunca necesite saber qué backend va a almacenar los datos.

Ese es todo el argumento arquitectónico de OpenTelemetry, y el Topic 1.1 es el vocabulario para eso. El resto de este documento es el modelo de datos preciso de cada señal, la representación en el cable y cómo *verificás* que el modelo se está respetando en un pipeline en vivo.

---

## 2. Señales: la taxonomía

Una **señal** en OpenTelemetry es una categoría de telemetría con su propio modelo de datos, API, SDK y servicio OTLP. A partir de la spec actual las señales son:

| Señal | Estabilidad | Responde la pregunta | Perfil de cardinalidad | Factor de costo |
|---|---|---|---|---|
| **Traces** | Stable | *¿Dónde* se fue el tiempo en esta request, a través de los servicios? | Alta (atributos por span) | Volumen de spans × tasa de sampling |
| **Metrics** | Stable | *¿Cuántos / cuánto / qué tan rápido*, agregado en el tiempo? | Acotada por la cardinalidad de atributos | Series temporales activas (cardinalidad) |
| **Logs** | Stable | *¿Qué pasó exactamente* en este instante, con detalle? | Muy alta (body ilimitado) | Bytes ingeridos + índice |
| **Baggage** | Stable | *¿Qué pares clave-valor contextuales* deberían viajar con la request? | N/A (propagación, no almacenamiento) | Tamaño de header / overhead de propagación |
| **Profiles** | Development/Experimental | *¿Qué línea de código / stack frame* quemó CPU/memoria? | Muy alta (agregación de stacks) | Volumen de muestras |

Dos cosas hacen tropezar a los candidatos:

- **Baggage es una señal pero no una señal de *almacenamiento* de telemetría.** Es un mecanismo de propagación: un conjunto de pares clave-valor llevados en el `Context` y a través de los límites de proceso vía el header W3C `baggage`. *No* se escribe automáticamente en spans o métricas (hacerlo es un paso de procesador explícito y deliberado, porque copiar baggage en cada span es un footgun de cardinalidad y de PII).
- **Profiles** es la cuarta señal "real" (continuous profiling) y se está estandarizando con su propio mensaje OTLP. Esperá que aparezca en material de examen más nuevo como "emergente/experimental". No la trates como stable.

### 2.1 La anatomía compartida por cada señal

Cada ítem de señal que sale de un proceso es una tupla de:

```
(Resource, InstrumentationScope, <signal-specific payload>)
```

- **`Resource`** — atributos inmutables que identifican la *entidad* que produjo la telemetría (la instancia del servicio, el host, el pod). El mismo para cada span/metric/log que el proceso emite durante su vida.
- **`InstrumentationScope`** (antes "InstrumentationLibrary") — el `name` y la `version` de la instrumentación que produjo este ítem, por ej. `io.opentelemetry.okhttp-3.0` versión `1.32.0`. Te permite atribuir un span defectuoso a una librería específica.
- **Payload** — el span, el data point de métrica, o el log record.

Este envoltorio de tres partes es la razón por la que los mensajes OTLP están anidados `resource → scope → data`. Internalizá esa forma; es la estructura que vas a leer en cada volcado del debug exporter y en cada captura OTLP.

---

## 3. Traces en profundidad

### 3.1 Modelo de datos

Un **trace** es un grafo acíclico dirigido (DAG) de **spans** que comparten un `trace_id`. Un **span** es una única operación nombrada y temporizada. Sus campos (mensaje OTLP `Span`):

| Campo | Tipo / tamaño | Notas |
|---|---|---|
| `trace_id` | 16 bytes (128-bit) | Globalmente único por trace. Codificado en hex en el cable como 32 chars. |
| `span_id` | 8 bytes (64-bit) | Único dentro del trace. 16 chars hex. |
| `parent_span_id` | 8 bytes | Vacío ⇒ este es un **root span**. |
| `name` | string | Nombre de operación de baja cardinalidad (`GET /orders/{id}`, no `GET /orders/42`). |
| `kind` | enum | `INTERNAL`, `SERVER`, `CLIENT`, `PRODUCER`, `CONSUMER`. |
| `start_time_unix_nano` / `end_time_unix_nano` | uint64 | Nanosegundos desde la época Unix. Duración = end − start. |
| `attributes` | lista clave-valor | Dimensiones (`http.response.status_code`, `db.system`). |
| `events` | lista de `(time, name, attributes)` | Marcadores puntuales *dentro* del span (por ej. `exception`). |
| `links` | lista de `(SpanContext, attributes)` | Referencias a *otros* traces/spans (fan-in, batching). |
| `status` | `{code, message}` | `UNSET` (default), `OK`, `ERROR`. |
| `trace_state` | string | W3C `tracestate`, pistas de routing/sampling del vendor. |

**`SpanKind` importa para la topología y para la semántica del backend.** Un par `CLIENT`+`SERVER` a través de un límite de red es como un backend reconstruye "el servicio A llamó al servicio B". Equivocarse con el kind rompe los mapas de servicios y la derivación de RED-metrics.

| Kind | Emitido por | Campo peer típico |
|---|---|---|
| `SERVER` | El receptor de una request entrante síncrona | `client.address` |
| `CLIENT` | El iniciador de una request saliente síncrona | `server.address` |
| `PRODUCER` | Encola un mensaje asíncrono | `messaging.destination.name` |
| `CONSUMER` | Procesa un mensaje asíncrono | vinculado al producer vía `links` |
| `INTERNAL` | Trabajo puramente en-proceso | — |

**La semántica de `Status`** es sutil y evaluada en el examen: `UNSET` es el default y significa "sin juicio explícito". Un span es `ERROR` solo cuando la instrumentación (o vos) decide que la operación falló. Notablemente, según las semantic conventions de HTTP, un span `SERVER` con un status `4xx` **no** es automáticamente `ERROR` (un 404 es problema del cliente), mientras que `5xx` sí lo es. `OK` está reservado para una anulación explícita del desarrollador y debería ser raro.

### 3.2 SpanContext y propagación — el formato de cable W3C Trace Context

El **`SpanContext`** es la identidad inmutable y serializable de un span que cruza el cable: `{trace_id, span_id, trace_flags, trace_state, is_remote}`. *No* es el span — no lleva atributos, ni timing. Es exactamente lo que se necesita para hacer que los spans del *siguiente* servicio sean hijos de este.

La propagación a través de HTTP usa los headers estándar de **W3C Trace Context**:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
          version    trace-id (16B)         parent-id (8B)    trace-flags
```

- `version` = `00`.
- `trace-id` = 32 hex minúsculas (todo-cero es inválido).
- `parent-id` = el `span_id` del que llama (se convierte en `parent_span_id` río abajo).
- `trace-flags` = campo de bits de 8-bit; el bit 0 (`01`) es el flag **sampled**.

```
tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

Específico del vendor, ordenado (izquierda = más reciente), con tamaño limitado. Así es como una decisión de sampling o la clave de routing de un vendor sobrevive a través de un mesh heterogéneo.

> **Modo de falla en producción:** un proxy o gateway que elimina headers desconocidos va a borrar `traceparent`, rompiendo silenciosamente los traces en fragmentos desconectados. Cada servicio río abajo se convierte en un nuevo span *root*. Vas a ver traces "huérfanos" de profundidad 1. El diagnóstico está en §8.

### 3.3 Sampling — el primer trade-off real

No podés almacenar cada span en un sistema de alto QPS. El sampling es donde el costo se encuentra con la fidelidad.

| Estrategia | Dónde se decide | ¿Ve el trace completo? | Costo de almacenamiento | ¿Captura errores raros? | Consistencia |
|---|---|---|---|---|---|
| **Head sampling** (`TraceIdRatioBased`, `ParentBased`) | En el root, al iniciar el span | No | Bajo, predecible | Pobremente (decisión tomada antes de conocer el resultado) | Consistente si `ParentBased` + flag propagado |
| **Tail sampling** (processor `tail_sampling` del Collector) | Después de que todo el trace esté ensamblado | Sí | Alto (debe bufferear todos los spans hasta decidir) | Sí (puede basarse en `status=ERROR`, latencia) | Requiere que todos los spans de un trace lleguen a una instancia del Collector |
| **Remote / adaptive** | Un control plane central empuja las tasas | No | Ajustable | Medio | Coordinado |

**Head sampling** es una tirada de moneda por request hecha en el root y *propagada* vía el bit `sampled` para que todo el trace coincida. Barato y determinista, pero decidís conservar un trace antes de saber que dio error. **Tail sampling** bufferea los spans en el Collector y decide una vez que el trace está completo — así podés conservar *todos los errores y todos los traces lentos* y descartar los aburridos 200s — a costa de memoria y del requisito duro de que cada span de un `trace_id` dado llegue a la *misma* instancia del Collector (esto fuerza un balanceo de carga consciente del `trace_id` vía el exporter `loadbalancing`). Esto es material del dominio del Collector, pero la *razón* por la que existe es un hecho del Topic 1.1: la calidad de la decisión de sampling está acotada por cuánto del trace podés ver cuando la tomás.

---

## 4. Metrics en profundidad

### 4.1 El pipeline instrument → stream → point

Las métricas de OpenTelemetry separan el **instrument de la API** que llamás en el código del **stream agregado** que se envía. La capa de View/Aggregation se ubica entre ambos.

```
Instrument (Counter/Histogram/…)  →  Measurement (value + attributes)
        →  View + Aggregation  →  Metric Stream  →  DataPoint(s)  →  OTLP
```

### 4.2 Instruments

| Instrument | Sync/Async | ¿Monotónico? | Uso típico | Agregación OTLP |
|---|---|---|---|---|
| `Counter` | Sync | Sí (add ≥ 0) | requests atendidas, bytes enviados | `Sum` |
| `UpDownCounter` | Sync | No | profundidad de cola, conexiones activas | `Sum` |
| `Histogram` | Sync | — | duración de request, tamaño de payload | `Histogram` / `ExponentialHistogram` |
| `Gauge` (sync) | Sync | No | temperatura actual, último valor | `Gauge` |
| `ObservableCounter` | Async (callback) | Sí | segundos de CPU desde `/proc` | `Sum` |
| `ObservableUpDownCounter` | Async | No | memoria en uso | `Sum` |
| `ObservableGauge` | Async | No | tamaño de heap actual muestreado en collect | `Gauge` |

**Sync vs async** es una decisión de diseño real: los instruments síncronos se llaman *inline* en el hot path en el momento en que ocurre el evento (y pueden adjuntar atributos con alcance de request y exemplars). Los instruments asíncronos registran un **callback** invocado solo en tiempo de collection — correcto para valores que *leés* (un gauge del OS) en vez de *contar*, y más barato porque se disparan una vez por intervalo de export sin importar el QPS.

### 4.3 Aggregation temporality — el concepto de métricas más evaluado

Un `Sum` (y `Histogram`) tiene una **aggregation temporality**:

| | **Cumulative** | **Delta** |
|---|---|---|
| Cada punto reporta | Total acumulado desde un `start_time` fijo | Cambio desde el punto *anterior* |
| `start_time` | Fijo al inicio del proceso | Avanza en cada intervalo |
| Comportamiento en restart | El total se resetea a 0 — el backend debe detectar la caída | Maneja naturalmente los restarts (cada delta se sostiene solo) |
| Memoria en el SDK | Debe retener el estado acumulado | Puede olvidar tras el export |
| Ajuste con el backend | **Prometheus** (nativo, `rate()` espera cumulative monotónico) | Estilo **StatsD/Datadog**, pipelines sin estado |
| Pérdida de un export | Recuperable (el siguiente punto cumulative sigue teniendo el total) | **Hueco permanente** (ese delta se perdió para siempre) |

Esta es la trampa clásica del examen: **Prometheus es cumulative; Delta no es directamente ingerible por Prometheus** sin la conversión `cumulativetodelta`/`deltatocumulative` del Collector. Elegí la temporality para que coincida con el *backend*, y configurala vía el exporter (`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta|cumulative|lowmemory`).

### 4.4 Cardinalidad — el modelo de costo de las métricas

Una **serie temporal** es una tupla única `(nombre de métrica, conjunto de atributos, resource)`. El costo y la memoria en todo backend de métricas escalan con el número de series temporales *activas*, es decir, la **cardinalidad**. Los atributos de alta cardinalidad (`user.id`, `request.id`, URLs crudas con IDs) multiplican las series combinatoriamente y son la causa número uno de una factura de métricas o de un OOM.

```
series ≈ (# distinct http.route) × (# distinct http.response.status_code)
         × (# distinct http.request.method) × (# pods)
```

Diez rutas × 15 status codes × 5 métodos × 200 pods = 150.000 series para *un* histograma. Agregá `user.id` (1M usuarios) y tenés una interrupción autoinfligida. La mitigación es el **exemplar**: mantené la métrica de baja cardinalidad y adjuntá una *muestra* de `trace_id`s a buckets específicos para que todavía puedas saltar de "el bucket del p99" a "un trace lento real".

### 4.5 Exemplars — el puente metrics↔traces

Un **exemplar** es una muestra `(value, timestamp, trace_id, span_id, filtered_attributes)` registrada en un bucket de histograma o en un sum. Es la clave de join de correlación que permite que el panel de "latencia p99" de un dashboard haga deep-link a un trace lento representativo *sin* elevar la cardinalidad. Los exemplars solo se registran significativamente cuando hay un span *sampled* activo en el contexto al momento de la medición — otra razón por la que traces y métricas deben compartir el `Context`.

---

## 5. Logs en profundidad

OpenTelemetry trata a los logs de manera diferente a traces y metrics: en vez de una API de logging completamente nueva para que adoptes, define un **modelo de datos LogRecord** y un **bridge/appender** que adapta los loggers existentes (Logback, log4j, `structlog`, zap) a OTLP. El objetivo es la correlación, no el reemplazo.

### 5.1 Modelo de datos LogRecord

| Campo | Notas |
|---|---|
| `time_unix_nano` | Cuándo ocurrió el evento (puede ser desconocido). |
| `observed_time_unix_nano` | Cuándo el collector/SDK lo observó (siempre conocido — fallback para el ordenamiento). |
| `severity_number` | Escala numérica 1–24 (ver abajo) — comparable por máquina. |
| `severity_text` | String de nivel original (`WARN`, `error`). |
| `body` | El mensaje; string **o** estructurado (map/array). |
| `attributes` | Clave-valores estructurados (el reemplazo moderno de parsear un string con regex). |
| `trace_id`, `span_id`, `trace_flags` | **Los campos de correlación** — poblados desde el `Context` activo. |
| `Resource`, `InstrumentationScope` | El mismo envoltorio que cada señal. |

**Rangos de `severity_number`** (evaluados):

| Rango | Nivel |
|---|---|
| 1–4 | TRACE |
| 5–8 | DEBUG |
| 9–12 | INFO |
| 13–16 | WARN |
| 17–20 | ERROR |
| 21–24 | FATAL |

La escala numérica existe para que un backend pueda filtrar "≥ WARN" de manera uniforme entre servicios que usan *strings* de nivel diferentes (`WARNING` vs `warn` vs `W`).

### 5.2 Por qué los campos de trace-context son el punto central

Una línea de log que lleva `trace_id`/`span_id` es una que puede pivotarse hacia y desde el span exacto dentro del cual ocurrió. Esto se configura automáticamente cuando el log bridge lee el `Context` activo. Sin ello volvés a `grep` y a las conjeturas. El diseño te permite *reducir* el volumen de logging (los logs son la señal más cara por byte) porque el trace lleva la estructura y el log lleva solo el detalle irreducible.

| Señal | Mejor para | Peor para | Costo por ítem |
|---|---|---|---|
| Metric | Tendencia, umbral de alerta, SLO | Explicar una request | El más barato (agregado) |
| Trace | Desglose de latencia, mapa de dependencias | Tendencia de largo plazo (sampleado) | Medio (sampleado) |
| Log | Detalle exacto de error, auditoría | Agregación, alertar sobre una tasa | El más caro (bytes) |

---

## 6. Baggage, Resource y Semantic Conventions — el sustrato de correlación

### 6.1 Baggage

**Baggage** es un conjunto de pares clave-valor almacenados en el `Context` y propagados a través de los límites de servicio vía el header W3C `baggage`:

```
baggage: userId=alice,serverNode=DF%2028,isProduction=false
```

Usalo para llevar datos con alcance de request (tenant id, cohorte de experimento) que un servicio *río abajo* necesita para enriquecer *su propia* telemetría. **Baggage no se adjunta automáticamente a los spans** — optás por ello (por ej. el copiado de `baggage` del Collector o el span processor del SDK). Dos reglas duras de producción:

1. **Nunca pongas secretos o PII en baggage** — viaja en headers de texto plano a cada servicio río abajo, incluyendo terceros.
2. **Baggage hace crecer el header de la request en cada hop** — mantenelo minúsculo; algunos gateways limitan el tamaño de header y van a descartar la request.

### 6.2 Resource

El **`Resource`** es la identidad inmutable del productor. Resource mínimo viable en producción:

```
service.name        = checkout-api        # REQUIRED; if unset, SDK uses "unknown_service"
service.namespace   = shop
service.version     = 1.8.3
service.instance.id = 7f3c…               # unique per replica
```

Enriquecido automáticamente por **resource detectors** (host, process, container, k8s, cloud). `service.name` es *requerido*; cuando falta, el SDK estampa `unknown_service:<process>` — un valor que vas a aprender a reconocer como "alguien se olvidó de configurar el SDK".

### 6.3 Semantic Conventions — el vocabulario compartido

Las **Semantic Conventions** son los nombres de atributos estandarizados y versionados que hacen posibles los joins cross-signal y cross-vendor. Son lo que garantiza que el `http.response.status_code` de la *métrica* y el `http.response.status_code` del *span* sean literalmente la misma clave.

| Legacy (pre-estabilización) | Stable |
|---|---|
| `http.method` | `http.request.method` |
| `http.status_code` | `http.response.status_code` |
| `net.peer.name` | `server.address` |
| `http.url` | `url.full` |

Como estas evolucionaron, la telemetría lleva un **`schema_url`** para que un backend sepa qué versión de convención sigue un ítem, y el `schemaprocessor` del Collector puede transformar entre versiones. **No inventes nombres de atributos cuando existe una convención** — un atributo `status` a medida es invisible para todo dashboard consciente de las convenciones.

---

## 7. OTLP — el formato de cable que ata todo

**OTLP (OpenTelemetry Protocol)** es el único protocolo sobre el que se envían todas las señales. Transportes:

| Transporte | Puerto (default) | Codificación | Ruta HTTP (por señal) |
|---|---|---|---|
| gRPC | `4317` | Protobuf | n/a (métodos de servicio) |
| HTTP | `4318` | Protobuf **o** JSON | `/v1/traces`, `/v1/metrics`, `/v1/logs`, `/v1/profiles` |

| | gRPC (`4317`) | HTTP/protobuf (`4318`) | HTTP/JSON (`4318`) |
|---|---|---|---|
| Throughput | El más alto (multiplexación HTTP/2, streaming) | Alto | Más bajo (costo de parseo JSON) |
| Amigable para browser | No | Sí (con CORS) | Sí |
| Debuggabilidad | Necesita `grpcurl` | `curl` + protobuf | `curl` legible |
| Amigabilidad con Proxy/LB | Necesita un LB consciente de HTTP/2 | Trivial | Trivial |
| Default cuando no se setea | `grpc` | — | — |

La forma del mensaje refleja el envoltorio compartido: `ExportTraceServiceRequest → resource_spans[] → { resource, scope_spans[] → { scope, spans[] } }`. OTLP también define el **partial success** (`rejected_spans` + `error_message`) y una división de errores **retryable vs non-retryable** para que los exporters hagan back off correctamente. La configuración de entorno del exporter:

```
OTEL_EXPORTER_OTLP_ENDPOINT=https://collector.obs.svc:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc          # or http/protobuf, http/json
OTEL_EXPORTER_OTLP_HEADERS=authorization=Bearer%20<token>
OTEL_EXPORTER_OTLP_COMPRESSION=gzip
```

---

## 8. Infraestructura completa de producción

El siguiente stack es un ejemplo autoconsistente y desplegable: una app configurada enteramente por variables de entorno OTEL, un Collector que recibe las tres señales, y el cableado de Kubernetes. Nada acá está truncado.

### 8.1 Configuración del OpenTelemetry Collector (las tres señales)

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

### 8.2 Deployment de Kubernetes: Collector + una app instrumentada

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

### 8.3 Configuración del lado de la app — cero código, puro entorno

El proceso de la app es instrumentado por el SDK; todo el comportamiento de telemetría es dirigido por env vars para que la misma imagen se envíe a cada entorno:

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

## 9. Verificación práctica y diagnóstico de fallas

Verificás un pipeline de telemetría de la misma forma que verificás cualquier pipeline de datos: inyectás una entrada conocida, la observás en cada hop, y confirmás que el esquema sobrevivió. `telemetrygen` (del repo Collector-contrib) es el emisor sintético canónico.

### 9.1 Emitir un trace conocido y verlo aterrizar

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

En la salida del `debug` exporter del Collector (`kubectl logs`), deberías ver el envoltorio compartido — Resource, Scope, luego el span, con un `Trace ID` válido no-cero:

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

**Criterios de aprobación:** `Trace ID` no-cero, un root span (`Parent ID` vacío) con dos hijos que comparten el mismo `Trace ID`, y el Resource lleva `service.name`.

### 9.2 Picar OTLP/HTTP directamente con `curl` (JSON)

Aísla "¿está arriba el receiver y aceptando?" de cualquier cuestión del SDK:

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

Un `partialSuccess` vacío = totalmente aceptado. Uno poblado te dice exactamente qué fue rechazado:

```json
{"partialSuccess":{"rejectedSpans":"1","errorMessage":"invalid trace id"}}
```

### 9.3 Confirmar el receiver sobre gRPC con `grpcurl`

```console
$ grpcurl -plaintext otel-collector.obs.svc:4317 list
grpc.reflection.v1alpha.ServerReflection
opentelemetry.proto.collector.logs.v1.LogsService
opentelemetry.proto.collector.metrics.v1.MetricsService
opentelemetry.proto.collector.trace.v1.TraceService
```

Ver los tres servicios = los tres pipelines están cableados en el receiver.

### 9.4 Leer las propias métricas del Collector (la telemetría del pipeline)

El Collector exporta su auto-telemetría en `:8888`. Estos son tus SLIs del pipeline:

```console
$ kubectl -n obs port-forward deploy/otel-collector 8888:8888 &
$ curl -s localhost:8888/metrics | grep -E 'receiver_accepted|exporter_sent|exporter_send_failed|refused'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 31402
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 0
otelcol_exporter_sent_spans{exporter="otlp/traces"} 31402
otelcol_exporter_send_failed_spans{exporter="otlp/traces"} 0
otelcol_processor_dropped_spans{processor="memory_limiter"} 0
```

**La identidad diagnóstica a memorizar:**
`accepted − (sent + send_failed + dropped + queued)` debería tender a cero. La divergencia te dice *dónde* mueren los datos:

| Síntoma | Significado | Solución |
|---|---|---|
| `receiver_refused_spans` > 0 | El `memory_limiter` está descartando carga | Subir límites / agregar réplicas / achicar el batch |
| `exporter_send_failed_spans` > 0 | Backend inalcanzable o rechazando | Chequear TLS/auth/salud del backend; observar `retry` |
| `exporter_queue_size` subiendo hacia `queue_size` | Backend más lento que la ingesta | Escalar el backend; subir `num_consumers`; riesgo de descarte |
| `accepted` = 0 a pesar del tráfico | Puerto/protocolo/endpoint equivocado en la app | Verificar `OTEL_EXPORTER_OTLP_ENDPOINT` y `PROTOCOL` |

### 9.5 Inspeccionar los pipelines en vivo con zPages

```console
$ kubectl -n obs port-forward deploy/otel-collector 55679:55679 &
$ curl -s "localhost:55679/debug/tracez" | head -20
# TraceZ: per-operation latency buckets and recent error samples for the
# Collector's own spans — confirms internal span flow and surfaces stuck ops.

$ curl -s "localhost:55679/debug/pipelinez"
# Renders each configured pipeline (traces/metrics/logs) with its
# receiver → processor → exporter chain, mutating vs read-only processors.
```

### 9.6 Diagnosticar la propagación de contexto rota (la falla de §3.2)

Síntoma: cada servicio produce traces "solo root" de profundidad 1; el mapa de servicios no muestra aristas.

```console
# 1. Confirm the caller emits traceparent (capture at the receiver / a debug proxy):
$ kubectl -n shop exec deploy/checkout-api -- \
    curl -s -D - http://orders-api.shop.svc/health -o /dev/null | grep -i traceparent
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01

# 2. Confirm the callee RECEIVES it (if the header is gone here, a proxy stripped it):
$ kubectl -n shop logs deploy/orders-api | grep -i "incoming traceparent"
(no output)   ← header was stripped between the two services
```

Causas raíz, en orden de frecuencia: (a) `OTEL_PROPAGATORS` mal configurado o disparejo entre servicios (por ej. uno habla `b3`, el otro `tracecontext`); (b) un hop de ingress/service-mesh/proxy que descarta headers desconocidos; (c) una librería cliente no instrumentada, así que nunca inyecta `traceparent`. Arreglá (a) estandarizando en `tracecontext,baggage` en toda la flota; arreglá (b) poniendo en allow-list `traceparent`/`tracestate`/`baggage` en el proxy; arreglá (c) agregando la instrumentación faltante.

### 9.7 El test de olfato de `unknown_service`

```console
$ kubectl -n obs logs deploy/otel-collector | grep 'service.name' | sort -u
     -> service.name: Str(checkout-api)
     -> service.name: Str(unknown_service:python)   ← someone forgot OTEL_SERVICE_NAME
```

Cualquier `unknown_service:*` en los Resource attributes de producción significa que un workload se envió sin `OTEL_SERVICE_NAME`/`service.name` seteado. Es telemetría no-joineable, no-dashboardeable. Tratala como un rollout fallido.

---

## 10. Resumen consolidado de trade-offs (recuerdo enfocado en el examen)

| Decisión | Opción A | Opción B | Elegí A cuando… |
|---|---|---|---|
| Señal para alertar | Metrics | Logs | Siempre — los logs son para detalle, las métricas para tasa/umbral |
| Temporality de métrica | Cumulative | Delta | El backend es Prometheus / tolerás un export perdido |
| Sampling | Head | Tail | El costo/predictibilidad importa más que conservar cada error |
| Transporte OTLP | gRPC (4317) | HTTP (4318) | Servidor-a-servidor, máximo throughput (usá HTTP para browsers) |
| Correlacionar metric→trace | Exemplar | Label de alta cardinalidad | Siempre exemplar — los labels hacen explotar la cardinalidad |
| Contexto cross-service | `tracecontext` | `b3` | Greenfield / vendor-neutral (b3 solo para interop con Zipkin) |
| Llevar datos de request río abajo | Baggage | Meter en headers ad hoc | Propagación estándar, pero nunca para PII/secretos |

**Tres hechos que es más probable que se evalúen en frío:**
1. `trace_id` es de 16 bytes (128-bit); `span_id` es de 8 bytes (64-bit); la versión de `traceparent` es `00`; el flag sampled es `01`.
2. Prometheus es **cumulative**; los defaults de OTLP importan, y Delta necesita conversión para llegar a Prometheus.
3. `service.name` es un Resource attribute **requerido**; su ausencia produce `unknown_service`.

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