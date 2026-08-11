# OTCA 2.5 — SDK Pipelines · Ejercicios Guiados

> **Peso del dominio:** 6.57% · **Examen:** OpenTelemetry Certified Associate (OTCA)
> **Temario de referencia:** [CNCF OTCA Curriculum](https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf)
> **Fuentes primarias:** [SDK spec — Trace](https://opentelemetry.io/docs/specs/otel/trace/sdk/) · [SDK spec — Metrics](https://opentelemetry.io/docs/specs/otel/metrics/sdk/) · [SDK spec — Logs](https://opentelemetry.io/docs/specs/otel/logs/sdk/) · [SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/) · [Python SDK](https://opentelemetry.io/docs/languages/python/)

Un **pipeline** es el camino que recorre una señal desde tu instrumentación hasta un backend, *dentro del proceso*, antes de cualquier salto de red:

```
                        ┌──────────────── Provider ────────────────┐
  API (get_tracer) ───► │  Sampler → [ Processor → Processor ] ───► Exporter ──► wire (OTLP/…)
                        └───────────────────────────────────────────┘
                                Resource is attached to every record
```

Cada señal tiene su propio provider y su propio vocabulario de pipeline, pero la forma es idéntica:

| Señal | Provider | Etapa que agrupa en lotes/engancha | Etapa terminal |
|---|---|---|---|
| Traces | `TracerProvider` | `SpanProcessor` (Simple / Batch) | `SpanExporter` |
| Metrics | `MeterProvider` | `MetricReader` (Periodic / Manual) | `MetricExporter` |
| Logs | `LoggerProvider` | `LogRecordProcessor` (Simple / Batch) | `LogRecordExporter` |

Estos labs usan el SDK de **opentelemetry-python** porque expone cada etapa del pipeline como un objeto explícito que podés cablear a mano — el examen evalúa los *conceptos*, y construirlos manualmente los vuelve concretos.

### Prerrequisitos (ejecutar una vez)

```bash
python3 -m venv .otca && source .otca/bin/activate
pip install \
  'opentelemetry-api==1.27.0' \
  'opentelemetry-sdk==1.27.0' \
  'opentelemetry-exporter-otlp-proto-grpc==1.27.0'
python3 -c "import opentelemetry.sdk; print('sdk ready')"
```

Esperado:

```
sdk ready
```

---

## Ejercicio 1 — Anatomía de un pipeline de traces

**Objetivo:** construir a mano una cadena `TracerProvider → SpanProcessor → SpanExporter` y leer un span exportado en crudo.

1. Creá `ex1_pipeline.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import (
       SimpleSpanProcessor,
       ConsoleSpanExporter,
   )

   # 1. Resource: identity attached to EVERY span this provider emits
   resource = Resource.create({"service.name": "pipeline-lab", "service.version": "1.0.0"})

   # 2. Provider: owns the sampler + the ordered list of processors
   provider = TracerProvider(resource=resource)

   # 3. Processor -> Exporter: the two pipeline stages
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))

   # 4. Register globally so trace.get_tracer() returns THIS provider
   trace.set_tracer_provider(provider)

   tracer = trace.get_tracer("otca.ex1")
   with tracer.start_as_current_span("checkout") as span:
       span.set_attribute("cart.items", 3)
       with tracer.start_as_current_span("charge-card"):
           pass

   provider.shutdown()   # flush + close the pipeline cleanly
   ```

2. Ejecutalo:

   ```bash
   python3 ex1_pipeline.py
   ```

3. Leé la salida. Se imprimen dos spans, **primero el hijo** (los spans se exportan al `end`, y el hijo termina antes que el padre). Abreviado:

   ```json
   {
       "name": "charge-card",
       "context": { "trace_id": "0x8f2c…", "span_id": "0x41a…", "trace_state": "[]" },
       "kind": "SpanKind.INTERNAL",
       "parent_id": "0x9b7…",
       "status": { "status_code": "UNSET" },
       "attributes": {},
       "resource": { "attributes": { "service.name": "pipeline-lab", "service.version": "1.0.0", "telemetry.sdk.language": "python", … } }
   }
   {
       "name": "checkout",
       "context": { "trace_id": "0x8f2c…", "span_id": "0x9b7…", "trace_state": "[]" },
       "parent_id": null,
       "attributes": { "cart.items": 3 },
       "resource": { … }
   }
   ```

4. Comentá la línea 4 (`trace.set_tracer_provider(provider)`) y volvé a ejecutar.

**Chequeo de comprensión:**

- **Q1.1** ¿En qué orden se ejecutan las cuatro etapas que atraviesa un span, desde `span.end()` hasta stdout?
- **Q1.2** Ambos spans comparten el mismo `trace_id` pero distinto `span_id`, y el `parent_id` del padre es `null`. ¿Qué te dice eso sobre quién es la raíz del trace?
- **Q1.3** El `service.name` que definiste una sola vez en el `Resource` aparece en *ambos* spans. ¿Qué etapa del pipeline es responsable de adjuntar el resource, y por qué es incorrecto pensar en el resource como "un atributo que definís por span"?
- **Q1.4** Con la línea 4 comentada, no se imprime ningún span aunque el código corre sin error. ¿A dónde fueron los spans?

---

## Ejercicio 2 — SimpleSpanProcessor vs BatchSpanProcessor

**Objetivo:** observar la diferencia de comportamiento entre los dos processors incorporados y entender la cola.

1. Creá `ex2_batch.py`:

   ```python
   import time
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter

   provider = TracerProvider()
   provider.add_span_processor(
       BatchSpanProcessor(
           ConsoleSpanExporter(),
           max_queue_size=2048,
           max_export_batch_size=512,
           schedule_delay_millis=5000,   # flush every 5s…
       )
   )
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.ex2")

   for i in range(3):
       with tracer.start_as_current_span(f"job-{i}"):
           pass
   print(">>> 3 spans ended, watch the clock <<<", flush=True)

   time.sleep(6)   # …so nothing prints until ~5s pass
   print(">>> woke up <<<", flush=True)
   provider.shutdown()
   ```

2. Ejecutá y observá *cuándo* aparece el texto:

   ```bash
   python3 ex2_batch.py
   ```

   Línea de tiempo esperada:

   ```
   >>> 3 spans ended, watch the clock <<<
   ( ~5 seconds of silence )
   { "name": "job-0", … }
   { "name": "job-1", … }
   { "name": "job-2", … }
   >>> woke up <<<
   ```

3. Reemplazá `BatchSpanProcessor(...)` por `SimpleSpanProcessor(ConsoleSpanExporter())` y volvé a ejecutar. Ahora cada span se imprime **inmediatamente** al terminar su span, *antes* de `">>> 3 spans ended"`.

4. Forzá un flush temprano: poné esta línea justo después del loop en la versión Batch y volvé a ejecutar:

   ```python
   provider.force_flush()   # export now, don't wait for schedule_delay
   ```

**Chequeo de comprensión:**

- **Q2.1** Con `BatchSpanProcessor`, ¿por qué los tres spans quedaron invisibles durante ~5 segundos aunque ya habían terminado?
- **Q2.2** `SimpleSpanProcessor` exporta de forma síncrona en cada `span.end()`. Nombrá un riesgo de producción que esto crea y que `BatchSpanProcessor` está diseñado específicamente para evitar.
- **Q2.3** Un servicio emite spans más rápido de lo que el exporter puede enviarlos y `max_queue_size` (2048) se llena. ¿Qué hace `BatchSpanProcessor` con los nuevos spans — bloquea el hilo de la aplicación, o los descarta? ¿Qué implica eso respecto a la telemetría vs. la latencia de las peticiones?
- **Q2.4** ¿Qué dos cosas garantiza `shutdown()` que dejar simplemente que el proceso salga no garantiza?

---

## Ejercicio 3 — Sampling: la primera compuerta del pipeline

**Objetivo:** colocar un `Sampler` en el provider y demostrar que decide *antes* de que corran los processors.

1. Creá `ex3_sampler.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import SimpleSpanProcessor, ConsoleSpanExporter
   from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased

   # Sample ~50% of ROOT traces; children follow their parent's decision
   sampler = ParentBased(root=TraceIdRatioBased(0.5))

   provider = TracerProvider(sampler=sampler)
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.ex3")

   sampled = 0
   for i in range(20):
       with tracer.start_as_current_span(f"req-{i}") as span:
           if span.get_span_context().trace_flags.sampled:
               sampled += 1
   print(f"\n>>> {sampled}/20 root spans were sampled <<<")
   provider.shutdown()
   ```

2. Ejecutalo unas cuantas veces:

   ```bash
   python3 ex3_sampler.py 2>/dev/null | tail -1
   ```

   Esperado (varía de corrida en corrida, pero cerca de la mitad):

   ```
   >>> 11/20 root spans were sampled <<<
   ```

3. Ajustá el ratio a `TraceIdRatioBased(0.0)` y volvé a ejecutar. Contá los bloques JSON de span impresos.

4. Ahora la sutileza favorita del examen — cambiá la raíz para forzar que **todos** sean sampleados pero mantené `ParentBased`:

   ```python
   from opentelemetry.sdk.trace.sampling import ALWAYS_ON
   sampler = ParentBased(root=ALWAYS_ON)
   ```

   Después imaginá una petición entrante cuyo contexto padre llega con `sampled=false`.

**Chequeo de comprensión:**

- **Q3.1** Con `TraceIdRatioBased(0.0)`, ¿cuántos bloques JSON de span se imprimen, y el cuerpo del loop `for` igual se ejecuta? ¿Qué revela eso sobre la diferencia entre *"un span existe en el código"* y *"un span se registra/exporta"*?
- **Q3.2** ¿Por qué el sampling pertenece al **provider** (antes de los processors) en lugar de ser un filtro dentro de un `SpanProcessor`? ¿Qué perderías al samplear más adelante en el pipeline?
- **Q3.3** En `ParentBased(root=ALWAYS_ON)`, un servicio upstream envía un contexto con `sampled=false`. ¿Tu servicio registra el span hijo? ¿Por qué `ParentBased` es el default recomendado para mantener los traces *completos* a través de los servicios?
- **Q3.4** `TraceIdRatioBased` decide usando el trace-id, no una tirada de moneda. ¿Por qué derivar la decisión del trace-id es esencial para un sampling consistente a través de servicios desplegados de forma independiente?

---

## Ejercicio 4 — Fan-out: muchos processors, muchos destinos

**Objetivo:** mostrar que un provider mantiene una *lista ordenada* de processors y puede enviar el mismo span a varios backends.

1. Creá `ex4_fanout.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import (
       BatchSpanProcessor, SimpleSpanProcessor, ConsoleSpanExporter,
   )
   from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

   provider = TracerProvider()

   # Destination A: local debugging tap (synchronous, human-readable)
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))

   # Destination B: real backend via OTLP over gRPC (batched, resilient)
   provider.add_span_processor(
       BatchSpanProcessor(OTLPSpanExporter(endpoint="http://localhost:4317", insecure=True))
   )

   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.ex4")
   with tracer.start_as_current_span("fan-out-demo"):
       pass
   provider.shutdown()
   ```

2. Ejecutá **sin** un Collector escuchando en 4317:

   ```bash
   python3 ex4_fanout.py
   ```

   El tap de Console igual imprime su span. El processor OTLP registra una falla de conexión pero **no** hace crashear tu app:

   ```
   { "name": "fan-out-demo", … }
   Transient error StatusCode.UNAVAILABLE encountered while exporting … retrying in 1s.
   Failed to export … to localhost:4317, error code: StatusCode.UNAVAILABLE
   ```

3. (Opcional) Iniciá un Collector y volvé a ejecutar para ver que el camino OTLP tiene éxito:

   ```bash
   docker run --rm -p 4317:4317 otel/opentelemetry-collector:0.109.0
   ```

**Chequeo de comprensión:**

- **Q4.1** Un solo `start_as_current_span("fan-out-demo")` produjo salida en dos destinos. ¿Cuántas instancias de `SpanProcessor` atravesó el span, y recibieron el *mismo* objeto span o copias?
- **Q4.2** El span de Console apareció aunque OTLP estaba caído. ¿Qué propiedad de la lista de processors garantiza que un exporter que falla no puede silenciar a otro?
- **Q4.3** Querés *todos* los spans en la consola pero solo un subconjunto *sampleado* enviado a un backend costoso. El sampling vive en el provider y afecta a todos los processors por igual — así que aquí no hay un sampler por processor disponible. Nombrá un mecanismo legítimo (fuera del pipeline de spans incorporado del SDK) que *sí* pueda aplicar retención distinta a distintos destinos.
- **Q4.4** ¿Por qué `ConsoleSpanExporter` se empareja aquí con `SimpleSpanProcessor`, pero `OTLPSpanExporter` se empareja con `BatchSpanProcessor`? Emparejá cada processor con el perfil de costo del exporter.

---

## Ejercicio 5 — El pipeline de métricas tiene *forma de pull*

**Objetivo:** construir `MeterProvider → MetricReader → MetricExporter` y ver por qué las métricas se agrupan en lotes sobre un **timer que el reader posee**, no sobre las llamadas al instrumento.

1. Creá `ex5_metrics.py`:

   ```python
   import time
   from opentelemetry import metrics
   from opentelemetry.sdk.metrics import MeterProvider
   from opentelemetry.sdk.metrics.export import (
       PeriodicExportingMetricReader, ConsoleMetricExporter,
   )

   reader = PeriodicExportingMetricReader(
       ConsoleMetricExporter(),
       export_interval_millis=3000,   # reader COLLECTS+EXPORTS every 3s
   )
   provider = MeterProvider(metric_readers=[reader])
   metrics.set_meter_provider(provider)

   meter = metrics.get_meter("otca.ex5")
   requests = meter.create_counter("http.server.requests", unit="{request}")

   for i in range(5):
       requests.add(1, {"http.route": "/health", "http.status_code": 200})
       time.sleep(1)

   provider.shutdown()   # forces a final collect+export
   ```

2. Ejecutalo:

   ```bash
   python3 ex5_metrics.py
   ```

   Esperado — la salida aparece con la **cadencia de 3s del reader**, y el contador es **acumulativo**:

   ```json
   {
     "resource_metrics": [{
       "scope_metrics": [{
         "scope": { "name": "otca.ex5" },
         "metrics": [{
           "name": "http.server.requests",
           "sum": {
             "data_points": [{
               "attributes": { "http.route": "/health", "http.status_code": 200 },
               "value": 3,
               "is_monotonic": true,
               "aggregation_temporality": 2
             }],
           }
         }]
       }]
     }]
   }
   ```

   (~3s más tarde, la misma serie reporta `"value": 5` — el total acumulado.)

3. Cambiá a temporalidad delta vía variable de entorno y volvé a ejecutar:

   ```bash
   OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta python3 ex5_metrics.py
   ```

   Ahora cada export reporta solo el incremento *desde la colección anterior*, no el total acumulado.

**Chequeo de comprensión:**

- **Q5.1** Llamaste a `requests.add(1, …)` cinco veces por separado, y sin embargo se imprimieron muchos menos de cinco bloques de export. ¿Por qué? ¿Qué componente decidió *cuándo* exportar — el instrumento o el reader?
- **Q5.2** En la corrida por defecto, el valor subió 3 → 5 entre exports. Bajo `aggregation_temporality: 2` (**cumulative**), ¿qué representa el número `5`, y por qué lo acumulativo es resiliente ante un export perdido?
- **Q5.3** Tras configurar la preferencia delta, dos exports sucesivos de la misma serie podrían leer `3` y luego `2`. ¿Qué significa cada número ahora, y qué debe hacer el *backend* que no tenía que hacer bajo cumulative?
- **Q5.4** Un pipeline de traces tiene un `SpanProcessor` entre el provider y el exporter; el pipeline de métricas tiene un `MetricReader` en la ranura análoga. ¿Por qué "reader" es la palabra correcta — qué *tira (pull)* que un span processor nunca hace?

---

## Ejercicio 6 — El pipeline de logs y el puente

**Objetivo:** cablear `LoggerProvider → LogRecordProcessor → LogRecordExporter` y puentear el logging nativo del lenguaje hacia él.

> El SDK de logs de Python todavía vive bajo el namespace `_logs` porque la API de Logs es más joven que Traces/Metrics. Cita: [Logs SDK spec](https://opentelemetry.io/docs/specs/otel/logs/sdk/).

1. Creá `ex6_logs.py`:

   ```python
   import logging
   from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
   from opentelemetry.sdk._logs.export import (
       BatchLogRecordProcessor, ConsoleLogExporter,
   )
   from opentelemetry.sdk.resources import Resource

   provider = LoggerProvider(resource=Resource.create({"service.name": "log-lab"}))
   provider.add_log_record_processor(BatchLogRecordProcessor(ConsoleLogExporter()))

   # The BRIDGE: route stdlib logging records into the OTel pipeline
   handler = LoggingHandler(level=logging.NOTSET, logger_provider=provider)
   logging.getLogger().addHandler(handler)
   logging.getLogger().setLevel(logging.INFO)

   log = logging.getLogger("payments")
   log.info("charge accepted", extra={"order.id": "A-91"})
   log.warning("retrying gateway")

   provider.shutdown()
   ```

2. Ejecutalo:

   ```bash
   python3 ex6_logs.py
   ```

   Esperado (abreviado) — cada registro de stdlib ahora carga un `resource` y una severidad de OTel:

   ```json
   {
     "body": "charge accepted",
     "severity_text": "INFO",
     "severity_number": 9,
     "attributes": { "order.id": "A-91", "code.function": "<module>" },
     "resource": { "attributes": { "service.name": "log-lab", … } },
     "trace_id": "0x00000000000000000000000000000000"
   }
   ```

3. Envolvé las dos llamadas de log dentro de un span activo (reusá la configuración del tracer del Ejercicio 1 en el mismo archivo) y volvé a ejecutar. Observá que `trace_id` / `span_id` en el registro de log pasan a ser **distintos de cero**.

**Chequeo de comprensión:**

- **Q6.1** Nunca llamaste a un método de logging de OpenTelemetry — llamaste al `log.info(...)` de stdlib. ¿Qué único objeto hizo que esos registros fluyeran hacia el pipeline de OTel, y cuál es el nombre general de este tipo de componente?
- **Q6.2** En el paso 2 el `trace_id` del registro de log es todo ceros; en el paso 3 está poblado. ¿Qué leyó el pipeline de logs del estado ambiente, y por qué esa correlación automática es la razón principal para correr los logs *a través* del SDK en lugar de escribir JSON a stdout vos mismo?
- **Q6.3** `severity_text: "INFO"` mapea a `severity_number: 9`. ¿Por qué OTel carga una severidad numérica *junto* a la textual — qué le permite hacer el número a un backend a través de fuentes de logs heterogéneas?
- **Q6.4** Las tres señales usaron un `BatchLogRecordProcessor` / `BatchSpanProcessor`. Enunciá la única regla arquitectónica que esta repetición revela sobre cómo está diseñado el SDK a través de las señales.

---

## Ejercicio 7 — Configurar todo el pipeline sin cambios de código

**Objetivo:** manejar el sampler, exporter, batching y endpoint enteramente a través de las variables de entorno estándar — el examen espera que reconozcas estos nombres.

> Cita: [SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/).

1. Creá `ex7_env.py` — notá que no hardcodea **nada** sobre sampling ni batching:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
   from opentelemetry.sdk.trace.sampling import ParentBasedTraceIdRatio
   import os

   # Read the standard vars the SDK defines (shown explicitly for teaching)
   ratio = float(os.getenv("OTEL_TRACES_SAMPLER_ARG", "1.0"))
   provider = TracerProvider(sampler=ParentBasedTraceIdRatio(ratio))
   provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)

   tracer = trace.get_tracer("otca.ex7")
   count = 0
   for i in range(100):
       with tracer.start_as_current_span(f"r-{i}") as s:
           if s.get_span_context().trace_flags.sampled:
               count += 1
   print(f">>> sampled {count}/100 <<<")
   provider.shutdown()
   ```

2. Ejecutalo de tres formas y compará solo la última línea:

   ```bash
   OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=1.0  python3 ex7_env.py 2>/dev/null | tail -1
   OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.1  python3 ex7_env.py 2>/dev/null | tail -1
   OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.0  python3 ex7_env.py 2>/dev/null | tail -1
   ```

   Esperado:

   ```
   >>> sampled 100/100 <<<
   >>> sampled 9/100 <<<
   >>> sampled 0/100 <<<
   ```

3. Leé (no ejecutes) esta tabla de las perillas del pipeline que OTCA espera que reconozcas:

   | Variable | Etapa del pipeline que ajusta | Ejemplo |
   |---|---|---|
   | `OTEL_SERVICE_NAME` | Resource | `payments-api` |
   | `OTEL_TRACES_SAMPLER` | Sampler del provider | `parentbased_traceidratio` |
   | `OTEL_TRACES_SAMPLER_ARG` | Argumento del sampler | `0.25` |
   | `OTEL_TRACES_EXPORTER` | Exporter(s) terminal(es) | `otlp,console` |
   | `OTEL_EXPORTER_OTLP_ENDPOINT` | Transporte del exporter | `http://collector:4317` |
   | `OTEL_EXPORTER_OTLP_PROTOCOL` | Formato de cable del exporter | `grpc` / `http/protobuf` |
   | `OTEL_BSP_SCHEDULE_DELAY` | Timer del BatchSpanProcessor (ms) | `5000` |
   | `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` | Lote del BatchSpanProcessor | `512` |
   | `OTEL_METRIC_EXPORT_INTERVAL` | PeriodicExportingMetricReader (ms) | `60000` |
   | `OTEL_SDK_DISABLED` | Todo el pipeline apagado | `true` |

**Chequeo de comprensión:**

- **Q7.1** El mismo binario produjo 100, 9 y 0 spans sampleados sin recompilación. ¿Qué principio del diseño del SDK hace posible la configuración por variable de entorno, y por qué el examen la prefiere para despliegues en contenedores?
- **Q7.2** `OTEL_TRACES_EXPORTER=otlp,console` acepta una lista separada por comas. En términos de pipeline, ¿qué construye suministrar dos valores?
- **Q7.3** Un compañero de equipo pone `OTEL_SDK_DISABLED=true` en un entorno de load-test. ¿Qué etapas de *los tres* pipelines apaga este interruptor, y cuál es el caso de uso previsto?
- **Q7.4** `OTEL_BSP_SCHEDULE_DELAY` y `OTEL_METRIC_EXPORT_INTERVAL` ambos controlan una cadencia de export, pero pertenecen a componentes distintos. Nombrá cada componente y explicá por qué los traces tienen por defecto segundos mientras que las métricas comúnmente tienen por defecto 60s.

---

## Ejercicio 8 — Diagnosticar un pipeline silencioso

**Objetivo:** practicar la falla que da más problemas a los principiantes — el código corre, sale con 0, y *nada* llega al backend.

1. Creá `ex8_broken.py` (tiene tres bugs deliberados escondidos):

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor
   from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

   provider = TracerProvider()
   provider.add_span_processor(
       BatchSpanProcessor(OTLPSpanExporter(endpoint="http://localhost:4317", insecure=True))
   )
   # (bug: provider never registered globally)

   tracer = trace.get_tracer("otca.ex8")
   with tracer.start_as_current_span("orphan"):
       pass
   # (bug: no force_flush / shutdown before exit)
   # (bug: no Collector is listening on 4317)
   ```

2. Ejecutalo — sale con 0 y no imprime nada:

   ```bash
   python3 ex8_broken.py ; echo "exit=$?"
   ```

   ```
   exit=0
   ```

3. Activá los diagnósticos propios del SDK para hacer hablar al pipeline. Agregá al inicio de todo y volvé a ejecutar:

   ```python
   import logging
   logging.basicConfig(level=logging.DEBUG)
   ```

4. Agregá un **debug tap** para poder probar que los spans se están *creando* aunque el exporter real falle — insertá antes del `with`:

   ```python
   from opentelemetry.sdk.trace.export import SimpleSpanProcessor, ConsoleSpanExporter
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   ```

5. Arreglá los tres bugs (registrá el provider con `trace.set_tracer_provider(provider)`, llamá a `provider.shutdown()` al final, y ya sea iniciá un Collector o apuntá el endpoint a uno en vivo). Volvé a ejecutar y confirmá que el span `orphan` llega a ambos taps.

**Chequeo de comprensión:**

- **Q8.1** En el archivo original, los spans se crearon y la app salió con 0, y sin embargo el backend OTLP no recibió nada. Enumerá los tres defectos independientes del pipeline y, para cada uno, indicá en qué etapa murió silenciosamente el span.
- **Q8.2** Agregar un tap de `ConsoleSpanExporter` es una técnica de diagnóstico. ¿Qué única pregunta responde el tap, y cómo te permite su respuesta *dividir* el problema en "lado de la instrumentación" vs. "lado del export"?
- **Q8.3** Con `BatchSpanProcessor`, ¿por qué la falta de `shutdown()`/`force_flush()` antes de que el proceso salga es un bug de pérdida de datos específicamente para programas *de corta vida* (CLIs, cron jobs, serverless), pero rara vez se nota en un servidor de larga duración?
- **Q8.4** `logging.basicConfig(level=logging.DEBUG)` sacó a la luz los errores de conexión OTLP que antes se tragaban. ¿Por qué el SDK *no* lanza las fallas de export como excepciones hacia el código de tu aplicación por defecto, y qué protege esa decisión de diseño?

---

## Clave de respuestas

<details>
<summary>Hacé clic para revelar las respuestas (Ejercicios 1–8)</summary>

### Ejercicio 1
- **A1.1** `span.end()` → el **SpanProcessor** activo del provider recibe `on_end` → el processor entrega el span a su **SpanExporter** (`export()`) → el exporter serializa y escribe a stdout. (El sampling ya ocurrió al *inicio* del span, aguas arriba de esto.)
- **A1.2** El span cuyo `parent_id` es `null` es la **raíz** del trace (`checkout`). `charge-card` carga un `parent_id` que apunta al `span_id` de `checkout`. Un `trace_id` compartido con `span_id`s distintos es exactamente cómo se codifica la relación padre/hijo dentro de un trace.
- **A1.3** El **Resource** es adjuntado por el **provider** (es una propiedad del `TracerProvider`, aplicada uniformemente a cada span que emite), no seteado por span. Pensarlo como un atributo por span es incorrecto porque el resource describe al *productor* (servicio/host/SDK), es idéntico para todo el proceso, y se deduplica en el cable — no es algo que la instrumentación setee en cada operación.
- **A1.4** A ningún lado/a un **no-op**. Sin `set_tracer_provider`, `trace.get_tracer()` devuelve el tracer no-op por defecto; los spans se crean como objetos no-registrantes y nunca entran a ningún pipeline. El camino del código corre pero no hay processor/exporter para emitir nada.

### Ejercicio 2
- **A2.1** `BatchSpanProcessor` encola los spans terminados y los exporta sobre su timer de **`schedule_delay`** (5000 ms acá), o cuando se llena un lote / en un flush. Los spans quedaron en la cola en memoria hasta que se disparó el timer.
- **A2.2** Export síncrono en el camino caliente: cada `span.end()` bloquea el hilo llamante en un round-trip de red/IO, así que la latencia del exporter o un backend lento infla directamente la latencia de la petición (y acopla el throughput de la app al throughput del exporter). El batching los desacopla al exportar de forma asíncrona en bloque.
- **A2.3** Cuando la cola está llena, `BatchSpanProcessor` **descarta** los nuevos spans (no bloquea la aplicación). Implicancia: la telemetría se trata como *best-effort* y se sacrifica para proteger la latencia de la petición — perder spans es preferible a ralentizar la petición del usuario.
- **A2.4** `shutdown()` (a) **vacía (flush)** cualquier span aún encolado, exportándolos antes de salir, y (b) **cierra** el exporter/libera sus recursos. Una salida pelada del proceso puede perder el lote encolado y saltearse el teardown limpio.

### Ejercicio 3
- **A3.1** Se imprimen **cero** bloques JSON de span con el ratio `0.0`, pero el cuerpo del `for` igual corre — `start_as_current_span` devuelve un span válido (no-registrante) y el bloque `with` se ejecuta normalmente. Esto distingue "un objeto span existe en el código" de "el span está *registrado y sampleado* para export." El sampling cambia el registro, no el flujo de control.
- **A3.2** El sampling en el provider corre al *inicio* del span, antes de que se registre cualquier trabajo, así que un span no sampleado puede crearse como no-registrante — ahorrando el costo de registrar atributos/eventos y el costo de todo el camino processor→exporter. Samplear después (en un processor) significaría que ya pagaste para registrar y encolar el span, y romperías la garantía del head-sampling de que el flag `sampled` se propaga aguas abajo.
- **A3.3** No — con `ParentBased`, un contexto padre válido que dice `sampled=false` es **respetado**, así que el hijo no se registra (el sampler de la raíz solo aplica cuando no hay padre). `ParentBased` es el default porque mantiene un trace distribuido **completo**: cada servicio honra la única decisión tomada en la raíz del trace, así que nunca obtenés traces medio sampleados, fragmentarios.
- **A3.4** Porque el trace-id es compartido por cada span del trace a través de todos los servicios, derivar la decisión de mantener/descartar determinísticamente de él significa que cada servicio desplegado de forma independiente computa la **misma** decisión para el mismo trace sin coordinación. Una tirada de moneda aleatoria por servicio mantendría el trace en un salto y lo descartaría en el siguiente.

### Ejercicio 4
- **A4.1** **Dos** instancias de `SpanProcessor` (el par Simple+Console y el par Batch+OTLP). El provider hace fan-out del *mismo* span hacia cada processor en el orden de la lista; los processors reciben el mismo objeto span y no deben mutarlo destructivamente.
- **A4.2** El provider itera su lista de processors de forma independiente; cada processor posee su propio exporter y manejo de errores. Una falla en un exporter queda contenida en ese processor y no se propaga a los demás, así que el tap de Console imprime sin importar el estado de OTLP.
- **A4.3** El head sampler incorporado del SDK es global al provider, así que la retención por destino no es una característica del pipeline del SDK. El lugar correcto es el **OpenTelemetry Collector** — p. ej. un processor `tail_sampling` más múltiples exporters/pipelines enruta un subconjunto sampleado al backend costoso mientras un pipeline más barato conserva más. (Cualquier capa de enrutamiento/filtrado aguas abajo sirve; el punto es que vive fuera del pipeline de spans dentro del proceso.)
- **A4.4** `ConsoleSpanExporter` escribe localmente y de forma barata, así que el `SimpleSpanProcessor` síncrono está bien y da salida inmediata y ordenada para debugging. `OTLPSpanExporter` hace un round-trip de red que puede ser lento o fallar, así que debe ser `BatchSpanProcessor` para mantener el export fuera del camino caliente y absorber caídas transitorias del backend.

### Ejercicio 5
- **A5.1** Porque el **MetricReader** — no el instrumento — decide el momento del export. `PeriodicExportingMetricReader` colecta y exporta sobre su propio timer de `export_interval_millis` (3s); las cinco llamadas a `add()` solo mutan una agregación en memoria. Los exports son snapshots periódicos, no eventos por medición.
- **A5.2** Bajo temporalidad **cumulative**, `5` es el total acumulado desde el comienzo del stream (todos los incrementos hasta la fecha). Es resiliente ante un export perdido porque el *siguiente* export exitoso igual carga el total acumulado completo — un mensaje perdido no pierde las cuentas que contenía.
- **A5.3** Bajo **delta**, `3` y luego `2` significan "3 incrementos en el primer intervalo, 2 más en el segundo" — cada export reporta solo el cambio desde la colección anterior. Ahora el backend debe **sumar los deltas a lo largo del tiempo** él mismo para reconstruir un total, y un export delta perdido pierde permanentemente esas cuentas (sin auto-recuperación).
- **A5.4** "Reader" es correcto porque un `MetricReader` **tira (pull)** del estado agregado actual desde el SDK a demanda (en su timer o en el collect), en lugar de que se le empuje un registro por operación. Un `SpanProcessor` es orientado a push — recibe cada span a medida que termina; nunca consulta al provider por un snapshot acumulado.

### Ejercicio 6
- **A6.1** El **`LoggingHandler`** — adjuntado al logger raíz de stdlib — convierte cada `logging.LogRecord` en un `LogRecord` de OTel y lo emite a través del pipeline del `LoggerProvider`. Genéricamente esto es un **log appender / puente (bridge)** (el "Logs Bridge" de la API).
- **A6.2** El pipeline leyó el **contexto del span activo** (trace_id/span_id) del Context ambiente en el momento de la emisión. Cuando hay un span activo, el log se estampa con sus ids; cuando no hay ninguno, son cero. La correlación automática trace↔log es la razón principal para enrutar los logs a través del SDK — obtenés logs unidos al trace/span exacto gratis, algo que un JSON manual a stdout no puede hacer sin que vos mismo cablees el contexto.
- **A6.3** El `severity_number` numérico es una escala normalizada (1–24) que le permite a un backend comparar y filtrar la severidad **de forma consistente a través de fuentes** que usan nombres de nivel textuales distintos (WARN vs WARNING vs W). El texto es para las personas; el número es comparable por máquina y estable a través de ecosistemas.
- **A6.4** El SDK es **simétrico a través de las señales**: cada señal es provider → processor(s) → exporter, y cada una ofrece el mismo patrón de processor Simple/Batch con los mismos trade-offs de batching. Aprendé la forma una vez y se transfiere a las tres.

### Ejercicio 7
- **A7.1** **Separación de la configuración respecto del código** — las etapas del pipeline (sampler, exporter, batching, resource) se construyen a partir de configuración externa en lugar de estar hardcodeadas, así que el comportamiento cambia sin rebuilds. El examen la prefiere porque los contenedores envían una imagen inmutable y se ajustan por entorno puramente a través de variables de entorno.
- **A7.2** Construye **dos exporters terminales** en el pipeline de esa señal (OTLP *y* console), así que cada span/metric/log se emite a ambos destinos — el equivalente por variable de entorno de agregar dos processors en el Ejercicio 4.
- **A7.3** `OTEL_SDK_DISABLED=true` convierte el SDK en un **no-op para las tres señales** — sin sampling, sin registro, sin procesamiento, sin export — deshabilitando efectivamente cada pipeline. Pensado para apagar temporalmente la telemetría (p. ej. load tests, o para acotar si la instrumentación está causando un problema) sin remover el código de instrumentación.
- **A7.4** `OTEL_BSP_SCHEDULE_DELAY` es el timer de flush del **BatchSpanProcessor**; `OTEL_METRIC_EXPORT_INTERVAL` es el intervalo de collect+export del **PeriodicExportingMetricReader**. Los traces hacen flush en segundos porque el valor de un trace es la oportunidad temporal (querés rápido los spans de una petición que falla); las métricas tienen por defecto ~60s porque son agregados periódicos donde una cadencia más gruesa reduce dramáticamente el volumen con poca pérdida de señal.

### Ejercicio 8
- **A8.1** (1) **El provider nunca se registró** — `get_tracer` devolvió un tracer no-op, así que `orphan` fue no-registrante y murió en la API antes de entrar a ningún pipeline. (2) **Sin `shutdown()`/`force_flush()`** — incluso si hubiera estado registrando, el lote encolado del `BatchSpanProcessor` se descartó al salir el proceso, muriendo en la etapa de la cola. (3) **Sin Collector en 4317** — el envío de red del exporter falló, muriendo en la etapa de export.
- **A8.2** El tap de `ConsoleSpanExporter` responde: *"¿el span se está creando y llegando a un processor siquiera?"* Si la consola muestra el span, la instrumentación y el pipeline dentro del proceso están bien y la falla está del lado del **export/transporte**; si la consola no muestra nada, la falla está **aguas arriba** (provider no registrado, tracer no-op, sampling, o el span nunca se registró).
- **A8.3** El batching mantiene los spans en memoria y hace flush sobre un timer; un programa de corta vida sale antes del primer tick del timer, así que los spans aún encolados se pierden salvo que `shutdown()`/`force_flush()` los drene. Un servidor de larga duración sigue tickeando, así que la mayoría de los lotes hacen flush durante la operación normal y la omisión queda enmascarada (solo el lote final, no vaciado, está en riesgo).
- **A8.4** Por diseño el SDK trata la telemetría como best-effort y **no debe** dejar que una falla de observabilidad haga crashear o bloquee la aplicación; los errores de export se registran internamente, no se lanzan al código del usuario. Esto protege la disponibilidad de la aplicación — un backend roto degrada tu telemetría, nunca tu servicio.

</details>

---

### Fuentes

- OpenTelemetry — Trace SDK specification: <https://opentelemetry.io/docs/specs/otel/trace/sdk/>
- OpenTelemetry — Metrics SDK specification: <https://opentelemetry.io/docs/specs/otel/metrics/sdk/>
- OpenTelemetry — Logs SDK specification: <https://opentelemetry.io/docs/specs/otel/logs/sdk/>
- OpenTelemetry — Sampling: <https://opentelemetry.io/docs/concepts/sampling/>
- OpenTelemetry — SDK environment variables: <https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/>
- OpenTelemetry — Python SDK (traces / metrics / logs): <https://opentelemetry.io/docs/languages/python/>
- CNCF — OTCA Curriculum: <https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf>