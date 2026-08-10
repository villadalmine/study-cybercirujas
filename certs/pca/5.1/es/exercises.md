# Tema 5.1 — Client Libraries · Ejercicios Guiados

> **Certificación:** Prometheus Certified Associate (PCA) — Dominio *Instrumentation and Exemplars*
> **Formato:** Cada ejercicio es una secuencia de pasos numerados que ejecutás en tu propia máquina, seguidos de puntos de control de comprensión. Todas las respuestas están colapsadas al final.
>
> **Fuentes de referencia (oficiales):**
> - Client libraries overview — https://prometheus.io/docs/instrumenting/clientlibs/
> - Writing client libraries (el contrato que toda library implementa) — https://prometheus.io/docs/instrumenting/writing_clientlibs/
> - Metric types — https://prometheus.io/docs/concepts/metric_types/
> - Metric and label naming — https://prometheus.io/docs/practices/naming/
> - Instrumentation best practices — https://prometheus.io/docs/practices/instrumentation/
> - Exposition formats — https://prometheus.io/docs/instrumenting/exposition_formats/
> - `client_python` — https://github.com/prometheus/client_python · https://prometheus.github.io/client_python/
> - `client_golang` — https://github.com/prometheus/client_golang

---

## Prerrequisitos

Vas a necesitar Python ≥ 3.8 y, para el Ejercicio 6, un toolchain de Go (≥ 1.21). Todo lo demás es `curl` y una shell.

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install 'prometheus_client==0.20.0'
```

Una **client library** es el código que embebés *dentro de tu aplicación* para definir métricas, mantener sus valores en un registry y renderizarlas bajo demanda en el formato de exposición de Prometheus. Es el lado de "push" de la instrumentación solo en el sentido de que *tu código* empuja números hacia objetos in-process; Prometheus sigue **haciendo pull** de la exposición sobre HTTP. Tené presente ese modelo — varios puntos de control dependen de él.

---

## Ejercicio 1 — Exponer el registry por defecto sobre HTTP

**Objetivo:** Levantar el proceso instrumentado más pequeño posible e inspeccionar qué te da una client library *gratis*.

1. Creá `app1.py`:

   ```python
   import time
   from prometheus_client import start_http_server

   if __name__ == "__main__":
       # Starts a WSGI server in a daemon thread, backed by the default registry.
       start_http_server(8000)
       print("serving metrics on :8000")
       while True:
           time.sleep(1)
   ```

2. Ejecutalo: `python3 app1.py`

3. En otra terminal, scrapealo:

   ```bash
   curl -s localhost:8000/metrics | head -n 25
   ```

4. Ahora scrapeá un path *diferente* y compará:

   ```bash
   curl -s localhost:8000/ | head -n 3
   curl -s localhost:8000/anything | head -n 3
   ```

5. Inspeccioná el `Content-Type` que la library anuncia:

   ```bash
   curl -s -D - -o /dev/null localhost:8000/metrics
   ```

Deberías ver, entre la salida, series como `process_resident_memory_bytes`, `process_cpu_seconds_total`, `process_start_time_seconds` y `python_info`, más un header como:

```
Content-Type: text/plain; version=0.0.4; charset=utf-8
```

**Puntos de control 1**
- **1a.** Nunca definiste una sola métrica, y sin embargo `/metrics` está lleno de series. ¿De dónde salieron `process_*` y `python_*`?
- **1b.** `/`, `/anything` y `/metrics` devolvieron todos una salida idéntica. ¿Qué te dice esto sobre cómo `start_http_server` enruta las requests, y por qué *no* es así como debería comportarse un endpoint de producción real?
- **1c.** ¿Cuál es el significado exacto de `version=0.0.4` en el `Content-Type`? ¿Es una versión de tu app, de Prometheus, o de otra cosa?

---

## Ejercicio 2 — Instrumentación directa: Counter y Gauge

**Objetivo:** Definir a mano los dos tipos de métrica más simples y observar cómo la client library los serializa.

1. Creá `app2.py`:

   ```python
   import time
   from prometheus_client import start_http_server, Counter, Gauge

   # NOTE: no `_total` suffix here — the client appends it.
   REQUESTS = Counter(
       "myapp_requests",
       "Total requests processed.",
       ["method"],
   )
   INPROGRESS = Gauge(
       "myapp_inprogress_requests",
       "Requests currently being processed.",
   )

   def handle(method: str) -> None:
       INPROGRESS.inc()
       REQUESTS.labels(method=method).inc()
       time.sleep(0.2)
       INPROGRESS.dec()

   if __name__ == "__main__":
       start_http_server(8000)
       while True:
           handle("GET")
           handle("POST")
   ```

2. Ejecutalo, luego scrapeá solo tus propias series:

   ```bash
   curl -s localhost:8000/metrics | grep '^myapp_'
   ```

3. Observá la forma de la salida. Deberías ver algo como:

   ```
   # HELP myapp_requests_total Total requests processed.
   # TYPE myapp_requests_total counter
   myapp_requests_total{method="GET"} 42.0
   myapp_requests_total{method="POST"} 42.0
   # HELP myapp_requests_created Total requests processed.
   # TYPE myapp_requests_created gauge
   myapp_requests_created{method="GET"} 1.7e+09
   ...
   # HELP myapp_inprogress_requests Requests currently being processed.
   # TYPE myapp_inprogress_requests gauge
   myapp_inprogress_requests 0.0
   ```

4. Scrapeá dos veces, con un segundo de diferencia, y confirmá que `myapp_requests_total` solo crece mientras `myapp_inprogress_requests` oscila entre `0` y `2`.

5. Intentá romper el counter — agregá una línea temporal `REQUESTS.labels(method="GET").dec()` y ejecutá. Anotá el resultado.

**Puntos de control 2**
- **2a.** Nombraste al counter `myapp_requests`, pero la serie expuesta es `myapp_requests_total`. ¿Qué lado agregó `_total`, y qué habrías obtenido si lo hubieras nombrado `myapp_requests_total` vos mismo?
- **2b.** ¿Qué son las series `myapp_requests_created`, por qué su `# TYPE` es un `gauge` y no un `counter`, y qué representan sus valores?
- **2c.** El Paso 5 falla. ¿Qué método *no* expone un objeto `Counter`, y qué propiedad de los counters está imponiendo la library a nivel de API?
- **2d.** Un `Gauge` ofrece `.inc()`, `.dec()`, `.set()`, `.set_to_current_time()`, y los context managers `.track_inprogress()` / `.time()`. Reescribí `handle()` para que `INPROGRESS` sea gestionado por un context manager en lugar de `inc/dec` manual. ¿Por qué es más seguro?

---

## Ejercicio 3 — Histogram: buckets, `_sum`, `_count`

**Objetivo:** Entender la naturaleza *compuesta* de un Histogram — una métrica lógica que una client library expande en muchas series.

1. Creá `app3.py`:

   ```python
   import random
   import time
   from prometheus_client import start_http_server, Histogram

   LATENCY = Histogram(
       "myapp_request_duration_seconds",
       "Request duration in seconds.",
       buckets=(0.1, 0.25, 0.5, 1.0, 2.5),  # explicit, application-tuned buckets
   )

   @LATENCY.time()  # decorator times the wrapped call and observes the result
   def do_work() -> None:
       time.sleep(random.expovariate(2))

   if __name__ == "__main__":
       start_http_server(8000)
       while True:
           do_work()
   ```

2. Ejecutalo, dejalo recolectar durante ~10 s, luego scrapealo:

   ```bash
   curl -s localhost:8000/metrics | grep '^myapp_request_duration_seconds'
   ```

   Forma esperada:

   ```
   myapp_request_duration_seconds_bucket{le="0.1"} 118.0
   myapp_request_duration_seconds_bucket{le="0.25"} 210.0
   myapp_request_duration_seconds_bucket{le="0.5"} 260.0
   myapp_request_duration_seconds_bucket{le="1.0"} 279.0
   myapp_request_duration_seconds_bucket{le="2.5"} 283.0
   myapp_request_duration_seconds_bucket{le="+Inf"} 284.0
   myapp_request_duration_seconds_count 284.0
   myapp_request_duration_seconds_sum 96.3...
   ```

3. Verificá que los valores de los buckets sean **no decrecientes** a medida que crece `le`. Elegí el `le` finito más grande y comparalo con el bucket `+Inf` y con `_count`.

4. Quitá el argumento explícito `buckets=`, reiniciá, y contá cuántas series `_bucket` aparecen ahora.

**Puntos de control 3**
- **3a.** Un Histogram es *una* métrica para vos. ¿Cuántas time series generó la client library a partir de él, y por qué fórmula (dados *N* buckets explícitos)?
- **3b.** Los buckets son **acumulativos**. ¿Qué cuenta realmente `myapp_request_duration_seconds_bucket{le="0.5"} 260`? ¿Por qué el bucket `le="+Inf"` debe siempre ser igual a `_count`?
- **3c.** En el Paso 4, sin un `buckets=` explícito, obtuviste un conjunto por defecto específico. ¿Cuáles son los buckets de histograma por defecto de Prometheus, y por qué son un mal default para, digamos, latencias de RPC medidas en milisegundos?
- **3d.** No podés leer una latencia p95 directamente de estas series — no hay label `quantile`. ¿Qué función de PromQL reconstruye cuantiles a partir de un histograma, y por qué el cálculo es solo una *estimación*?

---

## Ejercicio 4 — Summary, y por qué difiere entre client libraries

**Objetivo:** Ver el cuarto tipo de métrica central y enfrentar una divergencia deliberada entre client libraries.

1. Creá `app4.py`:

   ```python
   import random
   import time
   from prometheus_client import start_http_server, Summary

   S = Summary("myapp_processing_seconds", "Time spent processing.")

   if __name__ == "__main__":
       start_http_server(8000)
       while True:
           with S.time():
               time.sleep(random.random() / 5)
   ```

2. Ejecutalo y scrapealo:

   ```bash
   curl -s localhost:8000/metrics | grep '^myapp_processing_seconds'
   ```

3. Anotá qué series existen — y, crucialmente, cuáles **no**.

4. Leé la sección Summary de https://prometheus.io/docs/concepts/metric_types/#summary y la nota sobre el cliente de Python en https://github.com/prometheus/client_python#summary.

**Puntos de control 4**
- **4a.** Tu Summary produjo `_sum` y `_count` pero **ninguna** serie `{quantile="..."}`. ¿Es eso un bug en tu código, o una propiedad documentada de *esta* client library?
- **4b.** El Summary del cliente de Go *puede* exponer cuantiles configurados (por ejemplo, `quantile="0.99"`). Nombrá la razón operativa más importante para preferir un **Histogram** sobre un **Summary** con cuantiles cuando el número se mide a través de muchas instancias que pretendés agregar.
- **4c.** Tanto Histogram como Summary exponen `_sum` y `_count`. Usando solo esas dos series, escribí el PromQL para el tamaño *promedio* de evento durante los últimos 5 minutos.

---

## Ejercicio 5 — Registries personalizados y aislar qué exportás

**Objetivo:** Dejar de depender del registry por defecto implícito. Controlar exactamente qué collectors se exponen — el patrón detrás de los unit tests, los exporters multi-tenant y el Pushgateway.

1. Creá `app5.py`:

   ```python
   from prometheus_client import CollectorRegistry, Counter, generate_latest

   # A private registry — completely disconnected from the default one.
   reg = CollectorRegistry()

   JOBS = Counter(
       "batch_jobs_processed",
       "Batch jobs processed.",
       registry=reg,          # explicit target registry
   )
   JOBS.inc(7)

   # Render this registry to the wire format, no HTTP server involved.
   print(generate_latest(reg).decode())
   ```

2. Ejecutalo: `python3 app5.py`. Confirmá que la salida contiene `batch_jobs_processed_total 7.0` **y nada más** — sin `process_*`, sin `python_*`.

3. Ahora compará contra `generate_latest()` sin argumento (el registry por defecto) en un REPL de Python:

   ```python
   from prometheus_client import generate_latest
   print(generate_latest().decode()[:200])
   ```

4. Leé cómo `start_http_server(port, registry=...)` acepta un registry, y cómo `generate_latest` es la misma función que el handler HTTP llama internamente.

**Puntos de control 5**
- **5a.** El registry privado produjo solo `batch_jobs_processed_total`, pero el registry por defecto estaba lleno de `process_*`/`python_*`. Explicá el mecanismo: *cómo* llegaron esos collectors por defecto al registry por defecto, y por qué `reg` no los recibió.
- **5b.** Da dos situaciones concretas donde *debés* usar un `CollectorRegistry` personalizado en lugar del por defecto.
- **5c.** `generate_latest(reg)` devuelve `bytes`, no `str`. ¿Por qué una client library serializa a bytes, y qué implica eso sobre el charset declarado en el `Content-Type`?

---

## Ejercicio 6 — El mismo contrato en otro lenguaje (Go)

**Objetivo:** Confirmar que "client library" nombra una *especificación*, no algo de Python. Los cuatro tipos de métrica, el registry y el formato de exposición son idénticos; solo cambian los idiomas.

1. En un directorio nuevo:

   ```bash
   go mod init pca/ex6
   go get github.com/prometheus/client_golang/prometheus/promauto
   go get github.com/prometheus/client_golang/prometheus/promhttp
   ```

2. Creá `main.go`:

   ```go
   package main

   import (
       "math/rand"
       "net/http"
       "time"

       "github.com/prometheus/client_golang/prometheus"
       "github.com/prometheus/client_golang/prometheus/promauto"
       "github.com/prometheus/client_golang/prometheus/promhttp"
   )

   var requests = promauto.NewCounterVec(
       prometheus.CounterOpts{
           Name: "myapp_requests_total", // Go: you DO write the _total suffix
           Help: "Total requests processed.",
       },
       []string{"method"},
   )

   func main() {
       go func() {
           for {
               requests.WithLabelValues("GET").Inc()
               time.Sleep(time.Duration(rand.Intn(200)) * time.Millisecond)
           }
       }()
       http.Handle("/metrics", promhttp.Handler())
       http.ListenAndServe(":2112", nil)
   }
   ```

3. Ejecutá `go run main.go`, luego `curl -s localhost:2112/metrics | grep '^myapp_'`.

4. Compará el comportamiento de este endpoint contra el del Ejercicio 1: pedí `curl -s localhost:2112/` (root) versus `/metrics`.

**Puntos de control 6**
- **6a.** En Go escribiste `Name: "myapp_requests_total"` explícitamente, pero en Python (Ejercicio 2) escribir `_total` vos mismo estaba mal. Reconciliá estos dos hechos sin tildar de buggy a ninguna de las dos libraries.
- **6b.** A diferencia de `start_http_server`, el ejemplo de Go sirve métricas *solo* en `/metrics` (el root devuelve 404). ¿Qué componente es responsable de ese enrutamiento, y por qué `promhttp.Handler()` es la elección correcta de producción?
- **6c.** `promauto` difiere de `prometheus.NewCounterVec` en exactamente un comportamiento. ¿Qué hace `promauto` automáticamente, y qué falla silenciosa previene?

---

## Ejercicio 7 — Formato de exposición y content negotiation (text vs OpenMetrics)

**Objetivo:** Hacer que la client library emita ambos formatos de wire y leer la diferencia. Esta es la costura entre "client library" y "lo que Prometheus ingesta".

1. Volvé al `app2.py` en ejecución del Ejercicio 2 (Counter + Gauge).

2. Obtené el formato de texto por defecto explícitamente y anotá el header:

   ```bash
   curl -s -H 'Accept: text/plain' -D - localhost:8000/metrics | head -n 4
   ```

3. Ahora pedí OpenMetrics vía content negotiation:

   ```bash
   curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' \
        -D - localhost:8000/metrics | tail -n 12
   ```

4. Compará las dos salidas. Fijate específicamente en: el header `Content-Type`, las series `_created`, y la última línea del payload.

**Puntos de control 7**
- **7a.** ¿Qué único token al final de un payload de OpenMetrics es *requerido* y está ausente del formato de texto legacy `0.0.4`?
- **7b.** La client library eligió el formato de salida según tu request. ¿Qué mecanismo HTTP impulsó esa elección, y qué header seteó el *servidor* en respuesta?
- **7c.** En el formato legacy cada `# HELP`/`# TYPE` precede a sus samples, los valores son floats, y el body es `text/plain; version=0.0.4`. Nombrá **una** capacidad que OpenMetrics agrega y que el formato legacy no puede representar — y atala al nombre de este dominio del examen.

---

## Respuestas

<details>
<summary>Hacé clic para revelar todas las respuestas de los puntos de control</summary>

### Ejercicio 1
- **1a.** La client library de Python auto-registra tres collectors por defecto en el **registry por defecto** (`REGISTRY`) en tiempo de import: `ProcessCollector` (las series `process_*`, leídas de `/proc` en Linux), `PlatformCollector` (`python_info`) y `GCCollector` (`python_gc_*`). Los heredaste simplemente por usar `start_http_server`, que sirve ese registry por defecto. En plataformas que no son Linux el conjunto `process_*` está en gran parte vacío porque depende de `/proc`.
- **1b.** `start_http_server` usa una app WSGI mínima que devuelve la exposición de métricas para **cada** path — no hace ningún enrutamiento. Eso está bien para una demo pero es incorrecto para un servicio real: las apps de producción sirven métricas en un path dedicado (convencionalmente `/metrics`) junto a otras rutas, y normalmente montarías el handler de métricas en tu framework web existente en lugar de correr un segundo servidor ciego a paths.
- **1c.** `version=0.0.4` es la versión del **formato de exposición de texto de Prometheus** — el contrato de serialización on-the-wire. No tiene nada que ver con la versión de tu aplicación ni con la versión del servidor Prometheus. Su contraparte es `application/openmetrics-text; version=1.0.0` (Ejercicio 7).

### Ejercicio 2
- **2a.** La **client library** agregó `_total`. El cliente de Python trata el nombre de un `Counter` como la base y agrega el sufijo convencional `_total` (más una serie `_created`). Si lo hubieras nombrado `myapp_requests_total`, habrías expuesto el malformado `myapp_requests_total_total`. (Go es lo opuesto — ver 6a.)
- **2b.** `myapp_requests_created` lleva, por conjunto de labels, el **timestamp Unix de cuándo esa serie de counter fue creada/inicializada por primera vez**. Es un `gauge` porque es un punto absoluto en el tiempo que no aumenta monótonamente como el counter que acompaña; permite a los consumidores detectar resets del counter/reinicios del proceso. Estas series `_created` provienen del modelo de datos de OpenMetrics.
- **2c.** Un `Counter` deliberadamente **no expone `.dec()`** (ni `.set()`). La library impone **monotonicidad** a nivel de API: los counters solo pueden aumentar (o resetearse a cero en un reinicio). Si un valor puede bajar, debería ser un `Gauge`.
- **2d.** Usá el context manager incorporado:
  ```python
  def handle(method: str) -> None:
      with INPROGRESS.track_inprogress():
          REQUESTS.labels(method=method).inc()
          time.sleep(0.2)
  ```
  Es más seguro porque el decremento se ejecuta en un `finally` — una excepción dentro del bloque no puede dejar filtrado un gauge "en progreso" permanentemente incrementado, que es una fuente clásica de gauges atascados y siempre en ascenso.

### Ejercicio 3
- **3a.** A partir de *N* buckets explícitos la library generó **N + 3** series: un `_bucket` por cada `le` explícito, más el bucket implícito `le="+Inf"`, más `_sum` y `_count`. Aquí N = 5 → 8 series.
- **3b.** `le="0.5"} 260` cuenta cada observación **≤ 0.5 s** — los buckets son acumulativos ("menor o igual que"), no por intervalo. `le="+Inf"` cuenta *todas* las observaciones sin importar el valor, que es por definición el número total de observaciones, así que debe ser igual a `_count`.
- **3c.** Los defaults son `.005, .01, .025, .05, .075, .1, .25, .5, .75, 1.0, 2.5, 5.0, 7.5, 10.0, +Inf` — ajustados para **segundos** de latencia de web-request. Para RPCs de escala en milisegundos casi toda observación cae en el primer bucket, así que el histograma pierde toda resolución justo donde la necesitás; debés elegir buckets que enmarquen *tu* distribución esperada.
- **3d.** `histogram_quantile(0.95, rate(myapp_request_duration_seconds_bucket[5m]))`. Es una **estimación** porque las observaciones crudas se perdieron — solo sobreviven los conteos de buckets, así que la función interpola *linealmente dentro del bucket* en el que cae el cuantil. La precisión está acotada por el ancho del bucket, y cualquier valor por encima del bucket finito más grande queda recortado.

### Ejercicio 4
- **4a.** Comportamiento documentado, **no** un bug. El `Summary` del cliente de **Python** expone solo `_sum` y `_count` — **no** soporta cuantiles del lado del cliente en absoluto.
- **4b.** Los cuantiles de Summary se calculan **por instancia y no son agregables** — no podés promediar ni sumar `quantile="0.99"` entre pods para obtener un p99 de toda la flota. Los Histograms exponen conteos `_bucket` aditivos, así que agregás los buckets primero (`sum by (le) (rate(...))`) y *luego* aplicás `histogram_quantile`, obteniendo un cuantil correcto entre instancias. Esa agregabilidad es la ventaja operativa decisiva.
- **4c.** `rate(myapp_processing_seconds_sum[5m]) / rate(myapp_processing_seconds_count[5m])`. (Usar `rate` en ambos maneja correctamente los resets del counter; un simple `_sum / _count` da el promedio de toda la vida en su lugar.)

### Ejercicio 5
- **5a.** Los collectors por defecto se registran contra el objeto **registry por defecto** en el momento en que se importa `prometheus_client` (el `REGISTRY` a nivel de módulo recibe `ProcessCollector`, `PlatformCollector`, `GCCollector`). Tu `CollectorRegistry()` es un objeto independiente; nada se auto-registra en él, y vos adjuntaste solo `JOBS` vía `registry=reg`. Los registries son simplemente colecciones de collectors — el aislamiento es el punto.
- **5b.** Por ejemplo: (1) **unit tests**, donde querés un registry limpio por test sin filtraciones del ruido `process_*` ni colisiones "already registered"; (2) **batch jobs enviados al Pushgateway**, donde construís un registry descartable, agregás solo las métricas de ese job y hacés `push_to_gateway(...)`; también exporters multi-tenant que exponen un conjunto de métricas diferente por scrape target.
- **5c.** El formato de exposición son **bytes codificados en UTF‑8** en el wire, así que la library serializa a `bytes` para coincidir exactamente con lo que va en el body HTTP — sin recodificación implícita. Por eso el `Content-Type` declara explícitamente `charset=utf-8`.

### Ejercicio 6
- **6a.** El sufijo `_total` es una **convención de nombres del formato de exposición**, así que la serie expuesta debe terminar en `_total` de una u otra forma. Las libraries difieren solo en *quién lo escribe*: el cliente de **Python** lo agrega por vos (así que pasás el nombre base), mientras que el `client_golang` de **Go** toma el nombre de la métrica textualmente (así que tipeás `_total` vos mismo). Ambas producen salida idéntica; ninguna está mal — solo hay que conocer el contrato de cada library.
- **6b.** El **mux/router HTTP** (`http.ServeMux` vía `http.Handle("/metrics", ...)`) hace el enrutamiento; solo `/metrics` está registrado, así que `/` da 404. `promhttp.Handler()` es correcto para producción porque negocia el formato de exposición, maneja scrapes concurrentes de forma segura, y puede componerse con middleware de instrumentación y gzip — a diferencia de un writer hecho a mano.
- **6c.** `promauto.NewCounterVec` **registra el collector con el registry por defecto automáticamente** como parte de la construcción. `prometheus.NewCounterVec` a secas devuelve un collector *no registrado*; si te olvidás del `prometheus.MustRegister(...)` explícito, la métrica silenciosamente nunca aparece en `/metrics`. `promauto` previene ese error de "definida pero nunca exportada".

### Ejercicio 7
- **7a.** OpenMetrics requiere que el payload termine con la línea terminadora literal `# EOF`. El formato de texto legacy `0.0.4` no tiene tal marcador.
- **7b.** **Content negotiation** de HTTP: tu header de request `Accept` señaló el formato deseado, y la client library seteó el **`Content-Type`** de la respuesta en consecuencia (`text/plain; version=0.0.4` vs `application/openmetrics-text; version=1.0.0`). Prometheus hace exactamente esto cuando scrapea.
- **7c.** OpenMetrics puede llevar **exemplars** — referencias de trace-id/contexto adjuntas a un sample `_bucket` o de counter (agregadas después de un `#`), que el formato legacy no puede representar. Esto es precisamente la mitad "Exemplars" de este dominio del examen, *Instrumentation and Exemplars*: los exemplars son el puente desde una serie de métrica hacia el trace individual que produjo una observación. (OpenMetrics también modela nativamente los timestamps `_created` y los tipos `Info`/`StateSet`.)

</details>