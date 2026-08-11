# 4.3 Manejo de Errores

> **Dominio 4 — Mantenimiento y Depuración de OpenTelemetry** · Peso en el examen: **2.5%**
> OpenTelemetry Certified Associate (OTCA)

---

## 1. Motivación — el contrato de "no hacer daño"

La restricción arquitectónica que define un pipeline de telemetría es asimétrica: el sistema de observabilidad existe para informar sobre la salud del sistema objetivo, por lo que **nunca debe convertirse en el motivo por el cual el sistema objetivo falla.** Un SDK de tracing que lanza una excepción no manejada ante un span malformado, un exporter que bloquea el hilo de la request mientras un backend está caído, o un Collector que agota la memoria del nodo durante un pico de tráfico — cada uno de estos convierte tu capa de diagnóstico en la caída del servicio.

OpenTelemetry codifica esto en su **especificación de Error Handling**. Dos principios impulsan cada decisión de diseño que sigue a continuación:

1. **La API y el SDK no deben lanzar excepciones de runtime hacia el código del usuario.** Los errores se manejan internamente y se exponen a través de un canal de *autodiagnóstico* (un error handler + logs internos), nunca se propagan al call site instrumentado. El crasheo fail-fast se permite *solo* en el momento de la inicialización, nunca durante la operación en estado estable.
2. **La pérdida de datos es preferible a una backpressure que dañe la aplicación.** Cuando el pipeline no puede seguir el ritmo, el comportamiento de último recurso es descartar telemetría — pero debe descartarla de forma *observable* (los contadores se incrementan), nunca en silencio.

El manejo de errores en OpenTelemetry no es, por lo tanto, una sola funcionalidad; es un conjunto de comportamientos estratificados a lo largo de cinco fronteras. Este es el modelo mental que debés llevar a producción y al examen:

| Capa | Frontera | Falla que absorbe | Mecanismo primario |
|---|---|---|---|
| **API** | app ↔ instrumentación | Bug en la instrumentación, SDK no inicializado | Implementación no-op, nunca lanza |
| **Autodiagnóstico del SDK** | internos del SDK ↔ operador | Errores de export, problemas de config | **Error Handler** global + logger interno (`OTEL_LOG_LEVEL`) |
| **Modelo de señal/datos** | código ↔ datos de trace | Errores de negocio/runtime en la operación traceada | `Span.SetStatus(Error)` + `Span.RecordException()` |
| **Export del SDK** | SDK ↔ red | Indisponibilidad transitoria del backend | Cola de `BatchSpanProcessor` + retry/backoff de OTLP |
| **Pipeline del Collector** | receiver → processor → exporter | Caída del backend, presión de memoria, datos venenosos | `retry_on_failure`, `sending_queue`, `memory_limiter`, clasificación de errores permanente-vs-transitorio |

El resto de este tema recorre cada capa con configuración de nivel productivo.

---

## 2. Capa 1–2: seguridad de la API y el Error Handler del SDK

### 2.1 La API nunca lanza

Por especificación, llamar a la API antes de que un SDK esté instalado devuelve implementaciones **no-op**. Un `Tracer` del provider global sin SDK produce spans que no graban (non-recording); cada método es un stub seguro. Por esto las bibliotecas de instrumentación pueden llamar a la API incondicionalmente sin protegerse contra "¿está OpenTelemetry configurado?" — el modo de falla de un sistema no configurado es *silencio*, no un crash.

### 2.2 El Error Handler global (autodiagnóstico)

Cuando el SDK mismo se topa con un problema que no puede exponer al llamador — el caso clásico siendo un **exporter que falló al enviar un batch** — enruta el error a un handler configurable en lugar de lanzarlo. En Go:

```go
package main

import (
	"go.opentelemetry.io/otel"
)

// Custom handler: count SDK-internal errors so they become a metric,
// and rate-limit logging so a dead backend doesn't flood stderr.
func init() {
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		sdkInternalErrors.Add(1) // your own metric
		limitedLog.Printf("otel-sdk: %v", err)
	}))
}
```

Las perillas equivalentes en los distintos lenguajes:

| Lenguaje | Superficie de error | Control de verbosidad |
|---|---|---|
| Go | `otel.SetErrorHandler()` | — |
| Java | `io.opentelemetry` vía `java.util.logging` | Nivel de JUL en el logger de OTel |
| Python | módulo `logging`, logger `opentelemetry` | nivel estándar de `logging` |
| Node.js | API `diag` — `diag.setLogger()` | `DiagLogLevel` / `OTEL_LOG_LEVEL` |
| .NET | `EventSource` `OpenTelemetry-*` | `OTEL_LOG_LEVEL` |

La variable de entorno universal es **`OTEL_LOG_LEVEL`** (`error` | `warn` | `info` | `debug`). En producción la mantenés en `error` o `warn`; la subís a `debug` solo mientras diagnosticás, porque una falla de exporter charlatana en `debug` puede convertirse ella misma en un problema de carga.

```console
$ OTEL_LOG_LEVEL=debug OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317 ./app
opentelemetry: exporter connecting to http://collector:4317
opentelemetry: batch span processor started (max_queue=2048, batch=512)
opentelemetry: exporter export failed: rpc error: code = Unavailable desc = connection refused; retrying in 5s
opentelemetry: exporter export failed: rpc error: code = Unavailable desc = connection refused; retrying in 7.5s
opentelemetry: batch span processor dropped 512 spans: queue full
```

Esa última línea es la verdad de campo del contrato de "no hacer daño": en lugar de bloquear la aplicación esperando a un Collector muerto, el SDK **descarta spans e incrementa un contador de descartes**. La aplicación nunca ve un error.

---

## 3. Capa 3: manejo de errores a nivel de señal — Status y RecordException

Aquí es donde *tu* código participa. El resultado de un span se expresa a través de dos facilidades independientes que, con frecuencia — e incorrectamente —, se asumen como una sola.

### 3.1 Span Status

El modelo de datos del status tiene exactamente tres códigos:

| StatusCode | Significado | Quién lo establece |
|---|---|---|
| `Unset` | Por defecto. Resultado desconocido / normal. | Nadie — este es el valor inicial |
| `Error` | La operación falló. | La instrumentación, ante una falla conocida |
| `Ok` | Explícitamente *no* es un error; anula la heurística de un backend. | La aplicación, deliberadamente, y rara vez |

Regla de la especificación que hace tropezar a la gente: la instrumentación **SHOULD NOT** establecer `Ok`. Dejar un span exitoso como `Unset` es correcto — permite que los backends y el sampling apliquen su propia semántica. `Ok` es una anulación dura reservada para el autor de la aplicación que quiere decir "sé que esto parece un 4xx pero para mi negocio es un éxito". Solo `Error` lleva una `description` de texto libre.

### 3.2 RecordException

`RecordException` adjunta un **evento** de span llamado `exception` que lleva los atributos de las convenciones semánticas:

| Atributo | Ejemplo |
|---|---|
| `exception.type` | `java.net.SocketTimeoutException` |
| `exception.message` | `Read timed out` |
| `exception.stacktrace` | stack completo multilínea |
| `exception.escaped` | `true` si la excepción se propagó fuera del alcance del span |

### 3.3 La trampa: son ortogonales

**`RecordException` no establece el status en `Error`.** Registrar la excepción agrega detalle de diagnóstico; *no* marca el span como fallido. Debés llamar a ambos, en este orden de intención:

```python
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode

tracer = trace.get_tracer("checkout")

with tracer.start_as_current_span("charge_card") as span:
    try:
        gateway.charge(order)
    except PaymentError as exc:
        span.record_exception(exc)                       # detail: what & where
        span.set_status(Status(StatusCode.ERROR,          # verdict: it failed
                               "payment gateway declined"))
        raise
```

Existen atajos idiomáticos — el `start_as_current_span(..., record_exception=True, set_status_on_exception=True)` de Python (ambos con default `True`) hace las dos cosas automáticamente para las excepciones que escapan del bloque `with`. Pero cuando capturás y manejás sin re-lanzar (re-raise), el comportamiento automático no se dispara y volvés al patrón manual de dos llamadas de arriba.

| Patrón | ¿evento `exception`? | ¿Status en `Error`? |
|---|---|---|
| solo `record_exception()` | ✅ | ❌ (queda en `Unset`) |
| solo `set_status(Error)` | ❌ | ✅ |
| la excepción escapa del `with` (auto) | ✅ | ✅ |
| capturada + manejada, sin llamadas manuales | ❌ | ❌ |

Un span con una excepción registrada pero con status `Unset` es un defecto de producción real y común: el trace *se ve* bien en el panel de tasa de errores mientras el detalle de la excepción queda invisible en los eventos.

---

## 4. Capa 5: manejo de errores del pipeline del Collector

El Collector es donde el manejo de errores se convierte en una disciplina de infraestructura, porque se ubica entre muchos productores y un (frágil) backend.

### 4.1 Errores permanentes vs. transitorios

Cada consumidor en un pipeline devuelve un error hacia arriba en la cadena. El Collector los clasifica en dos categorías, y la distinción decide si los datos se **reintentan o se descartan**:

| Clase | Construido por | Ejemplos | Comportamiento |
|---|---|---|---|
| **Permanente** | `consumererror.NewPermanent(err)` | 400 Bad Request, payload malformado/venenoso, rechazo de esquema, 401/403 | **Descartado inmediatamente.** Reintentar un batch malformado nunca tendrá éxito y solo desperdicia la cola. |
| **Transitorio (no permanente)** | cualquier `error` común | `Unavailable`, `DeadlineExceeded`, 429, 502/503/504, connection refused | **Reintentado** por `retry_on_failure` con backoff. |

Por esto un Collector apuntado a un backend que devuelve `400` mostrará datos *descartados* sin tormenta de reintentos, mientras que un backend que simplemente está *caído* dispara backoff exponencial y crecimiento de la cola.

### 4.2 retry_on_failure y sending_queue

Ambos son provistos por `exporterhelper`, así que cualquier exporter OTLP/OTLP-HTTP/la mayoría los expone con semántica idéntica.

- **`retry_on_failure`** — backoff exponencial para errores transitorios. Después de `max_elapsed_time` se abandona el ítem (se descarta).
- **`sending_queue`** — desacopla el camino de recepción/procesamiento de la (lenta) red. Los productores encolan; los workers de `num_consumers` drenan la cola hacia el exporter. Cuando la cola está **llena**, el `enqueue` falla → esta es la señal de backpressure que se propaga de vuelta hacia el receiver.

| Ajuste | Por defecto | Significado en producción |
|---|---|---|
| `retry_on_failure.enabled` | `true` | Absorber blips transitorios del backend |
| `retry_on_failure.initial_interval` | `5s` | Primer backoff |
| `retry_on_failure.max_interval` | `30s` | Techo del backoff |
| `retry_on_failure.max_elapsed_time` | `300s` | Presupuesto total de reintentos antes del **descarte** |
| `sending_queue.enabled` | `true` | Desacoplar el ingreso del egreso |
| `sending_queue.num_consumers` | `10` | Paralelismo del egreso |
| `sending_queue.queue_size` | `1000` | Profundidad del buffer antes de backpressure/descarte |
| `sending_queue.storage` | *(sin setear → en memoria)* | Setear a una storage extension para una cola **persistente** |

**Compensación — cola en memoria vs. persistente:**

| | Cola en memoria (por defecto) | Cola persistente (`file_storage`) |
|---|---|---|
| Durabilidad ante reinicio/OOM/crash | ❌ se pierde toda la cola | ✅ sobrevive al reinicio |
| Latencia / throughput | máximo | menor (escritura a disco por ítem) |
| Costo operativo | ninguno | PVC / disco + I/O |
| Cuándo usarla | telemetría efímera, best-effort | señales de facturación/auditoría, enlace de backend poco confiable |

### 4.3 Backpressure con `memory_limiter`

`retry_on_failure` + `sending_queue` manejan un problema *aguas abajo* (backend caído). `memory_limiter` maneja el problema *aguas arriba*: productores enviando más rápido de lo que el Collector puede egresar. Ubicado **primero** en el pipeline, verifica periódicamente el uso del heap; por encima del límite blando **rechaza datos** (devuelve errores que se propagan de vuelta a los receivers, que luego rechazan al cliente con un status reintentable). Esto convierte "agotar la memoria del nodo y morir por OOM-kill" en "empujar backpressure hacia el emisor", que es exactamente el contrato de "no hacer daño" aplicado al Collector mismo.

> El orden importa: `memory_limiter` debe ser el **primer** processor; `batch` típicamente después de él. Un `batch` antes de `memory_limiter` acumularía memoria que el limiter está intentando acotar.

### 4.4 Manifiesto completo del Collector de producción

```yaml
# otelcol-config.yaml — production error-handling configuration
extensions:
  # Persistent queue backing store — survives Collector restarts/OOM.
  file_storage/queue:
    directory: /var/lib/otelcol/sending-queue
    timeout: 10s
    compaction:
      on_start: true
      directory: /var/lib/otelcol/compaction
  # Live in-process debugging surface.
  zpages:
    endpoint: 0.0.0.0:55679
  health_check:
    endpoint: 0.0.0.0:13133

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # FIRST processor: bounds heap, applies backpressure to receivers.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80        # hard limit — refuse data above this
    spike_limit_percentage: 25  # headroom for bursts between checks
  batch:
    timeout: 5s
    send_batch_size: 8192
    send_batch_max_size: 16384

exporters:
  otlp/backend:
    endpoint: tempo-gateway.observability.svc:4317
    tls:
      insecure: false
    # Transient backend outages: back off, don't hammer, give up after 5 min.
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    # Durable buffer: 10 workers, 5000 slots, persisted to disk.
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
      storage: file_storage/queue
  # Last-resort visibility into what is flowing (or failing).
  debug:
    verbosity: normal
    sampling_initial: 5
    sampling_thereafter: 200

service:
  extensions: [file_storage/queue, zpages, health_check]
  telemetry:
    logs:
      level: info
    metrics:
      # Expose otelcol_* internal metrics for scraping.
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, batch]
      exporters:  [otlp/backend, debug]
```

### 4.5 Kubernetes: la cola persistente necesita almacenamiento durable

Una `sending_queue` persistente solo es durable si su directorio sobrevive a los reinicios del Pod. Eso significa un `StatefulSet` (o un Deployment con un PVC vinculado) — no un `emptyDir`.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: otelcol
  namespace: observability
spec:
  serviceName: otelcol
  replicas: 1
  selector:
    matchLabels: { app: otelcol }
  template:
    metadata:
      labels: { app: otelcol }
    spec:
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.111.0
          args: ["--config=/conf/otelcol-config.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: metrics,   containerPort: 8888 }
            - { name: zpages,    containerPort: 55679 }
          livenessProbe:
            httpGet: { path: /, port: 13133 }
          volumeMounts:
            - { name: config, mountPath: /conf }
            - { name: queue,  mountPath: /var/lib/otelcol }  # persistent queue
      volumes:
        - name: config
          configMap: { name: otelcol-config }
  volumeClaimTemplates:
    - metadata: { name: queue }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests: { storage: 10Gi }
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Validá antes de desplegar

```console
$ otelcol-contrib validate --config=otelcol-config.yaml
$ echo $?
0
```

Una configuración inválida falla rápido al arrancar (permitido por la especificación — esto es el momento de inicialización, no runtime):

```console
$ otelcol-contrib validate --config=broken.yaml
Error: invalid configuration: exporters::otlp/backend: sending_queue.storage
references storage "file_storage/queue" which is not configured in service::extensions
$ echo $?
1
```

### 5.2 Las métricas de telemetría interna — tu primera parada

Scrapeá `:8888/metrics`. Estos contadores `otelcol_*` son la cuenta definitiva de lo que el pipeline descartó, reintentó y envió:

```console
$ curl -s http://otelcol:8888/metrics | grep -E 'exporter_(send_failed|sent|queue|enqueue)'
otelcol_exporter_sent_spans{exporter="otlp/backend"}          1.482940e+06
otelcol_exporter_send_failed_spans{exporter="otlp/backend"}   3.072000e+03
otelcol_exporter_enqueue_failed_spans{exporter="otlp/backend"} 5.120000e+02
otelcol_exporter_queue_size{exporter="otlp/backend"}          4.998000e+03
otelcol_exporter_queue_capacity{exporter="otlp/backend"}      5.000000e+03
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 1.024000e+03
```

Leé esto como un médico lee una ficha clínica:

| Señal | Qué significa | Causa raíz a verificar |
|---|---|---|
| `exporter_queue_size` ≈ `queue_capacity` | Cola **saturada** | Backend lento/caído; el egreso no puede drenar |
| `exporter_enqueue_failed_spans` en aumento | Cola llena → **productores con backpressure/descartados** | Igual que arriba; cola demasiado chica |
| `exporter_send_failed_spans` en aumento | El exporter se rinde tras el presupuesto de reintentos | Caída del backend que excede `max_elapsed_time`, o errores permanentes (400/401) |
| `receiver_refused_spans` en aumento | `memory_limiter` rechazando datos | Ingreso > egreso; Collector bajo presión de memoria — escalar horizontalmente o subir los límites |

El flujo de diagnóstico es causal: `queue_size` se satura → `enqueue_failed` trepa → `receiver_refused` trepa → los clientes reciben errores reintentables. Rastrealo de vuelta hasta el exporter y encontrás el backend.

### 5.3 zpages — estado del pipeline en vivo sin un backend

```console
$ curl -s http://otelcol:55679/debug/tracez | head
$ curl -s http://otelcol:55679/debug/pipelinez
```

`/debug/tracez` agrupa los propios spans del Collector por bucket de latencia y por **status de error**, permitiéndote ver operaciones internas que fallan en tiempo real. `/debug/pipelinez` muestra el cableado receiver→processor→exporter tal como se cargó — la forma más rápida de confirmar que `memory_limiter` está efectivamente primero.

### 5.4 El debug exporter — ¿están llegando los datos siquiera?

Cuando no podés distinguir si el problema es "no se produjeron datos" o "datos producidos pero no exportados", agregá el exporter `debug` con `verbosity: detailed` y leé stderr:

```console
$ kubectl logs -n observability otelcol-0 | tail
2026-08-11T14:22:07.114Z  info  TracesExporter  {"kind": "exporter",
  "data_type": "traces", "name": "debug", "resource spans": 1, "spans": 3}
2026-08-11T14:22:07.115Z  info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
ScopeSpans #0
Span #0
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Name           : charge_card
    Status code    : STATUS_CODE_ERROR
    Status message : payment gateway declined
Events:
    -> exception: exception.type=PaymentError, exception.message="declined"
```

Esta única salida confirma toda la cadena de extremo a extremo: el span lleva `STATUS_CODE_ERROR` **y** el evento `exception` — la señal de error correcta de dos partes de la §3.3.

### 5.5 Manual de fallas

| Síntoma | Causa probable | Confirmar con | Solución |
|---|---|---|---|
| App bien, pero no hay traces en el backend | Backend caído; cola drenando/descartando | `exporter_send_failed_spans`, logs `debug` del SDK | Restaurar backend; el retry/cola absorbe el hueco |
| Traces faltantes solo bajo carga | Cola demasiado chica / ingreso > egreso | `enqueue_failed` + `receiver_refused` en aumento | ↑ `queue_size`, ↑ `num_consumers`, escalar réplicas |
| Collector muerto por OOM-kill | Sin `memory_limiter` o límite demasiado alto | eventos de OOM del contenedor, sin `receiver_refused` | Agregar/ajustar `memory_limiter` como primer processor |
| Cola perdida en cada reinicio | Cola en memoria | `sending_queue.storage` sin setear | Agregar `file_storage` + volumen persistente |
| Tormenta de reintentos sobre datos malos | `400` del backend tratado como transitorio | `send_failed` sostenido, sin recuperación | El backend debería devolver `NewPermanent`; corregir el payload |
| El dashboard de tasa de errores se ve limpio pero existen excepciones | `record_exception` sin `set_status(Error)` | el exporter `debug` muestra `Status code: UNSET` | Establecer el status del span ante la falla (§3.3) |

---

## 6. Referencias

- **OpenTelemetry Specification — Error Handling:** https://opentelemetry.io/docs/specs/otel/error-handling/
- **Trace API — Span Status & Record Exception:** https://opentelemetry.io/docs/specs/otel/trace/api/#set-status
- **Semantic Conventions — Exceptions on spans:** https://opentelemetry.io/docs/specs/semconv/exceptions/exceptions-spans/
- **SDK configuration & environment variables (`OTEL_LOG_LEVEL`, `OTEL_BSP_*`):** https://opentelemetry.io/docs/languages/sdk-configuration/general/
- **Collector — `exporterhelper` (`retry_on_failure`, `sending_queue`):** https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
- **Collector — `memory_limiter` processor:** https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
- **Collector — `file_storage` extension (persistent queue):** https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/extension/storage/filestorage/README.md
- **Collector — Internal telemetry & metrics:** https://opentelemetry.io/docs/collector/internal-telemetry/
- **Collector — `zpages` extension:** https://github.com/open-telemetry/opentelemetry-collector/blob/main/extension/zpagesextension/README.md
- **Collector — `debug` exporter:** https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/debugexporter/README.md
- **OTCA Curriculum (CNCF):** https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf