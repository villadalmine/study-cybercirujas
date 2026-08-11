# Topic 2.1 — Data Model — Ejercicios Guiados

> **Objetivo de este topic.** OpenTelemetry define la telemetría en términos de un *modelo de datos independiente del lenguaje*, no en términos de ningún SDK o backend en particular. Cada señal — traces, metrics, logs — tiene una estructura precisa que sobrevive a la serialización, y todo está anclado a un **Resource** y producido por un **Instrumentation Scope**. En estos ejercicios no vas a *leer sobre* el modelo — lo vas a materializar, volcar los campos exactos que define la especificación, y correlacionarlos entre señales. Al terminar deberías poder señalar cualquier campo de un payload OTLP y decir qué es, por qué existe y qué invariantes debe mantener.
>
> **Fuentes de referencia (oficiales):**
> - Traces API / SpanContext — https://opentelemetry.io/docs/specs/otel/trace/api/
> - Metrics data model — https://opentelemetry.io/docs/specs/otel/metrics/data-model/
> - Logs data model — https://opentelemetry.io/docs/specs/otel/logs/data-model/
> - Common (attributes) — https://opentelemetry.io/docs/specs/otel/common/
> - Resource SDK — https://opentelemetry.io/docs/specs/otel/resource/sdk/
> - OTLP & proto — https://opentelemetry.io/docs/specs/otlp/ y https://github.com/open-telemetry/opentelemetry-proto

---

## Prerrequisitos — armá el sandbox

Vas a usar el SDK de OpenTelemetry para Python porque sus console exporters imprimen el modelo de datos textualmente. Más adelante vas a usar el Collector para ver la codificación OTLP en el cable. No se requiere ningún backend (Jaeger, Prometheus…).

**Pasos**

1. Creá un entorno aislado e instalá el SDK más el OTLP exporter:

   ```bash
   mkdir otca-datamodel && cd otca-datamodel
   python3.12 -m venv .venv
   source .venv/bin/activate
   pip install \
     'opentelemetry-sdk==1.27.0' \
     'opentelemetry-exporter-otlp-proto-grpc==1.27.0'
   ```

2. Confirmá que los paquetes API y SDK se resolvieron a la misma versión:

   ```bash
   pip list | grep opentelemetry
   ```

   Esperado (versiones alineadas):

   ```
   opentelemetry-api                        1.27.0
   opentelemetry-exporter-otlp-proto-grpc   1.27.0
   opentelemetry-sdk                        1.27.0
   opentelemetry-semantic-conventions       0.48b0
   ```

**Comprobá tu comprensión**

- **Q1.1** Los paquetes `opentelemetry-api` y `opentelemetry-sdk` son separados. ¿Cuál *define* los tipos del modelo de datos que vas a inspeccionar, y cuál *implementa* cómo se producen y exportan?
- **Q1.2** Nada acá instala Jaeger ni Prometheus. ¿Por qué es observable el modelo de datos *sin* ningún observability backend en absoluto?

---

## Ejercicio 1 — Anatomía de un Span

**Pasos**

1. Creá `span.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.trace import SpanKind

   resource = Resource.create({
       "service.name": "checkout-svc",
       "service.version": "2.4.1",
   })

   provider = TracerProvider(resource=resource)
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)

   # get_tracer(name, version) -> this pair IS the Instrumentation Scope
   tracer = trace.get_tracer("checkout.instrumentation", "0.1.0")

   with tracer.start_as_current_span("checkout", kind=SpanKind.SERVER) as parent:
       parent.set_attribute("cart.item_count", 3)
       parent.set_attribute("cart.currency", "EUR")
       with tracer.start_as_current_span("charge-card", kind=SpanKind.CLIENT) as child:
           child.set_attribute("payment.provider", "stripe")
   ```

2. Ejecutalo e imprimí prolijamente el primer span (el hijo):

   ```bash
   python span.py
   ```

   Salida esperada (dos documentos JSON; el hijo `charge-card` se emite primero porque termina primero, abreviado):

   ```json
   {
       "name": "charge-card",
       "context": {
           "trace_id": "0x8f3a1c9d2b7e4f60a1b2c3d4e5f60718",
           "span_id": "0x1a2b3c4d5e6f7081",
           "trace_state": "[]"
       },
       "kind": "SpanKind.CLIENT",
       "parent_id": "0x9f8e7d6c5b4a3021",
       "start_time": "2026-08-10T14:03:11.482113Z",
       "end_time":   "2026-08-10T14:03:11.482461Z",
       "status": { "status_code": "UNSET" },
       "attributes": { "payment.provider": "stripe" },
       "events": [],
       "links": [],
       "resource": {
           "attributes": {
               "service.name": "checkout-svc",
               "service.version": "2.4.1",
               "telemetry.sdk.language": "python",
               "telemetry.sdk.name": "opentelemetry",
               "telemetry.sdk.version": "1.27.0"
           },
           "schema_url": ""
       }
   }
   ```

3. Fijate en tres identificadores: `trace_id`, `span_id`, y el `parent_id` del hijo. Contá los dígitos hexadecimales en cada uno (ignorá el `0x`).

**Comprobá tu comprensión**

- **Q2.1** Contá los caracteres hexadecimales. ¿Cuántos *bytes* tiene un `trace_id`, y cuántos un `span_id`? ¿Qué campos del span hijo, tomados en conjunto, forman su **SpanContext**?
- **Q2.2** El `parent_id` del hijo es igual al `span_id` del padre, y ambos spans comparten el mismo `trace_id`. ¿Cuál de estos dos identificadores define el *trace*, y cuál es único *por span*?
- **Q2.3** `status_code` es `UNSET` aunque nada falló. ¿Cuáles son los tres valores posibles de `StatusCode`, y por qué `UNSET` — no `OK` — es el default correcto para un span que se completó normalmente?
- **Q2.4** `SpanKind` es `CLIENT` en el hijo y `SERVER` en el padre. Nombrá los cinco span kinds e indicá cuál es el default cuando omitís `kind=`.
- **Q2.5** Nunca escribiste `telemetry.sdk.*` en el resource, y sin embargo aparecen. ¿De dónde vinieron, y el Resource pertenece al *span* o al *proceso que lo produce*?

---

## Ejercicio 2 — Resource e Instrumentation Scope

**Pasos**

1. El Resource está pensado para describir *la entidad que produce telemetría* y normalmente se deja a la auto-detección más el entorno. Volvé a ejecutar `span.py` con un atributo de resource provisto out-of-band:

   ```bash
   OTEL_RESOURCE_ATTRIBUTES="deployment.environment=prod,service.instance.id=pod-7c9" \
     python span.py
   ```

   El bloque `resource.attributes` ahora contiene además:

   ```json
   "deployment.environment": "prod",
   "service.instance.id": "pod-7c9"
   ```

2. Ahora borrá el `service.name` de la llamada `Resource.create({...})` y quitá cualquier override de entorno, luego ejecutá de nuevo. Observá el resource:

   ```json
   "service.name": "unknown_service"
   ```

**Comprobá tu comprensión**

- **Q3.1** Ambos spans en el Ejercicio 1 llevaban un bloque `resource` *idéntico*. En la codificación OTLP el Resource **no** se repite por span. ¿A dónde se factoriza (cómo se llama el mensaje contenedor), y por qué es esto a la vez una optimización de tamaño y una afirmación semántica?
- **Q3.2** `service.name` cayó a `unknown_service` en lugar de dar error. ¿Qué te dice eso sobre si `service.name` es *requerido* por el modelo de datos, y cuál es el costo práctico de enviar telemetría con el valor por defecto?
- **Q3.3** El tracer se obtuvo con `get_tracer("checkout.instrumentation", "0.1.0")`. Ese par `(name, version)` es el **Instrumentation Scope**. ¿En qué difiere el Scope en su *propósito* respecto del Resource — es decir, qué pregunta responde cada uno sobre un span dado?

---

## Ejercicio 3 — Events, Links y Status

**Pasos**

1. Creá `span_rich.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor
   from opentelemetry.trace import Status, StatusCode, Link

   provider = TracerProvider()
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("lab")

   # A span whose context we will LINK to from another trace
   with tracer.start_as_current_span("enqueue") as producer:
       enqueue_ctx = producer.get_span_context()

   with tracer.start_as_current_span(
       "process-message",
       links=[Link(enqueue_ctx, attributes={"messaging.operation": "process"})],
   ) as span:
       span.add_event("dequeued", {"queue.depth": 12})
       try:
           raise ValueError("malformed payload")
       except ValueError as exc:
           span.record_exception(exc)
           span.set_status(Status(StatusCode.ERROR, "malformed payload"))
   ```

2. Ejecutalo e inspeccioná el span `process-message`:

   ```bash
   python span_rich.py
   ```

   Campos relevantes (abreviado):

   ```json
   "status": { "status_code": "ERROR", "description": "malformed payload" },
   "events": [
       { "name": "dequeued", "timestamp": "...", "attributes": { "queue.depth": 12 } },
       { "name": "exception", "timestamp": "...",
         "attributes": {
             "exception.type": "ValueError",
             "exception.message": "malformed payload",
             "exception.stacktrace": "Traceback (most recent call last): ..."
         }
       }
   ],
   "links": [
       { "context": { "trace_id": "0x...", "span_id": "0x..." },
         "attributes": { "messaging.operation": "process" } }
   ]
   ```

**Comprobá tu comprensión**

- **Q4.1** Un **Event** y un **Span** hijo son ambos "algo que pasó dentro de este span". ¿Cuál es la diferencia estructural, y cuál usarías para una ocurrencia instantánea en un punto del tiempo versus una unidad de trabajo anidada que tiene su propia duración?
- **Q4.2** `record_exception()` *no* puso el status en `ERROR` por sí mismo — llamaste a `set_status(...)` por separado. ¿Qué te dice eso sobre la relación entre registrar un exception event y marcar el span como fallido?
- **Q4.3** El span `enqueue` vivió en un trace *diferente*, y sin embargo `process-message` lo referencia vía un **Link**. En el patrón clásico producer/consumer (cola), ¿por qué un Link — en lugar de una relación parent/child normal — es el constructo correcto del modelo de datos?
- **Q4.4** Cada Event lleva su propio `timestamp`, y cae *entre* el `start_time` y el `end_time` del span. ¿Por qué debe el timestamp de un Event ser independiente del inicio del span, en lugar de un offset que el lector computa?

---

## Ejercicio 4 — El modelo de datos de Metrics: Sum, Gauge, Histogram

**Pasos**

1. Creá `metrics.py`:

   ```python
   from opentelemetry import metrics
   from opentelemetry.sdk.metrics import MeterProvider
   from opentelemetry.sdk.metrics.export import (
       ConsoleMetricExporter, PeriodicExportingMetricReader,
   )

   reader = PeriodicExportingMetricReader(
       ConsoleMetricExporter(), export_interval_millis=2000,
   )
   metrics.set_meter_provider(MeterProvider(metric_readers=[reader]))
   meter = metrics.get_meter("lab")

   requests = meter.create_counter(
       "http.server.request.count", unit="{request}",
       description="Total inbound requests",
   )
   in_flight = meter.create_up_down_counter(
       "http.server.active_requests", unit="{request}",
   )
   duration = meter.create_histogram(
       "http.server.request.duration", unit="ms",
   )

   for ms in (23.0, 57.0, 512.0):
       requests.add(1, {"http.route": "/checkout", "http.response.status_code": 200})
       in_flight.add(1);  duration.record(ms, {"http.route": "/checkout"});  in_flight.add(-1)

   import time; time.sleep(3)   # let the periodic reader flush once
   ```

2. Ejecutalo y leé las tres formas de métrica:

   ```bash
   python metrics.py
   ```

   Salida abreviada (un bloque `ScopeMetrics` que contiene tres metrics):

   ```
   Metric(name='http.server.request.count', unit='{request}', data=Sum(
       aggregation_temporality=AggregationTemporality.CUMULATIVE,
       is_monotonic=True,
       data_points=[NumberDataPoint(attributes={'http.route':'/checkout',
           'http.response.status_code':200}, start_time_unix_nano=..., time_unix_nano=...,
           value=3)]))

   Metric(name='http.server.active_requests', data=Sum(
       aggregation_temporality=AggregationTemporality.CUMULATIVE,
       is_monotonic=False,
       data_points=[NumberDataPoint(..., value=0)]))

   Metric(name='http.server.request.duration', unit='ms', data=Histogram(
       aggregation_temporality=AggregationTemporality.CUMULATIVE,
       data_points=[HistogramDataPoint(count=3, sum=592.0, min=23.0, max=512.0,
           bucket_counts=[0,0,1,1,0,0,0,0,0,0,1,0,0,0,0,0],
           explicit_bounds=[0,5,10,25,50,75,100,250,500,750,1000,2500,5000,7500,10000])]))
   ```

**Comprobá tu comprensión**

- **Q5.1** Un `Counter` produjo un `Sum` con `is_monotonic=True`; un `UpDownCounter` produjo un `Sum` con `is_monotonic=False`. ¿Qué le promete `is_monotonic` a un backend que puede asumir, y por qué a "active requests" *no* se le permite hacer esa promesa?
- **Q5.2** El valor del counter es `3` y el del up/down counter es `0`. Llamaste a `.add()` en ambos. En el modelo de datos, ¿cuál es la diferencia esencial entre el *instrument* (Counter) y el *metric point* (Sum) — es decir, con cuál interactuás en el código, y cuál aparece en el cable?
- **Q5.3** El data point del Histogram lleva `count`, `sum`, `min`, `max`, `bucket_counts` y `explicit_bounds`. Dada una request de 57 ms y los bounds `[…50,75…]`, ¿en qué bucket cae, y por qué un Histogram almacena *bucket counts* en lugar de las mediciones individuales 23/57/512?
- **Q5.4** Un `Gauge` es el cuarto tipo de point que no emitiste acá (viene de un gauge *asíncrono/observable*). A diferencia de un `Sum`, un `Gauge` **no** tiene campo `aggregation_temporality`. ¿Por qué la temporality no tiene sentido para un gauge?

---

## Ejercicio 5 — Aggregation temporality: cumulative vs delta

**Pasos**

1. Copiá `metrics.py` a `metrics_delta.py` y cambiá solo la construcción del exporter para preferir temporality **delta** para sums e histograms:

   ```python
   from opentelemetry.sdk.metrics.export import AggregationTemporality
   from opentelemetry.sdk.metrics import Counter, UpDownCounter, Histogram

   delta = {
       Counter: AggregationTemporality.DELTA,
       UpDownCounter: AggregationTemporality.CUMULATIVE,   # up/down stays cumulative
       Histogram: AggregationTemporality.DELTA,
   }
   reader = PeriodicExportingMetricReader(
       ConsoleMetricExporter(preferred_temporality=delta),
       export_interval_millis=2000,
   )
   ```

2. Envolvé el bucle de registro para que corra a lo largo de **dos** intervalos de exportación:

   ```python
   for cycle in range(2):
       for ms in (23.0, 57.0, 512.0):
           requests.add(1, {"http.route": "/checkout"})
           duration.record(ms, {"http.route": "/checkout"})
       time.sleep(2.5)   # force a flush between cycles
   ```

3. Ejecutalo y compará el `value` del counter en el *primer* batch exportado versus el *segundo*:

   ```bash
   python metrics_delta.py
   ```

   Bajo **delta**, cada batch reporta solo lo que pasó *en ese intervalo*:

   ```
   # first flush
   Sum(aggregation_temporality=DELTA, is_monotonic=True,
       data_points=[NumberDataPoint(start_time_unix_nano=T0, time_unix_nano=T1, value=3)])
   # second flush
   Sum(aggregation_temporality=DELTA, is_monotonic=True,
       data_points=[NumberDataPoint(start_time_unix_nano=T1, time_unix_nano=T2, value=3)])
   ```

   Volvé a ejecutar el `metrics.py` original (cumulative) con el mismo bucle de dos ciclos y en cambio verás `value=3` y luego `value=6`.

**Comprobá tu comprensión**

- **Q6.1** Delta reportó `3` y luego `3`; cumulative reportó `3` y luego `6`. Enunciá la definición de cada temporality en una oración cada una, en términos de *respecto a qué se mide el valor reportado*.
- **Q6.2** Notá que bajo delta el `start_time_unix_nano` del segundo point (`T1`) es igual al `time_unix_nano` del primero. ¿Por qué los delta points forman una ventana temporal *adyacente y sin superposición*, y cómo se vería el doble conteo si dos exporters re-emitieran ambos la misma ventana?
- **Q6.3** Prometheus scrapea cumulative counters; muchos sistemas basados en push prefieren delta. Dado que el SDK puede convertir cumulative → delta pero convertir delta → cumulative requiere memoria *con estado* de cada serie, ¿cuál temporality es el default más seguro para emitir desde el SDK, y por qué?

---

## Ejercicio 6 — El modelo de datos de Logs y correlación con traces

**Pasos**

1. Creá `logs.py` (el Logs SDK vive bajo `_logs` porque la API todavía se está estabilizando — eso es esperable):

   ```python
   import logging
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
   from opentelemetry.sdk._logs.export import ConsoleLogExporter, SimpleLogRecordProcessor

   trace.set_tracer_provider(TracerProvider())
   tracer = trace.get_tracer("lab")

   lp = LoggerProvider()
   lp.add_log_record_processor(SimpleLogRecordProcessor(ConsoleLogExporter()))
   logging.getLogger().addHandler(LoggingHandler(logger_provider=lp))
   logging.getLogger().setLevel(logging.INFO)
   log = logging.getLogger("orders")

   log.info("startup complete")                       # emitted OUTSIDE any span
   with tracer.start_as_current_span("place-order"):
       log.warning("inventory low for sku=%s", "A-19")  # emitted INSIDE a span
   ```

2. Ejecutá y compará los dos `LogRecord`s emitidos:

   ```bash
   python logs.py
   ```

   Abreviado (el segundo record está correlacionado con el span activo):

   ```json
   {
     "body": "startup complete",
     "severity_text": "INFO", "severity_number": 9,
     "trace_id": "0x00000000000000000000000000000000",
     "span_id": "0x0000000000000000",
     "attributes": {},
     "observed_timestamp": "..."
   }
   {
     "body": "inventory low for sku=A-19",
     "severity_text": "WARN", "severity_number": 13,
     "trace_id": "0x8f3a1c9d2b7e4f60a1b2c3d4e5f60718",
     "span_id": "0x1a2b3c4d5e6f7081",
     "attributes": { "code.filepath": "logs.py", "code.lineno": 15 }
   }
   ```

**Comprobá tu comprensión**

- **Q7.1** El `trace_id`/`span_id` del primer record son todos ceros; el segundo lleva los IDs del span que lo encierra. ¿Qué hace en el modelo de datos que un `LogRecord` "pertenezca" a un trace, y por qué esa correlación es *automática* acá en lugar de algo que escribiste a mano en el mensaje?
- **Q7.2** `INFO` se mapeó a `severity_number=9` y `WARN` a `13`. La especificación define `SeverityNumber` en una escala `1–24`. ¿Cuál es el punto de una severity *numérica* además de `severity_text`, dado que dos sistemas podrían deletrear el mismo nivel como `"WARN"` vs `"WARNING"`?
- **Q7.3** Un `LogRecord` tiene **ambos** un `timestamp` y un `observed_timestamp`. ¿Cuándo diferirían, y cuál está garantizado que esté presente incluso para un log que el pipeline levantó de un archivo sin hora embebida?
- **Q7.4** El `body` acá es un string plano, pero el modelo de datos lo tipa como un *any-value*. ¿Qué le permite eso llevar a un log estructurado que una línea de texto no puede, y cómo se solapa (pero se mantiene distinto de) los `attributes` del record?

---

## Ejercicio 7 — El formato de cable OTLP vía el Collector

Todo lo anterior fue el modelo *en memoria*. OTLP es cómo cruza la red. Vas a enviar spans reales a un Collector y leer el payload decodificado.

**Pasos**

1. Escribí `collector.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
   exporters:
     debug:
       verbosity: detailed
   service:
     pipelines:
       traces:
         receivers: [otlp]
         exporters: [debug]
   ```

2. Ejecutá el Collector:

   ```bash
   docker run --rm -p 4317:4317 \
     -v "$(pwd)/collector.yaml":/etc/otelcol-contrib/config.yaml \
     otel/opentelemetry-collector-contrib:0.108.0
   ```

3. En el venv, enviá spans sobre OTLP/gRPC en lugar de la consola:

   ```python
   # otlp_send.py
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

   provider = TracerProvider(resource=Resource.create({"service.name": "checkout-svc"}))
   provider.add_span_processor(BatchSpanProcessor(
       OTLPSpanExporter(endpoint="http://localhost:4317", insecure=True)))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("checkout.instrumentation", "0.1.0")

   with tracer.start_as_current_span("checkout"):
       with tracer.start_as_current_span("charge-card"):
           pass
   provider.shutdown()   # flush the batch
   ```

   ```bash
   python otlp_send.py
   ```

4. Leé la salida `debug` del Collector. Notá los **tres niveles de anidamiento**:

   ```
   ResourceSpans #0
   Resource attributes:
        -> service.name: Str(checkout-svc)
   ScopeSpans #0
   ScopeSpans[0].Scope: checkout.instrumentation 0.1.0
       Span #0
           Trace ID       : 8f3a1c9d2b7e4f60a1b2c3d4e5f60718
           Parent ID      :
           ID             : 9f8e7d6c5b4a3021
           Name           : checkout
           Kind           : Internal
           Start time     : 2026-08-10 14:20:01.1 +0000 UTC
           End time       : 2026-08-10 14:20:01.1 +0000 UTC
           Status code    : Unset
       Span #1
           Trace ID       : 8f3a1c9d2b7e4f60a1b2c3d4e5f60718
           Parent ID      : 9f8e7d6c5b4a3021
           ID             : 1a2b3c4d5e6f7081
           Name           : charge-card
   ```

**Comprobá tu comprensión**

- **Q8.1** El payload es `ResourceSpans → ScopeSpans → Span`, tres niveles de profundidad. Mapeá cada nivel de vuelta a los tres "anchors" que conociste antes (Resource, Instrumentation Scope, Span). ¿Por qué esta jerarquía es una *deduplicación* de exactamente los campos que se repiten a lo largo de muchos spans?
- **Q8.2** En el cable el `Trace ID` se imprime como hex pelado **sin** `0x` y el `Start time` es un string legible por humanos — pero el protobuf OTLP en realidad los codifica como un campo `bytes` de 16 bytes y un conteo de nanosegundos `fixed64`. ¿Por qué el modelo binario evita strings para IDs y timestamps, y qué perderías transmitiendo `"8f3a…"` como texto?
- **Q8.3** Cambiaste de `SimpleSpanProcessor`+`ConsoleSpanExporter` a `BatchSpanProcessor`+`OTLPSpanExporter`, y tuviste que llamar a `provider.shutdown()` para ver la salida. El *modelo de datos de cada span es idéntico byte por byte* al del Ejercicio 1. ¿Qué prueba eso sobre la relación entre el modelo de datos y el transport/exporter que lo lleva?
- **Q8.4** El pipeline de metrics tiene `ResourceMetrics → ScopeMetrics → Metric → data_points`, y los logs tienen `ResourceLogs → ScopeLogs → LogRecord`. Enunciá el único patrón estructural que las tres señales comparten, y por qué esa uniformidad es lo que permite que un solo pipeline del Collector maneje todas.

---

<details>
<summary><strong>Respuestas</strong></summary>

**Prerrequisitos**

- **A1.1** El paquete **API** (`opentelemetry-api`) *define* los tipos e interfaces — `Span`, `SpanContext`, `SpanKind`, las interfaces de los instruments, `SeverityNumber`, etc. — como un contrato estable. El **SDK** (`opentelemetry-sdk`) *implementa* la producción, sampling, agregación y exportación de esos tipos. La instrumentación depende solo de la API; la aplicación conecta el SDK. Esta separación es en sí misma un principio del modelo de datos: la forma de la telemetría se fija de manera independiente de quién la produce o la envía.
- **A1.2** Porque el modelo de datos es *agnóstico a la serialización* y *al backend*. Un backend es solo un posible consumidor de un payload OTLP. Los console exporters emiten los mismos objetos estructurados que de otro modo se codificarían a OTLP y se enviarían aguas abajo, así que el modelo es totalmente observable sin nada downstream.

**Ejercicio 1 — Span**

- **A2.1** `trace_id` tiene **32 caracteres hex = 16 bytes = 128 bits**; `span_id` tiene **16 caracteres hex = 8 bytes = 64 bits**. El **SpanContext** es la tupla inmutable y propagable `{trace_id, span_id, trace_flags, trace_state}` — la identidad del span que viaja a través de los límites de proceso (*no* incluye el name, los attributes ni el timing).
- **A2.2** `trace_id` define el **trace** y es compartido por cada span en él; `span_id` es **único por span**. Un hijo referencia a su padre copiando el `span_id` del padre en su propio `parent_id`.
- **A2.3** Los tres valores son **`UNSET`, `OK`, `ERROR`**. `UNSET` es el default porque un span completado normalmente *no* debería afirmar éxito. `OK` está reservado para cuando el código de la aplicación decide explícitamente que la operación tuvo éxito (anulando cualquier interpretación downstream); dejarlo en `UNSET` permite que los backends y la instrumentación apliquen sus propias heurísticas de error. Poner el default en `OK` suprimiría eso.
- **A2.4** Los cinco kinds son **`INTERNAL`, `SERVER`, `CLIENT`, `PRODUCER`, `CONSUMER`**. **`INTERNAL`** es el default cuando se omite `kind=`.
- **A2.5** Fueron inyectados por el **default resource detector del SDK**. El Resource describe **el proceso/entidad que produce la telemetría**, no un span individual — que es exactamente por qué es idéntico a lo largo de cada span de ese proceso y se factoriza en OTLP.

**Ejercicio 2 — Resource & Scope**

- **A3.1** Se eleva al mensaje envolvente **`ResourceSpans`** (y `ResourceMetrics`/`ResourceLogs` para las otras señales). Es una optimización de tamaño (una copia por batch en lugar de por span) *y* una afirmación semántica: cada span debajo comparte una entidad productora.
- **A3.2** `service.name` es **requerido** por el modelo de datos — tan requerido que el SDK sintetiza `unknown_service` en lugar de omitirlo. El costo práctico es que toda esa telemetría se colapsa en un único servicio sin nombre en el backend, destruyendo el agrupamiento por servicio, los dashboards y las alertas.
- **A3.3** El **Resource** responde *"¿qué entidad produjo esto?"* (service, host, pod, environment). El **Instrumentation Scope** responde *"¿qué librería/módulo de instrumentación lo emitió?"* (su name y version). Uno identifica la fuente en runtime; el otro identifica el camino de código que creó la señal — útil para atribuir bugs o comportamiento específico de versión a una instrumentación particular.

**Ejercicio 3 — Events, Links, Status**

- **A4.1** Un **Event** es una *anotación con timestamp, con name y attributes pero sin duración* embebida en el span; un **Span** hijo es una *unidad de trabajo identificada por separado con su propio start/end, context y status*. Usá un Event para una ocurrencia instantánea ("cache miss", "exception"); usá un Span hijo para trabajo anidado que tiene duración medible.
- **A4.2** Son **ortogonales**. `record_exception()` agrega un *event* `exception` al span (type/message/stacktrace), que es un registro factual; **no** cambia el resultado del span. Marcar el span como fallido es un acto separado y deliberado vía `set_status(ERROR, …)`. Una excepción capturada y manejada puede legítimamente dejar el span en `UNSET`/`OK`.
- **A4.3** En una cola, el consumer corre *asíncronamente y posiblemente mucho después* que el producer, y un mensaje puede estar agrupado en batch con otros — no hay relación síncrona parent/child de llamada. Un **Link** expresa una asociación causal entre spans en traces *diferentes* sin forzarlos a una única cadena parent/child, que es precisamente el caso producer→consumer (y de fan-in batch).
- **A4.4** Porque un Event marca un *instante real de reloj de pared* que debe ser comparable a lo largo de spans, servicios y relojes — no una posición relativa dentro de un span. Almacenarlo como un offset lo haría sin sentido una vez que el span se separa de su contexto, se re-temporiza, o se correlaciona con events de otros spans.

**Ejercicio 4 — Tipos de metric point**

- **A5.1** `is_monotonic=True` promete que el valor **solo alguna vez aumenta (se resetea a 0 en el reinicio)**, así que un backend puede computar rates y asumir que cualquier decremento es un reset del counter. "Active requests" sube *y* baja, así que no puede hacer esa promesa; afirmar monotonicidad haría que un decremento legítimo parezca un reset y corrompería la matemática de rates.
- **A5.2** El **instrument** (`Counter`, `UpDownCounter`, `Histogram`) es el objeto de la API sobre el que llamás `.add()`/`.record()`. El **metric point** (`Sum`, `Histogram`, …) es el *resultado agregado* que el SDK produce y pone en el cable. Muchas llamadas al instrument se colapsan en un único data point agregado por serie por intervalo. Programás contra instruments; los backends reciben points.
- **A5.3** 57 cae en el bucket acotado por `(50, 75]`. Un Histogram almacena **bucket counts pre-agregados** (más count/sum/min/max) para que arbitrariamente muchas mediciones se compriman a una estructura fija y fusionable — podés agregar a lo largo de instancias y tiempo y estimar quantiles sin transmitir ni almacenar cada muestra cruda.
- **A5.4** Un **Gauge** es una lectura de *último valor instantáneo* (p. ej. temperatura actual, memoria actual). "Cambio desde el inicio" vs "cambio desde la última exportación" es un sinsentido para un valor que no se acumula — no hay nada que acumular, así que la temporality no aplica.

**Ejercicio 5 — Temporality**

- **A6.1** **Cumulative**: el valor se mide *relativo a un start time fijo* (`start_time_unix_nano` permanece constante), así que crece monotónicamente. **Delta**: el valor se mide *relativo a la exportación previa*, es decir, solo lo que pasó en este intervalo, y el start time avanza en cada intervalo.
- **A6.2** Los delta points se definen sobre `[start_time_unix_nano, time_unix_nano)`, y el start del siguiente point es igual al end de este point — ventanas adyacentes y sin superposición que teselan el tiempo exactamente una vez. Si dos exporters re-emitieran ambos la misma ventana, el backend **sumaría intervalos superpuestos** y contaría doble ese tráfico.
- **A6.3** **Cumulative** es el default más seguro para el SDK. La conversión cumulative→delta es una resta barata y sin estado aguas abajo, pero delta→cumulative requiere que el pipeline *recuerde totales acumulados para cada serie* y sobreviva a reinicios — con estado, hambriento de memoria, y con pérdidas ante huecos. Emitir cumulative mantiene esa carga fuera del SDK.

**Ejercicio 6 — Logs**

- **A7.1** Un `LogRecord` "pertenece" a un trace cuando lleva un **`trace_id`/`span_id`** no-cero (y `trace_flags`). La correlación es automática porque el `LoggingHandler` lee el **span activo del contexto actual** en el momento de la emisión y estampa esos IDs en el record — el mismo contexto que parenta spans también parenta logs.
- **A7.2** El `SeverityNumber` numérico (1–24) es la severity **normalizada y comparable**: podés hacer range-query `>= 17` (todos los errores) sin importar cómo cada fuente deletree su texto. `severity_text` preserva la etiqueta *original* por fidelidad, pero es de forma libre y no está confiablemente ordenada; el número es lo que los backends filtran y sobre lo que alertan.
- **A7.3** `timestamp` es *cuándo ocurrió realmente el evento* (puede estar ausente si es desconocido); `observed_timestamp` es *cuándo el pipeline de telemetría observó/recolectó el record*. Difieren cuando un log se lee tarde de un archivo o cola. **`observed_timestamp`** está siempre presente — el collector lo establece incluso cuando el record no tiene hora embebida.
- **A7.4** Un `body` de tipo any-value puede llevar un **payload estructurado** (map, array, escalar tipado), no solo texto — así un log JSON permanece estructurado de punta a punta. Se solapa con `attributes` en que ambos contienen datos estructurados, pero son distintos en intención: `body` es *el mensaje/contenido en sí*, mientras que los `attributes` son *metadatos que describen el record* (archivo fuente, campos http, etc.) destinados a indexar y filtrar.

**Ejercicio 7 — OTLP**

- **A8.1** `ResourceSpans` = el **Resource** (entidad productora), `ScopeSpans` = el **Instrumentation Scope** (librería emisora), `Span` = el span individual. El anidamiento deduplica exactamente los dos anchors que son idénticos a lo largo de muchos spans, así que un batch de 10 000 spans de un servicio/librería lleva el Resource y el Scope **una vez cada uno** en lugar de 10 000 veces.
- **A8.2** Los IDs son `bytes` y los timestamps son `fixed64` de nanosegundos porque eso es **compacto e inequívoco**: 16 bytes crudos vs 32 caracteres de texto, sin variación de mayúsculas/`0x`/codificación, y los tiempos enteros se ordenan y restan sin parsing. Transmitirlos como strings duplica el tamaño y reintroduce ambigüedad de formato y costo de parseo.
- **A8.3** Prueba que el **modelo de datos es independiente del exporter y del transport**. Los processors `Simple`/`Batch` y los exporters console/OTLP cambian *cuándo y cómo* se bufferean y serializan los spans, pero los campos del span son idénticos. El transport es un portador; el modelo es el payload.
- **A8.4** Las tres siguen **`Resource<Signal> → Scope<Signal> → <SignalItem>`** — un anclaje uniforme de dos niveles de cada señal bajo un Resource y un Scope compartidos. Esa uniformidad es por qué un solo receiver/pipeline del Collector puede ingerir, procesar y enrutar traces, metrics y logs a través de la misma maquinaria estructural.

</details>