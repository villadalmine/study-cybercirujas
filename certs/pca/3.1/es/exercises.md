# Topic 3.1 — Metrics

> **Ejercicios de laboratorio guiados.** Vas a levantar un servidor Prometheus real, scrapear su propia instrumentación y un `node_exporter`, y leer a mano el stream crudo de métricas. El objetivo no es memorizar definiciones sino *ver*, en el formato de cable, qué es realmente un counter, un gauge, un histogram y un summary — y por qué esa distinción cambia cómo los consultás.

**Referencia curricular:** CNCF Prometheus Certified Associate — Observability Concepts / Metrics, Data Model and Labels, Exposition Format. Fuente: <https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf>

**Documentación primaria usada a lo largo del tema:**
- Data model — <https://prometheus.io/docs/concepts/data_model/>
- Metric types — <https://prometheus.io/docs/concepts/metric_types/>
- Exposition formats — <https://prometheus.io/docs/instrumenting/exposition_formats/>
- Metric and label naming — <https://prometheus.io/docs/practices/naming/>
- Histograms and summaries — <https://prometheus.io/docs/practices/histograms/>

**Prerrequisitos:** Docker + Docker Compose, `curl`, y un navegador. Sin instalación previa de Prometheus.

---

## Exercise 0 — Bring up the lab

Necesitás un *productor* de métricas (algo que exponga un endpoint `/metrics`) y un *consumidor* de métricas (Prometheus, que también es en sí mismo un productor). Usamos el propio endpoint de Prometheus como artefacto didáctico porque expone los cuatro metric types a la vez, más un `node_exporter` para counters y gauges más ricos.

1. Creá un directorio de trabajo y un `prometheus.yml`:

   ```yaml
   # prometheus.yml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']

     - job_name: node
       static_configs:
         - targets: ['node-exporter:9100']
   ```

2. Creá un `docker-compose.yml`:

   ```yaml
   services:
     prometheus:
       image: prom/prometheus:v2.53.0
       ports:
         - "9090:9090"
       volumes:
         - ./prometheus.yml:/etc/prometheus/prometheus.yml

     node-exporter:
       image: prom/node-exporter:v1.8.1
       ports:
         - "9100:9100"
   ```

3. Levantá y esperá ~30 s para que hayan ocurrido al menos dos scrapes:

   ```bash
   docker compose up -d
   sleep 30
   ```

4. Confirmá que ambos targets estén en `UP`:

   ```bash
   curl -s 'http://localhost:9090/api/v1/targets' \
     | grep -o '"health":"[a-z]*"'
   ```

   Esperado (el orden puede variar):

   ```
   "health":"up"
   "health":"up"
   ```

   También podés abrir <http://localhost:9090/targets> en un navegador.

**Comprehension check**

- **Q0.1** — La config de Prometheus le dice a `prometheus` que scrapee el target `localhost:9090`, pero Prometheus corre dentro de su propio contenedor. ¿Por qué `localhost` resuelve al proceso correcto acá, mientras que el job `node` debe usar el nombre de servicio `node-exporter:9100` en lugar de `localhost:9100`?
- **Q0.2** — Prometheus se describe como un sistema basado en *pull*. Según este setup, ¿quién inicia la conexión de red en el momento del scrape — el servidor Prometheus, o el endpoint `/metrics` que está siendo scrapeado?

---

## Exercise 1 — Read the exposition format

Cada target habla el mismo **exposition format** basado en texto. Aprendé a leerlo antes de tocar PromQL.

1. Traé el stream crudo que Prometheus expone sobre sí mismo:

   ```bash
   curl -s http://localhost:9090/metrics | head -n 20
   ```

   Vas a ver tripletes repetidos de `# HELP`, `# TYPE`, y una o más líneas de sample, por ejemplo:

   ```
   # HELP go_goroutines Number of goroutines that currently exist.
   # TYPE go_goroutines gauge
   go_goroutines 42
   # HELP prometheus_http_requests_total Counter of HTTP requests.
   # TYPE prometheus_http_requests_total counter
   prometheus_http_requests_total{code="200",handler="/metrics"} 7
   prometheus_http_requests_total{code="200",handler="/-/ready"} 2
   ```

2. Inspeccioná los headers HTTP para ver cómo se anuncia la versión del formato:

   ```bash
   curl -sI http://localhost:9090/metrics | grep -i content-type
   ```

   Esperado:

   ```
   Content-Type: text/plain; version=0.0.4; charset=utf-8
   ```

3. Aislá una única familia de métricas y leé su estructura con cuidado:

   ```bash
   curl -s http://localhost:9090/metrics \
     | grep '^prometheus_http_requests_total'
   ```

   Esperado (los valores y label sets varían):

   ```
   prometheus_http_requests_total{code="200",handler="/metrics"} 12
   prometheus_http_requests_total{code="200",handler="/-/healthy"} 3
   prometheus_http_requests_total{code="200",handler="/api/v1/targets"} 1
   ```

**Comprehension check**

- **Q1.1** — Descomponé la línea `prometheus_http_requests_total{code="200",handler="/metrics"} 12` en sus partes. Nombrá cada parte y decí qué aporta una línea `# TYPE` y una línea `# HELP`.
- **Q1.2** — En el paso 3 viste *tres líneas* que comparten todas el metric name `prometheus_http_requests_total`. ¿Son una time series o tres? ¿Qué las hace distintas?
- **Q1.3** — Las líneas de sample acá no tienen ningún número al final después del valor. El exposition format permite un timestamp opcional ahí. Si un target lo omite, ¿qué timestamp le adjunta Prometheus al sample, y por qué omitirlo es el default recomendado?

---

## Exercise 2 — Counters: monotonic, and never read raw

Un **counter** es una métrica acumulativa que solo sube (o se reinicia a cero cuando el proceso se reinicia). Casi nunca mirás su valor crudo; mirás su *rate of change*.

1. Muestreá un counter dos veces, con ~20 s de diferencia, y observá cómo trepa:

   ```bash
   curl -s http://localhost:9090/metrics | grep 'promhttp_metric_handler_requests_total{code="200"'
   sleep 20
   curl -s http://localhost:9090/metrics | grep 'promhttp_metric_handler_requests_total{code="200"'
   ```

   Esperado — el segundo valor es mayor:

   ```
   promhttp_metric_handler_requests_total{code="200"} 8
   promhttp_metric_handler_requests_total{code="200"} 10
   ```

2. Ahora consultá el *rate* en lugar del valor crudo. Abrí <http://localhost:9090/graph> o usá la API:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(node_cpu_seconds_total{mode="idle"}[1m])'
   ```

   Esperado (abreviado) — una pequeña fracción por segundo, un resultado por CPU:

   ```json
   {"status":"success","data":{"resultType":"vector","result":[
     {"metric":{"cpu":"0","mode":"idle"},"value":[1733680000,"0.98"]},
     {"metric":{"cpu":"1","mode":"idle"},"value":[1733680000,"0.97"]}
   ]}}
   ```

3. Contraste: corré la misma query pero sobre el counter *crudo*, y notá que el número es enorme y crece monótonamente — sin sentido como rate instantáneo:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=node_cpu_seconds_total{mode="idle",cpu="0"}'
   ```

   Esperado — un valor grande y acumulándose como `"48213.7"`.

**Comprehension check**

- **Q2.1** — ¿Por qué el valor crudo `48213.7` del paso 3 casi nunca es útil en un dashboard, mientras que `rate(...[1m])` del paso 2 sí lo es?
- **Q2.2** — Un counter *se reinicia a 0* cuando su proceso se reinicia. Si Prometheus calculara ingenuamente `current - previous` a través de un reinicio, obtendría un número negativo grande. ¿Cómo manejan `rate()` / `increase()` un reinicio de counter, y qué implica esto para calcular deltas de counter a mano?
- **Q2.3** — Por convención esta métrica se llama `..._total`. ¿Qué le señala el sufijo `_total` a quien lee, y qué metric type marca por convención?

---

## Exercise 3 — Gauges: they go up *and* down

Un **gauge** representa un valor que puede subir o bajar — una temperatura, una profundidad de cola, una huella de memoria, un conteo de requests en vuelo.

1. Leé un gauge directamente — su valor instantáneo *es* significativo:

   ```bash
   curl -s http://localhost:9090/metrics | grep '^prometheus_tsdb_head_series'
   ```

   Esperado:

   ```
   # HELP prometheus_tsdb_head_series Total number of series in the head block.
   # TYPE prometheus_tsdb_head_series gauge
   prometheus_tsdb_head_series 1361
   ```

2. Observá un gauge que oscila. Muestreá el conteo de goroutines y la memoria unas cuantas veces:

   ```bash
   for i in 1 2 3; do
     curl -s http://localhost:9090/metrics \
       | grep -E '^(go_goroutines|process_resident_memory_bytes) '
     sleep 5
   done
   ```

   Esperado — los valores se bambolean en ambas direcciones entre samples:

   ```
   go_goroutines 44
   process_resident_memory_bytes 8.7138304e+07
   go_goroutines 41
   process_resident_memory_bytes 8.7392256e+07
   go_goroutines 43
   process_resident_memory_bytes 8.7130112e+07
   ```

3. Encontrá un gauge de caso especial — una **info metric**. Su valor es siempre `1`; los *labels* llevan la carga útil:

   ```bash
   curl -s http://localhost:9090/metrics | grep '^prometheus_build_info'
   ```

   Esperado:

   ```
   prometheus_build_info{branch="HEAD",goversion="go1.22.4",revision="...",version="2.53.0"} 1
   ```

**Comprehension check**

- **Q3.1** — Para el counter del Exercise 2 necesitaste `rate()` para obtener un número útil. Para `prometheus_tsdb_head_series` en el paso 1 leíste el valor crudo directamente. Enunciá la regla práctica: ¿cuándo envolvés una métrica en `rate()`/`increase()`, y cuándo la leés en crudo?
- **Q3.2** — Aplicar `rate()` a `go_goroutines` es un error de modelado. ¿Por qué está mal aplicar funciones orientadas a counters a un gauge?
- **Q3.3** — `prometheus_build_info` está *tipado* como gauge pero su valor nunca cambia de `1`. ¿Cuál es el sentido de una métrica así, y cómo la usarías en una query para adjuntar el label `version` a otra series?

---

## Exercise 4 — Histograms: buckets you can aggregate

Un **histogram** muestrea observaciones (usualmente latencias o tamaños) en un conjunto de **cumulative buckets**, y expone tres series acompañantes por label set: `_bucket`, `_sum`, y `_count`.

1. Leé una familia de histogram completa:

   ```bash
   curl -s http://localhost:9090/metrics \
     | grep 'prometheus_http_request_duration_seconds'
   ```

   Esperado (abreviado — se muestra un `handler`):

   ```
   # TYPE prometheus_http_request_duration_seconds histogram
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="0.1"}  40
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="0.2"}  42
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="0.4"}  42
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="1"}    42
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="+Inf"} 42
   prometheus_http_request_duration_seconds_sum{handler="/metrics"}   1.234
   prometheus_http_request_duration_seconds_count{handler="/metrics"} 42
   ```

2. Leé los buckets con cuidado. `le` significa *less than or equal to*. Confirmá que son **cumulative**: cada conteo de bucket incluye todo lo de los buckets más chicos. Notá que el conteo del bucket `le="+Inf"` es igual al valor de `_count`.

3. Calculá un quantile *en tiempo de query* a partir de los buckets:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=histogram_quantile(0.9, rate(prometheus_http_request_duration_seconds_bucket[5m]))'
   ```

   Esperado — una latencia estimada del percentil 90 en segundos, p. ej. `"0.0921"`.

4. Calculá un *promedio* de observación a partir de `_sum` y `_count`:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_request_duration_seconds_sum[5m]) / rate(prometheus_http_request_duration_seconds_count[5m])'
   ```

   Esperado — una pequeña duración promedio en segundos, p. ej. `"0.031"`.

**Comprehension check**

- **Q4.1** — El bucket `le="0.1"` muestra `40` y `le="0.2"` muestra `42`. ¿Cuántas observaciones cayeron en el intervalo semiabierto `(0.1, 0.2]`? ¿Qué propiedad de los buckets hace de esto una simple resta?
- **Q4.2** — ¿Por qué las fronteras de los buckets del histogram deben elegirse *antes* de conocer la distribución de tus datos, y qué sale mal con tu estimación de `histogram_quantile` si todas tus latencias caen entre dos fronteras de bucket adyacentes?
- **Q4.3** — `histogram_quantile(0.9, rate(..._bucket[5m]))` envuelve las series de bucket en `rate()` primero. Dado que las series `_bucket` son counters, explicá por qué el `rate()` es requerido y no opcional.
- **Q4.4** — Corrés 10 réplicas de un servicio, cada una exponiendo este histogram. Explicá por qué podés hacer `sum by (le) (rate(..._bucket[5m]))` sobre las 10 y *después* aplicar `histogram_quantile` para obtener un percentil correcto a nivel de flota.

---

## Exercise 5 — Summaries: client-side quantiles, and why they don't add up

Un **summary** también rastrea observaciones, pero calcula **φ-quantiles seleccionados en el cliente** y los envía como números precalculados, junto con `_sum` y `_count`. **No** tiene buckets.

1. Leé una familia de summary (la métrica de pausa de GC de Go es un summary clásico):

   ```bash
   curl -s http://localhost:9090/metrics | grep '^go_gc_duration_seconds'
   ```

   Esperado:

   ```
   # TYPE go_gc_duration_seconds summary
   go_gc_duration_seconds{quantile="0"}    3.9e-05
   go_gc_duration_seconds{quantile="0.25"} 6.7e-05
   go_gc_duration_seconds{quantile="0.5"}  9.2e-05
   go_gc_duration_seconds{quantile="0.75"} 0.000133
   go_gc_duration_seconds{quantile="1"}    0.000456
   go_gc_duration_seconds_sum   0.012345
   go_gc_duration_seconds_count 87
   ```

2. Notá qué está **ausente**: no hay `_bucket` ni label `le`. La línea `quantile="0.5"` ya *es* la mediana — no interviene ninguna función `histogram_quantile`.

3. Probá (y razoná sobre) una agregación que es *inválida*. Supongamos que dos instancias reportan cada una `quantile="0.99"`. Promediar esos dos números **no** da el percentil 99 a nivel de flota:

   ```bash
   # Conceptually invalid — averaging pre-computed quantiles is mathematically wrong:
   # avg(go_gc_duration_seconds{quantile="0.99"})   # DO NOT trust this across instances
   ```

4. Confirmá la única agregación que *sí* es válida sobre un summary — el promedio, a partir de las dos series aditivas:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(go_gc_duration_seconds_sum[5m]) / rate(go_gc_duration_seconds_count[5m])'
   ```

   Esperado — pausa promedio de GC en segundos, p. ej. `"0.00013"`.

**Comprehension check**

- **Q5.1** — Enumerá cada diferencia observable entre la salida del histogram del Exercise 4 y la salida del summary del Exercise 5. ¿Qué series *comparten*?
- **Q5.2** — ¿Dónde se calcula el quantile para un summary versus para un histogram, y en qué momento en el tiempo (write path vs. query path)?
- **Q5.3** — ¿Por qué *no* podés agregar el `quantile="0.99"` de un summary a través de instancias, mientras que *sí* podés agregar los buckets de un histogram? Atá tu respuesta a Q4.4.
- **Q5.4** — Dá un escenario donde un summary es la mejor elección y uno donde lo es un histogram, según este trade-off (agregabilidad y quantiles configurables vs. exactitud y bajo costo en el cliente).

---

## Exercise 6 — The data model: labels, cardinality, and naming

Las métricas valen tanto como el diseño de sus labels. Acá sentís la *cardinality* directamente.

1. Contá en cuántas time series distintas se expande un único metric name a causa de sus labels:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count(node_cpu_seconds_total)'
   ```

   Esperado — una series por par `(cpu, mode)`, p. ej. `"32"` en un host de 8 cores con 4 modos de CPU... en realidad `8 cores × ~8 modes`, p. ej. `"64"`.

2. Mirá las dimensiones de label que producen ese fan-out:

   ```bash
   curl -s http://localhost:9090/metrics | grep '^node_cpu_seconds_total' | head
   ```

   Esperado:

   ```
   node_cpu_seconds_total{cpu="0",mode="idle"}   48213.7
   node_cpu_seconds_total{cpu="0",mode="system"}   611.2
   node_cpu_seconds_total{cpu="0",mode="user"}    1044.9
   node_cpu_seconds_total{cpu="1",mode="idle"}   48090.1
   ...
   ```

3. Razoná sobre un label **malo**. Imaginá agregar un label `request_id="a1b2c3..."` a un counter HTTP. Cada request único crea una time series nueva de cero que nunca se repite. **No** corras esto contra infraestructura real — solo mantené la imagen: una métrica con un label no acotado es una bomba de memoria.

4. Chequeá las convenciones de naming contra una métrica real. `node_cpu_seconds_total` codifica `namespace_subsystem_unit_suffix`. Identificá cada pieza y confirmá que la unidad es una **base unit** (seconds, no milliseconds).

**Comprehension check**

- **Q6.1** — Dá la definición exacta de una *time series* de Prometheus en términos de metric name y labels. Agregar un nuevo valor a un label existente, ¿multiplica el conteo de series cómo?
- **Q6.2** — ¿Por qué `request_id` (o `email`, `user_id`, path de URL completo con IDs) es un label peligroso, mientras que `mode` y `cpu` son seguros? ¿Cuál es la propiedad que los separa?
- **Q6.3** — Descomponé `node_cpu_seconds_total` en namespace, name, unit y suffix. Según el doc de naming best-practices, ¿por qué la unidad es `seconds` y no `milliseconds`, y por qué `_total` en lugar de `_count`?
- **Q6.4** — El label `__name__` nunca se escribió explícitamente en ninguna salida, pero existe en cada series. ¿Qué es, y qué hace el selector `{__name__="go_goroutines"}`?

---

## Exercise 7 — Tear down

```bash
docker compose down -v
```

Confirmá que los contenedores desaparecieron:

```bash
docker ps --filter "name=prometheus" --filter "name=node-exporter"
```

Esperado — una lista vacía (solo la fila de encabezado).

---

<details>
<summary><strong>Answers</strong> (click to expand)</summary>

### Exercise 0

**A0.1** — Prometheus scrapea el string de target que se le *da*, resuelto desde el namespace de red de *su propio contenedor*. Para el job `prometheus`, `localhost:9090` se resuelve dentro del contenedor de Prometheus, donde el propio proceso Prometheus escucha en `9090` — así que se scrapea a sí mismo. `node-exporter` corre en un contenedor *distinto*, por lo que `localhost` ahí apuntaría de vuelta al contenedor de Prometheus, no al exporter. Bajo Docker Compose, los contenedores se alcanzan entre sí por nombre de servicio sobre la red compartida, por lo que el exporter se direcciona como `node-exporter:9100`.

**A0.2** — El **servidor Prometheus** inicia cada conexión. Pull significa que Prometheus hace un HTTP GET saliente al endpoint `/metrics` de cada target en cada `scrape_interval`. El target es un servidor HTTP pasivo; nunca hace push. (El push existe solo vía el Pushgateway separado, para jobs batch de vida corta.)

### Exercise 1

**A1.1** — `prometheus_http_requests_total` es el **metric name**; `{code="200",handler="/metrics"}` es el **label set** (pares clave/valor, los valores son siempre strings); `12` es el **sample value** (un float64). Un timestamp opcional podría seguir. La línea `# TYPE` declara el tipo de la métrica (`counter`, `gauge`, `histogram`, `summary`, o `untyped`) para que Prometheus y el tooling sepan cómo tratarla; la línea `# HELP` es una descripción legible por humanos que aparece en la UI. Ambas son comentarios de metadata, uno por familia de métricas.

**A1.2** — **Tres time series distintas.** Una time series se identifica por el metric name *más el conjunto completo de labels*. Mismo nombre pero distintos valores de `handler` (y/o `code`) ⇒ series distintas, cada una con su propio stream de valores independiente a lo largo del tiempo.

**A1.3** — Cuando el target omite el timestamp, Prometheus estampa el sample con el **scrape time** (el reloj del servidor en el momento del scrape). Omitirlo es recomendado porque le permite a Prometheus dueñar el tiempo de forma consistente a través de todos los targets, evita problemas de clock-skew y staleness, y es lo que hacen las client libraries por defecto. Los timestamps explícitos se reservan para casos especiales como federation o métricas proxeadas.

### Exercise 2

**A2.1** — Un valor crudo de counter es el total acumulado desde el inicio del proceso; crece sin cota y su magnitud absoluta depende del uptime, así que no dice nada sobre la *actividad actual*. `rate(...[1m])` da el incremento promedio por segundo sobre la ventana — el throughput/utilización actual real, que es lo que alertás y graficás.

**A2.2** — `rate()` e `increase()` son **counter-reset aware**: cuando ven que el valor cae (un reinicio), lo tratan como si el counter hubiera ido a 0 y trepado de nuevo, en lugar de un delta negativo, así que no emiten un spike negativo espurio. Implicación: nunca calcules deltas de counter a mano con `current - previous` — vas a producir un número negativo enorme en cada reinicio. Usá siempre las funciones de counter.

**A2.3** — `_total` señala un **counter acumulativo** — monótonamente creciente, pensado para consumirse con `rate`/`increase`, no para leerse en crudo. Marca el tipo **counter** por convención.

### Exercise 3

**A3.1** — Regla práctica: los **counters** (acumulativos, `_total`) se envuelven en `rate()`/`increase()` porque solo su cambio a lo largo del tiempo es significativo. Los **gauges** (valores que suben y bajan) se leen en **crudo** — el valor instantáneo es en sí mismo la respuesta; todavía podés aplicar `avg_over_time`, `delta`, `deriv`, o `max_over_time` a un gauge, pero nunca `rate`/`increase`.

**A3.2** — `rate()`/`increase()` asumen crecimiento monótono e interpretan cualquier descenso como un reinicio de counter. Un gauge legítimamente desciende todo el tiempo, así que esas funciones "corregirían" silenciosamente descensos reales en falsos reinicios, produciendo sinsentidos. La incompatibilidad de tipo corrompe la matemática.

**A3.3** — Es una **info metric**: un gauge de `1` constante cuyos *labels* llevan metadata (version, revision, versión de Go). Su propósito es exponer metadata estática/de cambio lento como una series unible. Adjuntás sus labels a otra métrica con un group de vector-matching, p. ej.:
`some_metric * on(instance) group_left(version) prometheus_build_info`
— el `group_left(version)` copia el label `version` sobre los resultados de `some_metric`.

### Exercise 4

**A4.1** — `42 − 40 = 2` observaciones cayeron en `(0.1, 0.2]`. Es una simple resta porque los buckets son **cumulative**: `le="0.2"` cuenta *todo lo ≤ 0.2*, que ya incluye todo lo `≤ 0.1`, así que la diferencia aísla la banda entre ellos.

**A4.2** — Las fronteras de los buckets se hornean en la instrumentación en tiempo de escritura, antes de que puedas conocer la distribución en runtime. `histogram_quantile` estima el quantile mediante **interpolación lineal dentro del bucket** en el que cae el quantile. Si todas las observaciones se amontonan entre dos fronteras adyacentes, ese bucket es muy ancho en relación a tus datos, y la interpolación a través de él es gruesa — la estimación del percentil puede estar muy errada. Solución: elegí buckets que enmarquen tu rango de latencia esperado con suficiente resolución (o usá native/exponential histograms).

**A4.3** — Las series `_bucket` son **counters** (cada una es un conteo acumulativo que solo sube). `histogram_quantile` necesita el *rate de observaciones por bucket sobre la ventana*, es decir la forma reciente de la distribución — no los totales de todo-el-tiempo desde el inicio del proceso. `rate(..._bucket[5m])` convierte cada counter en un rate por segundo para que el quantile refleje el tráfico *actual*; alimentar counters crudos calcularía un quantile de todo-el-tiempo dominado por datos antiguos y se comportaría mal a través de reinicios.

**A4.4** — Porque los buckets de histogram son **aditivos a través de instancias**: la cantidad de requests `≤ 0.2s` en toda la flota es exactamente la suma de los conteos por instancia `≤ 0.2s`. Así que `sum by (le) (rate(..._bucket[5m]))` reconstruye una distribución cumulativa correcta a nivel de flota, y `histogram_quantile` sobre eso da un percentil global correcto. (Agregar quantiles precalculados, como forzaría un summary, *no* es válido — ver A5.3.)

### Exercise 5

**A5.1** — Un summary expone el metric name base con un label `quantile="φ"` (valores de quantile precalculados) más `_sum` y `_count`. Un histogram expone series `_bucket{le="..."}` más `_sum` y `_count`, y **ningún** label `quantile`. Diferencias: el summary tiene `quantile`/no `le`/no `_bucket`; el histogram tiene `le`/`_bucket`/no `quantile`. **Comparten:** ambos exponen `_sum` y `_count`.

**A5.2** — Summary: los quantiles se calculan **en el cliente (write path)**, continuamente a medida que llegan las observaciones, y se envían como números terminados. Histogram: solo se registran los conteos de bucket en el cliente; el quantile se calcula **en el servidor en tiempo de query (read path)** con `histogram_quantile`.

**A5.3** — El `quantile="0.99"` de un summary es un único escalar ya colapsado por instancia; no podés reconstruir el percentil 99 de la flota a partir de diez percentiles 99 distintos (el 99 de una unión no es el promedio/suma/máximo de los 99 de las partes). Un histogram guarda los *conteos de bucket* crudos, que son aditivos, así que podés fusionar primero las distribuciones (A4.4) y solo entonces calcular el quantile — matemáticamente válido.

**A5.4** — Un **summary** es mejor cuando necesitás quantiles exactos para una única instancia sin agregación cruzada entre instancias y querés los φ-quantiles específicos de forma barata y precisa (p. ej. un SLO de pausa de GC por instancia). Un **histogram** es mejor cuando necesitás agregar a través de muchas instancias, calcular quantiles *arbitrarios* después del hecho, o aplicar los mismos buckets a nivel de flota (p. ej. SLOs de request-latency a nivel de servicio) — el default casi universal para latencia estilo RED.

### Exercise 6

**A6.1** — Una time series se identifica de forma única por su **metric name junto con su conjunto completo de labels clave/valor** (formalmente, el label `__name__` más todos los demás labels). Agregar un nuevo valor a un label crea una series adicional *por cada combinación existente de los otros labels* — el total es el **producto** (Cartesiano) de todas las cardinalities de labels, así que el crecimiento es multiplicativo, no aditivo.

**A6.2** — `request_id`, `email`, URLs completas con IDs son **no acotados / de alta cardinality**: el conjunto de valores posibles es efectivamente infinito y cada nuevo valor engendra una series nueva permanente, agotando memoria y disco (explosión de cardinality). `mode` y `cpu` son **acotados y de baja cardinality** — un conjunto de valores chico, estable y conocido. La propiedad que los separa es si el espacio de valores del label es acotado y estable.

**A6.3** — `node` = namespace/prefijo (el exporter/library), `cpu` = el subsystem + `seconds` = base unit + `total` = suffix; forma completa `node_cpu_seconds_total`. La unidad es `seconds` porque la práctica de naming de Prometheus manda **base units** (seconds, bytes, ratios 0–1) para consistencia entre métricas y dashboards — nunca milliseconds ni megabytes. Termina en `_total` (no `_count`) porque es un **counter acumulativo**; `_count` está reservado para el conteo de observaciones de un histogram/summary.

**A6.4** — `__name__` es el **label interno reservado que contiene el metric name en sí**. Cada series lo lleva implícitamente. El selector `{__name__="go_goroutines"}` es exactamente equivalente a escribir `go_goroutines` — matchea todas las series de esa métrica — y como es un label matcher también te permite matchear nombres por regex, p. ej. `{__name__=~"node_cpu_.*"}`.

</details>