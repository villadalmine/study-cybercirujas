# PCA Tema 1.6 — Histogramas: Ejercicios guiados

> **Formato.** Cada ejercicio es un procedimiento numerado y ejecutable. Después de cada bloque hay **preguntas de comprensión** (Q1, Q2, …). Todas las respuestas viven en la única sección colapsable al final de todo. Todo lo de aquí es reproducible en una laptop con Docker (o un binario local de `prometheus`/`promtool`) y Python 3.
>
> **Qué *es* un histograma, en una línea.** Un histograma de Prometheus muestrea observaciones (normalmente duraciones o tamaños de solicitudes) y las cuenta en buckets **acumulativos**, exponiendo tres series derivadas — `<name>_bucket{le="..."}`, `<name>_sum`, `<name>_count` — a partir de las cuales el servidor calcula cuantiles *en tiempo de consulta*. Contrastá con un summary, que calcula los cuantiles *del lado del cliente* y no puede re-agregarse. ([metric_types](https://prometheus.io/docs/concepts/metric_types/#histogram), [practices/histograms](https://prometheus.io/docs/practices/histograms/))

**Requisitos previos para todo el conjunto**

```bash
# Option A: containers (recommended, self-contained)
docker --version          # any recent Docker
# Option B: local binaries
prometheus --version      # 2.40+ for native histograms; 3.x preferred
promtool --version
python3 --version         # 3.8+
pip install prometheus_client
```

---

## Ejercicio 1 — Anatomía de un histograma en el cable

**Objetivo:** leer un histograma clásico real directamente desde un endpoint de exposición e identificar cada componente antes de tocar PromQL.

1. Arrancá Prometheus para que se scrapee *a sí mismo* (su propio handler HTTP está instrumentado con un histograma):

   ```bash
   docker run --rm -d --name prom -p 9090:9090 prom/prometheus:v3.1.0
   ```

2. Generá un poco de tráfico propio para que el histograma no esté vacío, y después scrapeá la exposición cruda:

   ```bash
   for i in $(seq 1 30); do curl -s localhost:9090/api/v1/query?query=up >/dev/null; done
   curl -s localhost:9090/metrics | grep 'prometheus_http_request_duration_seconds' | grep 'query'
   ```

3. Leé la salida. Vas a ver algo estructuralmente así (los valores difieren):

   ```text
   # HELP prometheus_http_request_duration_seconds Histogram of latencies for HTTP requests.
   # TYPE prometheus_http_request_duration_seconds histogram
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.1"} 30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.2"} 30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.4"} 30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="1"}   30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="3"}   30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="8"}   30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="20"}  30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="60"}  30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="120"} 30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="+Inf"} 30
   prometheus_http_request_duration_seconds_sum{handler="/api/v1/query"}   0.041231
   prometheus_http_request_duration_seconds_count{handler="/api/v1/query"} 30
   ```

4. Confirmá las dos invariantes a ojo:
   - los valores de `le` solo aumentan, y el último es `+Inf`;
   - el conteo en el bucket `+Inf` es igual al valor de `..._count`.

**Preguntas de comprensión**

- **Q1.** El bucket `le="1"` marca `30`. ¿Significa eso que "30 solicitudes tardaron *exactamente* entre 0.4s y 1s"? ¿Qué cuenta en realidad?
- **Q2.** ¿Por qué el bucket `+Inf` es obligatorio, y a qué único valor debe ser siempre igual?
- **Q3.** Si dividieras `..._sum` por `..._count` (acá `0.041231 / 30`), ¿qué obtendrías, y por qué ese valor *no* sustituye al p90?
- **Q4.** El exporter de un colega emite `le="0.10000000000000001"` en lugar de `le="0.1"`. ¿Por qué esto es un peligro operativo real para la agregación entre targets?

---

## Ejercicio 2 — Instrumentá tu propio histograma y elegí los buckets

**Objetivo:** sentir la decisión de diseño más consecuente — los límites de los buckets — y ver cómo la biblioteca cliente deriva las tres series.

1. Guardá esto como `app.py`. Expone un histograma con buckets **elegidos a mano** y simula una latencia distribuida exponencialmente (media ≈ 0.25s):

   ```python
   import random, time
   from prometheus_client import start_http_server, Histogram

   LATENCY = Histogram(
       "app_request_latency_seconds",
       "End-to-end request latency in seconds",
       # Boundaries clustered around the region we care about (an SLO near 0.3s),
       # not a uniform 0..5 ramp. This is the whole game.
       buckets=(0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 2.5, 5.0),
   )

   @LATENCY.time()            # times the wrapped call and observes it
   def handle_request():
       time.sleep(random.expovariate(1 / 0.25))

   if __name__ == "__main__":
       start_http_server(8000)
       while True:
           handle_request()
   ```

2. Ejecutalo, y después scrapeá su endpoint:

   ```bash
   python3 app.py &
   sleep 5
   curl -s localhost:8000/metrics | grep app_request_latency_seconds
   ```

3. Inspeccioná la exposición. Fijate que la biblioteca cliente agregó `le="+Inf"` por vos y que los buckets son monótonamente no decrecientes:

   ```text
   # TYPE app_request_latency_seconds histogram
   app_request_latency_seconds_bucket{le="0.05"} 118.0
   app_request_latency_seconds_bucket{le="0.1"}  221.0
   app_request_latency_seconds_bucket{le="0.2"}  392.0
   app_request_latency_seconds_bucket{le="0.3"}  505.0
   app_request_latency_seconds_bucket{le="0.5"}  643.0
   app_request_latency_seconds_bucket{le="0.75"} 731.0
   app_request_latency_seconds_bucket{le="1.0"}  779.0
   app_request_latency_seconds_bucket{le="2.5"}  818.0
   app_request_latency_seconds_bucket{le="5.0"}  824.0
   app_request_latency_seconds_bucket{le="+Inf"} 825.0
   app_request_latency_seconds_sum   214.77
   app_request_latency_seconds_count 825.0
   ```

4. Apuntá un Prometheus hacia él. Creá `prometheus.yml`:

   ```yaml
   global:
     scrape_interval: 5s
     evaluation_interval: 5s
   scrape_configs:
     - job_name: demo-app
       static_configs:
         - targets: ["host.docker.internal:8000"]   # or localhost:8000 for a local binary
   ```

   ```bash
   docker run --rm -d --name prom2 -p 9091:9090 \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     --add-host=host.docker.internal:host-gateway \
     prom/prometheus:v3.1.0
   ```

5. Dejalo scrapear por ~2 minutos para que las ventanas de `rate()` del Ejercicio 3 tengan datos.

**Preguntas de comprensión**

- **Q5.** Elegiste 9 buckets finitos ajustados alrededor de 0.3s. ¿Cuáles son los dos costos que pagarías si en cambio usaras 50 buckets de 0.001 a 100? Nombrá el recurso específico de Prometheus que escala con la cantidad de buckets y en qué factor por serie/target.
- **Q6.** El bucket finito más alto es `le="5.0"`. A partir de los números de arriba, ¿aproximadamente cuántas observaciones excedieron los 5.0s, y de dónde lo leés?
- **Q7.** `@LATENCY.time()` — ¿en qué momento se registra la observación, al inicio o al final de la llamada, y qué le pasaría al histograma si la función envuelta lanzara una excepción? (Razonalo; el decorador usa un context manager.)

---

## Ejercicio 3 — Cuantiles: el patrón `histogram_quantile` + `rate`

**Objetivo:** calcular p50/p90/p99 correctamente, e interiorizar *por qué* están ahí los dos wrappers obligatorios (`rate`, `sum by (le)`).

1. Ejecutá una consulta instantánea de p90 con `promtool`:

   ```bash
   promtool query instant http://localhost:9091 \
     'histogram_quantile(0.9, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))'
   ```

   Forma esperada (valor cercano a la región 0.75–1.0 para esta distribución):

   ```text
   {} => 0.71 @[1754655600.000]
   ```

2. Ahora ejecutá p50, p90 y p99 juntos en el explorador de expresiones (`http://localhost:9091/graph`) o como tres llamadas de `promtool`:

   ```promql
   histogram_quantile(0.50, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))
   histogram_quantile(0.90, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))
   histogram_quantile(0.99, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))
   ```

   Resultados típicos:

   ```text
   p50 => 0.196
   p90 => 0.706
   p99 => 4.83     # <-- notice how imprecise this one is; Exercise 4 explains it
   ```

3. **Rompé** deliberadamente la consulta de dos maneras y observá los modos de falla:

   ```promql
   # (a) Forget rate(): feed raw ever-growing counters straight in.
   histogram_quantile(0.9, sum by (le) (app_request_latency_seconds_bucket))

   # (b) Drop the le label during aggregation.
   histogram_quantile(0.9, sum(rate(app_request_latency_seconds_bucket[1m])))
   ```

   La consulta (b) devuelve `NaN`. La consulta (a) devuelve un número plausible pero sin sentido que nunca reacciona a cambios recientes de latencia.

**Preguntas de comprensión**

- **Q8.** `histogram_quantile` necesita la *tasa de aumento* de cada bucket, no el valor crudo del bucket. Explicá, en términos de qué es una serie `_bucket`, por qué aplicar `rate()` primero no es opcional. ¿Qué evento real corrompería silenciosamente la versión con contador crudo?
- **Q9.** ¿Por qué al eliminar `le` (consulta b) se obtiene `NaN` en vez de un número equivocado? ¿Qué es estructuralmente incapaz de hacer `histogram_quantile` sin esa etiqueta?
- **Q10.** El Equipo A grafica `avg(histogram_quantile(0.99, ...))` a través de 20 pods. El Equipo B grafica `histogram_quantile(0.99, sum by (le) (rate(..._bucket[5m])))`. Solo uno es estadísticamente válido. ¿Cuál, y cuál es el nombre del error que comete el otro?
- **Q11.** El p99 volvió como `4.83`, sospechosamente cercano a tu bucket finito superior de `5.0`. Predecí qué devuelve `histogram_quantile(0.999, ...)` y por qué *no puede* exceder un número específico.

---

## Ejercicio 4 — Agregación, error de interpolación, y un SLO Apdex

**Objetivo:** agregar un histograma a través de una dimensión, cuantificar el error incorporado en la interpolación de buckets, y construir una señal de SLO real directamente desde los buckets.

1. **Error de interpolación, hecho visible.** Tus buckets saltan `1.0 → 2.5 → 5.0 → +Inf`. Cualquier cuantil que caiga en `(1.0, 2.5]` es *interpolado linealmente* a través de un bucket de 1.5s de ancho, asumiendo una distribución uniforme que tu cola exponencial no tiene. Confirmá el mecanismo pidiendo un cuantil que sabés que se sitúa en el bucket finito superior:

   ```promql
   histogram_quantile(0.995, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))
   ```

   Va a devolver un valor clavado cerca de `5.0` sin importar cuán mala sea la cola real, porque no hay resolución por encima de `5.0` — solo `+Inf`.

2. **Arreglo por diseño (no lo ejecutes todavía — razonalo):** para medir la cola honestamente agregarías buckets finitos *por encima* de la región de interés (p. ej. `7.5, 10, 20`). El lugar correcto para gastar el presupuesto de buckets es donde vivan tus umbrales de SLO y límites de alerta.

3. **Construí un puntaje Apdex** — un ratio de satisfacción con objetivo `T = 0.3s` (así "tolerante" ≤ `4T = 1.2s`). Como tus buckets son acumulativos, los conteos que necesitás son *exactamente* límites de buckets — pero fijate que no tenés `le="1.2"`. Agregalo en el `buckets=(...)` de `app.py` (insertá `1.2`) y reiniciá, **o** usá los límites disponibles más cercanos `0.3` y `1.0` para este ejercicio. La consulta de Apdex:

   ```promql
   (
       sum(rate(app_request_latency_seconds_bucket{le="0.3"}[5m]))
     + sum(rate(app_request_latency_seconds_bucket{le="1.2"}[5m]))
   ) / 2 / sum(rate(app_request_latency_seconds_bucket{le="+Inf"}[5m]))
   ```

   El resultado es un número en `[0,1]`, p. ej. `=> 0.68`.

4. **Ratio estilo error-budget** — fracción de solicitudes más lentas que el SLO de 0.3s:

   ```promql
   1 - (
       sum(rate(app_request_latency_seconds_bucket{le="0.3"}[5m]))
     /
       sum(rate(app_request_latency_seconds_bucket{le="+Inf"}[5m]))
   )
   ```

**Preguntas de comprensión**

- **Q12.** Derivá la fórmula de Apdex del paso 3 a partir de su definición — `(satisfied + tolerating/2) / total`, donde *satisfied* ≤ `T` y *tolerating* está en `(T, 4T]`. Mostrá por qué, con buckets acumulativos, colapsa a `(bucket_T + bucket_4T) / (2 · bucket_+Inf)`.
- **Q13.** ¿Por qué la consulta "fracción más lenta que 0.3s" del paso 4 es **exacta** (salvo la granularidad de scrape), mientras que el p99 del Ejercicio 3 es solo una *estimación*? ¿Qué diferencia estructural entre las dos preguntas elimina la interpolación?
- **Q14.** Querés un p99 más preciso sin inflar la cantidad de buckets en todos lados. ¿Dónde agregás los dos o tres buckets que te podés permitir, y qué principio decide su ubicación?
- **Q15.** `histogram_quantile` interpola asumiendo una distribución *uniforme* dentro de cada bucket. Para una latencia exponencial/de cola larga, ¿esto tiende a sobre- o subestimar un cuantil que cae profundo dentro de un bucket ancho? Dá la intuición.

---

## Ejercicio 5 — Histogramas nativos (la alternativa moderna)

**Objetivo:** contrastar los clásicos (con buckets, una serie por límite) con los **histogramas nativos** — una única serie que lleva buckets dispersos, exponenciales y con resolución automática — y ver cómo cambia la superficie de consulta.

1. Los histogramas nativos todavía están detrás de un feature flag. Reiniciá Prometheus con él habilitado:

   ```bash
   docker run --rm -d --name prom3 -p 9092:9090 \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     --add-host=host.docker.internal:host-gateway \
     prom/prometheus:v3.1.0 \
     --config.file=/etc/prometheus/prometheus.yml \
     --enable-feature=native-histograms
   ```

   Con el flag activo, Prometheus negocia el formato de exposición **protobuf** en tiempo de scrape para poder ingerir histogramas nativos. ([feature_flags](https://prometheus.io/docs/prometheus/latest/feature_flags/#native-histograms), [native histograms spec](https://prometheus.io/docs/specs/native_histograms/))

2. Un histograma nativo debe ser *emitido* por el cliente. En Go (`client_golang`), la misma métrica se vuelve nativa configurando un **factor** de bucket en lugar de una lista fija de límites:

   ```go
   latency := prometheus.NewHistogram(prometheus.HistogramOpts{
       Name: "app_request_latency_seconds",
       Help: "End-to-end request latency in seconds",
       // Native histogram: exponential buckets that auto-adjust resolution.
       NativeHistogramBucketFactor:     1.1,        // ~10% width per bucket
       NativeHistogramMaxBucketNumber:  100,        // cap cardinality per series
       NativeHistogramMinResetDuration: time.Hour,  // schema-reset guard
       // No `Buckets: []float64{...}` at all.
   })
   ```

3. Consultalo. **El contraste más importante:** no hay sufijo `_bucket` ni etiqueta `le` que preservar — el histograma nativo es una única muestra, así que `rate()` por sí solo lo reconstituye y `histogram_quantile` lo toma directamente:

   ```promql
   # Classic (Exercises 3-4):
   histogram_quantile(0.9, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))

   # Native — no _bucket, no `by (le)`:
   histogram_quantile(0.9, rate(app_request_latency_seconds[1m]))
   ```

4. Usá las funciones de acceso exclusivas de nativos que leen una muestra de histograma como un todo:

   ```promql
   histogram_count(rate(app_request_latency_seconds[1m]))          # observations/sec
   histogram_sum(rate(app_request_latency_seconds[1m]))            # summed value/sec
   histogram_avg(rate(app_request_latency_seconds[1m]))            # sum/count
   histogram_fraction(0, 0.3, rate(app_request_latency_seconds[1m]))  # fraction ≤ 0.3s, no bucket-boundary needed
   ```

   `histogram_fraction(0, 0.3, ...)` te da tu ratio de SLO del Ejercicio 4 paso 4 — pero para *cualquier* umbral, no solo donde casualmente ubicaste un bucket. ([querying functions](https://prometheus.io/docs/prometheus/latest/querying/functions/#histograms))

**Preguntas de comprensión**

- **Q16.** Un histograma clásico con 10 buckets produce ¿cuántas series temporales *por combinación de etiquetas*? ¿Y un histograma nativo cuántas produce? Enunciá ambos números y por qué el conteo del nativo es el mismo sin importar la resolución.
- **Q17.** ¿Por qué la consulta de cuantil del histograma nativo elimina tanto el sufijo `_bucket` *como* el wrapper `sum by (le)` que eran obligatorios para los histogramas clásicos?
- **Q18.** `histogram_fraction(0, 0.3, ...)` responde el ratio de SLO del Ejercicio 4 para un corte *arbitrario* de 0.3s. ¿Por qué un histograma clásico solo puede responder eso exactamente cuando `0.3` resulta ser un límite de bucket, mientras que un histograma nativo no está tan restringido (y cuál es la fuente residual de su pequeño error)?
- **Q19.** Tus dashboards todavía hacen `sum by (le)` sobre esta métrica después de cambiarla a nativa. ¿Qué pasa, y cómo lo notarías? (Considerá `always_scrape_classic_histograms` en la config de scrape.)

---

## Ejercicio 6 — Diagnóstico: leyendo resultados `NaN`, vacíos y clavados

**Objetivo:** convertir los modos de falla en una checklist que puedas correr bajo presión de examen.

1. Reproducí **"el cuantil devuelve `NaN`"** de tres maneras distintas y registrá la causa de cada una:

   ```promql
   # (a) No traffic in the window → every bucket rate is 0.
   histogram_quantile(0.9, sum by (le) (rate(app_request_latency_seconds_bucket[10s])))
   #     (run right after a fresh Prometheus start, before enough samples)

   # (b) le dropped by aggregation (from Exercise 3b).
   histogram_quantile(0.9, sum(rate(app_request_latency_seconds_bucket[1m])))

   # (c) Fewer than two buckets survive a filter.
   histogram_quantile(0.9, sum by (le) (rate(app_request_latency_seconds_bucket{le="+Inf"}[1m])))
   ```

2. Reproducí **"el cuantil clavado al bucket superior"** y conectalo con el Ejercicio 4:

   ```promql
   histogram_quantile(0.9999, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))
   ```

3. Confirmá la **regla práctica de la ventana de rate** — el rango debe abarcar al menos ~4 intervalos de scrape. Con `scrape_interval: 5s`, compará `[1m]` (12 muestras, estable) contra `[8s]` (≈1–2 muestras, con jitter/vacío):

   ```promql
   histogram_quantile(0.9, sum by (le) (rate(app_request_latency_seconds_bucket[8s])))
   ```

4. Verificá la **cardinalidad de buckets** antes de que te muerda — listá los valores distintos de `le` que lleva una métrica:

   ```promql
   count by (le) (app_request_latency_seconds_bucket)
   ```

**Preguntas de comprensión**

- **Q20.** Para cada uno de los tres productores de `NaN` del paso 1, nombrá la causa raíz en una cláusula.
- **Q21.** ¿Por qué pedir `0.9999` devuelve confiablemente tu `le` *finito* más alto (acá `5.0`) en vez de algo más grande? ¿Qué es lo que el bucket `+Inf` *no* te da?
- **Q22.** Una ventana de `rate()` demasiado corta sobre un bucket de histograma puede producir `NaN` o cuantiles que oscilan. Enunciá la regla "≥ 4× el intervalo de scrape" y por qué menos de dos muestras en la ventana es fatal para `rate()`.
- **Q23.** Sospechás que una métrica está haciendo explotar tu TSDB. `count by (le) (some_bucket)` muestra 40 valores de `le` a través de 200 targets. ¿Cuántas *series* de buckets son eso, y a cuál de counter/gauge/histogram recurrirías si pudieras tolerar el re-cuantilado del lado del servidor pero no esta cardinalidad?

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

**Q1.** El bucket `le="1"` es **acumulativo**: cuenta cada observación **≤ 1s**, es decir todas las solicitudes que tardaron *hasta* 1 segundo — no solo las que están entre 0.4s y 1s. Para obtener el conteo del segmento `(0.4, 1]` restás: `bucket{le="1"} − bucket{le="0.4"}`. El conteo acumulativo es exactamente lo que le permite al servidor interpolar cuantiles después.

**Q2.** El bucket `+Inf` captura cada observación sin importar su tamaño, así que es el total. Es obligatorio porque `histogram_quantile` necesita el gran total para localizar la posición de rango `φ · total`. Debe ser siempre igual a `..._count`. Si un exporter lo omitiera, los cuantiles por encima del último bucket finito serían incalculables.

**Q3.** `sum / count` es la **media aritmética** de la latencia (≈ 0.0014s acá — en realidad `0.041231/30`). No es el p90 porque la media está dominada por el grueso y esconde la cola: un servicio puede tener una media excelente y un p99 terrible. Los percentiles responden "qué tan malo es para el N% desafortunado"; la media no puede.

**Q4.** `le` es una **etiqueta de tipo string**, y `0.10000000000000001` y `0.1` son *valores de etiqueta diferentes*. Cuando hacés `sum by (le)` a través de targets, las dos escrituras no se fusionan — obtenés dos buckets a medio poblar, la monotonicidad acumulativa se rompe, y `histogram_quantile` produce resultados equivocados o `NaN`. Las bibliotecas cliente normalizan el formateo de floats para evitar esto; un exporter hecho a mano puede reintroducirlo.

**Q5.** Costo 1 — **cardinalidad de series temporales**: un histograma clásico crea *una serie por `le`* (más `_sum` y `_count`). 50 buckets ≈ 52 series **por combinación de etiquetas por target**; multiplicado a través de targets y otras etiquetas esto domina la memoria, el disco y el costo de consulta del TSDB. Costo 2 — **volumen de scrape/ingesta y `sum by (le)` más lento** sobre más series. El recurso que escala linealmente con la cantidad de buckets son las series temporales activas (y por lo tanto la memoria del head block), aproximadamente `(buckets + 2)` por identidad de serie.

**Q6.** `count − bucket{le="5.0"} = 825 − 824 = 1` observación excedió los 5.0s. Lo leés como `+Inf` menos el bucket finito más alto: `bucket{le="+Inf"} − bucket{le="5.0"}`.

**Q7.** La observación se registra al **final** de la llamada, cuando el temporizador/context manager sale (mide el tiempo de reloj transcurrido). Como `@Histogram.time()` usa un context manager, la observación se registra **incluso si la función lanza una excepción** — el `__exit__` se ejecuta durante la propagación de la excepción. Así que las excepciones se cronometran y cuentan como cualquier otra solicitud (*no* se descartan silenciosamente).

**Q8.** Una serie `_bucket` es un **contador monótonamente creciente** (total de observaciones ≤ le desde el inicio del proceso). Su valor crudo lleva toda la historia y se reinicia a 0 al reiniciar el proceso. `histogram_quantile` necesita la *forma actual* de la distribución — el aumento reciente por segundo de cada bucket — así que primero tenés que hacer `rate()` (o `increase()`). El evento real que corrompe la versión con contador crudo es un **reinicio de proceso / reinicio de contador**: `rate()` maneja el reinicio; un contador crudo mostraría una caída sin sentido y una línea base siempre creciente y congelada que nunca refleja la latencia reciente.

**Q9.** `histogram_quantile` reconstruye la distribución acumulativa *a partir de los límites `le`*. Eliminá `le` y colapsaste todos los buckets en un único número — no hay escalera de umbrales para interpolar, así que la función no tiene nada por dónde caminar y devuelve `NaN`. Es estructuralmente incapaz de localizar un rango sin los límites de bucket.

**Q10.** **El Equipo B** es válido. El Equipo A comete el clásico error de **promediar cuantiles** (promediar percentiles a través de series es matemáticamente absurdo — el promedio de los p99 por pod no es el p99 de la flota). El enfoque correcto es agregar los **buckets** con `sum by (le)` *primero*, y después tomar el cuantil una sola vez sobre la distribución fusionada.

**Q11.** `histogram_quantile(0.999, ...)` también devuelve un valor ≤ **5.0** (tu `le` *finito* más alto). No puede exceder 5.0 porque por encima de él solo está `+Inf`, que no tiene límite superior numérico hacia el cual interpolar — Prometheus devuelve el límite finito más alto. Cualquier cuantil cuyo rango caiga en el bucket `+Inf` se reporta en ese límite, que es por lo que la cola parece artificialmente topada.

**Q12.** Definición: `Apdex = (satisfied + tolerating/2) / total`, con `satisfied = count(≤T)` y `tolerating = count(≤4T) − count(≤T)`. Sustituí:
`= [count(≤T) + (count(≤4T) − count(≤T))/2] / total`
`= [count(≤T)/2 + count(≤4T)/2] / total`
`= (count(≤T) + count(≤4T)) / (2 · total)`.
Con buckets acumulativos `count(≤T) = bucket{le="T"}`, `count(≤4T) = bucket{le="4T"}`, `total = bucket{le="+Inf"}`, dando `(bucket_T + bucket_4T) / (2 · bucket_+Inf)`.

**Q13.** La consulta del paso 4 hace una pregunta cuyo límite (`0.3`) **es un borde de bucket real**, así que el conteo de solicitudes ≤ 0.3 está almacenado *exactamente* en ese bucket acumulativo — sin interpolación. Un cuantil (p99) pregunta "¿qué latencia tiene el 99% por debajo?" — la respuesta casi nunca cae en un borde de bucket, así que Prometheus debe **interpolar dentro de un bucket**, y esa estimación es solo tan buena como el ancho del bucket ahí.

**Q14.** Agregá los buckets extra **alrededor de la latencia específica donde cae el p99 y alrededor de tus umbrales de SLO/alerta** — las regiones que realmente consultás. Principio: la resolución de buckets debe ser más alta donde se toman decisiones; los buckets anchos están bien en rangos que nunca cuantilás. No repartas los buckets uniformemente; concentralos en los umbrales.

**Q15.** La interpolación asume que las observaciones se distribuyen **uniformemente** a través del bucket. Una distribución de cola larga/exponencial tiene *más masa cerca del borde inferior* de un bucket ancho, así que un cuantil profundo dentro del bucket tiende a ser **sobreestimado** (el modelo lineal ubica el rango más alto de lo que lo haría la distribución real, cargada hacia el frente). El remedio son buckets más angostos en esa región (o histogramas nativos).

**Q16.** Clásico con 10 buckets → las 10 series `_bucket` **más `_sum` y `_count` = 12 series** por combinación de etiquetas (el bucket `+Inf` es uno de los diez si lo contás entre ellos; el punto es ~N+2). Un histograma nativo → **1 serie** por combinación de etiquetas, porque todos los buckets, la suma y el conteo viajan dentro de una única muestra. El conteo del nativo se mantiene en 1 sin importar la resolución porque mayor resolución agrega *spans dispersos dentro de la muestra*, no nuevas series.

**Q17.** Porque un histograma nativo es una **única muestra que ya contiene todos sus buckets**. No hay una serie hija `_bucket` separada que nombrar, ni etiqueta `le` que preservar durante la agregación — `rate()` reconstituye el histograma completo, y `sum(rate(...))` (plano, o `sum by (job)`, etc.) fusiona histogramas elemento por elemento. `histogram_quantile` entonces lee la muestra fusionada directamente.

**Q18.** Un histograma clásico solo *conoce* los conteos en sus límites predefinidos; un corte que no sea un límite debe interpolarse, y si está entre límites la respuesta es una estimación — exacta solo cuando el umbral es igual a un borde de bucket. Un histograma nativo tiene resolución fina y exponencial en todos lados, así que `histogram_fraction(0, 0.3, ...)` encuentra un límite muy cercano a 0.3 para casi cualquier umbral. El error residual es solo el propio ancho de bucket del histograma nativo en ese valor (gobernado por el factor, p. ej. ~10% para 1.1) más la interpolación dentro de él — mucho más chico e independiente del umbral.

**Q19.** Después de cambiar a nativo, **no hay serie `..._bucket` ni etiqueta `le`**, así que `sum by (le) (rate(..._bucket[...]))` no matchea nada y devuelve **vacío** — los dashboards quedan en blanco en vez de dar error. Lo notás por los paneles vacíos. Para mantener los viejos dashboards basados en clásicos funcionando durante la migración, configurá **`always_scrape_classic_histograms: true`** en la config de scrape para que Prometheus ingiera *tanto* los buckets clásicos como el histograma nativo de esa métrica.

**Q20.** (a) **Sin observaciones en la ventana** → todas las tasas de bucket son 0, el total es 0, el rango indefinido → `NaN`. (b) **Etiqueta `le` eliminada** por `sum(...)` → sin límites para interpolar → `NaN`. (c) **Menos de dos buckets** sobreviven al filtro (`{le="+Inf"}` solo) → `histogram_quantile` necesita ≥ 2 límites → `NaN`.

**Q21.** El rango `0.9999 · total` cae dentro del bucket `+Inf`, que no tiene borde superior numérico hacia el cual interpolar, así que Prometheus reporta el **`le` finito más alto (5.0)**. El bucket `+Inf` te da un *conteo de solicitudes sobredimensionadas* pero **no su magnitud** — no puede decirte cuán lejos más allá de 5.0 se estira realmente la cola.

**Q22.** Regla práctica: el rango de `rate()` **debe ser ≥ ~4× el intervalo de scrape** para que la ventana contenga confiablemente varias muestras. `rate()` necesita al menos **dos muestras** en la ventana para calcular una pendiente; con una ventana `[8s]` sobre un scrape de 5s podés capturar solo una muestra (o cero), así que `rate()` no arroja ningún valor y el cuantil es `NaN` u oscila mientras la ventana se desliza a través de los bordes de las muestras.

**Q23.** 40 valores de `le` × 200 targets = **8.000 series de buckets** (antes de `_sum`/`_count`, así que ~8.400 en total). Si podés tolerar el re-cuantilado del lado del servidor pero no esta cardinalidad, cambiá la métrica a un **histograma nativo** (1 serie por conjunto de etiquetas en vez de 42) — conservás los cuantiles en tiempo de consulta y la re-agregación mientras colapsás la cantidad de series. (Un summary también reduciría la cardinalidad pero *pierde* el re-cuantilado del lado del servidor y la agregación entre targets, así que es el trade-off equivocado acá.)

</details>

---

### Sources

- Prometheus — *Metric types: Histogram*: https://prometheus.io/docs/concepts/metric_types/#histogram
- Prometheus — *Best practices: Histograms and summaries*: https://prometheus.io/docs/practices/histograms/
- Prometheus — *Querying functions: `histogram_quantile`, `histogram_fraction`, `histogram_count/sum/avg`*: https://prometheus.io/docs/prometheus/latest/querying/functions/#histograms
- Prometheus — *Native histograms (feature flag)*: https://prometheus.io/docs/prometheus/latest/feature_flags/#native-histograms
- Prometheus — *Native histograms specification*: https://prometheus.io/docs/specs/native_histograms/
- CNCF PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf