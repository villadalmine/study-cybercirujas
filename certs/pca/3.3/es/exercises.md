# PCA — Topic 3.3: Tracing and Spans
## Ejercicios guiados

> **Formato.** Cada ejercicio es una secuencia de pasos numerados que ejecutás en tu propia máquina, seguidos de una *Verificación de comprensión*. Hacé los pasos primero, respondé a partir de lo que observaste, y después abrí la sección plegable **Clave de respuestas** al final.
>
> **Prerrequisitos.** `python3.12+`, `pip` y `docker`. Creá un entorno aislado una sola vez:
> ```bash
> python3 -m venv .otel && source .otel/bin/activate
> pip install \
>   "opentelemetry-api>=1.27" \
>   "opentelemetry-sdk>=1.27" \
>   "opentelemetry-exporter-otlp-proto-grpc>=1.27"
> ```
>
> **Por qué esto forma parte de una pista de Prometheus/observabilidad.** Un trace es la tercera señal junto a las métricas y los logs; un *span* es la unidad atómica de un trace. El Ejercicio 6 cierra el ciclo de vuelta a Prometheus mediante los **exemplars**, el mecanismo estándar que vincula una muestra de métrica con el trace exacto que la produjo.

---

## Exercise 1 — Anatomía de un span individual

**Objetivo:** emitir un span a la consola y leer cada campo que la especificación requiere.

1. Creá `span01.py`:

    ```python
    from opentelemetry import trace
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import (
        ConsoleSpanExporter,
        SimpleSpanProcessor,
    )

    resource = Resource.create({"service.name": "shop-backend"})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)

    tracer = trace.get_tracer("exercise.tracer")

    with tracer.start_as_current_span("checkout") as span:
        span.set_attribute("cart.items", 3)
        span.set_attribute("cart.currency", "ARS")
    ```

2. Ejecutalo:

    ```bash
    python span01.py
    ```

3. Leé el JSON impreso en stdout. Un resultado representativo (tus IDs serán distintos en cada corrida):

    ```json
    {
        "name": "checkout",
        "context": {
            "trace_id": "0x8f2b0a1c9d4e5f60718293a4b5c6d7e8",
            "span_id": "0xa1b2c3d4e5f60718",
            "trace_state": "[]"
        },
        "kind": "SpanKind.INTERNAL",
        "parent_id": null,
        "start_time": "2026-08-08T12:00:00.000000Z",
        "end_time": "2026-08-08T12:00:00.001500Z",
        "status": {
            "status_code": "UNSET"
        },
        "attributes": {
            "cart.items": 3,
            "cart.currency": "ARS"
        },
        "events": [],
        "links": [],
        "resource": {
            "attributes": {
                "service.name": "shop-backend",
                "telemetry.sdk.language": "python",
                "telemetry.sdk.name": "opentelemetry",
                "telemetry.sdk.version": "1.27.0"
            },
            "schema_url": ""
        }
    }
    ```

4. Contá los caracteres hexadecimales en `trace_id` y en `span_id` (ignorá el prefijo `0x`).

**Verificación de comprensión**

- **Q1.1** ¿Cuántos bytes ocupan un `trace_id` y un `span_id`, y con cuántos caracteres hex se imprime cada uno?
- **Q1.2** ¿Por qué `parent_id` es igual a `null` acá?
- **Q1.3** El `status_code` es `UNSET`, no `OK`. ¿Qué significa `UNSET`, y quién se espera que lo ponga en `OK`?
- **Q1.4** `service.name` vive bajo `resource`, no bajo `attributes`. ¿Cuál es la diferencia semántica entre un *resource attribute* y un *span attribute*?

---

## Exercise 2 — Relaciones padre/hijo dentro de un mismo trace

**Objetivo:** anidar spans y demostrar que el enlace al padre y el trace ID compartido son lo que convierte spans aislados en un trace.

1. Creá `span02.py`:

    ```python
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import (
        ConsoleSpanExporter,
        SimpleSpanProcessor,
    )

    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("exercise.tracer")

    with tracer.start_as_current_span("checkout") as parent:
        with tracer.start_as_current_span("charge-card") as child:
            child.set_attribute("payment.method", "credit_card")
    ```

2. Ejecutalo y capturá la salida:

    ```bash
    python span02.py
    ```

3. Vas a ver **dos** objetos JSON. Fijate en el orden en que se imprimen.
4. Copiá estos tres valores en una nota de borrador:
   - `charge-card` → `context.span_id`
   - `charge-card` → `parent_id`
   - `checkout`    → `context.span_id`
5. Compará `checkout.trace_id` con `charge-card.trace_id`.

**Verificación de comprensión**

- **Q2.1** ¿Qué span se imprime **primero**, y por qué? (Pista: pensá en el `SimpleSpanProcessor` y en cuándo se exporta un span.)
- **Q2.2** ¿Qué campo específico de `charge-card` es igual al `span_id` de `checkout`? ¿Qué prueba eso?
- **Q2.3** ¿Comparten los dos spans el mismo `trace_id`? ¿Por qué es esa la propiedad que agrupa spans en un único trace?
- **Q2.4** Si `charge-card` hubiera lanzado una excepción no controlada, ¿se seguiría exportando `checkout`? Razoná sobre el tiempo de vida del span con los bloques `with`.

---

## Exercise 3 — Estado del span, eventos y excepciones registradas

**Objetivo:** distinguir los tres códigos de estado y ver cómo un error se adjunta a un span como un *evento*.

1. Creá `span03.py`:

    ```python
    from opentelemetry import trace
    from opentelemetry.trace import Status, StatusCode
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import (
        ConsoleSpanExporter,
        SimpleSpanProcessor,
    )

    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("exercise.tracer")

    with tracer.start_as_current_span("charge-card") as span:
        span.add_event("gateway.request.sent", {"gateway": "stripe"})
        try:
            raise RuntimeError("card declined: insufficient_funds")
        except RuntimeError as err:
            span.record_exception(err)
            span.set_status(Status(StatusCode.ERROR, "payment declined"))
    ```

2. Ejecutalo:

    ```bash
    python span03.py
    ```

3. En la salida, localizá:
   - el bloque `status`,
   - el arreglo `events` (ahora hay dos entradas).

    ```json
    "status": {
        "status_code": "ERROR",
        "description": "payment declined"
    },
    "events": [
        {
            "name": "gateway.request.sent",
            "timestamp": "2026-08-08T12:00:00.000200Z",
            "attributes": { "gateway": "stripe" }
        },
        {
            "name": "exception",
            "timestamp": "2026-08-08T12:00:00.000400Z",
            "attributes": {
                "exception.type": "RuntimeError",
                "exception.message": "card declined: insufficient_funds",
                "exception.stacktrace": "Traceback (most recent call last):\n  ...",
                "exception.escaped": "False"
            }
        }
    ]
    ```

**Verificación de comprensión**

- **Q3.1** Nombrá los tres valores de `StatusCode` e indicá cuál es el predeterminado antes de que asignes nada.
- **Q3.2** `record_exception()` **no** puso el estado en `ERROR` por sí mismo — tuviste que llamar a `set_status()`. ¿Por qué registrar una excepción y establecer el estado de error son dos acciones separadas?
- **Q3.3** ¿Cuál es el `name` del evento que produjo `record_exception()`, y qué tres atributos lleva por convención?
- **Q3.4** Un span cuyo `status_code` es `ERROR` sigue siendo un span válido y exportado. ¿Verdadero o falso? — ¿y qué te dice eso sobre cómo un backend de tracing calcula una "tasa de error"?

---

## Exercise 4 — Propagación de contexto distribuido con `traceparent` de W3C

**Objetivo:** transportar un trace a través de un límite de proceso inyectando y extrayendo el header HTTP del W3C Trace Context — el mecanismo que hace que el tracing sea *distribuido*.

1. Creá `span04_client.py` — el "llamador" que inyecta contexto en los headers de salida:

    ```python
    from opentelemetry import trace
    from opentelemetry.propagate import inject
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.trace import SpanKind

    trace.set_tracer_provider(TracerProvider())
    tracer = trace.get_tracer("exercise.tracer")

    headers = {}
    with tracer.start_as_current_span("call-payments", kind=SpanKind.CLIENT):
        inject(headers)          # writes W3C headers into the dict
        print(headers)
    ```

2. Ejecutalo y leé el header que escribió el propagador:

    ```bash
    python span04_client.py
    ```
    ```text
    {'traceparent': '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'}
    ```

3. Dividí ese valor de `traceparent` por el carácter `-`. Tiene exactamente **cuatro** campos:

    ```text
    00 - 4bf92f3577b34da6a3ce929d0e0e4736 - 00f067aa0ba902b7 - 01
    │      │                                  │                  │
    version  trace-id (16 bytes)              parent-id (8 bytes) trace-flags
    ```

4. Creá `span04_server.py` — el "llamado" que extrae el contexto y continúa el *mismo* trace:

    ```python
    from opentelemetry import trace
    from opentelemetry.propagate import extract
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import (
        ConsoleSpanExporter,
        SimpleSpanProcessor,
    )
    from opentelemetry.trace import SpanKind

    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("exercise.tracer")

    incoming = {
        "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    }
    ctx = extract(incoming)
    with tracer.start_as_current_span("handle-payment",
                                      context=ctx,
                                      kind=SpanKind.SERVER):
        pass
    ```

5. Ejecutá el lado servidor:

    ```bash
    python span04_server.py
    ```

6. En su salida, compará `context.trace_id` y `parent_id` contra el header que pasaste.

**Verificación de comprensión**

- **Q4.1** En `traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`, ¿qué significa cada uno de los cuatro campos?
- **Q4.2** El último campo es `01`. ¿Qué comportamiento único controla ese bit, y qué significaría `00` para el servicio receptor?
- **Q4.3** En `span04_server.py`, ¿cuál será el `trace_id` de `handle-payment`, y cuál será su `parent_id`? ¿De dónde salieron esos valores?
- **Q4.4** El span del cliente usó `SpanKind.CLIENT` y el span del servidor `SpanKind.SERVER`. ¿Por qué le importa el kind a un backend de tracing que renderiza la cascada (waterfall)?
- **Q4.5** Hay un header acompañante, `tracestate`. ¿Para qué sirve, y por qué se mantiene separado de `traceparent`?

---

## Exercise 5 — Muestreo head-based con `TraceIdRatioBased`

**Objetivo:** controlar el volumen de traces en el origen y entender por qué el *trace completo* se conserva o se descarta como una unidad.

1. Creá `span05.py`. Crea 20 traces raíz independientes con un ratio de muestreo del 25% y cuenta cuántos spans se registran realmente:

    ```python
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
    from opentelemetry.sdk.trace.export import (
        SpanExporter,
        SpanExportResult,
        SimpleSpanProcessor,
    )

    class CountingExporter(SpanExporter):
        def __init__(self):
            self.count = 0
        def export(self, spans):
            self.count += len(spans)
            return SpanExportResult.SUCCESS
        def shutdown(self):
            print(f"exported spans: {self.count} / 20")

    sampler = ParentBased(root=TraceIdRatioBased(0.25))
    provider = TracerProvider(sampler=sampler)
    counter = CountingExporter()
    provider.add_span_processor(SimpleSpanProcessor(counter))
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("exercise.tracer")

    for i in range(20):
        with tracer.start_as_current_span(f"request-{i}"):
            pass

    provider.shutdown()
    ```

2. Ejecutalo unas cuantas veces:

    ```bash
    python span05.py
    python span05.py
    ```
    ```text
    exported spans: 6 / 20
    exported spans: 4 / 20
    ```

3. Notá que el número fluctúa alrededor de 5 (25% de 20) pero no es exactamente 5.

**Verificación de comprensión**

- **Q5.1** El muestreo acá es *head-based*. ¿En qué momento de la vida de un trace se toma la decisión de conservar/descartar, y sobre qué entrada se calcula?
- **Q5.2** ¿Por qué el conteo exportado es ~5 pero no exactamente 5 en cada corrida?
- **Q5.3** El sampler está envuelto en `ParentBased`. Si este servicio recibe una petición cuyo `traceparent` tiene el flag de muestreo `01`, ¿se registrará el span hijo sin importar el ratio de 0.25? ¿Por qué es deseable ese comportamiento entre servicios?
- **Q5.4** Un estudiante quiere "conservar todos los traces que contengan un error". ¿Puede hacerlo el `TraceIdRatioBased` head-based? Si no, ¿qué estrategia de muestreo sí puede, y dónde se ejecuta?

---

## Exercise 6 — Enviar spans reales a Jaeger y vincular una métrica a un trace

**Objetivo:** exportar por OTLP a un backend en ejecución, ver la cascada, y conectar el trace a una métrica de Prometheus mediante un exemplar.

1. Iniciá Jaeger all-in-one con el receptor OTLP habilitado:

    ```bash
    docker run -d --name jaeger \
      -e COLLECTOR_OTLP_ENABLED=true \
      -p 16686:16686 \
      -p 4317:4317 \
      -p 4318:4318 \
      jaegertracing/all-in-one:1.60
    ```

2. Instalá el exporter de OTLP (ya está instalado si hiciste los prerrequisitos) y creá `span06.py`:

    ```python
    import time
    from opentelemetry import trace
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import (
        OTLPSpanExporter,
    )

    resource = Resource.create({"service.name": "shop-backend"})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(
        BatchSpanProcessor(
            OTLPSpanExporter(endpoint="localhost:4317", insecure=True)
        )
    )
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("exercise.tracer")

    with tracer.start_as_current_span("checkout") as parent:
        with tracer.start_as_current_span("charge-card"):
            time.sleep(0.05)
        with tracer.start_as_current_span("write-order"):
            time.sleep(0.02)

    provider.shutdown()   # flush the BatchSpanProcessor before exit
    ```

3. Ejecutalo, luego abrí la UI:

    ```bash
    python span06.py
    # Browse to http://localhost:16686
    # Service: "shop-backend"  →  Find Traces
    ```

4. Abrí el trace. Confirmá que la cascada muestra `checkout` arriba con `charge-card` y `write-order` anidados debajo, y que la barra de `charge-card` es más larga (~50 ms vs ~20 ms).
5. Anotá el **Trace ID** que se muestra en el encabezado de la UI (32 caracteres hex).
6. Ahora leé este fragmento de exposición OpenMetrics — una muestra de histograma de Prometheus que lleva un **exemplar** que apunta a exactamente uno de esos traces:

    ```text
    # TYPE http_request_duration_seconds histogram
    http_request_duration_seconds_bucket{le="0.1"} 1 # {trace_id="8f2b0a1c9d4e5f60718293a4b5c6d7e8"} 0.072 1.754e9
    ```

   Para almacenar exemplars, Prometheus debe iniciarse con el feature flag:

    ```bash
    prometheus --enable-feature=exemplar-storage
    ```

7. Desmontá todo cuando termines:

    ```bash
    docker rm -f jaeger
    ```

**Verificación de comprensión**

- **Q6.1** El script exporta con `BatchSpanProcessor`, no con `SimpleSpanProcessor`. ¿Por qué `provider.shutdown()` es esencial acá pero no en los Ejercicios 1–3?
- **Q6.2** ¿Qué puertos OTLP publicaste, y cuál es la diferencia entre `4317` y `4318`?
- **Q6.3** En la línea del exemplar, identificá las tres partes después del `#`: el conjunto de labels, el valor `0.072` y `1.754e9`. ¿Qué representa cada uno?
- **Q6.4** Explicá, en una sola oración, cómo un usuario de Grafana pasa de un pico en un panel de latencia de Prometheus al trace individual de Jaeger responsable de él.
- **Q6.5** Sin el flag `--enable-feature=exemplar-storage`, la métrica igual se scrapea bien pero el enlace se pierde. ¿Qué habilita exactamente el flag, y por qué está desactivado por defecto?

---

<details>
<summary><strong>Clave de respuestas</strong></summary>

### Exercise 1
- **A1.1** Un `trace_id` ocupa **16 bytes** (128 bits), impreso como **32 caracteres hex**; un `span_id` ocupa **8 bytes** (64 bits), impreso como **16 caracteres hex**. El `0x` es solo un prefijo de visualización. (Ver OpenTelemetry, *Traces*.)
- **A1.2** `checkout` es un **span raíz** — no tiene padre en este proceso ni contexto de trace entrante — así que su `parent_id` es `null`. Es el punto de entrada del trace.
- **A1.3** `UNSET` es el predeterminado: "no se estableció ningún estado explícito; tratar como ni éxito ni fallo". Los autores de la instrumentación normalmente lo dejan en `UNSET` y dejan que el backend infiera el éxito; `OK` se reserva para casos en que el código de la aplicación *afirma explícitamente* que la operación tuvo éxito, y `ERROR` se establece ante un fallo. Establecer `OK` está desaconsejado salvo que tengas una razón específica para anular la inferencia del backend.
- **A1.4** Un **resource attribute** describe la *entidad que produce* la telemetría (el servicio/proceso/host) y es idéntico para cada span que ese proceso emite — por ejemplo `service.name`. Un **span attribute** describe *esa única operación* (por ejemplo `cart.items`). Los resource attributes le permiten a un backend agrupar todos los spans por servicio; los span attributes te permiten filtrar dentro de un servicio.

### Exercise 2
- **A2.1** `charge-card` se imprime primero. Con `SimpleSpanProcessor`, un span se exporta en el instante en que **termina**; el bloque `with` interno se cierra antes que el externo, así que el hijo termina — y se exporta — antes que el padre.
- **A2.2** `charge-card.parent_id` es igual a `checkout.span_id`. Eso prueba que `charge-card` es un **hijo de** `checkout`: el enlace al padre es una referencia por span ID, no la contención en memoria.
- **A2.3** Sí — ambos spans llevan el **mismo `trace_id`**. Un trace se *define* como el conjunto de todos los spans que comparten un trace ID; los enlaces padre/hijo luego organizan esos spans en un árbol/DAG.
- **A2.4** Sí, `checkout` igual se exportaría. Su bloque `with` de todos modos termina (por el desenrollado de la excepción), lo cual finaliza el span; simplemente no quedaría marcado como `ERROR` salvo que capturaras la excepción y llamaras a `set_status`. La exportación del span está atada al *fin* del span, que el context manager garantiza.

### Exercise 3
- **A3.1** `UNSET` (el predeterminado), `OK` y `ERROR`. Antes de que llames a `set_status`, cada span está en `UNSET`.
- **A3.2** Responden dos preguntas distintas. `record_exception()` adjunta *detalle de diagnóstico* (tipo, mensaje, stacktrace) como un evento — útil incluso para una excepción *controlada* que no hizo fallar la operación. `set_status(ERROR)` afirma que *la operación en su conjunto falló*. Podés registrar una excepción de la que te recuperaste sin hacer fallar el span, así que el SDK mantiene las dos decisiones independientes.
- **A3.3** El evento se llama **`exception`**. Por convención lleva `exception.type`, `exception.message` y `exception.stacktrace` (más `exception.escaped`).
- **A3.4** **Verdadero.** Un span con error igual se registra y se exporta. Los backends calculan la "tasa de error" contando los spans cuyo `status_code == ERROR` contra el total — lo cual solo funciona *porque* los spans fallidos se emiten, no se descartan.

### Exercise 4
- **A4.1** `00` = **version** de la especificación Trace Context; `4bf9…4736` = **trace-id** (16 bytes / 32 hex); `00f0…02b7` = **parent-id**, es decir el span-id del span del llamador (8 bytes / 16 hex); `01` = **trace-flags**.
- **A4.2** El bit menos significativo de trace-flags es el flag **sampled**. `01` le dice al receptor "este trace fue muestreado — deberías registrar y exportar tus spans para él también". `00` significa "no muestreado"; un servicio downstream que respete la decisión del padre entonces no registraría.
- **A4.3** El `trace_id` de `handle-payment` será `4bf92f3577b34da6a3ce929d0e0e4736` y su `parent_id` será `00f067aa0ba902b7` — ambos **tomados del `traceparent` entrante** por `extract()`. Así es exactamente como el span del llamado se une al trace del llamador a través del límite de proceso.
- **A4.4** `SpanKind` le dice al backend el rol del span en una llamada remota: `CLIENT` (saliente, medido en el llamador) y `SERVER` (entrante, medido en el llamado). El par le permite a la UI ubicarlos correctamente en la cascada y calcular el tiempo de red/cola como la brecha entre el span cliente y el span servidor que envuelve.
- **A4.5** `tracestate` lleva **contexto clave-valor específico de proveedor / multi-proveedor** (por ejemplo una prioridad de muestreo o los propios IDs de un proveedor de APM) que debe sobrevivir a la propagación. Está separado de `traceparent` para que los campos de identidad obligatorios y de formato fijo nunca sean corrompidos por datos opcionales de proveedor, y para que un intermediario pueda reescribir su propia entrada de `tracestate` sin tocar la identidad del trace.

### Exercise 5
- **A5.1** La decisión es **head-based**: se toma en el momento en que **arranca el span raíz**, calculada de forma determinista a partir del **trace-id** (una prueba de hash/ratio). Cada span del trace luego hereda esa decisión.
- **A5.2** `TraceIdRatioBased(0.25)` conserva un trace cuando su trace-id cae en el 25% inferior del espacio de ids. Los trace-ids son efectivamente aleatorios, así que sobre 20 traces obtenés un resultado *binomial* centrado en 5, no exactamente 5 — la varianza es esperable con muestras pequeñas.
- **A5.3** Sí. `ParentBased` dice "si hay una decisión del padre (de un `traceparent` entrante), **respetala**; solo aplicá el ratio para spans *raíz*". Así que un `01` entrante fuerza a que el hijo se registre sin importar el `0.25`. Esto mantiene un trace distribuido **completo** — nunca terminás con un trace que fue muestreado en el servicio A pero descartado en el servicio B, lo cual produciría cascadas rotas.
- **A5.4** No — el muestreo head-based decide *antes* de que la petición se ejecute, así que no puede saber que va a ocurrir un error. "Conservar todos los traces con error" requiere **muestreo tail-based**, que almacena en buffer todos los spans de un trace y decide *después* de que se completa según su contenido (por ejemplo, cualquier span con `status == ERROR`). Se ejecuta en un collector/gateway (por ejemplo, el processor `tail_sampling` del OpenTelemetry Collector), no en el SDK de la aplicación.

### Exercise 6
- **A6.1** `BatchSpanProcessor` **almacena en buffer** los spans y los descarga de forma asíncrona en lotes; si el proceso sale antes de una descarga, los spans en buffer se pierden. `provider.shutdown()` fuerza una descarga final. Los Ejercicios 1–3 usaron `SimpleSpanProcessor`, que exporta de forma síncrona al finalizar cada span, así que no hay nada pendiente al salir.
- **A6.2** `4317` es **OTLP sobre gRPC**; `4318` es **OTLP sobre HTTP/protobuf**. El script apunta a gRPC (`localhost:4317`). Ambos se publicaron para que cualquiera de los dos transportes funcione contra este Jaeger.
- **A6.3** Después del `#`: `{trace_id="8f2b…d7e8"}` es el **conjunto de labels del exemplar** que identifica el trace; `0.072` es el **valor observado** para esa única medición (72 ms, la petición cuya latencia cayó en este bucket); `1.754e9` es la **marca de tiempo Unix** (segundos) en la que se registró el exemplar.
- **A6.4** El usuario hace clic en el marcador del exemplar en el panel de latencia de Prometheus/Grafana, que lee el label `trace_id` del exemplar y enlaza directamente a la vista de trace de Jaeger/Tempo para esa petición exacta.
- **A6.5** El flag habilita el **almacenamiento de exemplars en memoria** de Prometheus (un buffer circular separado adjunto a las series). Está desactivado por defecto porque los exemplars agregan sobrecarga de memoria y se introdujeron detrás de un feature flag; sin él, los exemplars se parsean durante el scrape pero no se retienen, así que el enlace métrica-a-trace no puede servirse a Grafana.

</details>

---

### Sources
- OpenTelemetry — *Traces / Spans* (span fields, SpanKind, status, events): https://opentelemetry.io/docs/concepts/signals/traces/
- OpenTelemetry — *Sampling*: https://opentelemetry.io/docs/concepts/sampling/
- OpenTelemetry — *Context propagation*: https://opentelemetry.io/docs/concepts/context-propagation/
- W3C — *Trace Context* (`traceparent` / `tracestate` format): https://www.w3.org/TR/trace-context/
- Jaeger — *Getting Started / all-in-one, OTLP*: https://www.jaegertracing.io/docs/latest/getting-started/
- Prometheus — *Exemplars* (OpenMetrics exemplar syntax, `exemplar-storage` feature flag): https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- CNCF — *PCA Curriculum*: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf