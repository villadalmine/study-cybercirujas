# Tema 2.1 — El Modelo de Datos de OpenTelemetry

> Peso en el examen: 6.58 · Dominio 2 (Fundamentos de OpenTelemetry) · Nivel: Producción / Arquitecto de Plataforma

---

## 1. Motivación: el problema arquitectónico que resuelve el modelo de datos

Antes de OpenTelemetry, un SRE que operaba una plataforma políglota heredaba un **problema de integración combinatorio**. Cada señal tenía su propio formato de transmisión, su propio agente y su propio esquema de identidad:

- Los traces hablaban Jaeger Thrift, Zipkin JSON v2 o un protocolo APM propietario.
- Las métricas hablaban texto de exposición de Prometheus, StatsD/DogStatsD UDP o el protocolo de línea de Graphite.
- Los logs hablaban syslog RFC 5424, GELF o líneas JSON crudas enviadas por Fluentd/Filebeat.

La consecuencia no era simplemente "tres agentes en lugar de uno". La falla más profunda era la **pérdida de correlación**. Un span en Jaeger y una línea de log en Elasticsearch que describían el *mismo request* no tenían una identidad compartida y comparable por máquina. Los ingenieros de guardia saltaban de una herramienta a otra copiando y pegando timestamps y adivinando. El `service.name` en un sistema era `service` en otro y `app` en un tercero; un `500` era `http.status_code` acá y `http_status` allá. Las decisiones de cardinalidad, retención y costo se tomaban de forma independiente por cada pilar, así que la misma falla se sobre-muestreaba en un almacén y se descartaba en otro.

El **modelo de datos de OpenTelemetry** es la respuesta a ese problema. Es un contrato *a nivel de especificación* — deliberadamente desacoplado de cualquier SDK, lenguaje o backend — que define:

1. **Una única estructura lógica para todas las señales** (traces, métricas, logs) enraizada en un `Resource` y un `InstrumentationScope` compartidos.
2. **Un esquema de identidad y correlación compartido** — el mismo `trace_id`/`span_id` que identifican un span están embebidos en los exemplars de las métricas y en los registros de log, de modo que las tres señales se apuntan entre sí por construcción, no por heurísticas de timestamp.
3. **Un sistema de atributos tipado y autodescriptivo** (`AnyValue`) más las **Semantic Conventions** que fijan los *nombres y significados* de los atributos en todo el ecosistema.
4. **Una codificación concreta de transmisión — OTLP** (OpenTelemetry Protocol) — que serializa ese modelo lógico sobre Protobuf, en gRPC o HTTP.

El principio de diseño que hay que internalizar para el examen: **el modelo de datos es agnóstico del transporte y agnóstico del backend.** OTLP es *una* codificación del modelo. Un export de Prometheus remote-write es una *proyección con pérdida* de la parte de métricas del mismo modelo. El modelo es la fuente de verdad; cada exporter es una traducción a partir de él.

```
                     ┌──────────────────────────────────────────┐
                     │              Resource                      │
                     │  service.name, service.namespace,          │
                     │  service.instance.id, host.*, k8s.*, ...   │
                     └──────────────────────────────────────────┘
                                       │ (shared by every signal)
        ┌──────────────────────────────┼──────────────────────────────┐
        ▼                               ▼                              ▼
  InstrumentationScope           InstrumentationScope           InstrumentationScope
  (name+version+schema_url)      (name+version+schema_url)       (name+version+schema_url)
        │                               │                              │
        ▼                               ▼                              ▼
   ┌─────────┐                     ┌─────────┐                    ┌─────────┐
   │  Spans  │  trace_id/span_id   │ Metrics │  exemplar.trace_id │  Logs   │
   │         │ ◄──────────────────►│ (points)│ ◄─────────────────►│ Records │
   └─────────┘   correlation       └─────────┘   correlation      └─────────┘
```

---

## 2. La estructura en capas del modelo

Toda señal comparte el mismo envoltorio de tres niveles. Aprendé esta forma una vez y se aplica a los tres mensajes OTLP:

```
Resource<Signal>          # 1 Resource + its schema_url
  └── Scope<Signal>       # 1 InstrumentationScope + its schema_url
        └── <Signal item> # Span | Metric | LogRecord
```

| Mensaje OTLP de nivel superior | Nivel intermedio | Ítem hoja |
|---|---|---|
| `ResourceSpans`   | `ScopeSpans`   | `Span`      |
| `ResourceMetrics` | `ScopeMetrics` | `Metric`    |
| `ResourceLogs`    | `ScopeLogs`    | `LogRecord` |

### 2.1 Resource

Un **Resource** es un conjunto inmutable de atributos que describe la entidad que produjo la telemetría — el *quién/dónde*. Se adjunta una sola vez y lo comparten todos los spans, métricas y logs emitidos por ese proceso. El atributo más importante de todos es `service.name`; sin él, los backends agrupan la telemetría bajo `unknown_service` y la correlación se derrumba.

Los atributos de Resource los pueblan los **Resource Detectors** (componentes del SDK que leen el entorno: ID del contenedor, K8s downward API, endpoints de metadata de la nube, `OTEL_RESOURCE_ATTRIBUTES`).

### 2.2 InstrumentationScope

Anteriormente `InstrumentationLibrary` (renombrado en la especificación estable). Identifica al *emisor de un instrumento dado* — típicamente la librería de instrumentación o un tracer/meter/logger con nombre:

```
InstrumentationScope {
  name        = "io.opentelemetry.okhttp-3.0"   // required, logical name
  version     = "1.32.0"
  schema_url  = "https://opentelemetry.io/schemas/1.27.0"
  attributes  = [ ... ]                          // scope-level attributes
}
```

### 2.3 Los atributos y el tipo `AnyValue`

Los atributos son pares clave–valor. El valor es un `AnyValue` — una unión tipada. Esto es lo que hace que OTLP sea autodescriptivo en la transmisión.

| Variante de `AnyValue` | Tipo subyacente | Notas |
|---|---|---|
| `string_value`  | UTF-8 string        | el más común |
| `bool_value`    | boolean             | |
| `int_value`     | signed 64-bit int   | los enteros son **int64**, no doubles |
| `double_value`  | IEEE-754 double     | |
| `bytes_value`   | raw bytes           | |
| `array_value`   | `ArrayValue` (list of `AnyValue`) | homogénea por convención |
| `kvlist_value`  | `KeyValueList` (nested map) | para atributos estructurados |

**Regla de producción:** las *claves* de los atributos deberían provenir de las Semantic Conventions cuando exista una (`http.request.method`, no `verb`). Los atributos son el principal impulsor de la **cardinalidad** y, por lo tanto, del costo de indexación y almacenamiento — nunca pongas valores no acotados (IDs de usuario, URLs completas con query strings, UUIDs de request) dentro de atributos de métricas.

---

## 3. Señal 1 — Traces

### 3.1 El Span

Un **Span** es una única operación con un inicio y un fin. Los campos definidos por el modelo:

| Campo | Tipo / tamaño | Significado |
|---|---|---|
| `trace_id`        | 16 bytes (128-bit) | identifica el trace completo; todo-ceros es inválido |
| `span_id`         | 8 bytes (64-bit)   | identifica este span; todo-ceros es inválido |
| `parent_span_id`  | 8 bytes            | vacío ⇒ este es un span raíz |
| `trace_state`     | string (W3C `tracestate`) | estado de propagación del vendor |
| `name`            | string             | nombre de operación de baja cardinalidad |
| `kind`            | enum               | ver abajo |
| `start_time_unix_nano` / `end_time_unix_nano` | fixed64 | reloj de pared, nanosegundos desde la época Unix |
| `attributes`      | repeated KeyValue  | dimensiones con alcance de span |
| `events`          | repeated Event     | puntos con timestamp dentro del span |
| `links`           | repeated Link      | referencias a *otros* spans/traces |
| `status`          | Status             | `Unset` / `Ok` / `Error` + message |
| `dropped_*_count` | uint32             | cantidad de atributos/eventos/links descartados por límites |
| `flags`           | uint32             | trace flags (incl. el bit sampled) |

**SpanKind** (determina la topología y la semántica RED/latencia que infiere un backend):

| Valor del enum | Numérico | Cuándo usarlo |
|---|---|---|
| `SPAN_KIND_UNSPECIFIED` | 0 | default; tratado como INTERNAL |
| `SPAN_KIND_INTERNAL`    | 1 | operación interna, sin frontera remota |
| `SPAN_KIND_SERVER`      | 2 | handler de RPC/HTTP entrante (lado servidor) |
| `SPAN_KIND_CLIENT`      | 3 | llamada síncrona saliente (lado cliente) |
| `SPAN_KIND_PRODUCER`    | 4 | envío de mensaje asíncrono (productor) |
| `SPAN_KIND_CONSUMER`    | 5 | recepción/procesamiento de mensaje asíncrono |

**Códigos de estado:**

| Status | Numérico | Establecido por |
|---|---|---|
| `STATUS_CODE_UNSET` | 0 | default — la operación se completó sin un veredicto de error explícito |
| `STATUS_CODE_OK`    | 1 | *solo* lo establece explícitamente el código de la aplicación que afirma el éxito |
| `STATUS_CODE_ERROR` | 2 | error; `message` lleva una descripción |

> Trampa de examen: un HTTP `4xx` **no** se convierte automáticamente en `STATUS_CODE_ERROR`. Para un span `SERVER`, un `4xx` se deja en `Unset` (el servidor se comportó correctamente); para un span `CLIENT`, un `4xx`/`5xx` es `Error`. La instrumentación, no el código de transporte, decide.

### 3.2 SpanContext y propagación W3C

El `SpanContext` — el subconjunto *propagable e inmutable* — es `{ trace_id, span_id, trace_flags, trace_state }`. Es lo que cruza una frontera de proceso. El propagador text-map por defecto es **W3C Trace Context**, transportado en dos headers HTTP:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  └───────────── trace_id ────────┘ └── parent_id ─┘ └ flags
             └ version (00)
tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

`trace_flags` es un campo de 8 bits; **el bit 0 es la flag `sampled`** (`01` = sampled). Los bits restantes están reservados.

### 3.3 Un payload de trace OTLP/JSON completo

Este es un `ExportTraceServiceRequest` completo y sintácticamente válido, tal como lo acepta un endpoint OTLP/HTTP en `POST /v1/traces`. Notá el anidamiento `resourceSpans → scopeSpans → spans` y los campos de bytes codificados como cadenas hexadecimales en JSON:

```json
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name",        "value": { "stringValue": "checkout" } },
          { "key": "service.namespace",   "value": { "stringValue": "shop" } },
          { "key": "service.version",     "value": { "stringValue": "2.4.1" } },
          { "key": "service.instance.id", "value": { "stringValue": "checkout-7c9f-abc12" } },
          { "key": "deployment.environment", "value": { "stringValue": "production" } },
          { "key": "k8s.pod.name",        "value": { "stringValue": "checkout-7c9f-abc12" } }
        ],
        "droppedAttributesCount": 0
      },
      "schemaUrl": "https://opentelemetry.io/schemas/1.27.0",
      "scopeSpans": [
        {
          "scope": {
            "name": "io.opentelemetry.instrumentation.http",
            "version": "2.9.0"
          },
          "schemaUrl": "https://opentelemetry.io/schemas/1.27.0",
          "spans": [
            {
              "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
              "spanId": "00f067aa0ba902b7",
              "parentSpanId": "",
              "name": "POST /api/checkout",
              "kind": 2,
              "startTimeUnixNano": "1723291200000000000",
              "endTimeUnixNano":   "1723291200145000000",
              "attributes": [
                { "key": "http.request.method", "value": { "stringValue": "POST" } },
                { "key": "url.path",            "value": { "stringValue": "/api/checkout" } },
                { "key": "http.response.status_code", "value": { "intValue": "200" } },
                { "key": "server.address",      "value": { "stringValue": "checkout.shop.svc" } },
                { "key": "network.protocol.version", "value": { "stringValue": "1.1" } }
              ],
              "events": [
                {
                  "timeUnixNano": "1723291200030000000",
                  "name": "cache.miss",
                  "attributes": [
                    { "key": "cache.key", "value": { "stringValue": "cart:abc12" } }
                  ]
                }
              ],
              "links": [
                {
                  "traceId": "8a3c60f7d188f8fa79d48a391a778fa6",
                  "spanId":  "b7ad6b7169203331",
                  "attributes": [
                    { "key": "link.type", "value": { "stringValue": "batch.parent" } }
                  ]
                }
              ],
              "status": { "code": 0 },
              "flags": 1
            }
          ]
        }
      ]
    }
  ]
}
```

---

## 4. Señal 2 — Métricas

Las métricas son donde el modelo es más rico y donde se originan la mayoría de los incidentes de producción, porque la **temporalidad** y la **agregación** son sutiles.

### 4.1 El envoltorio Metric y los cinco tipos de puntos

Un `Metric` tiene `name`, `description`, `unit` (cadena UCUM, p. ej. `ms`, `By`, `1`) y exactamente un oneof `data`:

| Tipo de punto | ¿Monótono? | ¿Lleva temporalidad? | Instrumento típico |
|---|---|---|---|
| `Gauge`               | n/a       | no (instantáneo implícito) | observable gauge (temperatura, profundidad de cola) |
| `Sum`                 | configurable | sí | Counter (monótono), UpDownCounter (no monótono) |
| `Histogram`           | n/a       | sí | Histogram de bucket explícito |
| `ExponentialHistogram`| n/a       | sí | Histogram exponencial base-2 |
| `Summary`             | n/a       | no  | **legacy** — cuantiles de Prometheus; no lo emitas desde SDKs de OTel |

### 4.2 Temporalidad: Delta vs Cumulative

Cada `Sum`, `Histogram` y `ExponentialHistogram` lleva un `aggregation_temporality`:

| Enum | Numérico | Significado |
|---|---|---|
| `AGGREGATION_TEMPORALITY_UNSPECIFIED` | 0 | inválido |
| `AGGREGATION_TEMPORALITY_DELTA`       | 1 | el valor cubre `(start, end]` — se reinicia cada intervalo |
| `AGGREGATION_TEMPORALITY_CUMULATIVE`  | 2 | el valor es el total acumulado desde `start_time_unix_nano` |

Esta es la decisión más relevante para el examen *y* para producción de todo el modelo de métricas:

| Dimensión | Delta | Cumulative |
|---|---|---|
| Significado del punto | cambio durante el intervalo | total desde el inicio |
| Manejo de reinicios | trivialmente correcto (nuevo intervalo, nuevo valor) | requiere detección de reset (el counter retrocede ⇒ reset) |
| Ajuste al backend | estilo StatsD, AWS CloudWatch EMF, muchos SaaS | **Prometheus** (su modelo nativo) |
| Memoria en el SDK | debe retener el estado de la última recolección brevemente | debe retener los totales acumulados durante toda la vida |
| Reagregación entre dimensiones | suma simple | suma simple |
| Alineación temporal | sensible al jitter del intervalo de recolección | robusto ante el jitter (la tasa se calcula al momento de la consulta) |
| Pérdida de un datapoint | pierde permanentemente el delta de ese intervalo | se auto-repara en el próximo scrape (el total es absoluto) |
| Escalado horizontal / pods efímeros | **preferido** — sin series de larga vida a través de la rotación de pods | tormentas de reset cuando los pods rotan |

**Regla general para plataformas:** si el backend final es Prometheus, mantené **Cumulative** de extremo a extremo. Si el backend es delta-nativo (o corrés cargas de trabajo serverless altamente efímeras), emití **Delta**, o convertí con el procesador `cumulativetodelta` / `deltatocumulative` del Collector. Nunca dejes que ambos se mezclen silenciosamente para la misma serie — ese es el clásico incidente de "la tasa se dispara al infinito después de un deploy".

### 4.3 Histogram vs ExponentialHistogram

| Propiedad | `Histogram` explícito | `ExponentialHistogram` |
|---|---|---|
| Fronteras de bucket | fijas, elegidas a mano `explicit_bounds` | derivadas de `scale`, cubriendo el rango automáticamente |
| Carga de configuración | alta — fronteras erróneas ⇒ percentiles inútiles | baja — resolución auto-ajustable |
| Tamaño en transmisión | proporcional a la cantidad de buckets que definiste | compacto; las fronteras son implícitas |
| Error relativo | no uniforme (grueso donde adivinaste mal) | acotado y uniforme en el espacio logarítmico |
| Combinabilidad entre servicios | solo si las fronteras coinciden exactamente | siempre combinable (reescalado a la escala mínima) |
| Mejor para | rangos de latencia conocidos y estables | rango dinámico desconocido/amplio (caza del P99 en la cola) |

El histograma exponencial codifica los buckets como `base = 2^(2^-scale)`. El índice de bucket `i` cubre `(base^i, base^(i+1)]`. Un `zero_count` y un `zero_threshold` manejan los valores en/cerca de cero; los `Buckets` `positive` y `negative` llevan cada uno un `offset` y un array `bucket_counts`. Una `scale` más alta ⇒ resolución más fina ⇒ más buckets.

### 4.4 Exemplars — el puente métricas→traces

Un **Exemplar** es una medición cruda adjunta a un punto agregado que lleva `trace_id`, `span_id`, `time_unix_nano`, el valor y `filtered_attributes`. Este es *el* mecanismo que te permite hacer clic en un pico de un histograma de latencia y saltar a un exemplar trace de un request que cayó en ese bucket. Es la mitad del lado de las métricas de la correlación entre señales.

### 4.5 Un payload de métricas OTLP/JSON completo

```json
{
  "resourceMetrics": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "checkout" } }
        ]
      },
      "scopeMetrics": [
        {
          "scope": { "name": "io.opentelemetry.instrumentation.http", "version": "2.9.0" },
          "metrics": [
            {
              "name": "http.server.request.duration",
              "description": "Duration of inbound HTTP requests",
              "unit": "s",
              "histogram": {
                "aggregationTemporality": 2,
                "dataPoints": [
                  {
                    "startTimeUnixNano": "1723291140000000000",
                    "timeUnixNano":      "1723291200000000000",
                    "count": "1050",
                    "sum": 84.2,
                    "min": 0.002,
                    "max": 1.911,
                    "bucketCounts": ["500","300","180","60","10"],
                    "explicitBounds": [0.005, 0.01, 0.025, 0.1],
                    "attributes": [
                      { "key": "http.request.method", "value": { "stringValue": "POST" } },
                      { "key": "http.route", "value": { "stringValue": "/api/checkout" } },
                      { "key": "http.response.status_code", "value": { "intValue": "200" } }
                    ],
                    "exemplars": [
                      {
                        "timeUnixNano": "1723291195000000000",
                        "asDouble": 1.911,
                        "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
                        "spanId":  "00f067aa0ba902b7",
                        "filteredAttributes": [
                          { "key": "customer.tier", "value": { "stringValue": "premium" } }
                        ]
                      }
                    ]
                  }
                ]
              }
            },
            {
              "name": "http.server.active_requests",
              "unit": "{request}",
              "sum": {
                "aggregationTemporality": 2,
                "isMonotonic": false,
                "dataPoints": [
                  {
                    "startTimeUnixNano": "1723291140000000000",
                    "timeUnixNano":      "1723291200000000000",
                    "asInt": "7",
                    "attributes": [
                      { "key": "http.request.method", "value": { "stringValue": "POST" } }
                    ]
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  ]
}
```

> Notá que `explicit_bounds` tiene *N* entradas y `bucket_counts` tiene *N+1* (el último bucket es `(+Inf]`). Un desfase de ±1 acá es el bug de histograma malformado más común.

---

## 5. Señal 3 — Logs

OpenTelemetry no inventó un nuevo formato de log desde cero; definió un **modelo de datos LogRecord** al cual se mapean los formatos de log existentes (syslog, JSON, log4j). Por eso los logs fueron la última señal en estabilizarse.

### 5.1 El LogRecord

| Campo | Tipo | Significado |
|---|---|---|
| `time_unix_nano`          | fixed64 | cuándo *ocurrió* el evento (puede ser 0/desconocido) |
| `observed_time_unix_nano` | fixed64 | cuándo lo *observó* el collector/SDK (siempre establecido) |
| `severity_number`         | enum (1–24) | severidad normalizada |
| `severity_text`           | string  | cadena de nivel original (`"WARN"`, `"error"`) |
| `body`                    | `AnyValue` | el mensaje — string *o* mapa estructurado |
| `attributes`              | KeyValue | campos estructurados (`http.request.method`, `db.statement`) |
| `trace_id` / `span_id`    | bytes   | **correlación con el span emisor** |
| `flags`                   | uint32  | flags del registro de log (incl. trace flags) |
| `dropped_attributes_count`| uint32  | atributos descartados por límite |

**SeverityNumber** se normaliza en seis bandas de cuatro pasos cada una — la clave para comparar niveles entre fuentes heterogéneas:

| Banda | Rango | Textos de ejemplo |
|---|---|---|
| TRACE | 1–4   | `TRACE`, `TRACE2` |
| DEBUG | 5–8   | `DEBUG`, `FINE` |
| INFO  | 9–12  | `INFO`, `NOTICE` |
| WARN  | 13–16 | `WARN`, `WARNING` |
| ERROR | 17–20 | `ERROR`, `SEVERE` |
| FATAL | 21–24 | `FATAL`, `CRITICAL`, `EMERGENCY` |

Como un log que lleva el mismo `trace_id`/`span_id` que un span es *por construcción* el mismo request, "mostrame todos los logs de este trace fallido" se convierte en una búsqueda exacta de índice en lugar de una adivinanza por ventana de timestamps. Esta es la recompensa de correlación por la que existe todo el modelo.

### 5.2 Un payload de logs OTLP/JSON completo

```json
{
  "resourceLogs": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "checkout" } }
        ]
      },
      "scopeLogs": [
        {
          "scope": { "name": "checkout.payments", "version": "2.4.1" },
          "logRecords": [
            {
              "timeUnixNano":         "1723291200140000000",
              "observedTimeUnixNano": "1723291200140500000",
              "severityNumber": 17,
              "severityText": "ERROR",
              "body": { "stringValue": "payment authorization declined by gateway" },
              "attributes": [
                { "key": "payment.gateway",  "value": { "stringValue": "stripe" } },
                { "key": "payment.decline_code", "value": { "stringValue": "insufficient_funds" } },
                { "key": "http.response.status_code", "value": { "intValue": "402" } }
              ],
              "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
              "spanId":  "00f067aa0ba902b7",
              "flags": 1
            }
          ]
        }
      ]
    }
  ]
}
```

---

## 6. Transporte OTLP: la codificación del modelo

| Variante | Puerto por defecto | Ruta(s) | Codificación | Notas |
|---|---|---|---|---|
| **OTLP/gRPC**       | `4317` | métodos de servicio gRPC | Protobuf (binario) | amigable con streaming, HTTP/2, mejor throughput |
| **OTLP/HTTP** (protobuf) | `4318` | `/v1/traces`, `/v1/metrics`, `/v1/logs` | Protobuf en el body, `Content-Type: application/x-protobuf` | amigable con firewalls/proxies |
| **OTLP/HTTP** (JSON) | `4318` | mismas rutas | JSON, `Content-Type: application/json` | depurable por humanos; campos de bytes codificados en hex |

Compromiso: gRPC da la mejor densidad y streaming nativo pero necesita HTTP/2 de extremo a extremo (muchos proxies corporativos aún lo rompen); OTLP/HTTP-JSON es el menos eficiente pero la única variante que podés armar a mano con `curl` para depurar. Los tres transportan el **modelo lógico idéntico** — elegir uno nunca cambia los datos, solo los bytes en la transmisión.

---

## 7. Infraestructura: manifiestos de pipeline de extremo a extremo

### 7.1 Configuración del Collector que ejercita cada señal

```yaml
# otelcol-config.yaml — validates all three signals of the data model
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # Guarantee service.name exists — the model's most critical Resource attribute
  resource:
    attributes:
      - key: service.name
        value: checkout
        action: insert            # insert = only if absent
      - key: deployment.environment
        value: production
        action: upsert
  # Enrich with K8s Resource attributes (semantic conventions k8s.*)
  k8sattributes:
    extract:
      metadata:
        - k8s.pod.name
        - k8s.namespace.name
        - k8s.node.name
  # Normalize temporality so a Prometheus backend never sees deltas
  cumulativetodelta: {}
  batch:
    timeout: 5s
    send_batch_size: 1024

exporters:
  debug:
    verbosity: detailed           # prints the decoded data model to stdout
  otlphttp/backend:
    endpoint: https://otel-gateway.observability.svc:4318
    tls:
      insecure: false

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [k8sattributes, resource, batch]
      exporters:  [debug, otlphttp/backend]
    metrics:
      receivers:  [otlp]
      processors: [k8sattributes, resource, batch]
      exporters:  [debug, otlphttp/backend]
    logs:
      receivers:  [otlp]
      processors: [k8sattributes, resource, batch]
      exporters:  [debug, otlphttp/backend]
  telemetry:
    logs:
      level: info
    metrics:
      level: detailed
      address: 0.0.0.0:8888
```

### 7.2 Kubernetes: OpenTelemetry Collector como CR de sidecar/deployment

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: gateway
  namespace: observability
spec:
  mode: deployment
  replicas: 2
  image: otel/opentelemetry-collector-contrib:0.109.0
  ports:
    - name: otlp-grpc
      port: 4317
    - name: otlp-http
      port: 4318
  config:
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    processors:
      batch: {}
    exporters:
      debug: { verbosity: detailed }
    service:
      pipelines:
        traces:  { receivers: [otlp], processors: [batch], exporters: [debug] }
        metrics: { receivers: [otlp], processors: [batch], exporters: [debug] }
        logs:    { receivers: [otlp], processors: [batch], exporters: [debug] }
```

### 7.3 Configuración de Resource del lado del SDK vía entorno

```yaml
# workload.env — how a service declares its Resource identity to the SDK
OTEL_SERVICE_NAME: checkout
OTEL_RESOURCE_ATTRIBUTES: "service.namespace=shop,service.version=2.4.1,deployment.environment=production"
OTEL_EXPORTER_OTLP_ENDPOINT: "http://gateway-collector.observability.svc:4318"
OTEL_EXPORTER_OTLP_PROTOCOL: "http/protobuf"
OTEL_METRICS_EXEMPLAR_FILTER: "trace_based"     # attach exemplars only for sampled spans
OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: "cumulative"
```

---

## 8. CLI: generar, enviar y decodificar el modelo

### 8.1 Validar una configuración del collector antes de desplegarla

```console
$ otelcol-contrib validate --config otelcol-config.yaml
$ echo "exit=$?"
exit=0
```

Un error estructural aparece de inmediato y con código distinto de cero:

```console
$ otelcol-contrib validate --config broken.yaml
Error: invalid configuration: service::pipelines::traces: references processor "resouce" which is not configured
$ echo "exit=$?"
exit=1
```

### 8.2 Generar datos OTLP reales con `telemetrygen`

```console
$ telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 \
    --traces 3 --child-spans 2 --service checkout
2026-08-10T14:03:11.204Z  info  traces/worker.go:99   traces generated  {"worker": 0, "traces": 3}
2026-08-10T14:03:11.205Z  info  traces/traces.go:78   stopping the exporter
```

```console
$ telemetrygen metrics --otlp-insecure --otlp-endpoint localhost:4317 \
    --metrics 5 --metric-type Histogram --service checkout
2026-08-10T14:03:40.881Z  info  metrics/worker.go:82  metrics generated  {"worker": 0, "metrics": 5}
```

### 8.3 Armar a mano un trace OTLP/HTTP-JSON con `curl`

```console
$ curl -sS -X POST http://localhost:4318/v1/traces \
    -H 'Content-Type: application/json' \
    --data-binary @trace.json -w '\nHTTP %{http_code}\n'

{"partialSuccess":{}}
HTTP 200
```

Un `200` con un `partialSuccess` vacío significa que se aceptaron todos los ítems. Un rechazo parcial reporta la cantidad y la razón en línea:

```console
$ curl -sS -X POST http://localhost:4318/v1/traces \
    -H 'Content-Type: application/json' --data-binary @bad-trace.json

{"partialSuccess":{"rejectedSpans":"1","errorMessage":"span has an invalid trace_id (all zeroes)"}}
```

### 8.4 Leer el modelo de datos decodificado desde el debug exporter

Con el `debug` exporter en `verbosity: detailed`, el collector imprime el modelo lógico reconstruido — Resource, Scope y cada ítem — para que puedas confirmar qué llegó realmente en la transmisión:

```console
$ kubectl -n observability logs deploy/gateway-collector | sed -n '/ResourceSpans/,/^$/p'
2026-08-10T14:03:11.310Z  info  Traces  {"resource spans": 1, "spans": 3}
ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
     -> service.namespace: Str(shop)
     -> telemetry.sdk.language: Str(go)
ScopeSpans #0
ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.27.0
InstrumentationScope telemetrygen 
Span #0
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Parent ID      : 
    ID             : 00f067aa0ba902b7
    Name           : POST /api/checkout
    Kind           : Server
    Start time     : 2026-08-10 14:03:11.2 +0000 UTC
    End time       : 2026-08-10 14:03:11.345 +0000 UTC
    Status code    : Unset
    Attributes:
         -> http.request.method: Str(POST)
         -> http.response.status_code: Int(200)
```

---

## 9. Verificación y diagnóstico de fallas

Los modos de falla de abajo están ordenados por qué tan seguido ocurren en producción y qué tan invisibles son para chequeos ingenuos (un `200` del endpoint prueba el *transporte*, no la *corrección del modelo*).

| Síntoma | Causa raíz en el modelo de datos | Diagnóstico | Solución |
|---|---|---|---|
| Todo cae bajo `unknown_service` | al `Resource` le falta `service.name` | el `debug` exporter no muestra el atributo `service.name` | establecer `OTEL_SERVICE_NAME` o el procesador `resource` con `insert` |
| Los logs no correlacionan con los traces | `LogRecord.trace_id`/`span_id` vacíos | inspeccionar los campos de bytes de un registro de log — todo cero | asegurar que el appender de logs corra dentro de un contexto de span activo; habilitar la inyección de trace-context en los logs |
| La consulta de tasa se dispara a ∞ después de cada deploy | desajuste de temporalidad: serie delta tratada como cumulative (o un counter cumulative reseteado al reiniciar el pod) | chequear `aggregationTemporality` (1 vs 2) en la métrica | fijar una única temporalidad de extremo a extremo; usar `deltatocumulative`/`cumulativetodelta`; habilitar detección de reset |
| Los percentiles no tienen sentido | las fronteras del `Histogram` explícito no cubren el rango real de latencia, o la longitud de `bucket_counts` ≠ `explicit_bounds`+1 | imprimir el punto; comparar longitudes | corregir las fronteras, o cambiar a `ExponentialHistogram` |
| El índice/costo del backend explota | valor de alta cardinalidad puesto en un **atributo** (UUID de request, URL cruda con query) | listar los valores distintos de atributo por clave | mover el valor a un atributo de span o descartarlo vía el procesador `attributes`/`transform` |
| El gRPC exporter falla detrás de un proxy, HTTP funciona | OTLP/gRPC necesita HTTP/2 de extremo a extremo | probar tanto `4317` como `4318` | cambiar `OTEL_EXPORTER_OTLP_PROTOCOL` a `http/protobuf` |
| `partialSuccess.rejectedSpans > 0` | `trace_id`/`span_id` inválido (todo-cero), longitud de bytes incorrecta, o timestamps negativos | leer el `errorMessage` en la respuesta | corregir la instrumentación emisora; nunca fabricar IDs |
| Atributos ausentes silenciosamente | se alcanzaron los límites de atributos/eventos del SDK | chequear `dropped_attributes_count` / `dropped_events_count` > 0 | subir `OTEL_ATTRIBUTE_COUNT_LIMIT` o reducir los atributos emitidos |
| Las métricas llegan pero nunca se actualizan en Prometheus | Summary/Gauge donde se esperaba un Sum, o `start_time_unix_nano` = 0 | inspeccionar el oneof `data` del punto y el start time | emitir el instrumento correcto; establecer siempre un start time válido |

### Ejercicio de diagnóstico — confirmar que la correlación entre señales es real

```console
# 1. Send a trace and capture its trace_id
$ telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 1 --service checkout
# 2. Confirm the same trace_id appears on the metric exemplar
$ kubectl -n observability logs deploy/gateway-collector | grep -A1 "Exemplar"
Exemplar #0
     -> Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736
# 3. Confirm a log record carries the identical trace_id
$ kubectl -n observability logs deploy/gateway-collector | grep -A2 "LogRecord" | grep "Trace ID"
     -> Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736
```

Tres señales, un mismo `trace_id` — esa identidad es el propósito entero del modelo de datos, y este ejercicio es cómo lo *demostrás* de extremo a extremo en lugar de asumirlo.

### Inspeccionar las propias métricas de salud del Collector

```console
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver_accepted|exporter_sent|processor_dropped)'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 3
otelcol_exporter_sent_spans{exporter="otlphttp/backend"} 3
otelcol_processor_dropped_metric_points{processor="batch"} 0
```

`accepted` debería ser igual a `sent` menos cualquier cosa descartada intencionalmente; una brecha persistente es pérdida de datos dentro del pipeline.

---

## 10. Referencias

- OpenTelemetry — Data Model (Traces): https://opentelemetry.io/docs/specs/otel/trace/api/
- OpenTelemetry — Trace Data Model / SDK: https://opentelemetry.io/docs/specs/otel/trace/sdk/
- OpenTelemetry — Metrics Data Model: https://opentelemetry.io/docs/specs/otel/metrics/data-model/
- OpenTelemetry — Logs Data Model: https://opentelemetry.io/docs/specs/otel/logs/data-model/
- OpenTelemetry — Common (AnyValue, KeyValue, InstrumentationScope): https://opentelemetry.io/docs/specs/otel/common/
- OpenTelemetry — Resource Data Model: https://opentelemetry.io/docs/specs/otel/resource/sdk/
- OpenTelemetry Protocol (OTLP) Specification: https://opentelemetry.io/docs/specs/otlp/
- OTLP Protobuf definitions (proto files): https://github.com/open-telemetry/opentelemetry-proto
- OpenTelemetry Semantic Conventions: https://opentelemetry.io/docs/specs/semconv/
- W3C Trace Context Recommendation: https://www.w3.org/TR/trace-context/
- OpenTelemetry Collector — Configuration: https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry Operator (OpenTelemetryCollector CR): https://github.com/open-telemetry/opentelemetry-operator
- `telemetrygen` load generator: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
- OTCA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf