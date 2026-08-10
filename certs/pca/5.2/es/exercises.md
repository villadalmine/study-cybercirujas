# Topic 5.2 — Instrumentation

> **Laboratorio guiado.** *Instrumentation* es el acto de agregar código emisor de métricas **dentro de tu propia aplicación** usando una **client library** de Prometheus, de modo que el proceso exponga un endpoint HTTP `/metrics` en el formato de exposición de texto. Esto es distinto de los *exporters* (Topic 5.1), que traducen métricas desde sistemas de **terceros** que no podés modificar. Si sos dueño del código fuente, instrumentás; si no lo sos, desplegás un exporter.
>
> Vas a construir un servicio real paso a paso, observar cómo cambia el formato de exposición crudo a medida que avanzás, y razonar sobre tipos de métricas, labels, cardinalidad, histograms, batch jobs y modos de falla en producción.

### Prerequisites

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install prometheus_client flask
# Optional, for the scraping and Pushgateway exercises:
#   docker (to run prom/prometheus and prom/pushgateway)
```

Mantené dos terminales abiertas: una ejecutando tu programa Python, otra ejecutando `curl`.

---

## Exercise 1 — Expose your first metric

1. Creá `app1.py`:

   ```python
   from prometheus_client import start_http_server, Counter
   import time

   # NOTE: no "_total" in the name — the Python client appends it for you.
   REQUESTS = Counter('myapp_requests', 'Total requests processed')

   if __name__ == '__main__':
       start_http_server(8000)          # serves /metrics on :8000
       while True:
           REQUESTS.inc()               # +1 each second
           time.sleep(1)
   ```

2. Ejecutalo: `python3 app1.py`

3. En la segunda terminal, hacé scraping del endpoint después de ~5 segundos:

   ```bash
   curl -s localhost:8000/metrics
   ```

4. Leé la salida. Junto a tu métrica vas a ver **default collectors** que `start_http_server` registra automáticamente en el registry por defecto:

   ```text
   # HELP python_gc_objects_collected_total Objects collected during gc
   # TYPE python_gc_objects_collected_total counter
   python_gc_objects_collected_total{generation="0"} 362.0
   ...
   # HELP process_cpu_seconds_total Total user and system CPU time spent in seconds.
   # TYPE process_cpu_seconds_total counter
   process_cpu_seconds_total 0.04
   # HELP process_resident_memory_bytes Resident memory size in bytes.
   # TYPE process_resident_memory_bytes gauge
   process_resident_memory_bytes 1.4327808e+07
   ...
   # HELP myapp_requests_total Total requests processed
   # TYPE myapp_requests_total counter
   myapp_requests_total 5.0
   # HELP myapp_requests_created Total requests processed
   # TYPE myapp_requests_created gauge
   myapp_requests_created 1.7534096e+09
   ```

5. Fijate en tres cosas: (a) cada métrica está precedida por una línea `# HELP` y una `# TYPE`; (b) tu counter se expone como `myapp_requests_total`, no `myapp_requests`; (c) apareció una segunda serie `myapp_requests_created` que nunca declaraste.

**Q1.1** — Nombraste el counter `myapp_requests`, sin embargo la serie scrapeada es `myapp_requests_total`. ¿Qué pasó, y qué estaría *mal* en nombrarlo `myapp_requests_total` en tu código?

**Q1.2** — ¿Qué es la serie `myapp_requests_created`, cuál es su tipo, y cómo podrías suprimirla?

**Q1.3** — ¿De dónde vinieron `process_cpu_seconds_total` y `process_resident_memory_bytes`, dado que tu código nunca los declaró?

---

## Exercise 2 — The four metric types

Ahora vas a exponer uno de cada tipo core e inspeccionar cómo se renderiza cada uno. Creá `app2.py`:

1. Agregá un **Counter** y un **Gauge**:

   ```python
   from prometheus_client import start_http_server, Counter, Gauge, Histogram, Summary
   import time, random

   PROCESSED = Counter('myapp_items_processed', 'Items processed')
   INFLIGHT  = Gauge('myapp_inflight_requests', 'In-flight requests')
   ```

2. Agregá un **Histogram** con buckets explícitos (segundos — una unidad base) y un **Summary**:

   ```python
   LATENCY = Histogram(
       'myapp_request_duration_seconds', 'Request duration in seconds',
       buckets=(0.1, 0.5, 1, 2.5, 5, 10),
   )
   PROCTIME = Summary('myapp_processing_seconds', 'Time spent processing')
   ```

3. Impulsá las métricas en un loop:

   ```python
   if __name__ == '__main__':
       start_http_server(8000)
       while True:
           INFLIGHT.inc()
           d = random.uniform(0.05, 3.0)
           LATENCY.observe(d)
           PROCTIME.observe(d)
           PROCESSED.inc()
           time.sleep(d)
           INFLIGHT.dec()
   ```

4. Ejecutalo y hacé scraping una vez: `curl -s localhost:8000/metrics | grep myapp_`. Estudiá cada renderizado.

5. El **Histogram** se expande en buckets acumulativos más un `_sum` y `_count`:

   ```text
   # TYPE myapp_request_duration_seconds histogram
   myapp_request_duration_seconds_bucket{le="0.1"} 1.0
   myapp_request_duration_seconds_bucket{le="0.5"} 4.0
   myapp_request_duration_seconds_bucket{le="1.0"} 6.0
   myapp_request_duration_seconds_bucket{le="2.5"} 9.0
   myapp_request_duration_seconds_bucket{le="5.0"} 11.0
   myapp_request_duration_seconds_bucket{le="10.0"} 11.0
   myapp_request_duration_seconds_bucket{le="+Inf"} 11.0
   myapp_request_duration_seconds_sum 18.734
   myapp_request_duration_seconds_count 11.0
   ```

6. El **Summary** en el cliente de Python renderiza **solo** `_sum` y `_count` — sin quantiles:

   ```text
   # TYPE myapp_processing_seconds summary
   myapp_processing_seconds_count 11.0
   myapp_processing_seconds_sum 18.734
   ```

**Q2.1** — Un `Counter` y un `Gauge` pueden ambos contener el número `4`. ¿Cuál es el contrato semántico que los separa, y cuál puede ser reseteado a un valor menor o decrementado?

**Q2.2** — En el paso 5, `..._bucket{le="0.5"}` es `4.0` y `..._bucket{le="1.0"}` es `6.0`. ¿Cuántas observaciones cayeron **en el intervalo** `(0.5, 1.0]`, y por qué no podés leer eso directamente de una sola línea de bucket?

**Q2.3** — El Summary de Python no imprimió líneas `quantile`, pero los docs de Prometheus describen los summaries como portadores de φ‑quantiles del lado del cliente. Reconciliá esto — ¿está mal la documentación, o el cliente?

---

## Exercise 3 — Instrument an HTTP service (RED signals)

Ahora instrumentá un handler HTTP real con las tres señales golden de request — **R**ate, **E**rrors, **D**uration — usando labels. Creá `service.py`:

1. Declará las métricas **una sola vez**, en el momento del import (nunca dentro del handler):

   ```python
   from flask import Flask, Response, request, abort
   from prometheus_client import (
       Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST,
   )
   import time, random

   app = Flask(__name__)

   REQUESTS = Counter(
       'http_requests', 'Total HTTP requests',
       ['method', 'endpoint', 'status'],
   )
   LATENCY = Histogram(
       'http_request_duration_seconds', 'HTTP request latency',
       ['method', 'endpoint'],
   )
   INPROGRESS = Gauge(
       'http_requests_in_progress', 'In-flight HTTP requests',
       ['method', 'endpoint'],
   )
   ```

2. Escribí un handler que sea **exception-safe**, usando los context managers para que el gauge y el timer siempre se liberen incluso si el body lanza una excepción:

   ```python
   @app.route('/work')
   def work():
       ep, m = '/work', request.method
       with INPROGRESS.labels(m, ep).track_inprogress():
           with LATENCY.labels(m, ep).time():
               time.sleep(random.uniform(0.05, 0.4))   # simulate work
               if random.random() < 0.1:               # 10% failures
                   REQUESTS.labels(m, ep, '500').inc()
                   abort(500)
       REQUESTS.labels(m, ep, '200').inc()
       return 'done\n'
   ```

3. Exponé el endpoint de métricas desde el mismo proceso:

   ```python
   @app.route('/metrics')
   def metrics():
       return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

   if __name__ == '__main__':
       app.run(host='0.0.0.0', port=5000)
   ```

4. Ejecutalo (`python3 service.py`), generá carga, luego hacé scraping:

   ```bash
   for i in $(seq 1 40); do curl -s localhost:5000/work >/dev/null; done
   curl -s localhost:5000/metrics | grep -E 'http_requests_total|_in_progress'
   ```

   Forma esperada:

   ```text
   http_requests_total{endpoint="/work",method="GET",status="200"} 36.0
   http_requests_total{endpoint="/work",method="GET",status="500"} 4.0
   http_requests_in_progress{endpoint="/work",method="GET"} 0.0
   ```

5. **(Opcional)** Hacé scraping con un Prometheus real. Creá `prometheus.yml`:

   ```yaml
   global:
     scrape_interval: 5s
   scrape_configs:
     - job_name: 'myapp'
       static_configs:
         - targets: ['host.docker.internal:5000']   # Linux: use your host IP
   ```

   ```bash
   docker run --rm -p 9090:9090 \
     -v "$(pwd)/prometheus.yml:/etc/prometheus/prometheus.yml" \
     prom/prometheus
   ```

   Luego en la UI de Prometheus (`localhost:9090`) ejecutá:

   ```promql
   sum by (status) (rate(http_requests_total[1m]))
   ```

**Q3.1** — ¿Por qué `Counter(...)`, `Histogram(...)` y `Gauge(...)` deben declararse en el scope del módulo y no crearse dentro de `work()` en cada request?

**Q3.2** — El handler usa `track_inprogress()` y `.time()` como context managers en lugar de `.inc()/.dec()` manuales y `time.perf_counter()`. ¿Qué falla de producción previene esto específicamente?

**Q3.3** — Incrementás un `Counter` para requests exitosos, pero el *rate* es un valor por segundo. ¿Por qué exponés un counter monotónico y computás el rate en tiempo de query con `rate(...)`, en lugar de mantener un gauge de "requests por segundo" en la aplicación?

---

## Exercise 4 — Labels, cardinality, and the naming rules

Los labels son poderosos y peligrosos. Este ejercicio hace concreto el peligro.

1. Agregá un counter deliberadamente **malo** a un script de prueba e impulsalo con valores únicos:

   ```python
   from prometheus_client import start_http_server, Counter
   import uuid, time

   BAD = Counter('bad_requests', 'Do not do this', ['user_id', 'request_id'])

   start_http_server(8000)
   for _ in range(1000):
       BAD.labels(user_id=str(uuid.uuid4()), request_id=str(uuid.uuid4())).inc()
   ```

2. Hacé scraping y contá cuántas time series produjo una *sola métrica*:

   ```bash
   curl -s localhost:8000/metrics | grep -c '^bad_requests_total'
   ```

   Vas a ver cerca de `1000` — una time series por cada combinación única de labels. Cada una se almacena, se indexa y se scrapea para siempre.

3. Contrastá con un conjunto de labels **acotado**. Los buenos valores de label vienen de un conjunto pequeño y conocido (`method`, `status_code`, `region`), nunca de entrada no acotada (`user_id`, `email`, `full URL with IDs`, `error message text`).

4. Aplicá las reglas de naming a tus métricas. Un nombre de métrica bien formado:
   - es `snake_case` con un **prefix** de aplicación/librería (`http_`, `myapp_`);
   - lleva una **única unidad base** como sufijo — `_seconds` (no `_milliseconds`), `_bytes` (no `_kilobytes`);
   - termina los counters en `_total`;
   - **nunca** codifica una dimensión que pertenece a un label (escribí `http_requests_total{method="GET"}`, no `http_get_requests_total`).

**Q4.1** — La cardinalidad total es el producto del número de valores distintos de cada label a lo largo de todas las combinaciones que realmente ocurren. Si una métrica tiene labels `method` (4 valores), `status` (6 valores) y `endpoint` (10 valores), ¿cuál es la cota superior teórica de sus time series?

**Q4.2** — ¿Por qué poner `request_id` en un label es catastrófico para Prometheus específicamente, y cuál es el lugar correcto para adjuntar un identificador por request para correlación posterior?

**Q4.3** — Reescribí el nombre `myapp_response_time_ms` para seguir las convenciones, y explicá cada cambio.

---

## Exercise 5 — Histograms vs Summaries and `histogram_quantile`

La decisión de instrumentación más evaluada: ¿histogram o summary?

1. Reutilizá el histogram `http_request_duration_seconds` del Exercise 3. Confirmá que expone `_bucket{le=...}`, `_sum` y `_count`.

2. Estimá la latencia del percentil 95 *en tiempo de query* a partir de los buckets:

   ```promql
   histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
   ```

3. Entendé por qué esto funciona: como los buckets son aditivos a lo largo de series y a lo largo del tiempo, Prometheus puede hacer `sum` por `le` **en el servidor** y luego interpolar el quantile. El resultado es un p95 a nivel de todo el fleet, agregado sobre cada instancia.

4. Ahora considerá un **Summary** con quantiles computados en el cliente (como pueden emitir los clientes de Go/Java):

   ```text
   http_request_duration_seconds{quantile="0.5"}  0.19
   http_request_duration_seconds{quantile="0.9"}  0.32
   http_request_duration_seconds{quantile="0.99"} 0.39
   ```

   Intentá "promediar el p99 a lo largo de tres instancias." No podés — promediar quantiles precomputados es matemáticamente inválido. Esta es la limitación fatal del summary para la agregación.

5. Computá la latencia *promedio*, que funciona con **cualquiera** de los dos tipos, ya que ambos exponen `_sum` y `_count`:

   ```promql
   rate(http_request_duration_seconds_sum[5m])
     /
   rate(http_request_duration_seconds_count[5m])
   ```

**Q5.1** — Enunciá el trade-off central en una oración: ¿qué te da un histogram que un summary no puede, y qué te da un summary que un histogram no puede?

**Q5.2** — El bucket explícito más grande de tu histogram es `le="10.0"` y todas las observaciones aterrizan en `+Inf` por encima de él (los buckets `10.0` y `+Inf` son iguales). ¿Qué devuelve `histogram_quantile(0.99, ...)` en ese régimen, y cuál es el fix?

**Q5.3** — ¿Por qué se aplica `histogram_quantile` a un `rate()` de la serie `_bucket` en lugar de a los counters `_bucket` crudos directamente?

---

## Exercise 6 — Batch jobs and the Pushgateway

Prometheus **hace pull**. Un batch job que corre durante 20 segundos y termina nunca se scrapea a tiempo. El Pushgateway es la excepción sancionada: el job **hace push** de sus métricas finales a un gateway, y Prometheus scrapea el gateway.

1. Iniciá un Pushgateway:

   ```bash
   docker run --rm -d -p 9091:9091 prom/pushgateway
   ```

2. Escribí un batch job `batch.py` que haga push al terminar con éxito:

   ```python
   from prometheus_client import CollectorRegistry, Gauge, push_to_gateway
   import time

   registry = CollectorRegistry()          # isolated registry, NOT the default one
   last_success = Gauge(
       'batch_job_last_success_timestamp_seconds',
       'Unix time of the last successful run',
       registry=registry,
   )
   duration = Gauge(
       'batch_job_duration_seconds', 'Duration of the last run',
       registry=registry,
   )

   start = time.time()
   time.sleep(2)                            # ... the actual work ...
   duration.set(time.time() - start)
   last_success.set_to_current_time()

   push_to_gateway('localhost:9091', job='nightly_backup', registry=registry)
   ```

3. Ejecutalo (`python3 batch.py`), luego leé lo que el gateway sirve ahora:

   ```bash
   curl -s localhost:9091/metrics | grep batch_job
   ```

   ```text
   batch_job_duration_seconds{instance="",job="nightly_backup"} 2.0007
   batch_job_last_success_timestamp_seconds{instance="",job="nightly_backup"} 1.7534101e+09
   ```

4. Apuntá Prometheus al gateway con `honor_labels: true` para que los labels `job`/`instance` empujados ganen:

   ```yaml
   scrape_configs:
     - job_name: 'pushgateway'
       honor_labels: true
       static_configs:
         - targets: ['localhost:9091']
   ```

**Q6.1** — ¿Por qué un batch job es el caso donde hacer push es apropiado, cuando el modelo de Prometheus es por lo demás estrictamente pull-based?

**Q6.2** — El gateway mantiene el último valor empujado **indefinidamente**, incluso después de que el job tuvo éxito y su host ya no está. ¿Por qué esto hace valiosa una alerta de *staleness* como `time() - batch_job_last_success_timestamp_seconds > 86400`, y por qué fallaría acá una alerta simple de "target down"?

**Q6.3** — ¿Por qué el job construye su propio `CollectorRegistry()` en lugar de usar el registry por defecto que usa `start_http_server`?

---

## Exercise 7 — Production gotchas (advanced)

### 7a. Multi-process servers reset your counters

1. Ejecutá `service.py` del Exercise 3 bajo Gunicorn con **4 workers**:

   ```bash
   gunicorn -w 4 -b 0.0.0.0:5000 service:app
   ```

2. Generá carga, luego hacé scraping de `/metrics` **repetidamente**:

   ```bash
   for i in $(seq 1 40); do curl -s localhost:5000/work >/dev/null; done
   curl -s localhost:5000/metrics | grep http_requests_total
   curl -s localhost:5000/metrics | grep http_requests_total   # run again
   ```

   Vas a ver el counter **saltar** entre scrapes — a veces pequeño, a veces distinto — porque cada uno de los 4 workers tiene su **propio registry en su propio proceso**, y el load balancer rutea cada scrape a un worker aleatorio.

3. Corregilo con el **multiprocess mode** del cliente. Configurá un directorio compartido y un hook `child_exit`:

   ```python
   # in a gunicorn config file, gunicorn.conf.py
   import os
   os.environ.setdefault('PROMETHEUS_MULTIPROC_DIR', '/tmp/prom_mp')

   def child_exit(server, worker):
       from prometheus_client import multiprocess
       multiprocess.mark_process_dead(worker.pid)
   ```

   ```python
   # in the /metrics handler, aggregate across all worker files:
   from prometheus_client import CollectorRegistry, multiprocess, generate_latest

   @app.route('/metrics')
   def metrics():
       registry = CollectorRegistry()
       multiprocess.MultiProcessCollector(registry)
       return Response(generate_latest(registry), mimetype=CONTENT_TYPE_LATEST)
   ```

   ```bash
   mkdir -p /tmp/prom_mp && rm -f /tmp/prom_mp/*   # must be empty at startup
   gunicorn -c gunicorn.conf.py -w 4 -b 0.0.0.0:5000 service:app
   ```

### 7b. Exemplars (OpenMetrics)

1. Adjuntá un trace ID a una observación para que un pico de latencia se enlace a un trace específico:

   ```python
   LATENCY.labels(m, ep).observe(0.42, exemplar={'trace_id': 'a1b2c3d4'})
   ```

2. Los exemplars se emiten **solo** en el formato OpenMetrics, así que el scraper debe pedirlo:

   ```bash
   curl -s -H 'Accept: application/openmetrics-text' localhost:5000/metrics \
     | grep -A1 duration_seconds_bucket
   ```

   ```text
   http_request_duration_seconds_bucket{endpoint="/work",method="GET",le="0.5"} 12 # {trace_id="a1b2c3d4"} 0.42 1.7534103e+09
   ```

3. Prometheus los almacena solo cuando se inicia con `--enable-feature=exemplar-storage`.

**Q7.1** — En multi-process mode, `Counter` e `Histogram` agregan correctamente a lo largo de los workers, pero un `Gauge` simple necesita un `multiprocess_mode` (por ej. `'livesum'`, `'max'`, `'liveall'`). ¿Por qué un gauge es fundamentalmente ambiguo de agregar a lo largo de procesos cuando un counter no lo es?

**Q7.2** — En el paso 2 de 7a, antes del fix, el counter scrapeado **bajó** entre dos scrapes. ¿Por qué eso es especialmente destructivo para `rate()` e `increase()`, y qué asume `rate()` sobre un counter que esto viola?

**Q7.3** — ¿Qué es un exemplar, y qué problema en la frontera entre metrics y tracing resuelve que ni un label ni una línea de log pueden?

---

## References

- Metric types — https://prometheus.io/docs/concepts/metric_types/
- Instrumenting your code / client libraries — https://prometheus.io/docs/instrumenting/clientlibs/
- Writing client libraries (semantics) — https://prometheus.io/docs/instrumenting/writing_clientlibs/
- Instrumentation best practices — https://prometheus.io/docs/practices/instrumentation/
- Metric and label naming — https://prometheus.io/docs/practices/naming/
- Histograms and summaries — https://prometheus.io/docs/practices/histograms/
- Exposition formats — https://prometheus.io/docs/instrumenting/exposition_formats/
- Pushing metrics / Pushgateway — https://prometheus.io/docs/instrumenting/pushing/ and https://github.com/prometheus/pushgateway
- Python client (usage, multiprocess, exemplars) — https://prometheus.github.io/client_python/ and https://github.com/prometheus/client_python
- OpenMetrics specification — https://github.com/OpenObservability/OpenMetrics

---

<details>
<summary><strong>Solutions</strong></summary>

**Q1.1** — El cliente de Python agrega automáticamente el sufijo `_total` a las time series de counter (siguiendo la convención de OpenMetrics de que los counters terminan en `_total`). Por lo tanto nombrás la métrica `myapp_requests` y se *expone* como `myapp_requests_total`. Escribir el sufijo vos mismo es el error: peleás contra la convención de la librería y arriesgás un feo `..._total_total` o una advertencia de validación según la versión. Dejá que el cliente lo agregue.

**Q1.2** — `myapp_requests_created` es un **Gauge** que contiene el timestamp Unix (en segundos) en el que el counter fue creado/reseteado por primera vez. Viene de la convención `_created` de OpenMetrics y se emite para counters, histograms y summaries para que los consumidores puedan detectar resets. Podés desactivarlo con `prometheus_client.disable_created_metrics()` en el código, o seteando la variable de entorno `PROMETHEUS_DISABLE_CREATED_SERIES=true`.

**Q1.3** — Del **default registry's default collectors**. `start_http_server` usa el `REGISTRY` global, que tiene un `ProcessCollector` (`process_cpu_seconds_total`, `process_resident_memory_bytes`, open FDs, start time), un `PlatformCollector` (`python_info`) y un `GCCollector` (`python_gc_*`) registrados automáticamente. Obtenés telemetría a nivel de proceso gratis.

**Q2.1** — Un **Counter** es monotónicamente no-decreciente entre resets: solo va para arriba (`.inc()`), y un descenso señala un reinicio del proceso. Responde "cuántos en total, alguna vez." Un **Gauge** es una instantánea que puede ir para arriba *y* para abajo (`.inc()`, `.dec()`, `.set()`); responde "cuál es el valor actual en este momento." Solo el Gauge puede decrecer legítimamente.

**Q2.2** — Los buckets son **acumulativos** (`le` = "less than or equal to"). `le="1.0"` cuenta *todas* las observaciones ≤ 1.0, y `le="0.5"` cuenta todas ≤ 0.5. La cantidad en el intervalo `(0.5, 1.0]` es la diferencia: `6.0 − 4.0 = 2`. No podés leerlo de una sola línea porque cada línea `_bucket` es un total acumulado hasta su umbral, no la población de una sola banda.

**Q2.3** — Ambos son correctos; describen *client libraries distintas*. El `Summary` del cliente de **Python** intencionalmente no implementa φ‑quantiles en streaming, así que expone solo `_sum` y `_count`. Los clientes de Go y Java *pueden* computar quantiles del lado del cliente y emitir series `{quantile="..."}`. El soporte de quantiles en un summary depende del cliente, y esta es una razón fuerte para preferir histograms en Python.

**Q3.1** — Los objetos de métrica se registran a sí mismos con el registry en la construcción. Recrearlos por request lanzaría un error "duplicated timeseries / already registered" (o, si lo sorteás, tirarías el estado acumulado en cada llamada, así que el counter nunca subiría). Declará cada métrica **una vez** en el scope del módulo; luego llamá `.labels(...).inc()/.observe()` por request. El objeto de métrica es de larga vida; solo los lookups de labels son por request.

**Q3.2** — Seguridad ante excepciones. Si el body del handler lanza una excepción después de un `INPROGRESS.inc()` manual (o después de iniciar un timer manual), el `.dec()` / stop correspondiente nunca corre, así que el gauge de in-flight **se fuga hacia arriba para siempre** y la latencia de los requests fallidos nunca se registra. `track_inprogress()` y `.time()` son context managers cuyo `__exit__` corre incluso ante una excepción, garantizando que el gauge se decremente y la duración se observe.

**Q3.3** — Un counter es la primitiva correcta porque sobrevive a los scrapes sin pérdidas: Prometheus puede computar el rate de *cualquier* ventana temporal a partir de dos muestras, tolerar scrapes perdidos y detectar resets. Un gauge de "requests por segundo" computado en la app fija una única ventana de promediado, pierde información entre scrapes, y no se puede re-agregar. La regla es **exponer conteos monotónicos crudos; derivar rates en tiempo de query** con `rate()`/`irate()`.

**Q4.1** — `4 × 6 × 10 = 240` time series en el peor caso (cada combinación ocurre). La cardinalidad es multiplicativa a lo largo de los labels — la razón por la que un solo label descuidado puede hacer explotar una métrica.

**Q4.2** — Prometheus crea e indexa **una time series por cada label-set único**, y la almacena esencialmente para siempre (sujeto a retención). Un label no acotado como `request_id` produce una nueva serie en cada request, haciendo explotar la memoria, el índice y el costo de query — una manera clásica de hacer OOM a un servidor de Prometheus. Los identificadores por request pertenecen a **traces y logs** (o como un **exemplar** adjunto a una muestra de métrica), no como un label de métrica.

**Q4.3** — `myapp_http_request_duration_seconds`. Cambios: mantené el **prefix** `myapp_`/`http_`; convertí la unidad de milisegundos a la **unidad base segundos** (`_ms` → `_seconds`), porque la convención de Prometheus son las unidades base; usá `duration` de manera consistente; y asegurate de que sea un histogram de `_seconds`. Si fuera un counter terminaría en `_total`; un histogram de duración termina en la unidad.

**Q5.1** — Un **histogram** almacena conteos por bucket que son aditivos, así que los quantiles pueden computarse y **agregarse a lo largo de instancias en tiempo de query** (`histogram_quantile` sobre un `sum by (le)`), a costa de buckets preelegidos y aproximación. Un **summary** da un quantile **exacto** del lado del cliente sin configuración de buckets, pero esos quantiles **no pueden agregarse** a lo largo de instancias ni re-ventanearse. Histogram = agregable/aproximado; summary = exacto/no-agregable.

**Q5.2** — Una vez que el quantile solicitado cae en el bucket superior acotado por `+Inf` (acá todo por encima de `10.0`), `histogram_quantile` no puede interpolar — el borde superior es infinito — así que devuelve el **límite inferior de ese bucket** (el borde inferior de `+Inf` = el último límite finito, `10.0`) o `+Inf`, es decir, un valor inútil/clampeado. El fix es **agregar buckets más altos** para que las observaciones reales aterricen en rangos finitos (elegí los límites de los buckets alrededor de tu distribución de latencia real/SLO).

**Q5.3** — Las series `_bucket` son **counters** (siempre crecientes). Alimentar counters crudos a `histogram_quantile` mezclaría toda la historia desde el inicio del proceso y sería sensible a los resets del counter. Aplicar primero `rate(..._bucket[5m])` convierte cada bucket a un rate por segundo sobre una ventana, normalizando para los resets y dando el quantile de la distribución **reciente** — que es lo que querés para alertar y armar dashboards.

**Q6.1** — Los batch/cron jobs son **de corta vida y terminan**, así que un scraper pull-based en un intervalo de 15–60 s usualmente los va a perder por completo — no hay un endpoint de larga vida al cual hacer pull. Empujar los resultados finales del job al Pushgateway le da a Prometheus una superficie estable, siempre scrapeable. (Es *solo* para batch jobs a nivel de servicio, no un workaround general para el modelo de pull.)

**Q6.2** — El gateway retiene el último push para siempre, así que la serie `batch_job_last_success_timestamp_seconds` está siempre presente incluso mucho después de que el job/host desaparezca. Una alerta de "target down" por lo tanto nunca dispara (el target del gateway sigue arriba). La alerta significativa es sobre la **staleness del valor en sí** — `time() - batch_job_last_success_timestamp_seconds > 86400` dice "ninguna corrida exitosa en un día," que es exactamente la falla que tiene un batch job.

**Q6.3** — `push_to_gateway` debe enviar **solo las métricas de este job**, no los collectors de proceso/GC/plataforma del registry por defecto. Usar un `CollectorRegistry()` fresco aísla el payload para que empujes un conjunto de series limpio y deliberado y no contamines el gateway con métricas de proceso por invocación que además cargarían semánticas confusas.

**Q7.1** — Un counter a lo largo de procesos es inequívoco: el valor del fleet es la **suma** del conteo monotónico de cada worker. Un gauge es una *instantánea actual*, así que "el valor a lo largo de 4 workers" no tiene un único significado correcto — ¿querés la suma de requests in-flight (`livesum`), el máximo, todos los valores mantenidos como series separadas (`liveall`), el último? El cliente te obliga a declarar `multiprocess_mode` porque la agregación es una elección semántica, no un hecho.

**Q7.2** — `rate()` e `increase()` asumen que el counter es **monotónico**: cualquier descenso se interpreta como un *reset* del counter, y la función compensa sumando el valor previo al reset. Cuando los scrapes rebotan entre workers con conteos parciales distintos, la serie tiembla para arriba y para abajo, así que `rate()` ve resets fantasma y **sobre-cuenta masivamente** (cada caída aparente se trata como un reinicio y se suma de nuevo), produciendo rates enormemente inflados. La agregación multiproceso da una única vista monotónica que restaura la suposición.

**Q7.3** — Un exemplar es una observación de ejemplo específica (por ej. la latencia de un request) adjunta a una muestra de métrica, que carga labels como `trace_id` más el valor y el timestamp — emitida solo en el formato OpenMetrics. Tiende un puente entre **métricas agregadas** y **traces individuales**: desde un pico de latencia p99 en un dashboard podés saltar directamente a *un trace real que estaba en ese bucket*. Un label de métrica no puede hacer esto (haría explotar la cardinalidad), y una línea de log no está enlazada desde el punto de métrica — el exemplar es el puntero desde "el gráfico subió" hasta "acá hay un request que lo causó."

</details>