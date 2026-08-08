# PCA — Topic 1.1: Selecting Data (PromQL)

> **Dominio:** PromQL · **Peso en el examen:** 4 · **Nivel:** SRE de Producción / Arquitecto de Plataforma
> *Todo lo que consultás en Prometheus — dashboards, alertas, recording rules, ventanas de burn-rate de SLO — empieza con un selector. La selección es donde se deciden la corrección y el costo antes de que se ejecute una sola función de agregación.*

---

## 1. Motivación: el problema arquitectónico que resuelve la selección

Un servidor Prometheus es una **base de datos de series temporales con un pipeline de scrape basado en pull y un motor de consultas embebido**. En régimen estacionario, un servidor de producción mantiene millones de series activas en su head block (datos en memoria respaldados por WAL), más bloques persistidos en disco. Una consulta simple como `sum(rate(http_requests_total[5m]))` parece trivial, pero antes de que ocurra cualquier operación matemática el motor debe responder una pregunta mucho más difícil:

> *Dado un timestamp de evaluación `t`, ¿cuáles de los millones de series coinciden, y qué samples de cada serie están dentro del alcance?*

Eso es **seleccionar datos**. Es el paso más sensible al rendimiento en PromQL por tres razones:

1. **La cardinalidad es el factor de costo.** La cantidad de series que toca un selector — no la cantidad de samples — domina las búsquedas en el índice, la asignación de memoria y la latencia de la consulta. Un selector que resuelve a 2 series y otro que resuelve a 2.000.000 de series se ven idénticos en sintaxis.
2. **La selección define la corrección temporal.** Los selectores instantáneos, los selectores de rango, `offset` y `@` fijan cada uno *qué samples en el tiempo* participan. Una lógica de alertas "correcta" pero que selecciona la ventana de tiempo equivocada produce pages falsos o, peor, gaps silenciosos.
3. **La selección es donde se resuelve la staleness.** Un target que desapareció hace 3 minutos vs. hace 7 minutos se comporta distinto bajo el lookback delta por defecto de 5 minutos. Los post-mortems de incidentes de SRE frecuentemente se remontan a un malentendido de este límite.

El modo de falla en producción que este topic previene:

```
Alert "TargetDown" flaps every scrape cycle
  → root cause: query relies on absent() over a selector whose
    lookback-delta hides the gap for up to 5 minutes
  → the alert fires and resolves inside the staleness window
```

Acertar con la selección es la diferencia entre un stack de observabilidad en el que se confía y uno que se silencia.

---

## 2. El modelo de datos de Prometheus — qué resuelve realmente un selector

Una **serie temporal** se identifica de manera única por su conjunto completo de labels. El nombre de la métrica *no* es especial en el momento del almacenamiento — se guarda como el label reservado `__name__`. Estos dos son idénticos:

```promql
http_requests_total{job="api", code="200"}
{__name__="http_requests_total", job="api", code="200"}
```

Cada serie es un stream append-only de samples `(timestamp_ms, float64)` (o samples de native-histogram en Prometheus 3.x). El TSDB mantiene un **índice invertido** que mapea cada par `label=value` a una lista ordenada de IDs de serie (una *postings list*). Un selector se compila en una **intersección de conjuntos sobre postings lists**:

```
job="api"        → postings: {12, 88, 143, 5567, ...}
code="200"       → postings: {88, 143, 900, ...}
__name__="http_requests_total" → postings: {88, 143, 5567, ...}
                                  ─────────────────────────────
intersection     → {88, 143}     ← series the engine will read
```

Por esto la forma de tus matchers cambia el costo de la consulta en órdenes de magnitud: un matcher de igualdad (`=`) impacta una sola postings list; un matcher de regex (`=~`) puede tener que unir cientos de ellas antes de intersecar.

Existen dos categorías de selectores, y todo en este topic es una variación de una de ellas:

| Tipo de selector | Devuelve | Ejemplo | Alimenta funciones como |
|---|---|---|---|
| **Instant vector selector** | un sample por serie coincidente en el tiempo `t` | `node_memory_MemAvailable_bytes` | `sum`, `topk`, operadores de comparación |
| **Range vector selector** | una *porción* de samples sobre una duración por serie | `node_memory_MemAvailable_bytes[5m]` | `rate`, `increase`, `*_over_time` |

Un range vector **no puede graficarse ni usarse para alertar directamente** — primero debe reducirse a un instant vector mediante una función. `promtool` y la API HTTP rechazarán un range selector desnudo como expresión de alerta/gráfico.

---

## 3. Instant vector selectors

Sintaxis: un nombre de métrica y/o un bloque de matcher `{}`.

```promql
http_requests_total
http_requests_total{code="500"}
{__name__="http_requests_total", code="500"}   # equivalent
```

**Semántica de evaluación** (memorizá esto — se testea mucho):

> Para cada serie coincidente, el motor devuelve el **sample más reciente cuyo timestamp esté dentro de `[t - lookback_delta, t]`**. Si no existe ningún sample en esa ventana, la serie se descarta del resultado. Si el sample más reciente dentro de la ventana es un **stale marker**, la serie también se descarta.

`lookback_delta` tiene un valor por defecto de **5 minutos** y se configura con `--query.lookback-delta`. Consecuencias:

- Una métrica scrapeada cada 15s siempre tendrá un sample fresco; el lookback casi nunca importa.
- Una métrica scrapeada cada 4 minutos está bien con el lookback por defecto pero **desaparece de las consultas** en el instante en que bajás `--query.lookback-delta` por debajo de su scrape interval — una caída autoinfligida clásica de dashboards.

**La regla del empty-matcher.** Un selector debe contener **al menos un matcher que no coincida con el string vacío**. Esto es rechazado:

```promql
{job=~".*"}            # ERROR: vector selector must contain at least one
                       # non-empty matcher
```

Como `.*` coincide con `""`, el motor se niega a escanear todo el índice. Usá un matcher que excluya el vacío:

```promql
{job=~".+"}            # OK: ".+" cannot match the empty string
{__name__=~".+"}       # OK: selects every series (expensive, but legal)
```

---

## 4. Label matchers y el motor de regex RE2

Cuatro operadores de matcher:

| Operador | Significado | Comportamiento de postings | Costo |
|---|---|---|---|
| `=` | el label es igual al valor | postings list única | el más barato |
| `!=` | el label no es igual | complemento — lee todo, resta | moderado |
| `=~` | el label coincide con regex | unión de las postings de cada valor coincidente | alto (fan-out) |
| `!~` | el label no coincide con regex | complemento de la unión | el más alto |

**Hechos críticos sobre regex:**

1. El motor es **RE2** (la librería de regex de tiempo lineal de Google). Sin backreferences, sin lookahead. Esto garantiza que no haya backtracking catastrófico — una decisión deliberada de resistencia a DoS.
2. **Los matchers están completamente anclados.** `code=~"5.."` se comporta como `^5..$`. Para coincidir con un substring tenés que escribir los wildcards explícitamente:

```promql
path=~"/api/.*"        # anchored: matches paths STARTING with /api/
path=~".*login.*"      # matches paths CONTAINING login
```

3. **Alternaciones optimizadas.** Prometheus reescribe `=~"a|b|c"` a un conjunto de búsquedas de igualdad internamente (desde 2.34+), así que una alternación acotada es casi tan barata como `=`. Un regex cargado de `.*` sin acotar no lo es.

**Tabla de trade-off — expresar "uno de varios jobs":**

| Expresión | Corrección | Costo de índice | Legibilidad | Recomendación |
|---|---|---|---|---|
| `{job=~"api\|web\|worker"}` | exacta | bajo (reescrito a eq-set) | alta | ✅ preferida |
| `{job=~"a.*"}` (confiando en el prefijo) | frágil — coincide con `apiv2`, `analytics` | medio | baja | ❌ evitar |
| tres consultas separadas unidas con `or` | exacta | 3× costo de parseo | baja | ❌ evitar |
| `{job!~"db\|cache"}` (negación) | invierte la intención, deriva a medida que aparecen nuevos jobs | alto | media | ⚠️ usar con moderación |

**Escape.** Los metacaracteres de regex en los valores deben escaparse: para coincidir con un hostname con puntos literal usá `instance=~"node1\\.prod\\.example\\.com.*"` (o mejor, `=` si el valor es exacto).

---

## 5. Range vector selectors

Agregá una **duración** entre corchetes para seleccionar una ventana de samples por serie:

```promql
http_requests_total[5m]
rate(http_requests_total[5m])       # range → instant, via rate()
```

Unidades de duración válidas, combinables en orden descendente: `ms`, `s`, `m`, `h`, `d`, `w`, `y` — p. ej. `[1h30m]`, `[2w]`. Notá que `d`=24h e `y`=365d son ingenuas respecto del calendario.

**Límite de la ventana — un cambio disruptivo de Prometheus 3.0 que tenés que conocer:**

| Versión de Prometheus | Intervalo seleccionado por `v[d]` en el tiempo `t` | Límite |
|---|---|---|
| ≤ 2.x | `[t − d, t]` | cerrado–cerrado (ambos extremos inclusive) |
| **≥ 3.0** | `(t − d, t]` | **abierto por izquierda**, cerrado por derecha |

El cambio de 3.0 eliminó un off-by-one de larga data donde un sample que caía exactamente en `t − d` se contaba dos veces en pasos de evaluación adyacentes. Para `rate`/`increase` esto desplaza casos límite de extrapolación; las recording rules migradas desde 2.x pueden mostrar una diferencia de un sample en los bordes de la ventana. **La regla práctica sigue vigente: hacé el rango de al menos 4× el scrape interval** para que un range vector siempre contenga ≥ 4 samples y `rate()` tenga pendiente con la cual trabajar.

```promql
# scrape_interval = 15s  →  [1m] guarantees ~4 samples
rate(node_network_receive_bytes_total[1m])
```

Rangos demasiado cortos devuelven vacío silenciosamente (`rate` necesita ≥ 2 puntos en la ventana); rangos demasiado largos suavizan justo los picos que estás intentando alertar.

---

## 6. Modificadores de tiempo: `offset` y `@`

### 6.1 `offset` — desplazamiento de tiempo relativo

`offset <duration>` desplaza el *timestamp de evaluación* de ese selector hacia el pasado:

```promql
http_requests_total offset 5m           # value as it was 5 minutes ago
rate(http_requests_total[5m] offset 1w) # last-week's rate, same instant
```

El offset se coloca **después** del nombre de la métrica y después de cualquier `[range]`, pero **antes** de que cualquier función lo envuelva. Comparación semana a semana:

```promql
  sum(rate(http_requests_total[5m]))
/ sum(rate(http_requests_total[5m] offset 1w))
```

**El offset negativo** (desplazar hacia el *futuro* — significativo solo dentro de consultas de rango) requiere habilitar la feature:

```promql
http_requests_total offset -5m
```
> Detrás de `--enable-feature=promql-negative-offset` en Prometheus 2.x; **estable por defecto en Prometheus 3.0**.

### 6.2 `@` — fijación de tiempo absoluto

`@ <unix_timestamp>` fija la evaluación del selector a un instante de reloj de pared fijo, **independiente del propio tiempo de evaluación de la consulta**. Esta es la herramienta para "comparar todo contra un baseline conocido-bueno":

```promql
http_requests_total @ 1609746000        # value at 2021-01-04T07:40:00Z, always
```

Formas especiales usables en **consultas de rango** (`/api/v1/query_range`):

```promql
http_requests_total @ start()           # value at the range-query start
http_requests_total @ end()             # value at the range-query end
```

`@ start()` es la forma canónica de dibujar una **línea de baseline plana** a lo largo de todo un gráfico — el valor se fija al inicio del rango y no se mueve a medida que el gráfico avanza en pasos.

> `@` estaba detrás de `--enable-feature=promql-at-modifier` en 2.x; **estable por defecto en Prometheus 3.0**.

### 6.3 Composición e independencia del orden

`@` y `offset` se componen. El offset se aplica **relativo al tiempo de `@`**, y los dos son independientes del orden — estos son idénticos:

```promql
http_requests_total @ 1609746000 offset 5m
http_requests_total offset 5m @ 1609746000
# both evaluate the selector at 1609746000 − 300 = 1609745700
```

**Trade-off — estrategias de comparación de baseline:**

| Técnica | ¿El baseline se mueve con el gráfico? | Caso de uso | Salvedad |
|---|---|---|---|
| `offset 1w` | sí (relativo) | tendencia semana a semana en un dashboard móvil | la estacionalidad debe ser exactamente 1w |
| `@ <ts>` | no (absoluto) | fijar a un incidente / timestamp de deploy específico | el timestamp está hardcodeado, no es portable |
| `@ start()` | no (por render) | línea de referencia plana a lo largo de un gráfico de rango | solo válido en consultas de rango |
| snapshot de recording rule | no (materializado) | baseline costoso reutilizado por muchas alertas | agrega una rule + almacenamiento |

---

## 7. Subqueries — un range vector a partir de una expresión instantánea

Una subquery te permite ejecutar una expresión instantánea *repetidamente sobre una ventana*, produciendo un range vector que podés alimentar a una función de rango. Sintaxis:

```
<instant_expression> [ <range> : <resolution> ]
```

La `resolution` es opcional y por defecto toma el `evaluation_interval` global. Uso canónico — *el rate máximo de request de 5 minutos visto en los últimos 30 minutos*:

```promql
max_over_time( rate(http_requests_total[5m])[30m:1m] )
```

Esto evalúa `rate(http_requests_total[5m])` en pasos de 1 minuto a lo largo de una ventana de 30 minutos, y luego toma el máximo. **Las subqueries son costosas** — rango-interno × resolución-externa samples por serie — y son la causa #1 de errores `query processing would load too many samples`. Guía de producción:

| Situación | Preferir |
|---|---|
| Exploración puntual en la UI | subquery (rápida de escribir) |
| Reutilizada en alertas / dashboards | **recording rule** — materializá el `rate` interno, luego seleccioná el range de la métrica registrada |
| Anidamiento profundo (subquery de subquery) | refactorizar — casi siempre es un olor a recording-rule |

---

## 8. Staleness y el lookback delta

Cuando un target deja de exponer una serie (target caído, serie que ya no se emite, descartada por relabel), Prometheus inyecta un **stale marker** (un NaN especial) en el siguiente scrape. Efectos sobre la selección:

- Un selector instantáneo devuelve la serie **hasta** que el stale marker entra en la ventana de lookback, y luego **la descarta inmediatamente** — *no* esperás los 5 minutos completos si se escribió un stale marker.
- Si el target entero desaparece sin un stale marker prolijo (p. ej., partición de red), la serie persiste durante **hasta `--query.lookback-delta` (5m)** antes de que la selección deje de devolverla.

Por esto `up == 0` y `absent(...)` disparan en líneas de tiempo distintas. Diseñá las alertas en consecuencia:

```promql
# Detects a target-down within one scrape, not up to 5 minutes later:
up{job="api"} == 0

# Detects a whole job disappearing (no series at all) — subject to lookback:
absent(up{job="api"})
```

---

## 9. Manifiestos — completos, sintácticamente válidos, sin abreviar

### 9.1 Servidor Prometheus con los flags de tuning de consulta que gobiernan la selección

```yaml
# prometheus-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
  labels:
    app.kubernetes.io/name: prometheus
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prometheus
    spec:
      serviceAccountName: prometheus
      containers:
        - name: prometheus
          image: prom/prometheus:v3.1.0
          args:
            - "--config.file=/etc/prometheus/prometheus.yml"
            - "--storage.tsdb.path=/prometheus"
            - "--storage.tsdb.retention.time=15d"
            # ── selection-critical flags ──────────────────────────────
            - "--query.lookback-delta=5m"        # staleness window for instant selectors
            - "--query.max-samples=50000000"     # hard ceiling on samples a single query may load
            - "--query.timeout=2m"
            - "--query.max-concurrency=20"
            # In Prometheus 3.x @ and negative-offset are ON by default;
            # no --enable-feature flags are required for them.
          ports:
            - name: web
              containerPort: 9090
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
            - name: tsdb
              mountPath: /prometheus
          readinessProbe:
            httpGet:
              path: /-/ready
              port: web
            initialDelaySeconds: 10
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              memory: "2Gi"
      volumes:
        - name: config
          configMap:
            name: prometheus-config
        - name: tsdb
          emptyDir: {}
```

### 9.2 Scrape config — los labels acá son exactamente lo que coincidirán tus selectores

```yaml
# prometheus-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s          # ← sets the natural sample cadence
      evaluation_interval: 15s      # ← default subquery resolution
      external_labels:
        cluster: prod-eu-west-1

    scrape_configs:
      - job_name: api               # becomes label job="api"
        kubernetes_sd_configs:
          - role: endpoints
            namespaces:
              names: [default]
        relabel_configs:
          # Keep only endpoints of Services annotated for scraping
          - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
            action: keep
            regex: "true"
          # Expose pod name as a queryable label
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          # Expose the node so you can select by topology
          - source_labels: [__meta_kubernetes_pod_node_name]
            target_label: node
```

### 9.3 `ServiceMonitor` del Prometheus Operator — target de scrape declarativo

```yaml
# servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # matched by the Prometheus CR's serviceMonitorSelector
spec:
  namespaceSelector:
    matchNames: [default]
  selector:
    matchLabels:
      app.kubernetes.io/name: api
  endpoints:
    - port: metrics                  # named port on the Service
      interval: 15s
      path: /metrics
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
```

### 9.4 Recording rule — materializar una selección costosa para que las alertas seleccionen barato

```yaml
# recording-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: api-selection-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: api.rules
      interval: 30s
      rules:
        # Pre-compute the per-job 5m error rate once, so 20 alerts don't
        # each re-run the range selection + rate.
        - record: job:http_requests:rate5m
          expr: |
            sum by (job, code) (
              rate(http_requests_total{job="api"}[5m])
            )
        # Baseline pinned via subquery, materialized:
        - record: job:http_requests:rate5m_max30m
          expr: |
            max_over_time( job:http_requests:rate5m[30m:1m] )
```

---

## 10. CLI y salida real de terminal

### 10.1 Validar rules y selectores antes de shippear

```console
$ promtool check rules recording-rules.yaml
Checking recording-rules.yaml
  SUCCESS: 2 rules found
```

### 10.2 Consulta instantánea vía `promtool` (un instant vector selector)

```console
$ promtool query instant http://localhost:9090 \
    'http_requests_total{job="api", code="500"}'
http_requests_total{code="500", instance="10.1.4.9:8080", job="api", pod="api-7c9f-abc"} => 42 @ 1739012400
http_requests_total{code="500", instance="10.1.4.9:8080", job="api", pod="api-7c9f-xyz"} => 17 @ 1739012400
```

El `@ 1739012400` a la derecha es el **timestamp del sample** al que resolvió el lookback — confirmá que está dentro de `lookback-delta` respecto de "ahora".

### 10.3 Consulta de rango (un resultado de rango/matriz), con un baseline por subquery

```console
$ promtool query range --start=1739012000 --end=1739012400 --step=60 \
    http://localhost:9090 \
    'max_over_time(rate(http_requests_total{job="api"}[5m])[30m:1m])'
{job="api"} =>
  3.87 @[1739012000]
  4.02 @[1739012060]
  4.11 @[1739012120]
  4.11 @[1739012180]
  3.95 @[1739012240]
```

### 10.4 API HTTP cruda — lo que el motor realmente devuelve para un vector selector

```console
$ curl -sG 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=up{job="api"}' | jq .
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": { "__name__": "up", "instance": "10.1.4.9:8080", "job": "api" },
        "value": [ 1739012400, "1" ]
      }
    ]
  }
}
```

`resultType: vector` ⇒ un selector instantáneo. Un range selector o una consulta de rango devuelve `resultType: matrix` con un array `values` en lugar de un único `value`.

### 10.5 El modificador `@` y un offset negativo sobre la API

```console
$ curl -sG 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=http_requests_total @ 1609746000 offset 5m' \
    --data-urlencode 'time=1739012400' | jq '.data.result[0].value'
[
  1739012400,
  "918"
]
```

Notá que el **timestamp del resultado es 1739012400 (tiempo de la consulta)** pero el **valor 918 es el sample en `1609746000 − 300`** — prueba de que `@`+`offset` desacoplaron el tiempo del valor del tiempo de la consulta.

### 10.6 Medir el costo de un selector (cardinalidad) — introspección del TSDB

```console
$ promtool tsdb analyze /prometheus
Block ID: 01HFZK...  Duration: 2h0m0s  Series: 1,284,551  Samples: 612,443,190

Label pairs most involved in churning series:
120334 __name__=apiserver_request_duration_seconds_bucket
 88210 le=<many>
 41002 job=api

Highest cardinality labels:
   le: 43  (histogram buckets)
   pod: 9,214
   instance: 512

Highest cardinality metric names:
   apiserver_request_duration_seconds_bucket: 214,553
   http_requests_total: 61,004
```

`http_requests_total` por sí solo son 61k series — un `sum(rate(http_requests_total[5m]))` desnudo no interseca nada y lee las 61k. Acotalo con `{job="api"}` **primero**.

### 10.7 Cardinalidad en vivo de un único selector vía la API de status del TSDB

```console
$ curl -sG 'http://localhost:9090/api/v1/status/tsdb' | \
    jq '.data.seriesCountByMetricName[0:3]'
[
  { "name": "apiserver_request_duration_seconds_bucket", "value": 214553 },
  { "name": "http_requests_total", "value": 61004 },
  { "name": "node_cpu_seconds_total", "value": 18944 }
]
```

---

## 11. Guía de verificación y diagnóstico de fallas

| Síntoma | Causa probable en la selección | Comando / verificación de diagnóstico | Solución |
|---|---|---|---|
| La consulta devuelve vacío, la métrica "existe" | error de tipeo en un valor de label; regex no anclado como pensás | `curl .../api/v1/label/job/values`; probar regex con `{job=~"api"}` vs `{job=~".*api.*"}` | corregir el valor; agregar `.*` explícito |
| `parse error: vector selector must contain at least one non-empty matcher` | todo matcher puede coincidir con `""` (p. ej. `{job=~".*"}`) | leer la expresión | cambiar `.*` → `.+` o agregar un matcher `=` |
| Serie presente, luego intermitentemente ausente | scrape_interval ≥ `--query.lookback-delta` | comparar `scrape_interval` con lookback-delta | subir lookback-delta o bajar el scrape interval |
| `rate()` devuelve vacío para ventanas cortas | `[range]` < ~2× scrape_interval → <2 samples en la ventana | verificar scrape interval vs range | usar `[1m]`+ para scrapes de 15s |
| `query processing would load too many samples` | selector amplio o subquery pesada excede `--query.max-samples` | inspeccionar cardinalidad vía `status/tsdb` | acotar los matchers; materializar con una recording rule |
| La alerta flapea dentro de ~5 min de la pérdida del target | apoyarse en `absent()`/selector instantáneo dentro de la ventana de lookback | correlacionar con el timing de `up == 0` | alertar sobre `up == 0` para detección rápida |
| La comparación semana a semana está desfasada por horas | `offset 1w` ignora DST / deriva de calendario | verificar que `d`/`w` sean 24h/7×24h fijos | fijar con `@ <ts>` para un baseline exacto |
| El upgrade a 3.x cambió los samples de borde de una recording rule | el límite del rango pasó de `[..]` → `(..]` (abierto por izquierda) | comparar la salida de la rule entre versiones | normalmente benigno; ampliar el rango si hace falta |

**Workflow de verificación dorado antes de promover cualquier selector a una alerta/rule:**

```console
# 1. Does it parse and is it a valid alert expression (instant vector)?
$ promtool check rules my-rules.yaml

# 2. How many series does it actually touch? (cost gate)
$ curl -sG 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=count(http_requests_total{job="api"})' | \
    jq '.data.result[0].value[1]'
"61"

# 3. Are the sample timestamps fresh (inside lookback)?
$ promtool query instant http://localhost:9090 \
    'timestamp(up{job="api"}) - time()'
{...} => -3   # 3s old → healthy, well within 5m lookback
```

Si el paso 2 devuelve un número en los miles para algo que esperabas que fueran docenas, **pará** — tu selector está sub-restringido y será tu próximo incidente de latencia.

---

## 12. Referencias (fuentes oficiales)

- **PCA Curriculum (CNCF):** https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
- **PromQL — Basics (instant/range selectors, matchers, durations):** https://prometheus.io/docs/prometheus/latest/querying/basics/
- **PromQL — Operators & modifiers (`offset`, `@`, subqueries):** https://prometheus.io/docs/prometheus/latest/querying/operators/
- **PromQL — Examples:** https://prometheus.io/docs/prometheus/latest/querying/examples/
- **Staleness:** https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness
- **HTTP API (`/api/v1/query`, `query_range`, `status/tsdb`):** https://prometheus.io/docs/prometheus/latest/querying/api/
- **Data model (labels, `__name__`, samples):** https://prometheus.io/docs/concepts/data_model/
- **Query engine flags (`--query.lookback-delta`, `--query.max-samples`):** https://prometheus.io/docs/prometheus/latest/command-line/prometheus/
- **Feature flags & `@`/negative-offset history:** https://prometheus.io/docs/prometheus/latest/feature_flags/
- **Prometheus 3.0 migration (range boundary change, defaults):** https://prometheus.io/docs/prometheus/latest/migration/
- **RE2 regex syntax:** https://github.com/google/re2/wiki/Syntax
- **Prometheus Operator — ServiceMonitor / PrometheusRule API:** https://prometheus-operator.dev/docs/operator/api/
- **promtool reference:** https://prometheus.io/docs/prometheus/latest/command-line/promtool/