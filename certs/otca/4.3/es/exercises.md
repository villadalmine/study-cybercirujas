# OTCA Dominio 4 · Tema 4.3 — Manejo de errores

**Ejercicios de laboratorio guiados (nivel producción)**

> Estos ejercicios corresponden al Dominio 4 de OTCA, *Maintaining and Debugging Observability Pipelines*. Aquí, «manejo de errores» se refiere a la semántica de fallos de la **ruta de exportación de telemetría**: cómo el OpenTelemetry Protocol (OTLP) clasifica los fallos, cómo el `exporterhelper` del Collector reintenta y encola, cómo la contrapresión (backpressure) se propaga aguas arriba, y cómo registrás y observás los descartes. El ejercicio final cubre el *otro* significado de manejo de errores: registrar errores de la aplicación como telemetría.
>
> **Fuentes de referencia**
> - Semántica de fallos y éxito parcial de OTLP — https://opentelemetry.io/docs/specs/otlp/#failures
> - `exporterhelper` (cola + reintento) — https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
> - Extensión `file_storage` (cola persistente) — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/storage/filestorage
> - Procesador `memory_limiter` — https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
> - Telemetría interna del Collector — https://opentelemetry.io/docs/collector/internal-telemetry/
> - Convenciones semánticas de excepciones — https://opentelemetry.io/docs/specs/semconv/exceptions/

### Prerrequisitos del laboratorio

- Un host Linux con Docker (los ejemplos usan `--network host`, que requiere Linux).
- La imagen Collector Contrib: `otel/opentelemetry-collector-contrib:latest`.
- Un generador de carga: `telemetrygen` (distribuido como imagen contrib, sin necesidad de compilar localmente).

```bash
# Pull once
docker pull otel/opentelemetry-collector-contrib:latest
docker pull ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest

# Helper alias used throughout (10 traces over gRPC to a local Collector)
gen() { docker run --rm --network host \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-endpoint localhost:4317 --otlp-insecure --traces "${1:-10}"; }
```

> Las métricas de tipo counter obtenidas de `:8888/metrics` pueden llevar un sufijo `_total` según la versión de tu Collector (p. ej. `otelcol_exporter_send_failed_spans` vs `..._total`). Hacé grep sobre la raíz mostrada en cada ejercicio.

---

## Ejercicio 1 — Fallos reintentables y backoff exponencial

**Objetivo:** observar qué hace el Collector cuando el backend aguas abajo es inalcanzable (un error de transporte *reintentable*) y cómo `retry_on_failure` gobierna el backoff y el descarte final.

1. Creá `ex1.yaml`. El exporter `otlp` apunta al puerto `4999`, donde **no hay nada escuchando**, así que cada exportación recibe `connection refused` (mapeado a gRPC `UNAVAILABLE`, un código reintentable). `debug` demuestra que los datos llegan al pipeline.

    ```yaml
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    exporters:
      debug:
        verbosity: normal
      otlp:
        endpoint: localhost:4999
        tls:
          insecure: true
        # retry_on_failure is ON by default; shown here explicitly with tight values
        retry_on_failure:
          enabled: true
          initial_interval: 2s
          max_interval: 6s
          max_elapsed_time: 20s
    service:
      telemetry:
        metrics:
          level: detailed
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [debug, otlp]
    ```

2. Iniciá el Collector en primer plano para poder leer sus logs:

    ```bash
    docker run --rm --name otc --network host \
      -v "$(pwd)/ex1.yaml:/etc/otelcol-contrib/config.yaml" \
      otel/opentelemetry-collector-contrib:latest
    ```

3. En una segunda terminal, enviá trazas y observá la primera terminal:

    ```bash
    gen 10
    ```

4. Leé las líneas de log de reintento. Vas a ver advertencias repetidas con un `interval` creciente, y luego un descarte final después de ~20s:

    ```text
    warn  internal/retry_sender.go  Exporting failed. Will retry the request after interval.
      {"kind":"exporter","data_type":"traces","name":"otlp",
       "error":"rpc error: code = Unavailable desc = ... connection refused",
       "interval":"2.31s"}
    warn  ... "interval":"3.7s"}
    warn  ... "interval":"5.9s"}
    error internal/queue_sender.go  Exporting failed. Dropping data.
      {"kind":"exporter","data_type":"traces","name":"otlp",
       "error":"no more retries left: rpc error: code = Unavailable ...",
       "dropped_items":20}
    ```

5. En una tercera terminal, obtené las métricas de autoobservabilidad:

    ```bash
    curl -s localhost:8888/metrics | grep -E 'otelcol_exporter_(sent|send_failed)_spans'
    ```

    ```text
    otelcol_exporter_send_failed_spans{exporter="otlp",...} 20
    otelcol_exporter_sent_spans{exporter="otlp",...} 0
    otelcol_exporter_sent_spans{exporter="debug",...} 20
    ```

**Comprobación de comprensión**

- **Q1.1** ¿Por qué `connection refused` se trata como *reintentable* mientras que un `400 Bad Request` no lo sería?
- **Q1.2** Con `initial_interval: 2s`, `max_interval: 6s`, `max_elapsed_time: 20s`, ¿por qué los intervalos crecen pero se topan en ~6s, y qué evento termina el bucle de reintentos?
- **Q1.3** `debug` informa 20 spans enviados pero `otlp` informa 20 *fallidos*. ¿Por qué el fallo de un exporter no impidió que el otro tuviera éxito?
- **Q1.4** Un colega configura `max_elapsed_time: 0` «para ir a lo seguro». ¿Cuál es el riesgo en producción de ese valor?

---

## Ejercicio 2 — La cola de envío y la contrapresión

**Objetivo:** entender que los reintentos ocurren *detrás de una cola*, y qué hace la cola cuando se llena.

1. Creá `ex2.yaml`. El backend sigue caído, pero ahora los reintentos nunca se rinden (`max_elapsed_time: 0`) y la cola es deliberadamente diminuta para que se sature:

    ```yaml
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    exporters:
      otlp:
        endpoint: localhost:4999
        tls:
          insecure: true
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_elapsed_time: 0        # retry forever -> items stay in the queue
        sending_queue:
          enabled: true
          num_consumers: 1
          queue_size: 2              # deliberately tiny
    service:
      telemetry:
        metrics:
          level: detailed
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [otlp]
    ```

2. Iniciálo (el mismo `docker run` del Ejercicio 1, cambiando el archivo), luego inundálo más rápido de lo que el único consumidor (atascado) puede drenar:

    ```bash
    for i in 1 2 3 4 5; do gen 5 & done; wait
    ```

3. Prestá atención a los logs de fallo de encolado y obtené las métricas de la cola:

    ```bash
    curl -s localhost:8888/metrics | grep -E 'otelcol_exporter_(queue_size|queue_capacity|enqueue_failed_spans)'
    ```

    ```text
    otelcol_exporter_queue_size{exporter="otlp",...} 2
    otelcol_exporter_queue_capacity{exporter="otlp",...} 2
    otelcol_exporter_enqueue_failed_spans{exporter="otlp",...} 55
    ```

    Log del Collector cuando la cola está llena:

    ```text
    error exporterhelper/queue_sender.go  Exporting failed. Rejecting data.
      {"kind":"exporter","data_type":"traces","name":"otlp",
       "error":"sending queue is full","dropped_items":5}
    ```

**Comprobación de comprensión**

- **Q2.1** Se están descartando datos, pero `otelcol_exporter_send_failed_spans` puede permanecer en 0 mientras `otelcol_exporter_enqueue_failed_spans` sube. ¿Cuál es la diferencia entre estos dos contadores de descarte?
- **Q2.2** La cola está llena porque el único consumidor está bloqueado reintentando por siempre contra un backend caído. Nombrá **dos** cambios de configuración distintos que aliviarían esto, y el compromiso (trade-off) de cada uno.
- **Q2.3** Cuando la cola de envío rechaza datos, el *receiver* OTLP devuelve un error al cliente aguas arriba. ¿Ese error es reintentable o permanente, y cuál es el comportamiento deseado del cliente?
- **Q2.4** ¿Por qué una inundación persistente sumada a `max_elapsed_time: 0` crea un modo de fallo peor que `max_elapsed_time: 300s`?

---

## Ejercicio 3 — Cola persistente (sobrevivir a reinicios)

**Objetivo:** hacer que la cola de envío sea duradera con la extensión `file_storage` para que la telemetría en búfer sobreviva a un reinicio del Collector.

1. Prepará un directorio escribible en el host para el respaldo en disco de la cola:

    ```bash
    mkdir -p otc-storage && chmod 777 otc-storage
    ```

2. Creá `ex3.yaml`. Fijate en la referencia `storage:` dentro de `sending_queue` y en la extensión en `service.extensions`:

    ```yaml
    extensions:
      file_storage/queue:
        directory: /storage
        timeout: 1s
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    exporters:
      otlp:
        endpoint: localhost:4999      # still down for now
        tls:
          insecure: true
        retry_on_failure:
          enabled: true
          max_elapsed_time: 0
        sending_queue:
          enabled: true
          queue_size: 1000
          storage: file_storage/queue   # <-- persistent, disk-backed queue
    service:
      extensions: [file_storage/queue]
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [otlp]
    ```

3. Iniciá el Collector con el volumen de almacenamiento montado:

    ```bash
    docker run --rm --name otc --network host \
      -v "$(pwd)/ex3.yaml:/etc/otelcol-contrib/config.yaml" \
      -v "$(pwd)/otc-storage:/storage" \
      otel/opentelemetry-collector-contrib:latest
    ```

4. Enviá trazas mientras el backend está caído, confirmá que la cola tiene datos en disco, y luego **matá el Collector** (Ctrl-C):

    ```bash
    gen 10
    ls -la otc-storage/     # a bbolt DB file is present
    ```

5. Levantá un backend real en el puerto `4999` (un segundo Collector que solo imprime), luego reiniciá el primer Collector contra el *mismo* volumen de almacenamiento:

    ```bash
    # Terminal A: a backend that accepts OTLP on 4999 and prints
    cat > sink.yaml <<'EOF'
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4999
    exporters:
      debug:
        verbosity: normal
    service:
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [debug]
    EOF
    docker run --rm --network host \
      -v "$(pwd)/sink.yaml:/etc/otelcol-contrib/config.yaml" \
      otel/opentelemetry-collector-contrib:latest
    ```

    ```bash
    # Terminal B: restart the ORIGINAL collector; it re-reads the persisted queue
    docker run --rm --name otc --network host \
      -v "$(pwd)/ex3.yaml:/etc/otelcol-contrib/config.yaml" \
      -v "$(pwd)/otc-storage:/storage" \
      otel/opentelemetry-collector-contrib:latest
    ```

6. Observá en la **Terminal A** que las 10 trazas que enviaste *antes del crash* ahora se entregan: fueron reproducidas desde el disco.

**Comprobación de comprensión**

- **Q3.1** Repetí este ejercicio mentalmente *sin* la referencia `storage:`. ¿Qué les pasa a las 10 trazas en búfer cuando se mata el Collector, y por qué?
- **Q3.2** Los datos persistidos viven en un archivo bbolt dentro del volumen montado. ¿Qué debe cumplirse respecto de esa ruta para que la garantía de durabilidad se sostenga en Kubernetes?
- **Q3.3** Una cola persistente con `queue_size: 1000` igual tiene un límite. Dá un escenario donde incluso la cola persistente descarta datos, y cómo lo detectarías.
- **Q3.4** ¿Por qué la cola persistente protege contra los reinicios del Collector pero **no** contra la pérdida del disco del host?

---

## Ejercicio 4 — Errores permanentes vs. éxito parcial

**Objetivo:** distinguir un fallo *permanente* (no reintentable) de uno *reintentable*, y entender el **éxito parcial** de OTLP. Reintentar un error permanente desperdicia recursos y nunca tiene éxito.

1. Iniciá un backend simulado (mock) que responde cada POST OTLP/HTTP con `400 Bad Request` (un error permanente):

    ```bash
    python3 - <<'EOF'
    from http.server import BaseHTTPRequestHandler, HTTPServer
    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            self.send_response(400)
            self.send_header('Content-Length', '0')
            self.end_headers()
        def log_message(self, *a): pass
    print("mock OTLP/HTTP backend returning 400 on :4318")
    HTTPServer(('0.0.0.0', 4318), H).serve_forever()
    EOF
    ```

2. Creá `ex4.yaml` usando el exporter **HTTP** apuntando al mock, con el reintento habilitado:

    ```yaml
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    exporters:
      otlphttp:
        endpoint: http://localhost:4318
        retry_on_failure:
          enabled: true
          initial_interval: 2s
          max_elapsed_time: 20s
    service:
      telemetry:
        metrics:
          level: detailed
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [otlphttp]
    ```

3. Iniciá el Collector (montá `ex4.yaml`) y enviá trazas:

    ```bash
    gen 10
    ```

4. Leé el log del Collector. A diferencia del Ejercicio 1, **no hay bucle de reintentos**: el lote se descarta de inmediato:

    ```text
    error exporterhelper/common.go  Exporting failed. Rejecting data.
      Try enabling sending_queue to survive temporary failures.
      {"kind":"exporter","data_type":"traces","name":"otlphttp",
       "error":"not retryable error: Permanent error: rpc error: code = ...
                error exporting items, request to http://localhost:4318/v1/traces
                responded with HTTP Status Code 400",
       "dropped_items":10}
    ```

5. Confirmá vía métricas que estos cuentan como fallos de envío, y que no se intentó ningún reintento (el descarte es inmediato):

    ```bash
    curl -s localhost:8888/metrics | grep -E 'otelcol_exporter_send_failed_spans'
    ```

6. **Paso de razonamiento (éxito parcial):** ahora considerá un backend que devuelve HTTP `200` pero con un cuerpo OTLP de `{"partialSuccess":{"rejectedSpans":"3","errorMessage":"3 spans rejected: missing service.name"}}`. Leé la sección de la especificación OTLP sobre éxito parcial y predecí el comportamiento del Collector antes de mirar la respuesta.

**Comprobación de comprensión**

- **Q4.1** ¿Por qué OTLP prohíbe que el cliente reintente un `400`/`INVALID_ARGUMENT`, aunque los datos genuinamente no se entregaron?
- **Q4.2** Enumerá los códigos de estado HTTP que OTLP define como reintentables, y los códigos de estado gRPC que define como reintentables. ¿Cuál código es *condicionalmente* reintentable, y ante qué señal?
- **Q4.3** En **éxito parcial**, el servidor devuelve `200 OK` *y* un conteo `rejectedSpans`. ¿Debería el cliente reintentar los spans rechazados? ¿Qué se espera que haga en su lugar?
- **Q4.4** Un backend que aplica throttling devuelve `429` con un header `Retry-After: 30` (o gRPC `RESOURCE_EXHAUSTED` + `RetryInfo`). ¿Cómo debe tratar un cliente conforme ese header/campo, y por qué es peligroso ignorarlo?

---

## Ejercicio 5 — Contrapresión aguas arriba con `memory_limiter`

**Objetivo:** ver cómo un Collector bajo presión de memoria *rechaza* datos y empuja la contrapresión hacia sus clientes en lugar de ser terminado por OOM.

1. Creá `ex5.yaml`. `memory_limiter` es el **primer** procesador; los límites se fijan absurdamente bajos para disparar el rechazo rápidamente:

    ```yaml
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 20            # hard limit (tiny, for the demo)
        spike_limit_mib: 5       # soft limit = 20 - 5 = 15 MiB
      batch: {}
    exporters:
      debug:
        verbosity: normal
    service:
      telemetry:
        metrics:
          level: detailed
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]   # memory_limiter FIRST
          exporters: [debug]
    ```

2. Iniciálo, luego martillalo lo suficientemente fuerte como para cruzar el límite blando:

    ```bash
    for i in $(seq 1 8); do gen 20000 & done; wait
    ```

3. Prestá atención a los logs de rechazo y obtené el contador de rechazos:

    ```text
    warn  memorylimiter/memorylimiter.go  Memory usage is above soft limit.
      Refusing data.  {"cur_mem_mib": 16}
    ```

    ```bash
    curl -s localhost:8888/metrics | grep -E 'otelcol_processor_refused_spans'
    ```

    ```text
    otelcol_processor_refused_spans{processor="memory_limiter",...} 43120
    ```

4. Del **lado del cliente**, `telemetrygen` registra errores de exportación: el receiver respondió con un error reintentable, así que un cliente bien comportado hace backoff y reintenta:

    ```text
    traces  failed to export ... rpc error: code = Unavailable
            desc = data refused due to high memory usage
    ```

**Comprobación de comprensión**

- **Q5.1** ¿Por qué `memory_limiter` debe ser el *primer* procesador del pipeline? ¿Qué se rompe si ponés `batch` antes que él?
- **Q5.2** Explicá los dos umbrales: qué pasa entre el límite blando (`limit_mib - spike_limit_mib`) y el límite duro, y qué pasa en/por encima del límite duro.
- **Q5.3** Cuando `memory_limiter` rechaza datos, el receiver OTLP devuelve un error *reintentable* al cliente. Trazá la cadena completa de lo que hace a continuación un cliente SDK conforme. ¿Por qué «rechazar y dejar que el cliente reintente» es mejor que descartar en silencio?
- **Q5.4** `memory_limiter` protege a un Collector del OOM pero puede crear una tormenta de reintentos entre muchos clientes. ¿Qué otros dos mecanismos de este tema lo complementan para absorber esa presión en lugar de rebotarla de vuelta?

---

## Ejercicio 6 — Registrar errores de la aplicación como telemetría

**Objetivo:** el lado productor del manejo de errores. El código instrumentado debe *registrar* los fallos para que el pipeline tenga algo que transportar: fijar el **status** del span en `ERROR` y adjuntar un **evento de excepción** siguiendo las convenciones semánticas.

1. Estudiá esta instrumentación en Python (el patrón es idéntico en todos los lenguajes). Registra una excepción y marca el span como fallido:

    ```python
    from opentelemetry import trace
    from opentelemetry.trace import Status, StatusCode

    tracer = trace.get_tracer("checkout")

    def charge(order):
        with tracer.start_as_current_span("charge_card") as span:
            try:
                do_charge(order)                 # raises on failure
            except PaymentDeclined as exc:
                span.record_exception(exc)        # -> "exception" event
                span.set_status(Status(StatusCode.ERROR, "payment declined"))
                raise
    ```

2. Predecí el span resultante antes de ejecutar nada: llevará `status.code = ERROR` y un evento llamado `exception` con estos atributos:

    ```text
    span "charge_card"
      status:  ERROR  ("payment declined")
      event "exception"
        exception.type:       PaymentDeclined
        exception.message:    card 4111... declined by issuer
        exception.stacktrace: Traceback (most recent call last): ...
    ```

3. Contrastá con el *comportamiento por defecto*: un span cuyo camino de código lanzó una excepción pero donde te olvidaste de `set_status`. Su status permanece `UNSET`: los dashboards de tasa de errores aguas abajo **subcontarán** el fallo.

**Comprobación de comprensión**

- **Q6.1** ¿Cuál es la diferencia entre `span.record_exception()` y `span.set_status(ERROR)`? ¿Por qué normalmente necesitás ambos, y qué alimenta cada uno?
- **Q6.2** Los tres códigos de status canónicos de un span son `UNSET`, `OK`, `ERROR`. ¿Por qué la especificación dice que la instrumentación *raramente* debería fijar `OK`, y dejar los spans exitosos en `UNSET`?
- **Q6.3** Nombrá los atributos estándar que lleva un evento `exception`, y por qué usar exactamente esas claves (en lugar de unas personalizadas) importa para un backend.
- **Q6.4** Esta es una capa *diferente* de «manejo de errores» respecto de los Ejercicios 1–5. En una oración, distinguí un error de la aplicación registrado en un span de un error de exportación del pipeline manejado por `exporterhelper`.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.1** `connection refused` es una condición *de nivel de transporte y transitoria* —el destino puede estar simplemente reiniciándose o brevemente inalcanzable—, así que un reintento puede plausiblemente tener éxito. Se mapea a gRPC `UNAVAILABLE`, que OTLP lista como reintentable. Un `400 Bad Request` / `INVALID_ARGUMENT` significa que el *payload en sí* es inaceptable (malformado, esquema incorrecto, demasiado grande, faltan campos requeridos). Reenviar bytes idénticos fallará de forma idéntica por siempre, así que OTLP lo clasifica como permanente y el cliente no debe reintentar.

**A1.2** `exporterhelper` usa backoff exponencial: cada intervalo ≈ anterior × `multiplier` (por defecto 1.5) más jitter (`randomization_factor`, por defecto 0.5), acotado a `max_interval`; de ahí que los intervalos crezcan 2s → ~3s → ~6s y luego dejen de crecer. El bucle termina cuando el tiempo acumulado de reintentos supera `max_elapsed_time` (20s acá); en ese punto el ítem se descarta, se registra como `Dropping data`, y se incrementa `otelcol_exporter_send_failed_spans`.

**A1.3** Cada exporter de un pipeline se maneja de forma independiente a través de su propio `exporterhelper` (su propio estado de cola/reintentos). Un fan-out a `[debug, otlp]` envía el mismo lote a ambos; `debug` escribe en stdout y tiene éxito de inmediato, mientras que `otlp` falla y reintenta por su cuenta. El fallo de un exporter no revierte ni bloquea el éxito de otro.

**A1.4** `max_elapsed_time: 0` significa *reintentar por siempre*. Con un backend persistentemente inalcanzable, los ítems nunca se liberan; se acumulan detrás de la cola de envío hasta que se llena, momento en el cual el Collector empieza a rechazar datos nuevos en el receiver (Ejercicio 2). Convierte un descarte acotado y observable en un backlog no acotado y contrapresión en cascada. Usá un valor finito a menos que combines `0` con una cola **persistente** y planificación de capacidad.

### Ejercicio 2

**A2.1** `enqueue_failed_spans` cuenta los datos rechazados **en la puerta de entrada**: el ítem nunca entró a la cola porque estaba llena, así que se descartó antes de cualquier intento de exportación. `send_failed_spans` cuenta los datos que *sí* fueron desencolados y entregados al exporter pero no lograron enviarse tras agotar los reintentos. Cola llena ⇒ sube `enqueue_failed`; backend caído con una cola que drena ⇒ sube `send_failed`.

**A2.2** Dos cualesquiera de: (a) aumentar `num_consumers`: más emisores paralelos drenan la cola más rápido, a costa de más carga/conexiones concurrentes sobre el backend; (b) aumentar `queue_size`: absorber cortes más largos, a costa de más memoria (o disco, si es persistente); (c) fijar un `max_elapsed_time` finito: dejar de atascar a un consumidor en una petición sin esperanza para que pueda pasar al siguiente ítem, a costa de descartar datos antes durante cortes reales; (d) habilitar una cola persistente para cambiar presión de RAM por disco.

**A2.3** Cuando la cola de envío está llena, el receiver devuelve un error **reintentable** al cliente aguas arriba (p. ej. gRPC `UNAVAILABLE` / HTTP `503`). El comportamiento deseado es que el cliente haga backoff y reintente más tarde: la contrapresión se propaga hacia la fuente en lugar de descartar datos en silencio en el borde.

**A2.4** Con `max_elapsed_time: 300s`, los ítems atascados finalmente se liberan (se descartan) y el único consumidor se libera para procesar el siguiente lote, así que la cola sigue circulando. Con `max_elapsed_time: 0`, el consumidor queda clavado por siempre en la primera petición inalcanzable; la cola nunca puede drenar, se llena permanentemente, y *todos* los lotes subsiguientes son rechazados en el receiver: un corte total y autoinfligido en vez de una pérdida parcial.

### Ejercicio 3

**A3.1** Sin `storage:`, la cola de envío es **solo en memoria**. Matar el proceso descarta la RAM, así que las 10 trazas en búfer se pierden sin registro alguno: la cola arranca vacía al reiniciar. La persistencia es lo que permite que los ítems en búfer sobrevivan al proceso.

**A3.2** El `directory` debe estar respaldado por almacenamiento duradero e independiente del nodo que se vuelva a adjuntar a la *misma* instancia del Collector tras un reinicio, es decir, un `PersistentVolumeClaim`, no un `emptyDir` (que se elimina junto con el pod) ni la capa efímera del contenedor. También debe ser escribible por el UID del Collector y, dado que bbolt toma un lock de archivo, montarse como `ReadWriteOnce` en una única réplica.

**A3.3** Si el backend está caído el tiempo suficiente (o el throughput es lo bastante alto) como para que los ítems en búfer superen `queue_size: 1000`, los ítems nuevos se rechazan en el encolado: la persistencia acota la durabilidad, no la capacidad. Detectálo por `otelcol_exporter_enqueue_failed_spans` subiendo y `otelcol_exporter_queue_size` clavado en `otelcol_exporter_queue_capacity`.

**A3.4** La garantía de la cola persistente es solo tan fuerte como el disco en el que escribe. Un reinicio vuelve a leer ese disco, así que los datos en búfer sobreviven. Pero si el volumen mismo se destruye (pérdida del nodo con un `emptyDir`, PVC eliminado, fallo de disco), el archivo bbolt desaparece y la telemetría en búfer es irrecuperable: la durabilidad está acotada a la durabilidad propia del medio de almacenamiento.

### Ejercicio 4

**A4.1** Un `400`/`INVALID_ARGUMENT` informa que el *contenido de la petición* es inaceptable: proto malformado, violación de esquema, campos requeridos faltantes, o tamaño excesivo. Nada respecto de reenviar los bytes idénticos cambia el resultado, así que reintentar solo quema CPU, red y cuota mientras garantiza el mismo rechazo. OTLP lo marca como permanente para que los clientes fallen rápido y expongan un bug/error de configuración real en lugar de ocultarlo detrás de reintentos infinitos.

**A4.2** **HTTP** reintentables: `429 Too Many Requests`, `502 Bad Gateway`, `503 Service Unavailable`, `504 Gateway Timeout`. **gRPC** reintentables: `CANCELLED`, `DEADLINE_EXCEEDED`, `ABORTED`, `OUT_OF_RANGE`, `UNAVAILABLE`, `DATA_LOSS`. El código condicionalmente reintentable es gRPC `RESOURCE_EXHAUSTED`: reintentálo **solo** cuando el servidor señale que la recuperación es posible devolviendo un `RetryInfo` en el status; de lo contrario, tratálo como permanente.

**A4.3** No: el éxito parcial significa que el servidor rechazó *definitivamente* esos `rejectedSpans` (p. ej. datos inválidos); son no reintentables por definición. El resto fue aceptado. El cliente **no** debe reenviar los ítems rechazados; debería registrar/emitir una advertencia (exponiendo `errorMessage`) para que un operador pueda corregir los datos de origen. Un `200` con `rejectedSpans: 0` y un mensaje no vacío es una advertencia pura.

**A4.4** El cliente debe **respetar la demora**: esperar al menos `Retry-After` segundos (HTTP) o el `RetryInfo.retry_delay` (gRPC) antes del siguiente intento. Ignorarlo y reintentar de inmediato amplifica la carga sobre un backend ya sobrecargado, convirtiendo el throttling en una sobrecarga autorreforzada (tormenta de reintentos) que puede mantener el backend caído y hacer que al cliente se le aplique rate limiting o se lo banee.

### Ejercicio 5

**A5.1** `memory_limiter` debe ejecutarse primero para poder rechazar datos en el punto más temprano posible, antes de que otros procesadores asignen memoria reteniéndolos/copiándolos. Si `batch` corre primero, los lotes acumulan telemetría en memoria *por delante de* la protección del limiter, así que el mismísimo crecimiento que el limiter existe para prevenir ocurre antes de que pueda actuar, anulando la protección y arriesgando un OOM.

**A5.2** Entre el límite blando (`limit_mib − spike_limit_mib`) y el límite duro, el procesador entra en un estado de «rechazo»: fuerza la recolección de basura y rechaza los datos entrantes (devolviendo errores aguas arriba) para hacer bajar la memoria. En/por encima del límite duro (`limit_mib`) rechaza duramente todos los datos. El margen para picos (spike headroom) existe porque la memoria puede saltar entre los intervalos de chequeo de 1s; rechazar *antes* del techo duro deja espacio para absorber ese pico sin una terminación por OOM.

**A5.3** La cadena: `memory_limiter` rechaza el lote → el receiver OTLP traduce eso en una respuesta reintentable (gRPC `UNAVAILABLE` / HTTP `503`) → el exporter del cliente ve un error reintentable → mantiene los datos en su propia cola y reintenta con backoff más tarde. Es mejor que descartar en silencio porque los datos se preservan en la fuente y se entregan una vez que la presión cede, y el fallo es visible/observable en lugar de perderse: la contrapresión es una señal, un descarte silencioso es pérdida de datos.

**A5.4** Una **cola de envío persistente** en los clientes (y/o un Collector intermediario) absorbe los datos rechazados en disco en lugar de rebotarlos, y el **reintento finito con backoff exponencial + jitter** distribuye los reintentos para que miles de clientes no reenvíen al unísono. Juntos convierten «rechazar y reintentar de inmediato» en «almacenar en búfer de forma duradera y reintentar gradualmente», previniendo la tormenta de reintentos.

### Ejercicio 6

**A6.1** `record_exception()` adjunta al span un **evento** llamado `exception`, capturando tipo/mensaje/stacktrace: es detalle diagnóstico sobre *qué* salió mal. `set_status(ERROR)` marca el **resultado del span** como fallido, que es de lo que dependen las métricas de tasa de errores, las decisiones de muestreo y el resaltado de error/rojo. Normalmente necesitás ambos: el evento le da a una persona el stack trace; el status hace que el fallo cuente en los agregados. Registrar una excepción **no** fija automáticamente el status.

**A6.2** La convención es que los spans son exitosos salvo prueba en contrario, así que dejar un span sano en `UNSET` es la norma y los backends interpretan `UNSET` como «no es un error». `OK` se reserva para los casos en que una aplicación quiere *explícitamente* anular cualquier inferencia y afirmar el éxito (p. ej. un 4xx que es esperado/manejado y no debería contar como error). Fijar `OK` de forma rutinaria no agrega información y puede impedir que un backend o una instrumentación posterior marque correctamente un fallo.

**A6.3** El evento `exception` lleva `exception.type`, `exception.message`, `exception.stacktrace`, y opcionalmente `exception.escaped` (si la excepción se propagó fuera del alcance del span). Usar exactamente estas claves de convención semántica significa que cualquier backend conforme puede agrupar por tipo de excepción, renderizar el stack trace y construir dashboards de errores sin parsing personalizado por lenguaje o por aplicación: la interoperabilidad es el propósito mismo de las convenciones semánticas.

**A6.4** Un error de la aplicación registrado en un span (status `ERROR` + evento `exception`) es telemetría que describe que *la carga de trabajo observada* falló y es *contenido* a entregar; un error de exportación del pipeline manejado por `exporterhelper` es un fallo de *la entrega de la telemetría misma*, manejado con reintento/cola/contrapresión: el payload frente al transporte de ese payload.

</details>