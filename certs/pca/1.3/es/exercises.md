# PCA — Topic 1.3: Aggregating over time
## Ejercicios guiados (PromQL de nivel producción)

> **Alcance.** Este topic cubre la familia `*_over_time()`: las funciones de PromQL que colapsan un **range vector** (muchas samples de una serie a lo largo de una ventana de tiempo) en un único valor **por serie**. La trampa recurrente del examen es confundir esta agregación *temporal* con la agregación *dimensional* de los operadores (`sum`, `avg`, `max`, …) que colapsan a través de series en un único instante. Cada ejercicio de abajo ejercita esa distinción sobre un Prometheus real.

**Fuentes de referencia**
- Catálogo de `_over_time`: https://prometheus.io/docs/prometheus/latest/querying/functions/#aggregation_over_time
- Selectores de range-vector: https://prometheus.io/docs/prometheus/latest/querying/basics/#range-vector-selectors
- Subqueries: https://prometheus.io/docs/prometheus/latest/querying/subqueries/
- *Operadores* de agregación (para contrastar): https://prometheus.io/docs/prometheus/latest/querying/operators/#aggregation-operators
- Currículum PCA: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf

---

## Lab setup

Necesitás un Prometheus corriendo con unos minutos de historial scrapeado. Con el self-scraping alcanza — Prometheus expone abundantes counters y gauges sobre sí mismo.

1. Creá `prometheus.yml`:

   ```yaml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ["localhost:9090"]
   ```

2. Iniciá Prometheus (fijá una versión para que las salidas sean reproducibles):

   ```bash
   docker run -d --name prom -p 9090:9090 \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     prom/prometheus:v2.53.0
   ```

3. Generá algo de tráfico HTTP para que los counters tengan movimiento, luego **esperá al menos 6 minutos** para que cada ventana `[5m]` esté completamente poblada:

   ```bash
   for i in $(seq 1 300); do
     curl -s 'http://localhost:9090/api/v1/query?query=up' >/dev/null
   done
   sleep 360
   ```

4. Dos formas de ejecutar queries — usá cualquiera de las dos a lo largo del ejercicio:
   - **Expression browser**: http://localhost:9090/graph
   - **HTTP API + jq** (usada en las salidas de abajo):

     ```bash
     q() { curl -s 'http://localhost:9090/api/v1/query' \
             --data-urlencode "query=$1" | jq -r '.data.result'; }
     ```

---

## Exercise 1 — Range vector in, instant vector out

Toda la familia comparte una única firma: **requiere** un range vector `[d]` y **devuelve** un instant vector.

1. Ejecutá un selector de range-vector crudo e inspeccioná su forma:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=up[5m]' | jq -r '.data.result[0].values | length'
   ```

   Esperado: un conteo cercano a **20** (300 s ÷ 15 s). Puede ser 20 o 21 según el alineamiento del borde de la ventana.

2. Ahora envolvelo en `count_over_time`:

   ```bash
   q 'count_over_time(up[5m])'
   ```

   ```json
   [
     {
       "metric": { "__name__": "up", "instance": "localhost:9090", "job": "prometheus" },
       "value": [ 1733680000, "20" ]
     }
   ]
   ```

3. Rompelo a propósito — pasale un **instant** vector a una función `_over_time`:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count_over_time(up)'
   ```

   Obtenés un HTTP 400 y un error como
   `expected type range vector in call to function "count_over_time", got instant vector`.

> ❓ **Comprehension check 1**
> 1. `up[5m]` es un range vector. ¿Por qué *no* podés graficarlo directamente en la pestaña Graph del expression browser, y sin embargo `count_over_time(up[5m])` grafica sin problema?
> 2. El resultado de `count_over_time(up[5m])` fue `20`, no `1`. ¿Qué contó exactamente — y por qué ese número es función de tu `scrape_interval`?
> 3. Tenés tres series `up` (tres targets). ¿Cuántas series de salida devuelve `count_over_time(up[5m])`, y qué significa cada valor?

---

## Exercise 2 — Smoothing a noisy gauge: `avg/min/max_over_time`

Los gauges (memoria, goroutines, profundidad de cola) fluctúan entre scrapes. La familia `_over_time` te da un resumen estadístico por serie de la ventana sin tocar las demás series.

1. Mirá el gauge crudo, luego su promedio, mínimo y máximo a 5 minutos:

   ```bash
   q 'go_goroutines'
   q 'avg_over_time(go_goroutines[5m])'
   q 'min_over_time(go_goroutines[5m])'
   q 'max_over_time(go_goroutines[5m])'
   ```

   Valores típicos:

   ```text
   go_goroutines                     -> 47
   avg_over_time(go_goroutines[5m])  -> 45.3
   min_over_time(go_goroutines[5m])  -> 41
   max_over_time(go_goroutines[5m])  -> 52
   ```

2. Calculá la dispersión pico-a-valle de la ventana en una sola expresión:

   ```bash
   q 'max_over_time(go_goroutines[5m]) - min_over_time(go_goroutines[5m])'
   ```

3. Compará el valor instantáneo de un gauge de memoria residente contra su promedio suavizado — útil cuando un dashboard parpadea:

   ```bash
   q 'process_resident_memory_bytes'
   q 'avg_over_time(process_resident_memory_bytes[5m])'
   ```

> ❓ **Comprehension check 2**
> 1. `max_over_time(go_goroutines[5m])` devolvió `52`, pero el valor actual es `47`. ¿Está rota la métrica? Explicá qué representa `52`.
> 2. En el paso 2 la resta devolvió **un** valor por serie sin necesidad de `on()`/`ignoring()`. ¿Por qué el vector match "simplemente funciona" acá, cuando restar dos métricas arbitrarias suele requerir matching modifiers?
> 3. Tu ingeniero de alerting quiere paginar sobre un techo de memoria *sostenido*, no sobre un único scrape puntual. ¿Cuál de `max_over_time` / `avg_over_time` / `min_over_time` reduce las falsas páginas por picos de un solo scrape, y qué sacrifica cada elección?

---

## Exercise 3 — Sample presence and scrape health: `count_over_time`, `present_over_time`, `absent_over_time`

Estas tres responden "¿llegaron datos?" en lugar de "¿cuál era su valor?" — la columna vertebral de las alertas dead-man's-switch.

1. `present_over_time` devuelve `1` por cada serie con **al menos una** sample en la ventana:

   ```bash
   q 'present_over_time(up[5m])'
   ```

   ```json
   [ { "metric": { "__name__": "up", "instance": "localhost:9090", "job": "prometheus" },
       "value": [ 1733680000, "1" ] } ]
   ```

2. Compará el volumen de scrape entre una ventana corta y una larga para ver la cobertura parcial de un target que recién arrancó:

   ```bash
   q 'count_over_time(scrape_samples_scraped[1m])'
   q 'count_over_time(scrape_samples_scraped[10m])'
   ```

3. `absent_over_time` es la primitiva de alerting inversa. Preguntá por una serie que **existe**, luego por una que **no**:

   ```bash
   q 'absent_over_time(up[5m])'                          # -> [] (empty)
   q 'absent_over_time(up{job="does-not-exist"}[5m])'    # -> value "1"
   ```

   ```json
   // second query
   [ { "metric": { "job": "does-not-exist" }, "value": [ 1733680000, "1" ] } ]
   ```

> ❓ **Comprehension check 3**
> 1. `present_over_time(up[5m])` y `absent_over_time(up[5m])` son casi-opuestas. Indicá con precisión qué devuelve cada una cuando la serie **está** presente, y cuando **no** lo está. ¿Por qué no podés simplemente escribir `up == 0` para detectar un target faltante?
> 2. Para una alerta Dead Man's Switch ("paginame si esta métrica deja de llegar por 10 minutos"), ¿qué función va en la expresión de la alerta, y por qué `absent()` (sin `_over_time`) es una peor elección para un target inestable y scrapeado ocasionalmente?
> 3. En el paso 3, notá que los labels del resultado de `absent_over_time` vinieron de tu **query**, no de datos almacenados. ¿De dónde salió `{job="does-not-exist"}`, y cuál es el riesgo si tu selector usa un regex matcher como `job=~".+"`?

---

## Exercise 4 — Statistical shape of a window: `quantile_over_time`, `stddev_over_time`, `stdvar_over_time`, `sum_over_time`

1. Estimá el percentil 95 de la duración de scrape para cada target durante 30 minutos:

   ```bash
   q 'quantile_over_time(0.95, scrape_duration_seconds[30m])'
   ```

   ```text
   -> 0.0043   # 95% of scrapes finished within ~4.3 ms
   ```

2. Medí la volatilidad del conteo de goroutines:

   ```bash
   q 'stddev_over_time(go_goroutines[30m])'   # standard deviation
   q 'stdvar_over_time(go_goroutines[30m])'   # variance (= stddev^2)
   ```

3. Probá las guard rails de `quantile_over_time` — φ debe estar dentro de `[0, 1]`:

   ```bash
   q 'quantile_over_time(1.5, scrape_duration_seconds[30m])'   # -> +Inf
   q 'quantile_over_time(-0.2, scrape_duration_seconds[30m])'  # -> -Inf
   ```

4. Ahora el filo cortante — `sum_over_time` sobre un **counter** es un bug clásico. Contrastalo con el patrón correcto:

   ```bash
   q 'sum_over_time(prometheus_http_requests_total[5m])'   # meaningless number
   q 'increase(prometheus_http_requests_total[5m])'        # the real "requests in 5m"
   ```

> ❓ **Comprehension check 4**
> 1. `quantile_over_time(0.95, scrape_duration_seconds[30m])` dio un p95 por target. ¿En qué difiere, mecánicamente y en significado, de `histogram_quantile(0.95, ...)` sobre un histogram nativo/clásico? ¿Cuándo la forma `_over_time` *no* es un percentil de latencia válido?
> 2. ¿Por qué `sum_over_time(prometheus_http_requests_total[5m])` es semánticamente incorrecto? Recorré qué suma en realidad, y por qué `increase(...)` es lo que querías decir.
> 3. `stdvar_over_time` devolvió un número ~ al cuadrado de `stddev_over_time`. ¿Cuál le pasarías a una regla de anomalía de la forma "el valor actual está a más de 3σ de la media de la ventana", y escribí esa regla como un boceto de expresión PromQL.

---

## Exercise 5 — Aggregating *derived* data with subqueries: `max_over_time(rate(...))`

A menudo querés "el **rate** pico de requests en los últimos 30 minutos." Pero `rate()` devuelve un instant vector, y no podés agregar `[30m]` a una llamada de función. La **subquery** `[range:resolution]` cierra la brecha.

1. Probá primero la forma ingenua (rota):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=max_over_time(rate(prometheus_http_requests_total[1m])[30m])'
   ```

   → parse error: `[30m]` no puede seguir a una función; un range selector solo se adjunta a un selector pelado.

2. Corregilo con sintaxis de subquery — el `rate` interno evaluado cada `1m` a lo largo de una ventana de `30m`, luego `max_over_time` lo colapsa:

   ```bash
   q 'max_over_time( rate(prometheus_http_requests_total[1m])[30m:1m] )'
   ```

   ```text
   -> 2.87   # peak per-second request rate seen in any 1m step of the last 30m
   ```

3. Omití la resolución para heredar el `evaluation_interval` global, y compará con el promedio de la misma serie derivada:

   ```bash
   q 'max_over_time( rate(prometheus_http_requests_total[1m])[30m:] )'
   q 'avg_over_time( rate(prometheus_http_requests_total[1m])[30m:1m] )'
   ```

4. `last_over_time` arrastra hacia adelante la sample más reciente — útil para alinear un gauge lento sobre una grilla de steps, o para sobrevivir a huecos breves:

   ```bash
   q 'last_over_time(process_resident_memory_bytes[5m])'
   ```

> ❓ **Comprehension check 5**
> 1. En `rate(...)[30m:1m]`, nombrá los tres parámetros de tiempo en juego (`1m`, `30m`, `1m`) y decí con precisión qué controla cada uno.
> 2. Las subqueries son convenientes pero costosas. ¿Por qué `max_over_time(rate(...)[30m:15s])` cuesta mucho más de evaluar que `[30m:5m]`, y qué alternativa de producción (pista: rules) elimina ese costo en el momento de la query?
> 3. ¿Cuál es la diferencia entre `last_over_time(x[5m])` y simplemente consultar `x`? Dá un escenario donde devuelvan valores **diferentes** para la misma serie.

---

## Exercise 6 — The core exam distinction: over **time** vs over **dimensions**

Este es el patrón que los examinadores prueban más. `avg_over_time` promedia **una serie a lo largo del tiempo**; el operador `avg` promedia **muchas series en un instante**. Son ortogonales y frecuentemente se combinan.

1. Hay tres targets de `scrape_duration_seconds` (o uno, en este lab mínimo — lo que importa es la forma de la respuesta). Mirá ambas direcciones:

   ```bash
   # Temporal: one output series PER target, each smoothed over 5m
   q 'avg_over_time(scrape_duration_seconds[5m])'

   # Dimensional: ONE output value, collapsing all targets at "now"
   q 'avg(scrape_duration_seconds)'
   ```

2. Combinalas correctamente — suavizá cada serie a lo largo del tiempo, *luego* promediá a través de las series:

   ```bash
   q 'avg( avg_over_time(scrape_duration_seconds[5m]) )'
   ```

3. Observá cómo `by` interactúa solo con el **operador**, nunca con `_over_time`:

   ```bash
   q 'max( max_over_time(scrape_duration_seconds[5m]) ) by (job)'
   ```

4. Mirá los conjuntos de labels para hacerlo concreto:

   ```bash
   q 'avg_over_time(scrape_duration_seconds[5m])'   # keeps instance+job labels
   q 'avg(scrape_duration_seconds)'                  # drops all labels
   ```

> ❓ **Comprehension check 6**
> 1. En una oración cada uno, definí el eje que `avg_over_time(x[5m])` colapsa y el eje que `avg(x)` colapsa.
> 2. `avg_over_time(x[5m])` **preserva** cada label de `x`, mientras que `avg(x)` los **descarta** (a menos que agregues `by`). Explicá por qué esa asimetría es una consecuencia directa de lo que agrega cada uno.
> 3. Un colega escribe `avg_over_time(x)` y `avg(x[5m])`. Ambos son errores. Indicá el error en cada uno, y dá la expresión corregida que preserva la intención para ambos.
> 4. Para "el promedio, a través de todos los targets, del pico de duración de scrape de cada target en la última hora", escribí la expresión completa y justificá el orden de anidamiento (¿por qué no `max_over_time(avg(...)[1h:])`?).

---

## Exercise 7 — Putting it together: a real alert expression

1. Construí una regla que dispare cuando el error rate **suavizado** de un job se mantiene por encima de un umbral — combinando una subquery, `_over_time`, y una agregación dimensional:

   ```promql
   # "avg per-second 5xx rate over the last 15m, summed per job, exceeds 1"
   sum by (job) (
     avg_over_time(
       rate(prometheus_http_requests_total{code=~"5.."}[5m])[15m:1m]
     )
   ) > 1
   ```

2. Agregá un dead-man's-switch acompañante para que la alerta misma no pueda quedarse ciega:

   ```promql
   absent_over_time(prometheus_http_requests_total[10m])
   ```

3. Razoná sobre el costo de evaluación y la corrección antes de enviarlo (ver checks).

> ❓ **Comprehension check 7**
> 1. Pelá la expresión del paso 1 de adentro hacia afuera y nombrá qué hace cada capa: `rate(...[5m])`, `[15m:1m]`, `avg_over_time(...)`, `sum by (job)(...)`.
> 2. ¿Por qué el `sum by (job)` está por **afuera** y no está incorporado en un `sum_over_time`? ¿Qué computaría `sum_over_time(rate(...)[15m:1m])` en cambio, y por qué está mal acá?
> 3. Si `prometheus_http_requests_total{code=~"5.."}` produjo **cero** samples (nunca hubo un 5xx), ¿qué devuelve la expresión del paso 1, y dispararía la alerta? ¿Cómo cubre la regla del paso 2 el punto ciego que esto crea?

---

<details>
<summary><strong>Answer key — Exercises 1–7</strong></summary>

### Exercise 1
1. La pestaña Graph grafica **instant vectors** sobre el rango de la query — un número por serie por step. Un range vector (`up[5m]`) es un *conjunto de series de samples crudas* con muchos valores marcados con timestamp en un único instante de evaluación; no tiene un único valor para graficar. `count_over_time(up[5m])` reduce cada range vector a un único valor instantáneo, que *sí* es graficable. (La pestaña Table/Console mostrará las samples crudas del range-vector, pero no las graficará.)
2. Contó el **número de samples crudas** de `up` que cayeron dentro de la ventana móvil de 5 minutos. Con `scrape_interval: 15s`, 5 min ÷ 15 s = **20** scrapes → 20 samples. Cambiá el intervalo y el conteo cambia proporcionalmente — `count_over_time` mide la *densidad de scrapes*, no el valor de la métrica.
3. **Tres** series de salida — una por serie de entrada. Las funciones `_over_time` agregan **cada serie de forma independiente a lo largo del tiempo**; nunca fusionan series. Cada valor es el conteo de samples de ese target particular en la ventana.

### Exercise 2
1. No está rota. `max_over_time(go_goroutines[5m])` devuelve el **valor más alto que observó cualquier scrape dentro de la ventana móvil de 5 minutos**. El conteo llegó a un pico de 52 en algún scrape anterior y desde entonces se asentó en 47; la ventana todavía recuerda el 52.
2. Ambos operandos (`max_over_time(...)` y `min_over_time(...)`) se derivan de la **misma** serie fuente y por lo tanto llevan **conjuntos de labels idénticos** (`_over_time` preserva los labels). El vector matching uno-a-uno por defecto de PromQL empareja series con labels iguales, así que el match es exacto sin `on()`/`ignoring()`. La resta produce un resultado por cada serie original.
3. `avg_over_time` suprime mejor los picos de un solo scrape porque un outlier queda diluido por ~20 samples — pero también **oculta** ráfagas cortas reales (podrías perderte un blowup de memoria genuino de 30 segundos). `max_over_time` nunca oculta un pico pero pagina sobre transitorios. `min_over_time` muestra el *piso* sostenido y es esencialmente inútil para una alerta de techo. Elección típica de producción: alertar sobre `avg_over_time` (o `quantile_over_time(0.9, …)`) mantenido `for:` unos minutos para exigir persistencia.

### Exercise 3
1. `present_over_time(up[5m])` → `1` cuando la serie tiene ≥1 sample en la ventana, y no devuelve **ninguna serie** (vacío) cuando está ausente. `absent_over_time(up[5m])` → devuelve **nada** cuando la serie está presente, y una única serie con valor `1` (labels tomados de los equality matchers del selector) cuando está ausente. `up == 0` no puede detectar un target *faltante*: si el scrape target desaparece por completo, la serie `up` deja de producirse, así que `up == 0` no tiene nada para evaluar y da vacío — nunca dispararías. `up == 0` solo captura un target que está **scrapeado pero fallando**; `absent_over_time` captura un target que **no está siendo scrapeado/almacenado en absoluto**.
2. Usá **`absent_over_time(metric[10m])`**. El `absent(metric)` simple mira solo el **único instante de evaluación más reciente**, así que para un target inestable que reporta cada pocos minutos alterna entre "presente" y "ausente" en casi cada evaluación de la regla → flapping de alertas. `absent_over_time` tolera los huecos: se mantiene callado mientras *cualquier* sample haya caído en la ventana de 10 minutos, y dispara solo cuando el target realmente quedó en silencio durante toda la ventana.
3. Los labels del resultado vienen de los **equality matchers de tu selector** (`job="does-not-exist"`), porque no hay serie almacenada de la cual tomar prestados los labels — Prometheus sintetiza la salida a partir del texto de la query. Con un matcher de **regex** como `job=~".+"`, no hay equality matchers para copiar, así que un resultado de `absent_over_time` que dispara sería **sin labels** (solo valor `1`), lo que vuelve la alerta resultante ambigua y difícil de rutear. Siempre dale a los selectores de `absent`/`absent_over_time` labels de igualdad concretos para que la alerta lleve una identidad útil.

### Exercise 4
1. `quantile_over_time(0.95, x[30m])` computa el percentil 95 **de los valores crudos de scrape de la serie `x` a lo largo de 30 minutos** — un percentil *a través del tiempo* de un gauge/escalar ya observado. `histogram_quantile(0.95, …)` estima un percentil **a través de una población de eventos en un instante** interpolando dentro de los buckets del histogram. La forma `_over_time` **no** es un percentil de *latencia* válido de requests: percentila las *samples de scrape en sí* (por ejemplo, el p95 de las 120 lecturas de scrape_duration), no el p95 de la distribución de latencia de las requests subyacentes. Usá `_over_time` para "cómo se comportó este gauge a lo largo del tiempo"; usá `histogram_quantile` para "cuál es el p95 de los eventos."
2. Un counter solo aumenta; `sum_over_time` literalmente suma los 20 valores crudos que crecen monotónicamente (por ejemplo, 1000 + 1001 + … + 1019) — un número sin significado físico que escala con la densidad de scrapes y la magnitud del counter. Lo que querías es **cuánto creció el counter en la ventana**, que es `increase(...[5m])` (o `rate(...[5m]) * 300`). `_over_time` sobre counters es casi siempre un bug; tomá `rate`/`increase` primero.
3. Alimentá **`stddev_over_time`** (misma unidad que la métrica, así que es comparable con una desviación cruda). Boceto: `abs(x - avg_over_time(x[30m])) > 3 * stddev_over_time(x[30m])`. `stdvar_over_time` está en unidades *al cuadrado* y se usa cuando componés varianzas matemáticamente, no para un umbral de "distancia en σ".

### Exercise 5
1. El `[1m]` interno = la **ventana de rate**: sobre cuántos minutos móviles se computa cada punto de `rate()`. `[30m` = el **rango de la subquery**: el span total de puntos de `rate` derivados que `max_over_time` escaneará. `:1m]` = la **resolución/step de la subquery**: cada cuánto se evalúa el `rate` interno dentro de ese span (30 puntos evaluados acá). `max_over_time` luego devuelve el mayor de esos 30 puntos.
2. El costo escala con el **número de evaluaciones internas** = rango ÷ resolución. `[30m:15s]` = 120 computaciones internas de `rate`; `[30m:5m]` = 6. Cada `rate` interno es en sí mismo un escaneo de rango, así que una resolución fina multiplica el trabajo dramáticamente y puede machacar la TSDB. Corrección de producción: precomputá `rate(...)` en una **recording rule** a un intervalo fijo, luego ejecutá `max_over_time(job:http_rate:rate1m[30m])` sobre la serie *almacenada* — sin subquery, barato y cacheable.
3. `x` devuelve el valor actual en el instante de evaluación, sujeto a **staleness** — si la última sample es más vieja que ~5 min (o está marcada como stale) no devuelve *nada*. `last_over_time(x[5m])` devuelve la **sample más reciente dentro de la ventana de 5 minutos independientemente del manejo de staleness**, arrastrándola hacia adelante. Difieren cuando un target dejó de reportar recientemente pero muestreó, digamos, hace 4 minutos: `x` puede estar vacío/stale, mientras que `last_over_time(x[5m])` todavía devuelve ese valor de hace 4 minutos.

### Exercise 6
1. `avg_over_time(x[5m])` colapsa el eje del **tiempo** (muchas samples de cada serie → una por serie). `avg(x)` colapsa el eje de **series/dimensión** (muchas series en un instante → un valor).
2. `_over_time` agrega *dentro* de una serie, así que la identidad de la serie — sus labels — queda intacta y preservada. El **operador** `avg` agrega *a través* de las series; para producir un único resultado combinado debe descartar los labels que distinguían las entradas (conservando solo los nombrados en `by`). El comportamiento de los labels se sigue directamente de qué eje se está fusionando.
3. `avg_over_time(x)` — le falta el **range vector** requerido; necesita una ventana: `avg_over_time(x[5m])`. `avg(x[5m])` — al **operador** se le pasó un **range vector**, que no puede tomar; o bien quitá la ventana para un promedio instantáneo `avg(x)`, o, si se buscaba un promedio temporal por serie a través de series, `avg(avg_over_time(x[5m]))`.
4. `avg( max_over_time(scrape_duration_seconds[1h]) )`. El `max_over_time` interno da el **pico de cada target** durante la hora (un valor por target, labels intactos); el `avg` externo promedia esos picos a través de los targets. La forma rechazada `max_over_time(avg(...)[1h:])` primero promedia *a través de los targets en cada step* (destruyendo la identidad por target) y luego toma el máximo de esa línea de tiempo del promedio de la flota — responde "el pico del promedio de la flota", no "el promedio de los picos por target." El orden codifica la intención.

### Exercise 7
1. `rate(prometheus_http_requests_total{code=~"5.."}[5m])` → rate de 5xx por segundo, por serie, suavizado sobre 5 min. `[15m:1m]` → subquery: evaluá ese rate cada 1 min a lo largo de los últimos 15 min, produciendo un range vector derivado. `avg_over_time(...)` → por serie, promediá esos 15 puntos de rate en un único valor (un rate suavizado de 15 minutos). `sum by (job)(...)` → colapsá las series restantes **a través de las dimensiones**, sumando por `job`.
2. `sum by (job)` es un colapso **dimensional** que debe ocurrir *después* de que cada serie se reduzca a un único valor instantáneo — fusiona *series diferentes*. `sum_over_time(rate(...)[15m:1m])` es un colapso **temporal** que *sumaría las 15 samples de rate sucesivas de cada serie individual* — inflando el rate de una serie por ~15× (y todavía por serie, no por job). Eso no es ni un promedio ni un total entre jobs; es dimensional y numéricamente incorrecto.
3. Con cero samples de 5xx el `rate` interno produce **ninguna serie**, así que `avg_over_time` y `sum by (job)` también producen **vacío** — la comparación `> 1` no tiene nada para probar y la alerta **no puede disparar**. Ese es el punto ciego: "sin datos" se lee idéntico a "saludable." El `absent_over_time(prometheus_http_requests_total[10m])` del paso 2 dispara precisamente cuando la métrica subyacente deja de llegar, así que un exporter/scrape roto se captura aunque la regla de error rate haya quedado en silencio.

</details>