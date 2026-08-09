# Prometheus Certified Associate (PCA) — Dominio 2.4: Modelo de datos y etiquetas

## Ejercicios guiados

> **Alcance.** Estos labs hacen tangible el modelo de datos de Prometheus: cómo se almacena un *sample*, por qué el nombre de una métrica en realidad no es más que otra etiqueta, cómo se adjuntan `job`/`instance` en el momento del scrape, cómo los histograms y summaries se descomponen en múltiples series, cómo se comportan los matchers de valor vacío, y cómo unas etiquetas descuidadas hacen detonar la cardinalidad. Recorrelos en orden — cada uno asume el entorno construido en el paso de configuración.
>
> Todo lo que sigue es ejecutable. Ejecutá los comandos, leé la salida *real* en tu máquina, y recién entonces contrastá tu razonamiento con las respuestas.

---

### Configuración del lab (ejecutar una vez)

Necesitás un servidor Prometheus que se scrapee a **sí mismo** y un `node_exporter`. La configuración de dos targets es deliberada: muchas preguntas sobre etiquetas solo tienen sentido cuando existe más de un target y más de un job.

1. Creá un directorio de trabajo y una configuración de scrape:

   ```bash
   mkdir -p ~/pca-2.4 && cd ~/pca-2.4
   cat > prometheus.yml <<'EOF'
   global:
     scrape_interval: 15s
     external_labels:
       monitor: pca-lab

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']

     - job_name: node
       static_configs:
         - targets: ['localhost:9100']
           labels:
             env: lab
             region: eu-west-1
   EOF
   ```

2. Iniciá ambos procesos (se muestra con Docker; los binarios nativos funcionan de forma idéntica — solo apuntá `--config.file` al mismo YAML):

   ```bash
   docker run -d --name node --net host \
     quay.io/prometheus/node-exporter:latest

   docker run -d --name prom --net host \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     prom/prometheus:latest
   ```

3. Confirmá que ambos están arriba. La métrica `up` es la propia señal de salud de Prometheus, sintetizada por target en cada scrape:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=up' | jq -r \
     '.data.result[] | "\(.metric.job)\t\(.metric.instance)\t\(.value[1])"'
   ```

   Se espera:

   ```
   node        localhost:9100   1
   prometheus  localhost:9090   1
   ```

Si ambas líneas terminan en `1`, el lab está listo.

---

### Ejercicio 1 — Anatomía de un sample en el endpoint de exposición

Prometheus almacena un flujo de **samples**. Un sample es: el nombre de una métrica, un conjunto de etiquetas, un valor `float64`, y un timestamp `int64` en milisegundos. El formato de exposición en texto de `/metrics` te muestra todo *excepto* el timestamp (Prometheus estampa el sample él mismo, en el momento del scrape).

1. Extraé tres familias de métricas directamente de `node_exporter`, antes de que Prometheus las toque:

   ```bash
   curl -s http://localhost:9100/metrics \
     | grep -E '^(# (HELP|TYPE) )?node_cpu_seconds_total|^node_filesystem_avail_bytes' \
     | head -n 12
   ```

   Salida representativa:

   ```
   # HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
   # TYPE node_cpu_seconds_total counter
   node_cpu_seconds_total{cpu="0",mode="idle"} 20356.54
   node_cpu_seconds_total{cpu="0",mode="system"} 245.19
   node_cpu_seconds_total{cpu="0",mode="user"} 512.33
   node_cpu_seconds_total{cpu="1",mode="idle"} 20401.12
   node_filesystem_avail_bytes{device="/dev/sda1",fstype="ext4",mountpoint="/"} 3.284...e+10
   ```

2. Fijate lo que el exporter **no** emitió: no hay `job`, ni `instance`, ni `env`. Ahora comparalo con cómo se ve la *misma* métrica después de la ingesta:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=node_cpu_seconds_total{cpu="0",mode="idle"}' \
     | jq '.data.result[0].metric'
   ```

   Se espera:

   ```json
   {
     "__name__": "node_cpu_seconds_total",
     "cpu": "0",
     "mode": "idle",
     "instance": "localhost:9100",
     "job": "node",
     "env": "lab",
     "region": "eu-west-1"
   }
   ```

3. Contá en cuántas series distintas se despliega un solo counter de CPU en este host:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count(node_cpu_seconds_total)' \
     | jq -r '.data.result[0].value[1]'
   ```

**Verificación de comprensión**

- **Q1.1** En `node_cpu_seconds_total{cpu="0",mode="idle"} 20356.54`, nombrá cada parte sintáctica: el nombre de la métrica, las etiquetas y el valor. ¿Qué cuarto componente de un sample almacenado está *ausente* en esta línea, y quién lo aporta?
- **Q1.2** El exporter no emitió etiqueta `job` ni `instance`, y sin embargo la serie consultada tiene ambas. ¿De dónde salieron `instance`, `job`, `env` y `region`, y en qué momento se adjuntaron?
- **Q1.3** `node_cpu_seconds_total` está declarada como `# TYPE ... counter`. ¿Qué invariante promete un counter sobre su valor a lo largo del tiempo, y qué función de PromQL existe precisamente porque los counters en crudo no son directamente útiles?
- **Q1.4** Si una máquina tiene 4 CPUs lógicas y el exporter reporta 8 modos de CPU, ¿cuántas series `node_cpu_seconds_total` produce ese único nombre de métrica, y cuál es la regla general que relaciona las etiquetas con el número de series?

---

### Ejercicio 2 — El nombre de la métrica es solo una etiqueta (`__name__`)

Internamente no existe un campo "name" privilegiado. El nombre de la métrica se almacena en la etiqueta reservada `__name__`, y la notación `foo{bar="baz"}` es puro azúcar sintáctico para `{__name__="foo", bar="baz"}`.

1. Seleccioná una serie usando **solo** la etiqueta reservada, sin ningún nombre suelto:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query={__name__="up", job="node"}' \
     | jq '.data.result[0].metric'
   ```

   Se espera:

   ```json
   { "__name__": "up", "instance": "localhost:9100", "job": "node", "env": "lab", "region": "eu-west-1" }
   ```

2. Usá un matcher de regex sobre el nombre para encontrar cada familia de métricas que describe la salud del scrape. Esto es imposible si el nombre *no* es una etiqueta:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count by (__name__) ({__name__=~"scrape_.+"})' \
     | jq -r '.data.result[] | "\(.metric.__name__)\t\(.value[1])"'
   ```

   Se espera (los nombres pueden variar levemente según la versión):

   ```
   scrape_duration_seconds          2
   scrape_samples_post_metric_relabeling  2
   scrape_samples_scraped           2
   scrape_series_added              2
   ```

3. Ahora probá un selector donde **cada** matcher puede coincidir con la cadena vacía, y leé el error:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query={job=~".*"}' | jq '.error, .errorType'
   ```

   Se espera:

   ```
   "vector selector must contain at least one non-empty matcher"
   "bad_data"
   ```

**Verificación de comprensión**

- **Q2.1** Reescribí `up{job="node"}` en la forma `{...}` completamente sin azúcar, sin nombre de métrica suelto. ¿Cuál es la etiqueta reservada exacta que lleva el nombre?
- **Q2.2** Los cuatro operadores de matcher son `=`, `!=`, `=~`, `!~`. ¿Cuáles dos son regex anclados, y qué significa "completamente anclado" para `=~"scrape_.+"` — coincide con `node_scrape_x`?
- **Q2.3** ¿Por qué se rechaza `{job=~".*"}` mientras que `{job=~".+"}` se acepta? Enunciá la regla sobre los selectores que coinciden con vacío.
- **Q2.4** Los nombres de etiqueta que empiezan con `__` (como `__name__`) son una clase reservada. ¿Qué les pasa a las etiquetas `__meta_*` y `__address__` para cuando una serie se almacena, y por qué no las ves en los resultados de las consultas?

---

### Ejercicio 3 — Etiquetas de target: `job`, `instance` y `external_labels`

`job` e `instance` son **etiquetas de target** — Prometheus las adjunta desde la configuración de scrape, no desde el exporter. `instance` toma por defecto el `__address__` del target (`host:port`); `job` es el `job_name`. `external_labels` se comportan de forma diferente: se estampan solo en los datos que *salen* del servidor (remote‑write, federación, alertas), no en las series almacenadas localmente.

1. Confirmá el origen como etiqueta de target de `job`/`instance` listando cada target y sus etiquetas descubiertas/finales:

   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.labels.instance)\t\(.scrapeUrl)"'
   ```

   Se espera:

   ```
   node        localhost:9100   http://localhost:9100/metrics
   prometheus  localhost:9090   http://localhost:9090/metrics
   ```

2. Mostrá que `env`/`region` (definidas en `static_configs.labels` del job `node`) existen en las series de `node` pero están **ausentes** en las series de `prometheus`:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=up' \
     | jq -r '.data.result[] | "\(.metric.job)\tenv=\(.metric.env // "<none>")\tregion=\(.metric.region // "<none>")"'
   ```

   Se espera:

   ```
   node        env=lab      region=eu-west-1
   prometheus  env=<none>   region=<none>
   ```

3. Ahora buscá `monitor="pca-lab"` (el valor de `external_labels`) en las series almacenadas localmente:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=up{monitor="pca-lab"}' \
     | jq '.data.result | length'
   ```

   Se espera:

   ```
   0
   ```

**Verificación de comprensión**

- **Q3.1** Un target se define solo como `targets: ['localhost:9100']` sin `instance` explícito. ¿Qué valor recibe `instance`, y de qué etiqueta mágica se deriva?
- **Q3.2** Dos exporters en el mismo host exponen la métrica `process_cpu_seconds_total`. Después de que Prometheus scrapea ambos, ¿qué evita que las dos series colisionen en una sola? Sé específico sobre qué etiquetas difieren.
- **Q3.3** El paso 3 devolvió `0`. Explicá con precisión por qué `external_labels` no coincidió con ninguna serie `up` almacenada localmente, y nombrá un contexto donde `monitor="pca-lab"` *sí* aparecería.
- **Q3.4** Si un exporter expusiera él mismo una etiqueta literalmente llamada `job` (p. ej. `mymetric{job="frontend"} 5`), ¿qué hace Prometheus con ella por defecto en el momento del scrape, y qué perilla de configuración cambia ese comportamiento?

---

### Ejercicio 4 — Los histograms y summaries se descomponen en muchas series

Una sola métrica de tipo histogram no es una única serie. Prometheus (y el exporter) la exponen como: una serie `_bucket` **por cada límite `le`** (acumulativa), más `_sum` y `_count`. Un summary, en cambio, expone una serie **por cada `quantile`**, más `_sum` y `_count`. Prometheus se instrumenta a sí mismo con ambos, así que no hace falta ningún exporter extra.

1. Inspeccioná un histogram real — la propia latencia de peticiones HTTP de Prometheus:

   ```bash
   curl -s http://localhost:9090/metrics \
     | grep '^prometheus_http_request_duration_seconds' \
     | grep 'handler="/api/v1/query"' | head
   ```

   Salida representativa:

   ```
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.1"} 42
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.2"} 47
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.4"} 48
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="+Inf"} 48
   prometheus_http_request_duration_seconds_sum{handler="/api/v1/query"} 3.17
   prometheus_http_request_duration_seconds_count{handler="/api/v1/query"} 48
   ```

2. Comprobá que los buckets son **acumulativos** ("menor o igual que") y que el bucket `+Inf` es igual a `_count`:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
     'query=prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="+Inf"}
            == on(handler) prometheus_http_request_duration_seconds_count{handler="/api/v1/query"}' \
     | jq '.data.result | length'
   ```

   Una longitud distinta de cero significa que la igualdad se cumplió.

3. Ahora inspeccioná un **summary** — fijate en la etiqueta `quantile` en vez de `le`, y en que los quantiles se calculan *del lado del cliente*:

   ```bash
   curl -s http://localhost:9090/metrics \
     | grep '^prometheus_target_interval_length_seconds' | head
   ```

   Salida representativa:

   ```
   prometheus_target_interval_length_seconds{interval="15s",quantile="0.5"} 15.0004
   prometheus_target_interval_length_seconds{interval="15s",quantile="0.9"} 15.0011
   prometheus_target_interval_length_seconds{interval="15s",quantile="0.99"} 15.0019
   prometheus_target_interval_length_seconds_sum{interval="15s"} 9012.4
   prometheus_target_interval_length_seconds_count{interval="15s"} 601
   ```

4. Calculá una latencia p95 real a partir del histogram (esta es la recompensa de la etiqueta `le`):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
     'query=histogram_quantile(0.95, sum by (le) (rate(prometheus_http_request_duration_seconds_bucket[5m])))' \
     | jq -r '.data.result[0].value[1]'
   ```

**Verificación de comprensión**

- **Q4.1** Se expone un histogram con 10 buckets explícitos para un único valor de `handler`. ¿Cuántas series temporales produce en total ese histogram, y cuál serie está garantizado que será la más grande? Explicá por qué.
- **Q4.2** ¿Qué significa la etiqueta `le="0.2"` para una serie `_bucket`, y por qué el valor de `le="0.2"` debe ser siempre ≥ el valor de `le="0.1"`?
- **Q4.3** Tanto los histograms como los summaries exponen `_sum` y `_count`. Da la razón operativa por la que podés *agregar un histogram entre instancias* pero en general *no podés* agregar las series `quantile` de un summary. Ligá tu respuesta a dónde se calcula el quantile.
- **Q4.4** En `histogram_quantile(0.95, sum by (le) (rate(...[5m])))`, ¿por qué es obligatorio `by (le)`, y qué se rompería si en cambio agregaras *eliminando* la etiqueta `le`?

---

### Ejercicio 5 — Cardinalidad: el modo de fallo de las etiquetas

El número de series es el producto de las combinaciones distintas de valores de etiqueta. Una sola etiqueta mal elegida (un user ID, una URL completa, un request ID) multiplica el número de series sin límite. Esta es la forma individual más común de tumbar un servidor Prometheus, y el 2.4 espera que razones sobre esto de forma *cuantitativa*.

1. Preguntale directamente a la TSDB qué nombres de métrica y pares de etiquetas dominan la memoria:

   ```bash
   curl -s http://localhost:9090/api/v1/status/tsdb | jq '{
     total_series: .data.headStats.numSeries,
     top_metrics:  (.data.seriesCountByMetricName[:5]),
     top_labels:   (.data.labelValueCountByLabelName[:5])
   }'
   ```

   Salida representativa:

   ```json
   {
     "total_series": 1284,
     "top_metrics": [
       { "name": "node_cpu_seconds_total", "value": 64 },
       { "name": "prometheus_http_request_duration_seconds_bucket", "value": 210 }
     ],
     "top_labels": [
       { "name": "__name__", "value": 312 },
       { "name": "le",       "value": 26 }
     ]
   }
   ```

2. Calculá el total de series activas de dos formas y reconcilialas:

   ```bash
   # From the TSDB head stats:
   curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.headStats.numSeries'

   # From PromQL, using the "matches any non-empty name" idiom:
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count({__name__=~".+"})' \
     | jq -r '.data.result[0].value[1]'
   ```

3. Modelá una bomba de cardinalidad *en papel antes de causar una*. Supongamos que agregás una etiqueta `user_id` (10.000 usuarios distintos) a `api_http_requests_total`, que ya tiene `method` (5) × `status` (6) × `handler` (40) a lo largo de `instance` (3):

   ```bash
   echo "before: $((5*6*40*3))"
   echo "after (+user_id): $((5*6*40*3*10000))"
   ```

   ```
   before: 3600
   after (+user_id): 36000000
   ```

4. Encontrá al peor infractor actual por nombre y decidí si su cardinalidad es *estructural* (acotada) o *no acotada*:

   ```bash
   curl -s http://localhost:9090/api/v1/status/tsdb \
     | jq -r '.data.seriesCountByMetricName[] | "\(.value)\t\(.name)"' | sort -rn | head
   ```

**Verificación de comprensión**

- **Q5.1** Da la fórmula del número de series que produce un nombre de métrica, en función de sus etiquetas. ¿Por qué *agregar una etiqueta de cardinalidad alta* es categóricamente peor que agregar una de cardinalidad baja?
- **Q5.2** En el paso 3, una sola etiqueta convirtió 3.600 series en 36.000.000. Clasificá `user_id` como de cardinalidad acotada o no acotada, y enunciá la regla general sobre qué *nunca* debería convertirse en un valor de etiqueta.
- **Q5.3** El idiom `count({__name__=~".+"})` cuenta todas las series. ¿Por qué `".+"` y no `".*"`, y por qué `count(...)` aquí es seguro en un lab pero potencialmente costoso en una TSDB de producción grande?
- **Q5.4** `le` (buckets de histogram) y `quantile` (summaries) son técnicamente etiquetas de cardinalidad algo alta que introducís *a propósito*. ¿Por qué son aceptables cuando `user_id` no lo es? ¿Qué las acota?

---

### Ejercicio 6 — Reescribir etiquetas en la ingesta con relabeling

Las etiquetas no son hechos inmutables provenientes del exporter — vos las moldeás. `relabel_configs` actúan sobre las etiquetas especiales `__*` (etiquetas de target, `__address__`, `__meta_*` del service discovery) *antes* del scrape; `metric_relabel_configs` actúan sobre las etiquetas de cada sample *después* del scrape. Dominar la diferencia es central para el 2.4.

1. Agregá un job de scrape que **reescribe la etiqueta instance** y **descarta métricas ruidosas**. Añadí esto a `prometheus.yml`:

   ```yaml
     - job_name: node-relabeled
       static_configs:
         - targets: ['localhost:9100']
       relabel_configs:
         # Derive a clean host label from __address__ (strip the port)
         - source_labels: [__address__]
           regex: '([^:]+):.*'
           target_label: host
           replacement: '$1'
         # Overwrite instance with a friendly name
         - source_labels: [__address__]
           regex: 'localhost:9100'
           target_label: instance
           replacement: 'edge-node-01'
       metric_relabel_configs:
         # Drop a whole family after scraping — it never hits the TSDB
         - source_labels: [__name__]
           regex: 'go_.*'
           action: drop
   ```

2. Recargá la configuración sin reiniciar (requiere `--web.enable-lifecycle`, activado por defecto en la imagen vía flag — de lo contrario `docker restart prom`):

   ```bash
   curl -s -X POST http://localhost:9090/-/reload || docker restart prom
   sleep 20
   ```

3. Confirmá que el target relabeleado lleva el `instance` reescrito y la nueva etiqueta `host`:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=up{job="node-relabeled"}' \
     | jq '.data.result[0].metric | {instance, host, job}'
   ```

   Se espera:

   ```json
   { "instance": "edge-node-01", "host": "localhost", "job": "node-relabeled" }
   ```

4. Confirmá que la familia `go_*` fue descartada solo para este job:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count(go_goroutines{job="node-relabeled"})' \
     | jq '.data.result | length'
   ```

   Se espera: `0` (descartada) — mientras que `count(go_goroutines{job="prometheus"})` sigue devolviendo `1`.

**Verificación de comprensión**

- **Q6.1** Enunciá la diferencia de momento entre `relabel_configs` y `metric_relabel_configs`. ¿Cuál puede actuar sobre las etiquetas `__meta_kubernetes_pod_label_*`, y por qué la otra no puede?
- **Q6.2** En el paso 1 la acción `drop` apunta a `__name__ =~ "go_.*"`. ¿Descartar aquí ahorra ancho de banda de scrape, almacenamiento, ambos, o ninguno? Explicá qué te cuesta el "después del scrape".
- **Q6.3** Reescribiste `instance` a `edge-node-01`. ¿Qué riesgo crea sobrescribir `instance` con un valor no único si más adelante agregás un segundo target a este job?
- **Q6.4** Las etiquetas de service discovery como `__meta_ec2_tag_Name` son visibles durante el relabeling pero nunca aparecen en las series almacenadas. ¿Cómo *promovés* una a una etiqueta permanente, y qué pasa si no lo hacés?

---

## Respuestas

<details>
<summary>Clic para revelar las respuestas de todas las verificaciones de comprensión</summary>

### Ejercicio 1

**Q1.1** — Nombre de la métrica: `node_cpu_seconds_total`. Etiquetas: `{cpu="0", mode="idle"}`. Valor: `20356.54` (un `float64`). El cuarto componente ausente es el **timestamp** (`int64`, milisegundos desde la época Unix). El formato de exposición en texto normalmente lo omite; **Prometheus lo aporta en el momento del scrape**, estampando el sample con el momento del scrape. (Un sample almacenado = nombre + etiquetas + valor + timestamp.)

**Q1.2** — Son **etiquetas de target**, adjuntadas por Prometheus durante la ingesta, no emitidas por el exporter. `instance` y `job` provienen de la configuración de scrape (`instance` toma por defecto el `__address__` del target, `job` sale de `job_name`); `env` y `region` provienen del bloque `labels:` bajo `static_configs` de ese job. Todas se aplican en el momento del scrape a través del pipeline de relabeling, *después* de que se obtiene el texto en crudo.

**Q1.3** — Un counter solo **crece monótonamente** (se reinicia a 0 únicamente al reiniciarse el proceso); nunca decrece durante la vida de un proceso. El valor acumulado en crudo no tiene sentido por sí solo, así que `rate()` (e `irate()`/`increase()`) existe para calcular el cambio por segundo mientras maneja de forma transparente los reinicios del counter.

**Q1.4** — 4 CPUs × 8 modos = **32 series** para ese único nombre de métrica. Regla general: un nombre de métrica produce una serie **por cada combinación distinta de valores de etiqueta** — el conteo es el producto (cartesiano) de los valores distintos de cada etiqueta, restringido a las combinaciones que efectivamente ocurren.

### Ejercicio 2

**Q2.1** — `{__name__="up", job="node"}`. La etiqueta reservada que lleva el nombre es **`__name__`**.

**Q2.2** — Los dos operadores de regex son `=~` (coincide) y `!~` (no coincide). Los regex de Prometheus están **completamente anclados** — envueltos implícitamente en `^(?:...)$` — así que `=~"scrape_.+"` coincide con cadenas que empiezan con `scrape_`, y **no** coincide con `node_scrape_x` (esa cadena no empieza en `scrape_`).

**Q2.3** — Un selector de vector debe contener al menos un matcher que **no** coincida con la cadena vacía. `.*` coincide con la cadena vacía (y con las series que carecen por completo de la etiqueta), así que `{job=~".*"}` seleccionaría *todo*, incluidas las series sin nombre, y se rechaza. `.+` requiere al menos un carácter, así que `{job=~".+"}` es un matcher no vacío válido.

**Q2.4** — Las etiquetas con prefijo `__` están reservadas para uso interno. `__address__` y `__meta_*` existen **solo durante la fase de relabeling**; una vez que el relabeling termina, se **eliminan** antes del almacenamiento. Por eso nunca aparecen en los resultados de las consultas — se consumieron para derivar etiquetas reales como `instance`, no se persistieron.

### Ejercicio 3

**Q3.1** — `instance` pasa a ser `localhost:9100`, derivado de la etiqueta especial **`__address__`** (el `host:port` que se le indicó a Prometheus scrapear). A menos que la relabelees, `instance` == `__address__`.

**Q3.2** — Las etiquetas de target **`job`** y/o **`instance`** difieren (aquí difieren ambas, o como mínimo `job`). Como cada serie se identifica de forma única por su conjunto *completo* de etiquetas, `process_cpu_seconds_total{job="a",instance="..."}` y `process_cpu_seconds_total{job="b",instance="..."}` son series distintas y no pueden colisionar.

**Q3.3** — `external_labels` se aplican **solo a los datos que salen del servidor** — remote‑write, federación (`/federate`) y alertas enviadas a Alertmanager — nunca a los samples almacenados localmente. Por eso una consulta local de `up{monitor="pca-lab"}` no encuentra nada. `monitor="pca-lab"` *sí* aparecería en el lado receptor de remote‑write/federación, o en las etiquetas de una alerta en Alertmanager.

**Q3.4** — Por defecto Prometheus **da prioridad a las etiquetas de target sobre las expuestas**: el `job` del target gana y el `job` en conflicto del exporter se renombra a **`exported_job`** (en general `exported_<label>`). Poner `honor_labels: true` en la configuración de scrape invierte esto, dejando que la etiqueta del exporter tenga precedencia (se usa para pushgateway/federación).

### Ejercicio 4

**Q4.1** — 10 buckets + `_sum` + `_count` = **12 series** para un `handler`. El **bucket `+Inf` es siempre el más grande** (igual a `_count`), porque los buckets son *acumulativos* — cada uno cuenta todas las observaciones ≤ su `le`, y `+Inf` cuenta cada observación.

**Q4.2** — `le="0.2"` significa "conteo de observaciones cuyo valor fue **menor o igual que 0.2**". Como los buckets son acumulativos, el bucket `le="0.2"` incluye necesariamente todo lo contado por `le="0.1"` más lo que caiga en `(0.1, 0.2]`, así que su valor nunca puede ser menor.

**Q4.3** — Un histogram expone conteos de bucket acumulativos en crudo, así que podés **sumar los conteos de bucket entre instancias** y *después* calcular un quantile con `histogram_quantile` — la matemática es asociativa. Un summary calcula sus **quantiles del lado del cliente, por instancia**, y no hay forma correcta de promediar quantiles precalculados (el p95 de dos hosts no es el promedio de sus p95). De ahí que los summaries no se agreguen; los histograms sí. La distinción depende de *dónde se calcula el quantile*.

**Q4.4** — `histogram_quantile` necesita la **distribución por bucket**, así que la etiqueta `le` debe sobrevivir a la agregación; `by (le)` la preserva mientras colapsa todo lo demás. Si agregaras eliminando `le`, todos los límites de bucket se fusionarían en un solo número, la curva acumulativa se destruiría, y la función no podría interpolar un quantile — obtendrías un sinsentido o un resultado vacío.

### Ejercicio 5

**Q5.1** — Para un nombre de métrica, series = producto sobre sus etiquetas de `(valores distintos de esa etiqueta)`, contando solo las combinaciones que ocurren. Agregar una etiqueta de cardinalidad baja multiplica por una constante pequeña; agregar una etiqueta de cardinalidad *alta* multiplica por un factor grande (o no acotado), así que el total explota de forma multiplicativa, no aditiva.

**Q5.2** — `user_id` es de cardinalidad **no acotada** (crece con tu base de usuarios, potencialmente sin límite). Regla: los valores que son efectivamente no acotados o únicos por evento — user IDs, direcciones de email, URLs/paths completos con IDs, request/trace IDs, timestamps, container IDs — **nunca** deben ser valores de etiqueta. Ponelos en logs/traces, no en etiquetas de métrica.

**Q5.3** — `".+"` requiere ≥1 carácter, coincidiendo con todo nombre de métrica real (toda serie tiene un `__name__` no vacío); `".*"` sería un selector que coincide todo con vacío y se rechaza. `count({__name__=~".+"})` debe *tocar cada serie* para contarla — trivial en una TSDB de lab, pero en un servidor de millones de series es un escaneo completo costoso y debería reemplazarse por las head stats de `/api/v1/status/tsdb`.

**Q5.4** — `le` y `quantile` son **acotadas por diseño**: el número de buckets/quantiles se fija en el momento de la instrumentación (típicamente 5–15) y no crece con el tráfico ni los usuarios. `user_id` crece sin límite con la población. La cardinalidad acotada y controlada por el desarrollador es aceptable; la cardinalidad abierta y dirigida por los datos no lo es.

### Ejercicio 6

**Q6.1** — `relabel_configs` se ejecutan **antes del scrape**, sobre las etiquetas `__*` del target (incluidas `__address__` y las etiquetas `__meta_*` del service discovery), para decidir *si y cómo* scrapear un target. `metric_relabel_configs` se ejecutan **después del scrape**, sobre las etiquetas de cada sample, para filtrar/reescribir las series ingeridas. Solo `relabel_configs` puede ver `__meta_kubernetes_pod_label_*`, porque esas etiquetas `__meta_*` existen solo durante el relabeling del target y desaparecen antes de que lleguen los samples.

**Q6.2** — Descartar en `metric_relabel_configs` ocurre **después del scrape**, así que ahorra **almacenamiento (y el costo de memoria/índice de la TSDB) pero no el ancho de banda del scrape ni la CPU de parseo** — Prometheus igual obtuvo y decodificó las series `go_*`, y recién después las descartó antes de escribir. Para ahorrar el costo de red/parseo necesitarías que el exporter dejara de exponerlas (no es posible vía relabeling).

**Q6.3** — `instance` debe ser **única dentro de un job** (junto con `job`, es la identidad del target). Sobrescribirla con una constante como `edge-node-01` significa que un segundo target en el mismo job produciría la *misma* clave `{job, instance}`, causando colisiones de series / errores de "out of order" por samples duplicados y volviendo indistinguibles a los dos targets.

**Q6.4** — Promovela con una regla de relabeling que copie la etiqueta `__meta_*` en un `target_label` normal (p. ej. `source_labels: [__meta_ec2_tag_Name]` → `target_label: node_name`) *durante* `relabel_configs`. Si no la copiás antes de que el scrape se complete, la etiqueta `__meta_*` se **elimina y se pierde** — nunca llega a ser consultable.

</details>

---

### Fuentes

- Prometheus — *Data model*: https://prometheus.io/docs/concepts/data_model/
- Prometheus — *Metric types* (counter, gauge, histogram, summary): https://prometheus.io/docs/concepts/metric_types/
- Prometheus — *Jobs and instances* (`up`, `job`, `instance`, métricas sintetizadas en el scrape): https://prometheus.io/docs/concepts/jobs_instances/
- Prometheus — *Querying basics* (selectores, matchers, regla de matcher vacío): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — *Configuration* (`relabel_configs`, `metric_relabel_configs`, `honor_labels`, `external_labels`): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — *Metric and label naming / cardinality guidance*: https://prometheus.io/docs/practices/naming/ y https://prometheus.io/docs/practices/instrumentation/#do-not-overuse-labels
- Prometheus — *TSDB status API* (`/api/v1/status/tsdb`): https://prometheus.io/docs/prometheus/latest/querying/api/#tsdb-stats
- CNCF — *PCA Curriculum*: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf