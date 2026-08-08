# 1.4 Agregación sobre dimensiones

> PCA Dominio 1 — *Observability Concepts / PromQL*. Peso en el examen: 4.
> Modelo mental previo: una métrica de Prometheus no es un número, es un **conjunto de series temporales** indexado por una tupla de labels. La agregación es la operación que colapsa ese espacio de labels en tiempo de consulta.

---

## 1. El problema de producción: demasiadas dimensiones para mirar

Un único nombre de métrica instrumentada en un clúster real nunca es una sola serie. Tomemos una flota de API de tamaño moderado instrumentada con un counter estándar `http_requests_total`. Su cardinalidad es el producto cartesiano del conjunto de valores de cada label:

```
http_requests_total{job, instance, method, code, handler, ...}
```

Con 40 pods (`instance`), 5 métodos HTTP, 8 códigos de estado y 30 handlers, ese único nombre de métrica resuelve a `40 × 5 × 8 × 30 = 48,000` series distintas. Un operador humano, un panel de dashboard o un umbral de alerta no pueden consumir 48,000 líneas. Lo que el SRE realmente quiere es un puñado de **señales a nivel de servicio**: tasa total de peticiones por servicio, ratio de errores por clase de estado, latencia p99 por ruta.

Los **operadores de agregación** son el mecanismo que proyecta el conjunto de series de alta dimensionalidad sobre las dimensiones que te importan, sumando/promediando/contando a través de las dimensiones que *no* te importan. Esta es la mitad en tiempo de consulta de la reducción dimensional; la mitad en tiempo de almacenamiento son las recording rules (Sección 3), que ejecutan la *misma* agregación de forma programada y persisten un resultado de baja cardinalidad.

Tres fuerzas arquitectónicas hacen de esto una preocupación de primera clase en vez de algo cosmético:

| Fuerza | Consecuencia si la agregación se hace mal | Palanca correcta |
|---|---|---|
| **Costo de consulta** | Agregar 48k series en cada refresco de dashboard × 12 paneles × 30 espectadores derrite el motor de consultas | Pre-agregar con recording rules; consultar el resultado de baja cardinalidad |
| **Legibilidad de la señal** | Las series por pod fluctúan en los deploys; las alertas paginan por el hipo de un solo pod | Agregar al nivel de servicio (`by (job)`) para que la señal de SLO sea estable |
| **Corrección del counter** | `rate()` y `sum()` **no** conmutan — el orden equivocado oculta silenciosamente los reinicios del counter | Siempre `sum(rate(x[5m]))`, nunca `rate(sum(x)[5m])` |

Esa última fila es el hecho más evaluado y peor aplicado de este dominio. Recibe su propio tratamiento en la Sección 5.

### 1.1 La gramática

Todo operador de agregación sigue una de dos formas sintácticas equivalentes:

```promql
<aggr-op> [ by | without ( <label-list> ) ] ( [ <parameter>, ] <instant-vector> )
<aggr-op> ( [ <parameter>, ] <instant-vector> ) [ by | without ( <label-list> ) ]
```

Ambas formas son idénticas en significado; la cláusula de agrupamiento puede aparecer antes o después de la expresión entre paréntesis. Tres reglas firmes:

1. **Los operadores de agregación consumen un *instant vector* únicamente.** `sum(http_requests_total[5m])` es un error de tipos — un range vector `[5m]` debe primero reducirse a un instant vector mediante una función (`rate`, `avg_over_time`, …).
2. **`by (...)`** conserva *solo* los labels listados en la salida y descarta el nombre de la métrica (`__name__`) y todo lo demás.
3. **`without (...)`** conserva *todo excepto* los labels listados, y *además* siempre elimina `__name__`.

`by` y `without` son la perilla de "agregar sobre estas dimensiones". `by (job)` significa "dame un resultado por `job`, colapsando cualquier otra dimensión". `without (instance, pod)` significa "colapsá solo `instance` y `pod`, conservá el resto". Son duales; elegí el que nombre la lista más corta, para que los nuevos labels que aparezcan más adelante caigan por defecto en el comportamiento seguro (con `without` un nuevo label se *conserva*; con `by` un nuevo label se *descarta*).

---

## 2. El catálogo de operadores y sus compromisos

Hay once operadores de agregación (más dos experimentales). Se dividen en tres clases de comportamiento: **reducers** que emiten un valor por grupo y descartan los labels no agrupados, **selectors** que emiten un *subconjunto de las series de entrada originales con los labels originales intactos*, y **re-labellers** que sintetizan un nuevo label.

| Operador | Param | Clase | Valor de salida | ¿Conserva los labels originales? |
|---|---|---|---|---|
| `sum` | — | reducer | Σ de las muestras del grupo | No (solo labels de `by`/`without`) |
| `avg` | — | reducer | media aritmética | No |
| `min` / `max` | — | reducer | valor extremo de muestra | No |
| `count` | — | reducer | **número de series** en el grupo | No |
| `stddev` / `stdvar` | — | reducer | desviación estándar / varianza poblacional | No |
| `group` | — | reducer | siempre `1` (marcador de existencia) | No |
| `quantile` | φ (0–1) | reducer | cuantil-φ *a través de las series* | No |
| `topk` | k | **selector** | las k muestras más grandes | **Sí** |
| `bottomk` | k | **selector** | las k muestras más pequeñas | **Sí** |
| `count_values` | "label" | re-labeller | cantidad de series que comparten cada valor | Nuevo label = el valor muestreado |
| `limitk` * | k | selector | k series arbitrarias (muestreo) | Sí |
| `limit_ratio` * | r (−1..1) | selector | muestra determinista por ratio | Sí |

`*` `limitk` / `limit_ratio` requieren `--enable-feature=promql-experimental-functions` (Prometheus ≥ 2.50).

### 2.1 Reducers vs selectors — la diferencia de conjunto de labels que rompe las consultas

Esta distinción causa más dashboards rotos que cualquier otra. Un **reducer** *destruye* todo label no nombrado en la cláusula de agrupamiento:

```promql
sum by (code) (rate(http_requests_total[5m]))
# output series carry only {code="..."} — instance, handler, pod are gone
```

Un **selector** (`topk`/`bottomk`) devuelve *las series de entrada reales sin cambios*, simplemente filtradas a las k más altas/bajas:

```promql
topk(3, rate(http_requests_total[5m]))
# output series still carry {job,instance,method,code,handler,...} — full identity
```

Como `topk`/`bottomk` conservan la identidad, son perfectos para el **triaje ad-hoc** ("mostrame los 5 pods más ruidosos") pero peligrosos en **reglas de alerta y recording rules**: el *conjunto* de series devueltas puede cambiar de una evaluación a la siguiente, así que los timers de `for:` se reinician y las alertas fluctúan. Nunca pongas `topk`/`bottomk` en una expresión `alert:` que dispara paginación.

`topk`/`bottomk` también aceptan una cláusula de agrupamiento, con el significado de "top-k *por grupo*":

```promql
topk(3, rate(http_requests_total[5m])) by (job)   # 3 noisiest instances within each job
```

### 2.2 `count` vs `sum` vs `count_values`

Tres operadores que se confunden:

| Pregunta | Operador | Ejemplo |
|---|---|---|
| "¿Cuántas series coinciden?" | `count` | `count by (job) (up == 1)` → targets saludables por job |
| "¿Cuál es el total de los valores?" | `sum` | `sum by (job) (up)` → el mismo número *solo porque up∈{0,1}* |
| "¿Cuántas series contienen cada valor distinto?" | `count_values` | `count_values("version", node_uname_info)` → una serie por versión de OS, valor = cuántos nodos la ejecutan |

`count_values` es el raro: su parámetro de tipo string nombra un **nuevo label de salida** que recibe el *valor de muestra* de cada serie de entrada, y el valor del resultado es el conteo poblacional. Es el equivalente en PromQL de `GROUP BY value` en SQL.

### 2.3 `avg` no es "promedio de promedios"

`avg` calcula la media aritmética sin ponderar *a través de las series en un único instante*. Esto es correcto para gauges de peso comparable (por ejemplo CPU% por nodo) pero **incorrecto** para derivar un ratio a nivel de flota a partir de ratios por instancia, porque las instancias tienen tráfico desigual. Para obtener una media correctamente ponderada debés agregar el numerador y el denominador por separado y dividir:

```promql
# WRONG — mean of per-instance error ratios, ignores traffic weight
avg by (job) (rate(http_requests_total{code=~"5.."}[5m]) / rate(http_requests_total[5m]))

# RIGHT — ratio of aggregated rates (traffic-weighted)
  sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))
/ sum by (job) (rate(http_requests_total[5m]))
```

### 2.4 Agregar *sobre dimensiones* vs agregar *sobre el tiempo*

El nombre del examen — "aggregating over dimensions" — se contrasta deliberadamente con "aggregating over time". Son ejes ortogonales y usan herramientas distintas:

| Eje | Qué colapsa | Herramienta | Entrada → salida |
|---|---|---|---|
| **Sobre dimensiones** (este tema) | el eje de labels/series, en un mismo timestamp | operadores de agregación (`sum`, `avg`, …) | instant vector → instant vector, menos series |
| **Sobre el tiempo** | el eje temporal, dentro de una serie | `<fn>_over_time`, `rate`, `increase` | range vector → instant vector, mismo conteo de series |

Se componen en un orden fijo: reducir primero el tiempo (por serie), luego reducir las dimensiones:

```promql
sum by (job) (            # 2) collapse the series/label axis
  rate(                   # 1) collapse the time axis, per series
    http_requests_total[5m]
  )
)
```

Invertir el orden (`rate(sum(...)[5m])`) es a la vez un error de tipos *y* un error de corrección — ver Sección 5.

---

## 3. Infraestructura completa: reducción en tiempo de consulta persistida como recording rules

El patrón de producción es: definir la agregación *una vez* como recording rule, dejar que Prometheus la evalúe de forma programada, y apuntar cada dashboard y alerta a las series pre-agregadas baratas. El nombrado sigue la convención oficial `level:metric:operations`.

### 3.1 `prometheus.yml` — scrape + cableado de reglas

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: prod-eu-1

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: api
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: job
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: instance
```

### 3.2 `/etc/prometheus/rules/http.rules.yml` — las agregaciones

```yaml
groups:
  - name: http.aggregations
    interval: 30s
    rules:
      # Fleet request rate, collapsing instance/handler/method
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))

      # Same, but retaining the status-code dimension for error-ratio math
      - record: job_code:http_requests:rate5m
        expr: sum by (job, code) (rate(http_requests_total[5m]))

      # Error ratio — traffic-weighted, built from the two rules above
      - record: job:http_requests_errors:ratio5m
        expr: |
            sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))
          /
            sum by (job) (rate(http_requests_total[5m]))

      # p99 latency: histogram aggregation MUST keep the `le` bucket dimension
      - record: job:http_request_duration_seconds:p99_5m
        expr: |
          histogram_quantile(
            0.99,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
          )

      # Fleet health: how many instances of each job are up
      - record: job:up:count
        expr: count by (job) (up == 1)
```

La regla de p99 es el patrón canónico de "agregar un histograma sobre dimensiones" y un ítem frecuente en el examen: **sumás los counters de los buckets `by (job, le)`** — conservando `le` para que la estructura de bucket acumulativo sobreviva — *luego* aplicás `histogram_quantile`. Promediar cuantiles pre-calculados a través de instancias es estadísticamente sin sentido; debés agregar los buckets crudos.

### 3.3 Reglas de alerta construidas sobre las series agregadas

```yaml
groups:
  - name: http.alerts
    rules:
      - alert: HighErrorRatio
        # Reads the cheap pre-aggregated recording rule, not the raw 48k series
        expr: job:http_requests_errors:ratio5m > 0.05
        for: 10m
        labels:
          severity: page
        annotations:
          summary: "5xx ratio {{ $value | humanizePercentage }} on {{ $labels.job }}"

      - alert: JobUnderReplicated
        expr: job:up:count < 3
        for: 5m
        labels:
          severity: ticket
        annotations:
          summary: "Only {{ $value }} instances up for {{ $labels.job }}"
```

### 3.4 Forma nativa del operator: el CRD `PrometheusRule` (kube-prometheus-stack)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: http-aggregations
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # must match the Prometheus ruleSelector
spec:
  groups:
    - name: http.aggregations
      interval: 30s
      rules:
        - record: job:http_requests:rate5m
          expr: sum by (job) (rate(http_requests_total[5m]))
        - record: job:http_requests_errors:ratio5m
          expr: |
              sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))
            /
              sum by (job) (rate(http_requests_total[5m]))
```

---

## 4. CLI: evaluar agregaciones y leer el formato de cable

### 4.1 `promtool query instant` — evaluación de una sola vez

```console
$ promtool query instant http://localhost:9090 \
    'sum by (code) (rate(prometheus_http_requests_total[5m]))'
{code="200"} 8.4666666666 @[1723104000.000]
{code="400"} 0.0333333333 @[1723104000.000]
{code="500"} 0.0000000000 @[1723104000.000]
```

Notá que las series de salida contienen **solo** `{code}` — todos los demás labels (`handler`, `instance`) fueron colapsados por `by (code)`.

Comparalo con un selector, que preserva la identidad completa:

```console
$ promtool query instant http://localhost:9090 \
    'topk(2, rate(prometheus_http_requests_total[5m]))'
{code="200", handler="/api/v1/query", instance="localhost:9090"} 5.20 @[1723104000.000]
{code="200", handler="/metrics",      instance="localhost:9090"} 2.13 @[1723104000.000]
```

### 4.2 API HTTP cruda — la forma del JSON

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=count by (job) (up == 1)' | jq .
```
```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      { "metric": { "job": "api" },        "value": [1723104000, "6"] },
      { "metric": { "job": "prometheus" }, "value": [1723104000, "1"] }
    ]
  }
}
```

El objeto `metric` casi vacío (solo `job`, sin `__name__`) es la huella de un resultado de reducer: la agregación eliminó el nombre de la métrica y todo label no agrupado.

`count_values` en acción:

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=count_values("release", node_uname_info)' | jq -c '.data.result[]'
{"metric":{"release":"5.15.0-119-generic"},"value":[1723104000,"18"]}
{"metric":{"release":"6.8.0-40-generic"},"value":[1723104000,"7"]}
```

### 4.3 Validación estática antes del deploy

```console
$ promtool check rules /etc/prometheus/rules/http.rules.yml
Checking /etc/prometheus/rules/http.rules.yml
  SUCCESS: 5 rules found
```

### 4.4 Unit-testing de la lógica de agregación (`promtool test rules`)

`http.test.yml`:

```yaml
rule_files:
  - http.rules.yml
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      # counter climbing 60/min => 1 req/s for this series
      - series: 'http_requests_total{job="api", instance="a", code="200"}'
        values: '0+60x10'
      # counter climbing 120/min => 2 req/s
      - series: 'http_requests_total{job="api", instance="b", code="200"}'
        values: '0+120x10'
      # counter climbing 6/min => 0.1 req/s
      - series: 'http_requests_total{job="api", instance="a", code="500"}'
        values: '0+6x10'
    promql_expr_test:
      # sum by (job) collapses both instances and both codes: 1 + 2 + 0.1 = 3.1
      - expr: job:http_requests:rate5m
        eval_time: 10m
        exp_samples:
          - labels: '{job="api"}'
            value: 3.1
      # error ratio: 0.1 / 3.1 = 0.032258...
      - expr: job:http_requests_errors:ratio5m
        eval_time: 10m
        exp_samples:
          - labels: '{job="api"}'
            value: 0.03225806451612903
```

```console
$ promtool test rules http.test.yml
Unit Testing:  http.test.yml
  SUCCESS
```

Este test es la barandilla que prueba que tu cláusula `by` colapsa las dimensiones previstas — las instancias `a`/`b` y ambos códigos de estado desaparecen, dejando exactamente una serie `{job="api"}`.

---

## 5. Verificación y diagnóstico de fallas

### 5.1 La trampa de ordenamiento `rate` / `sum` (el bug número uno)

`rate()` necesita ver un *único counter monótono* para poder detectar y corregir los reinicios (un reinicio de pod baja el counter a 0). Si `sum` primero, los reinicios en distintas instancias ocurren en momentos distintos, y la serie sumada parece una línea dentada no monótona que `rate` malinterpreta — subconteo, picos, o `NaN`.

```promql
#  WRONG: sum flattens per-instance resets → rate sees false drops
rate(sum by (job) (http_requests_total)[5m])   # also a type error in most forms

#  RIGHT: rate each counter, then sum the per-second rates
sum by (job) (rate(http_requests_total[5m]))
```

**Regla:** `rate`/`increase`/`irate` van *más adentro*; los operadores de agregación van *más afuera*. Aplicá rate a los counters, luego agregá los rates.

### 5.2 Resultado vacío tras una operación binaria — labels de agrupamiento no coincidentes

Dividir dos agregaciones solo empareja series cuyos conjuntos de labels son idénticos. Si el numerador y el denominador usan listas `by` distintas, el emparejamiento de vectores no encuentra pares y devuelve vacío:

```promql
# BUG: numerator grouped by (job,code); denominator by (job) → labels differ → {}
  sum by (job, code) (rate(http_requests_total{code=~"5.."}[5m]))
/ sum by (job)       (rate(http_requests_total[5m]))
```

Diagnosticá evaluando cada lado por separado y comparando los conjuntos de labels, o corregí el agrupamiento para que coincida (ambos `by (job)`), o usá emparejamiento explícito de vectores (`/ on (job) group_left ...`). Primer reflejo cuando un panel de ratio queda en blanco: **los dos lados no comparten un conjunto de labels.**

### 5.3 Confirmar que una cláusula `by` colapsó lo que pretendías

Contá cuántas series sobrevivieron por grupo; debería igualar el número de grupos distintos, no el fan-in crudo:

```console
$ promtool query instant http://localhost:9090 'count(job:http_requests:rate5m)'
{} 12 @[1723104000.000]     # 12 jobs — good; a value near 48000 means the by-clause didn't collapse
```

### 5.4 Forense de cardinalidad — agregación anidada

Para encontrar qué nombre de métrica está haciendo explotar tu TSDB, agregá el *conteo de series en sí*:

```promql
topk(10, count by (__name__) ({__name__=~".+"}))
```

Para medir la cardinalidad aportada por un solo label (candidato para descartar con `without`):

```promql
count(count by (le) (http_request_duration_seconds_bucket))   # how many histogram buckets
```

`count(count by (X) (...))` — el `count` externo sobre un `count by` interno — es la sonda idiomática de "¿cuántos valores distintos tiene el label X?".

### 5.5 `NaN` que se traga un grupo entero

Los operadores de agregación no omiten `NaN`. Un único miembro `NaN` (por ejemplo una división `0/0` aguas arriba) se propaga a `sum`/`avg` y envenena el resultado de todo el grupo. Si un panel `sum by (job)` muestra huecos donde esperás un número, inspeccioná los miembros con `topk`:

```console
$ promtool query instant http://localhost:9090 \
    'topk(20, rate(http_requests_total[5m])) by (job)'
```

y filtrá la expresión ofensora aguas arriba (`... > 0`, `clamp_min`, o protegé el denominador) antes de que llegue a la agregación.

### 5.6 Cuantil de histograma que devuelve sinsentido

`histogram_quantile` requiere el label `le`. Si agregás `by (job)` y *olvidás* `le`, la estructura de buckets se destruye y la función devuelve `NaN` o basura:

```promql
# BROKEN: le collapsed → histogram_quantile has no buckets to interpolate
histogram_quantile(0.99, sum by (job) (rate(http_request_duration_seconds_bucket[5m])))

# CORRECT: keep le in the by-list
histogram_quantile(0.99, sum by (job, le) (rate(http_request_duration_seconds_bucket[5m])))
```

### 5.7 `topk`/`bottomk` en alertas → fluctuación

Como los selectors devuelven un *conjunto cambiante* de series, una `alert:` construida sobre `topk(...)` crea y destruye continuamente series en estado de disparo, reiniciando `for:` y provocando tormentas de paginación. Verificalo observando cómo cambia el conjunto de series activas entre evaluaciones; **corregí** alertando sobre un umbral de reducer (`sum by (job) (...) > N`) y reservando `topk` para la anotación/notebook donde estás haciendo triaje de *cuál* miembro es el peor.

### Lista de chequeo de diagnóstico

| Síntoma | Causa probable | Confirmá con |
|---|---|---|
| El gráfico de rate tiene picos/caídas en los momentos de deploy | `sum` antes de `rate` | Mové `rate` más adentro |
| El panel de ratio está vacío | las listas `by` de numerador/denominador difieren | Evaluá cada lado; compará labels |
| El resultado tiene ~la cardinalidad cruda | `by`/`without` nombran los labels equivocados | `count(<expr>)` debería igualar el conteo de grupos |
| El grupo entero muestra `NaN`/hueco | un miembro `NaN` se propagó | `topk(N, ...) by (group)` para encontrarlo |
| p99 es `NaN` o absurdo | `le` descartado en la agregación | Agregá `le` a la lista `by` |
| La alerta fluctúa on/off | `topk`/`bottomk` en `expr` | Reemplazá por reducer + umbral |

---

## 6. Referencias

- Prometheus — *Querying: Operators → Aggregation operators*: https://prometheus.io/docs/prometheus/latest/querying/operators/#aggregation-operators
- Prometheus — *Querying basics* (instant vs range vectors): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — *Query functions* (`rate`, `histogram_quantile`, `<fn>_over_time`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — *Recording rules*: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — *Recording-rule naming convention* (`level:metric:operations`): https://prometheus.io/docs/practices/rules/
- Prometheus — *Histograms and summaries* (aggregating buckets before `histogram_quantile`): https://prometheus.io/docs/practices/histograms/
- Prometheus — *promtool unit testing rules*: https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus — *HTTP API* (`/api/v1/query` response schema): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus Operator — *PrometheusRule* API reference: https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PrometheusRule
- CNCF — *PCA Curriculum*: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf