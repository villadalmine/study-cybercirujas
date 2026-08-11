# OTCA — Dominio 4: Mantenimiento y Depuración de Pipelines de Observabilidad
## Tema 4.2 — Depuración de Pipelines (Ejercicios Guiados)

> **Alcance.** Estos ejercicios se enfocan en el pipeline del **Collector** de OpenTelemetry — el lugar donde OTCA ubica la "depuración de pipelines". Vas a hacer que un pipeline en ejecución sea observable para *sí mismo*, y luego usarás sus tres superficies nativas de depuración — el **debug exporter**, la **telemetría interna del propio Collector** (`:8888/metrics` + `zpages`) y la **validación de configuración** — para localizar dónde se descarta, rechaza o desecha silenciosamente la telemetría.
>
> **Fuentes de referencia (oficiales):**
> - Guía de troubleshooting del Collector — https://opentelemetry.io/docs/collector/troubleshooting/
> - Telemetría interna del Collector — https://opentelemetry.io/docs/collector/internal-telemetry/
> - `debug` exporter — https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/debugexporter/README.md
> - Extensión `zpages` — https://github.com/open-telemetry/opentelemetry-collector/blob/main/extension/zpagesextension/README.md
> - Extensión `pprof` — https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/extension/pprofextension/README.md
> - Herramienta de carga `telemetrygen` — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
> - Currículum de OTCA — https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf

---

## Ejercicio 0 — Construir un banco de pruebas depurable

Necesitás un Collector que puedas romper a propósito y un generador de tráfico que controles por completo.

1. Instalá un Collector que incluya las extensiones de depuración. La distribución `contrib` incluye `zpages`, `pprof` y `health_check`:

   ```bash
   # Any recent contrib binary works; version pin is up to you.
   otelcol-contrib --version
   telemetrygen --help | head -n 5
   ```

2. Escribí la configuración base `collector.yaml`. Fijate en las tres superficies de depuración cableadas desde el principio — `extensions` (zpages/pprof/health_check), el `debug` exporter y `service.telemetry`:

   ```yaml
   extensions:
     health_check:
       endpoint: 0.0.0.0:13133
     pprof:
       endpoint: 0.0.0.0:1777
     zpages:
       endpoint: 0.0.0.0:55679

   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     batch: {}
     memory_limiter:
       check_interval: 1s
       limit_mib: 128
       spike_limit_mib: 32

   exporters:
     debug:
       verbosity: basic
     otlp/backend:
       endpoint: 127.0.0.1:4319       # deliberately points at nothing yet
       tls:
         insecure: true

   service:
     extensions: [health_check, pprof, zpages]
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, batch]
         exporters: [debug, otlp/backend]
     telemetry:
       logs:
         level: info
       metrics:
         level: detailed
         address: 0.0.0.0:8888
   ```

3. Arrancalo y confirmá que llegó al estado en ejecución:

   ```bash
   otelcol-contrib --config collector.yaml
   # In another shell:
   curl -s http://localhost:13133/ | jq .
   ```

   Esperado:

   ```json
   { "status": "Server available", "upSince": "2026-08-11T12:00:00Z", "uptime": "3.1s" }
   ```

4. Enviá una ráfaga controlada de 10 spans sobre OTLP/gRPC:

   ```bash
   telemetrygen traces --otlp-insecure --traces 10 --otlp-endpoint localhost:4317
   ```

> **Verificá tu comprensión (0):**
> - **0a.** ¿Qué decisión de distribución (`core` vs `contrib`) afecta si `zpages` y `pprof` están siquiera *disponibles* para habilitar, y por qué importa eso antes de poder depurar un pipeline en el terreno?
> - **0b.** En el paso 2, el exporter `otlp/backend` apunta a `127.0.0.1:4319`, donde nada está escuchando. ¿Se negará a arrancar el Collector? Justificá usando la distinción entre *validación de configuración* y *conectividad en tiempo de ejecución*.
> - **0c.** ¿Por qué `telemetrygen` es un mejor primer diagnóstico que reinstrumentar tu aplicación real cuando un pipeline "no funciona"?

---

## Ejercicio 1 — Hacer que el pipeline hable: el `debug` exporter y su escala de verbosidad

El `debug` exporter escribe una representación de cada batch que recibe en los propios logs del Collector. Es la forma más rápida de responder "¿está llegando siquiera algún dato a este pipeline?".

1. Con `verbosity: basic` (del Ejercicio 0), reenviá tráfico y observá la stdout del Collector:

   ```bash
   telemetrygen traces --otlp-insecure --traces 3 --otlp-endpoint localhost:4317
   ```

   Línea de log esperada (un resumen por batch):

   ```
   2026-08-11T12:01:07.512Z  info  Traces  {"kind": "exporter", "data_type": "traces", "name": "debug", "resource spans": 1, "spans": 3}
   ```

2. Subí la resolución. Editá el exporter y reiniciá:

   ```yaml
   exporters:
     debug:
       verbosity: detailed
   ```

3. Reenviá un span y leé el registro completo:

   ```bash
   telemetrygen traces --otlp-insecure --traces 1 --otlp-endpoint localhost:4317
   ```

   Esperado (truncado):

   ```
   ResourceSpans #0
   Resource attributes:
        -> service.name: Str(telemetrygen)
   ScopeSpans #0
   Span #0
       Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
       ID             : 00f067aa0ba902b7
       Name           : okey-dokey-0
       Kind           : Server
       Start time     : 2026-08-11 12:01:40.11 +0000 UTC
       End time       : 2026-08-11 12:01:40.11 +0000 UTC
       Status code    : Unset
       Attributes:
            -> net.peer.ip: Str(1.2.3.4)
            -> peer.service: Str(telemetrygen-server)
   ```

4. Ahora demostrá que la ubicación del exporter importa. Mové temporalmente `debug` para que quede **después** de un processor que descarta datos — insertá un filter (contrib) que descarte todo, *antes* de que el debug exporter pueda verlo. Cambiá el pipeline para enrutar a través de un segundo pipeline donde `debug` esté primero vs último, y compará lo que imprime cada `debug`.

   ```yaml
   processors:
     filter/dropall:
       error_mode: ignore
       traces:
         span:
           - 'true'          # matches every span -> drops it
   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [filter/dropall, batch]
         exporters: [debug, otlp/backend]
   ```

   Reenviá tráfico. Observá que el `debug` exporter ahora imprime **nada** — el batch está vacío para cuando llega a los exporters.

> **Verificá tu comprensión (1):**
> - **1a.** Un compañero deja `verbosity: detailed` en un Collector de producción que ingesta 50k spans/s. Nombrá dos riesgos operativos concretos y el cambio de configuración de una sola palabra que los mitiga.
> - **1b.** En el paso 1 el log dice `"resource spans": 1, "spans": 3`. ¿Cuál es la diferencia entre un conteo de *resource span* y un conteo de *span*, y qué te dice una relación de `1:3` sobre el batch?
> - **1c.** En el paso 4 el `debug` exporter quedó en silencio aun cuando `telemetrygen` reportó éxito. ¿Qué prueba esto sobre *dónde* en el pipeline se está perdiendo el dato, y por qué el `debug` exporter por sí solo es insuficiente para distinguir "descartado por un processor" de "nunca recibido"?

---

## Ejercicio 2 — Localizar la pérdida con las métricas internas del Collector

El `debug` exporter te dice qué llega al *final*. Las métricas internas en `:8888/metrics` te dicen qué pasó en cada *etapa* — receiver, processor, exporter — y te permiten calcular la pérdida con precisión.

1. Escrapeá el endpoint de telemetría interna mientras fluye tráfico:

   ```bash
   telemetrygen traces --otlp-insecure --traces 1000 --otlp-endpoint localhost:4317
   curl -s http://localhost:8888/metrics | grep -E 'otelcol_(receiver|processor|exporter)_.*spans'
   ```

2. Leé el pipeline como un flujo. Un pipeline sano se equilibra en cada salto:

   ```
   otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 1000
   otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 0
   otelcol_exporter_sent_spans{exporter="debug"} 1000
   otelcol_exporter_sent_spans{exporter="otlp/backend"} 0
   otelcol_exporter_send_failed_spans{exporter="otlp/backend"} 1000
   otelcol_exporter_queue_size{exporter="otlp/backend"} 1000
   otelcol_exporter_queue_capacity{exporter="otlp/backend"} 1000
   ```

3. Interpretá antes de arreglar. El receiver *aceptó* los 1000 (el ingreso está bien). `debug` *envió* 1000 (el pipeline está bien cableado). Pero `otlp/backend` tiene `send_failed = 1000` y `queue_size == queue_capacity` — el endpoint aguas abajo está muerto (ese era nuestro deliberado `127.0.0.1:4319`) y la cola de envío está saturada.

4. Levantá un sink real para que el exporter tenga a dónde ir, y luego re-escrapeá:

   ```bash
   # Minimal second Collector acting as the backend on :4319
   cat > backend.yaml <<'EOF'
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4319
   exporters:
     debug: {verbosity: basic}
   service:
     pipelines:
       traces:
         receivers: [otlp]
         exporters: [debug]
   EOF
   otelcol-contrib --config backend.yaml
   ```

   Reenviá 1000 spans y confirmá que los contadores ahora se equilibran:

   ```
   otelcol_exporter_sent_spans{exporter="otlp/backend"} 1000
   otelcol_exporter_send_failed_spans{exporter="otlp/backend"} 0
   otelcol_exporter_queue_size{exporter="otlp/backend"} 0
   ```

5. Ahora provocá un rechazo *del lado del receiver* para ver la otra clase de pérdida. Bajá el memory limiter a fondo e inundalo:

   ```yaml
   processors:
     memory_limiter:
       check_interval: 1s
       limit_mib: 20        # unrealistically low on purpose
       spike_limit_mib: 5
   ```

   ```bash
   telemetrygen traces --otlp-insecure --duration 20s --rate 20000 --otlp-endpoint localhost:4317
   curl -s http://localhost:8888/metrics | grep -E 'refused|otelcol_processor'
   ```

   Esperado ver valores distintos de cero:

   ```
   otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 43120
   otelcol_processor_refused_spans{processor="memory_limiter"} 43120
   ```

> **Verificá tu comprensión (2):**
> - **2a.** Escribí la fórmula general para "spans perdidos en la etapa de exportación" usando dos series `otelcol_exporter_*`, y explicá por qué `send_failed` por sí solo puede subestimar la pérdida cuando hay una cola involucrada.
> - **2b.** En el paso 2, `otelcol_exporter_sent_spans{exporter="debug"}` es 1000 pero `otelcol_exporter_sent_spans{exporter="otlp/backend"}` es 0. ¿Por qué el mismo pipeline muestra un exporter teniendo éxito y otro fallando, y qué descarta eso inmediatamente como causa?
> - **2c.** Contrastá `otelcol_receiver_refused_spans` con `otelcol_exporter_send_failed_spans`: ¿cuál señala **contrapresión funcionando según lo diseñado** versus **una caída aguas abajo**, y cómo se vería cada uno para la *aplicación* que envía datos?
> - **2d.** ¿Por qué `queue_size == queue_capacity` es un indicador anticipado sobre el que deberías alertar *antes* de que `send_failed` suba, en un exporter configurado con reintentos?

---

## Ejercicio 3 — Inspeccionar el pipeline en vivo con `zpages`

`zpages` te da una vista en proceso y sin dependencias del Collector en ejecución: qué pipelines están cableados, qué componentes están sanos, y un búfer circular muestreado de spans recientes *que el propio Collector emitió* mientras procesaba.

1. Abrí la vista de pipelines:

   ```bash
   curl -s http://localhost:55679/debug/pipelinez
   ```

   Vas a ver cada pipeline, su tipo de dato, y los receivers → processors → exporters ordenados — la respuesta autoritativa a "¿está `otlp/backend` realmente adjunto al pipeline de traces?".

2. Abrí la vista de service/extensions para confirmar que arrancó cada extensión:

   ```bash
   curl -s http://localhost:55679/debug/servicez
   curl -s http://localhost:55679/debug/extensionz
   ```

3. Abrí `tracez` para ver operaciones internas muestreadas, agrupadas por latencia y por error:

   ```
   http://localhost:55679/debug/tracez
   ```

   Las columnas muestran las muestras en ejecución / por bucket de latencia / de error por nombre de span. Cuando las exportaciones están fallando, el bucket de error para la operación de exportación se llena — una confirmación visual de lo que midió el contador `send_failed` del Ejercicio 2.

4. Correlacioná: con el backend todavía **caído**, cargá `tracez`, cliqueá la muestra de error para el span de exportación, y leé el mensaje de estado registrado. Luego levantá el backend y observá cómo el bucket de error deja de crecer.

> **Verificá tu comprensión (3):**
> - **3a.** `zpages` no requiere sistemas externos (ni Prometheus, ni backend). Nombrá un escenario de depuración donde esa propiedad la hace estrictamente más útil que el endpoint `:8888/metrics`.
> - **3b.** `/debug/pipelinez` muestra `otlp/backend` correctamente adjunto, pero no llega ningún dato al backend. ¿Qué otras dos superficies de los Ejercicios 1–2 consultás a continuación, y en qué orden?
> - **3c.** ¿Por qué `zpages` (al igual que `pprof`) generalmente debería estar ligada a `localhost` o protegida en producción, en lugar de `0.0.0.0`?

---

## Ejercicio 4 — La misconfiguración silenciosa: un componente definido pero nunca cableado

El bug más común de "el pipeline está roto y nada da error": un componente existe bajo `receivers:`/`processors:`/`exporters:` pero no está listado en una entrada de `service.pipelines`, así que se instancia para validación pero nunca se ejecuta realmente.

1. Introducí el bug. Agregá un processor de redacción pero "olvidate" de agregarlo al pipeline:

   ```yaml
   processors:
     batch: {}
     redaction/pii:
       allow_all_keys: true
       blocked_values:
         - '4[0-9]{12}(?:[0-9]{3})?'   # naive card-number pattern
   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]            # redaction/pii is NOT here
         exporters: [debug, otlp/backend]
   ```

2. Reiniciá y observá: **ningún error**. El Collector valida `redaction/pii` (parsea), así que el arranque tiene éxito. La PII fluye directo.

3. Confirmá que el processor está inerte usando `zpages`:

   ```bash
   curl -s http://localhost:55679/debug/pipelinez | grep -A3 traces
   ```

   La lista de processors mostrará solo `[batch]` — prueba de que el redactor no está en la ruta de datos.

4. Ahora introducí una misconfiguración *fatal* para contrastar las dos clases de fallo — referenciá un exporter que no está definido:

   ```yaml
   service:
     pipelines:
       traces:
         exporters: [debug, otlp/backendz]   # typo: no such exporter
   ```

   Reiniciá. Esperado — el Collector **se niega a arrancar**:

   ```
   Error: failed to build pipelines: pipeline "traces": references exporter "otlp/backendz" which is not configured
   2026/08/11 12:20:03 collector server run finished with error
   ```

5. Validá la configuración sin ejecutar el Collector entero — el chequeo pre-vuelo rápido:

   ```bash
   otelcol-contrib validate --config collector.yaml
   ```

> **Verificá tu comprensión (4):**
> - **4a.** Los pasos 2 y 4 son ambos "misconfiguraciones", pero uno arranca limpiamente y el otro aborta. Enunciá la regla precisa que determina qué errores se detectan al arrancar y cuáles pasan silenciosamente.
> - **4b.** Dado que un componente definido-pero-no-cableado no produce *ningún* log ni *ninguna* métrica propia, ¿qué única superficie de depuración lo expone de forma confiable, y por qué fallan en hacerlo tanto `:8888/metrics` como el `debug` exporter?
> - **4c.** ¿Dónde se ubica `otelcol validate` en la escalera de "las fuentes existen vs. las fuentes dicen lo que afirmás" — es decir, qué clase de error *nunca* puede detectar?

---

## Ejercicio 5 — Contrapresión, la cola de envío y ajuste de reintentos

Cuando el destino es lento en lugar de estar muerto, el dato no se pierde instantáneamente — se encola, reintenta y eventualmente se derrama. Leer estas dinámicas es central en la depuración de pipelines.

1. Configurá la cola y los reintentos del exporter explícitamente para que el comportamiento sea observable:

   ```yaml
   exporters:
     otlp/backend:
       endpoint: 127.0.0.1:4319
       tls:
         insecure: true
       sending_queue:
         enabled: true
         num_consumers: 2
         queue_size: 1000
       retry_on_failure:
         enabled: true
         initial_interval: 5s
         max_interval: 30s
         max_elapsed_time: 300s
   ```

2. Matá el backend (`Ctrl-C` en `backend.yaml`), inundá el Collector frontal, y observá cómo la cola se llena y luego rechaza:

   ```bash
   telemetrygen traces --otlp-insecure --duration 30s --rate 5000 --otlp-endpoint localhost:4317
   curl -s http://localhost:8888/metrics | grep -E 'queue_size|queue_capacity|enqueue_failed|send_failed'
   ```

   Progresión esperada (la cola se satura, luego el encolado empieza a fallar):

   ```
   otelcol_exporter_queue_capacity{exporter="otlp/backend"} 1000
   otelcol_exporter_queue_size{exporter="otlp/backend"} 1000
   otelcol_exporter_enqueue_failed_spans{exporter="otlp/backend"} 88240
   otelcol_exporter_send_failed_spans{exporter="otlp/backend"} 3000
   ```

3. Restaurá el backend y confirmá que la cola **se drena** (los reintentos tienen éxito, `queue_size` cae hacia 0) en lugar de perderse los spans — el punto entero de la cola.

4. Razoná sobre el ajuste: duplicar `queue_size` compra más búfer para caídas transitorias pero cuesta memoria y puede ocultar un problema crónico aguas abajo; `num_consumers` aumenta la concurrencia de exportación.

> **Verificá tu comprensión (5):**
> - **5a.** Distinguí `otelcol_exporter_enqueue_failed_spans` de `otelcol_exporter_send_failed_spans`. ¿Cuál significa "la cola está llena" y cuál significa "el intento de envío en sí falló"?
> - **5b.** Con `retry_on_failure` habilitado, un único batch lógico puede incrementar `send_failed` varias veces. ¿Qué implica eso sobre usar `send_failed` como un número crudo de "spans perdidos"?
> - **5c.** Una cola que está *permanentemente* cerca de la capacidad pero nunca se desborda tampoco es sana. ¿Qué condición crónica indica ese estado estacionario, y qué relación de métricas graficarías para detectarlo?
> - **5d.** ¿Por qué simplemente agrandar `queue_size` corre el riesgo de convertir una caída visible en un problema invisible de calidad de datos (datos rancios/tardíos), y qué señal aguas arriba te dice que la cola está enmascarando un déficit de capacidad real?

---

<details>
<summary><strong>Clave de respuestas — cliqueá para expandir</strong></summary>

### Ejercicio 0
- **0a.** `zpages`, `pprof` y muchos receivers/exporters viven solo en la distribución **contrib** (o en un build personalizado vía el OpenTelemetry Collector Builder). Si desplegás la imagen delgada `core`/base, esas extensiones simplemente no existen para habilitar — así que la primera pregunta en el terreno siempre es "¿qué distribución/componentes desplegamos realmente?". No podés depurar con una herramienta que tu binario no contiene.
- **0b.** **Arranca**. La *validación* de configuración solo chequea que el YAML parsee, que los componentes referenciados estén definidos, y que los tipos sean válidos. La *conectividad* en tiempo de ejecución (¿puedo alcanzar `127.0.0.1:4319`?) solo se ejercita cuando el exporter intenta enviar. Así que un endpoint muerto se manifiesta como `send_failed`/crecimiento de la cola en tiempo de ejecución, no como un error de arranque. (Algunos exporters intentan una conexión de forma perezosa en la primera exportación, no en el arranque.)
- **0c.** `telemetrygen` produce una **cantidad conocida y exacta** de datos OTLP bien formados bajo demanda, sin código de aplicación, sin muestreo, y sin ambigüedad de instrumentación. Eso convierte "¿es la app, el SDK o el Collector?" en un experimento controlado: si 1000 spans generados no llegan, la falla está en el receiver o después — la aplicación queda eliminada como variable.

### Ejercicio 1
- **1a.** Riesgos: (1) **explosión del volumen de logs / presión de disco e I/O** — cada span se serializa a logs; (2) **sobrecarga de CPU y latencia** más potencial **fuga de PII hacia los logs**. Mitigación: poner `verbosity: basic` (o quitar el debug exporter). "Cambio de una sola palabra" = `basic`.
- **1b.** Un **resource span** es un bloque `ResourceSpans` — todos los spans que comparten el mismo `Resource` (p. ej., mismo `service.name`/host). El conteo de **span** son spans individuales. `1:3` significa que los tres spans vinieron de un único recurso (una instancia de servicio) en ese batch — útil para detectar si un batch mezcla muchos servicios o está dominado por una sola fuente ruidosa.
- **1c.** Prueba que la pérdida ocurre **aguas arriba de los exporters, dentro del pipeline** (el processor `filter` descartó todo antes de la etapa de exportación). El `debug` exporter solo observa el *final* del pipeline, así que puede decirte "no llegó nada a los exporters" pero **no puede** distinguir "un processor lo descartó" de "el receiver nunca lo aceptó" — para eso necesitás las métricas internas por etapa (Ejercicio 2) o `zpages` (Ejercicio 3).

### Ejercicio 2
- **2a.** Pérdida en la etapa de exportación ≈ `otelcol_exporter_send_failed_spans + otelcol_exporter_enqueue_failed_spans` (datos rechazados porque el envío falló *y* datos rechazados porque la cola estaba llena). `send_failed` por sí solo subestima la pérdida porque los ítems que nunca llegaron a entrar *en* la cola se cuentan bajo `enqueue_failed`, no bajo `send_failed`.
- **2b.** Los dos exporters tienen **destinos independientes**; el pipeline se ramifica hacia ambos. `debug` escribe en logs locales (siempre alcanzable) mientras que `otlp/backend` apunta a un endpoint muerto. Como la ingesta tuvo éxito para una rama, esto descarta inmediatamente el **receiver, los processors y el cableado del pipeline** como causa — la falla está aislada al aguas abajo del exporter `otlp/backend`.
- **2c.** `receiver_refused` = el Collector **empujó de vuelta al cliente** (p. ej., el `memory_limiter` rechazó) — contrapresión funcionando según lo diseñado; la *aplicación* ve errores gRPC/HTTP (p. ej., `RESOURCE_EXHAUSTED`) y puede reintentar. `exporter_send_failed` = el Collector aceptó los datos pero el **aguas abajo está fallando** — la aplicación ve éxito mientras el dato muere dentro del Collector. El primero es visible para el productor; el segundo es silencioso para él.
- **2d.** Con reintentos habilitados, una cola llena significa que el nuevo dato no tiene a dónde ir en el momento en que ocurre un fallo más; `send_failed`/`enqueue_failed` solo suben *después* de la saturación. `queue_size == queue_capacity` es la señal determinística más temprana de que estás a un tropiezo de descartar datos, así que es la mejor alerta anticipada.

### Ejercicio 3
- **3a.** Cuando **no hay backend de métricas / no hay red** hacia el exterior — p. ej., un nodo aislado, una caja de producción bloqueada, o la propia caída que estás depurando es la ruta de telemetría en sí. `zpages` se sirve en proceso sobre un puerto local sin dependencias, así que funciona cuando el escrapeo de Prometheus no.
- **3b.** A continuación: (1) los contadores de **`:8888/metrics`** para ver si `otlp/backend` muestra `sent` vs `send_failed`/crecimiento de la cola, luego (2) los logs del **`debug` exporter** / las muestras de error de `tracez` para leer el estado de fallo real. Orden: métricas primero (cuantificar + clasificar), luego el detalle de log/trace (encontrar la causa raíz del error específico).
- **3c.** `zpages` y `pprof` exponen **estado interno, payloads muestreados y datos de profiling/memoria** que pueden filtrar información sensible o ayudar a un atacante; ligarlo a `0.0.0.0` publica eso a la red. Ligalo a `localhost` o ponelo detrás de autenticación/política de red.

### Ejercicio 4
- **4a.** Regla: el Collector falla al arrancar por errores detectables mediante **construcción estática del grafo** — componentes indefinidos, discrepancias de tipo, YAML impar---seable, un pipeline que referencia un nombre que no existe. **No puede** detectar errores *semánticos* que son individualmente válidos — un processor real que simplemente elegiste no cablear es una configuración legal (de efecto nulo), así que no hay error.
- **4b.** **`zpages` `/debug/pipelinez`**, que imprime la lista *real* y ordenada de componentes por pipeline. `:8888/metrics` falla porque un processor no cableado nunca se ejecuta, así que no emite **ninguna** serie `otelcol_processor_*` que falte de forma obvia; el `debug` exporter falla porque el dato sigue fluyendo correctamente hacia los exporters — nada se ve mal al final.
- **4c.** `otelcol validate` se ubica en el peldaño más bajo: **"la configuración está estructuralmente bien formada y es autoconsistente"**. Nunca puede detectar errores **semánticos/de comportamiento** — un pipeline válido-pero-incorrecto (redactor no cableado, un endpoint equivocado que resulta resolver, un processor que transforma datos incorrectamente). Análogo a "la URL resuelve" ≠ "la página dice lo que afirmás".

### Ejercicio 5
- **5a.** `enqueue_failed` = el ítem **no pudo entrar en la cola de envío porque estaba llena** (descarte en la puerta). `send_failed` = el ítem fue desencolado y el **intento real de envío al destino falló**. Cola llena → `enqueue_failed`; transmisión fallida → `send_failed`.
- **5b.** Con reintentos, un batch puede fallar-y-reintentar varias veces, incrementando `send_failed` en cada intento. Así que `send_failed` es un **contador de intentos, no un contador de spans-únicos-perdidos** — usarlo crudo sobrecuenta la pérdida. La pérdida real se aproxima mejor con `enqueue_failed` (nunca entró) más los ítems cuyos reintentos agotaron `max_elapsed_time`.
- **5c.** Una cola permanentemente casi llena significa **ingreso sostenido > egreso sostenido** — el *throughput* del destino está crónicamente por debajo de tu tasa de datos (no una caída transitoria). Graficá `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity` a lo largo del tiempo; una línea que se mantiene alta sin drenar es la firma.
- **5d.** Una cola más grande absorbe más backlog, así que en lugar de descartar datos visiblemente el Collector **los entrega tarde** — los spans/métricas llegan con minutos de retraso, degradando silenciosamente el alertado y la correlación mientras cada métrica de "pérdida" lee cero. La pista de que la cola está enmascarando un déficit real es una **cola que se llena más rápido de lo que se drena durante carga normal** (`queue_size` creciente con tráfico estable) y `otelcol_receiver_refused_*` elevado aguas arriba una vez que el búfer finalmente se satura — el déficit reaparece como contrapresión en el receiver.

</details>