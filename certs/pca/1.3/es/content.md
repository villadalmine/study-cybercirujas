# Agregación en el tiempo — agregación de range-vectors en PromQL para SRE de producción

> PCA · Dominio: PromQL · Tema 1.3 · Peso en el examen: 4
> Temas prerequisito: Selección de datos (range vs instant vectors), Tasas y derivadas (`rate`, `increase`).

---

## 1. Motivación y el problema arquitectónico de producción

Prometheus almacena cada scrape como una muestra cruda: un par `(timestamp, float64)` por serie, tomado en el intervalo de scrape (comúnmente 15s o 30s). Esta resolución cruda es correcta para el almacenamiento pero *incorrecta para casi todo consumidor*:

- **Los dashboards submuestrean.** Un panel de 7 días renderizado con un ancho de ~1000px hace que Grafana solicite una consulta con un `step` de ~10 minutos. Si graficás el gauge crudo, Prometheus devuelve la **única muestra instantánea** más cercana a cada step de 10 minutos. Con un scrape de 15s eso es **1 de cada ~40 muestras**; un pico de memoria de 2 minutos que ocurrió *entre* dos steps es invisible. Esto es el clásico **aliasing / submuestreo**.
- **Las alertas oscilan (flapping).** Disparar sobre un único scrape ruidoso (`node_load1 > 8`) se activa con una muestra desafortunada y se recupera con la siguiente. Necesitás una afirmación sobre una *ventana de tiempo*, no sobre un instante.
- **La matemática de SLO / disponibilidad es temporal.** "¿Qué fracción de los últimos 30 días estuvo up este target?" no es respondible desde un instant vector — es una integral en el tiempo.
- **Las consultas de rango largo son costosas.** Cargar 30 días de muestras crudas para 100k series en tiempo de consulta funde el motor de consultas. Querés preagregar en una serie más gruesa.

**La agregación en el tiempo** es la respuesta de PromQL. La familia `*_over_time()` toma un **range vector** (una serie muestreada a lo largo de una ventana de tiempo) y colapsa la **dimensión temporal** en un único valor por serie, devolviendo un **instant vector**. Es el dual temporal de la *agregación sobre dimensiones* (tema 1.4: `sum`, `avg`, `topk`, … que colapsan la **dimensión de etiquetas** a través de muchas series en un mismo instante).

```
                 label dimension  ───────────────────►
                 (aggregate over dimensions: sum/avg/topk...)
   time  │  s1: ● ● ● ● ● ● ● ● ●
   dim   │  s2: ● ● ● ● ● ● ● ● ●
   │     │  s3: ● ● ● ● ● ● ● ● ●
   ▼     │       └──────[5m]──────┘
  (aggregate over time:            avg_over_time(metric[5m])
   *_over_time)                    → one value per series
```

El modelo mental que hay que fijar para el examen: **`*_over_time` nunca mezcla series entre sí.** Procesa cada serie de forma independiente y conserva su conjunto completo de etiquetas. Para combinar series *también* necesitás un operador de agregación — los dos se componen:

```promql
avg by (job) (avg_over_time(node_load1[5m]))
#   ^^^^^^^^^^^ over dimensions (spatial)
#              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ over time (temporal), per-series first
```

### El límite semántico crítico: valores crudos vs. tasas

`*_over_time` opera sobre los **valores crudos de las muestras** con **sin manejo de reseteos de contador y sin extrapolación**. Este es el error de producción más común:

- `avg_over_time(node_load1[5m])` — **correcto**. `node_load1` es un gauge; promediar valores crudos tiene sentido.
- `sum_over_time(http_requests_total[5m])` — **sin sentido**. `http_requests_total` es un contador monótono; sumar sus valores acumulativos crudos produce un número sin interpretación física, e ignora silenciosamente los reseteos de contador. Para agregar un contador en el tiempo primero lo convertís a una tasa (`rate(...)`) y luego, si hace falta, agregás la tasa con una **subquery** (§2.4).

---

## 2. Comparación técnica y compromisos

### 2.1 La familia `*_over_time`

Todas operan sobre un range vector y devuelven un instant vector con **una muestra por serie de entrada**, preservando todas las etiquetas.

| Función | Devuelve por serie | Soporte de native histogram | Uso típico en producción |
|---|---|---|---|
| `avg_over_time(v[d])` | media aritmética de las muestras en la ventana | sí | suavizar gauges; utilización promedio |
| `min_over_time(v[d])` | muestra mínima | no (histogramas ignorados) | piso del peor caso; "¿estuvo alguna vez por debajo de X?" |
| `max_over_time(v[d])` | muestra máxima | no (histogramas ignorados) | **detección de picos/spikes**, margen de capacidad |
| `sum_over_time(v[d])` | suma de las muestras | sí | integrar un delta de *gauge* por scrape; **nunca** un contador |
| `count_over_time(v[d])` | número de muestras en la ventana | sí (cuentas) | verificaciones de densidad de scrape / presencia de datos |
| `quantile_over_time(φ, v[d])` | cuantil φ (0≤φ≤1, interpolación lineal) | no | percentil por serie de un gauge en el tiempo |
| `stddev_over_time(v[d])` | desviación estándar poblacional | no | medición de volatilidad / ruido |
| `stdvar_over_time(v[d])` | varianza estándar poblacional | no | entradas para heurísticas de anomalía |
| `last_over_time(v[d])` | muestra más reciente en la ventana | sí | arrastrar el último valor hacia adelante; **conserva `__name__`** |
| `present_over_time(v[d])` | `1` si existe ≥1 muestra | sí | "¿reportó esta serie algo en la ventana?" |
| `mad_over_time(v[d])` | desviación absoluta mediana | no | detección robusta de anomalías — **experimental**, requiere `--enable-feature=promql-experimental-functions` |

Relacionadas pero **no** parte de la familia over-time (leen un range vector para computar cambio, y **descartan `__name__`**): `rate`, `irate`, `increase`, `delta`, `idelta`, `deriv`, `predict_linear`, `resets`, `changes`, `double_exponential_smoothing` (antes `holt_winters`, experimental en Prometheus 3.x). Y `absent_over_time(v[d])` es un caso especial: devuelve un vector `1` de 1 elemento **solo cuando el range vector está vacío**, usado para alertar sobre datos faltantes.

**Comportamiento de etiquetas a memorizar:** toda función `*_over_time` **descarta la etiqueta `__name__`** — *excepto* `last_over_time`, que devuelve una muestra almacenada real sin modificar y por lo tanto conserva el nombre de la métrica.

### 2.2 `avg_over_time` vs `rate` — ambas suavizan, pero no son intercambiables

| | `avg_over_time(gauge[5m])` | `rate(counter[5m])` |
|---|---|---|
| Tipo de métrica de entrada | gauge | counter |
| Qué computa | media de valores crudos | incremento promedio por segundo |
| Consciente de reseteos de contador | n/a | sí (maneja reseteos) |
| Extrapolación en los bordes de la ventana | no | sí (extrapola a los límites de la ventana) |
| Unidad de salida | igual que la entrada | unidad-de-entrada **por segundo** |
| Uso incorrecto | sobre un contador → sinsentido | sobre un gauge → sinsentido (trata las caídas como reseteos) |

### 2.3 Elegir la agregación para alertas: función de ventana vs `for:`

Tres formas de exigir que una condición persista — cada una con un perfil de falla distinto:

| Expresión | Dispara cuando… | Comportamiento ante una única caída | Comportamiento ante un hueco de scrape |
|---|---|---|---|
| `metric > X` **`for: 5m`** | *toda* evaluación en 5m excede X | una caída **reinicia** el temporizador | una evaluación faltante puede reiniciar/extender el tiempo |
| `min_over_time(metric[5m]) > X` | el *mínimo* sobre 5m aún excede X | tolerante solo si la caída se mantiene por encima de X | un hueco **no** reinicia (la ventana igual se evalúa) |
| `avg_over_time(metric[5m]) > X` | la *media* sobre 5m excede X | tolerante ante caídas breves | robusto ante huecos |
| `max_over_time(metric[5m]) > X` | *cualquier* muestra en 5m excedió X | dispara ante un único pico | robusto ante huecos |

Regla práctica de producción: usá `for:` cuando querés "continuamente verdadero"; usá `max_over_time` cuando debés capturar un pico transitorio que `for:` se perdería porque el pico duró menos de un ciclo de evaluación; usá `avg_over_time`/`min_over_time` para amortiguar el flapping.

### 2.4 Agregar una serie *derivada* en el tiempo: subqueries

No podés escribir `max_over_time(rate(http_requests_total[5m]))` — `rate(...)` es un instant vector, y `*_over_time` necesita un range vector. La **subquery** convierte una expresión instantánea de nuevo en un range vector:

```promql
max_over_time(  rate(http_requests_total[5m])  [30m:1m]  )
#               └─────── inner instant query ───┘  └──┬─┘
#                                                  range:resolution
```

Se lee como: "evaluá `rate(...[5m])` cada 1 minuto durante los últimos 30 minutos, luego tomá el máximo". Así es como encontrás el *pico de tasa de peticiones de 5 minutos durante la última media hora* — una señal de capacidad común.

**Compromiso:** las subqueries son costosas. Cada punto de salida re-ejecuta la consulta interna a la sub-resolución; `[30m:1m]` = 30 evaluaciones internas *por step externo por serie*. Preferí una **recording rule** para materializar `rate(...)` y luego agregar la serie registrada, si el patrón se usa repetidamente (§3).

### 2.5 Downsampling al vuelo vs con recording rule

| | `*_over_time` ad-hoc en tiempo de consulta | Recording rule (preagregada) |
|---|---|---|
| Costo de consulta | alto — carga el range vector completo cada vez | bajo — lee series precomputadas |
| Frescura | siempre actual | se retrasa por `interval` |
| Impacto en cardinalidad | ninguno (transitorio) | agrega nuevas series al TSDB |
| Mejor para | exploración, dashboards ad-hoc | dashboards/alertas consultados repetidamente, rangos largos |

---

## 3. Manifiestos de infraestructura completos

### 3.1 Configuración de Prometheus que conecta los archivos de reglas

`prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 30s        # how often recording/alerting rules run
  external_labels:
    cluster: prod-eu-1
    region: eu-west

rule_files:
  - /etc/prometheus/rules/aggregation_recording.yml
  - /etc/prometheus/rules/aggregation_alerts.yml

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['node1:9100', 'node2:9100', 'node3:9100']
```

### 3.2 Recording rules — downsampling temporal y preagregación

`aggregation_recording.yml`:

```yaml
groups:
  - name: node-load.over-time
    interval: 1m                    # this group evaluates once per minute
    rules:
      # Smoothed 5-minute average load, per instance (dashboard-friendly).
      - record: instance:node_load1:avg_over_time_5m
        expr: avg_over_time(node_load1[5m])

      # Peak load in the last hour — capacity headroom signal.
      - record: instance:node_load1:max_over_time_1h
        expr: max_over_time(node_load1[1h])

      # Volatility of load — feeds anomaly heuristics.
      - record: instance:node_load1:stddev_over_time_1h
        expr: stddev_over_time(node_load1[1h])

  - name: memory.over-time
    interval: 1m
    rules:
      # Worst-case available memory over 10m — undersampling-proof.
      - record: instance:node_memory_MemAvailable_bytes:min_over_time_10m
        expr: min_over_time(node_memory_MemAvailable_bytes[10m])

  - name: request-rate.over-time
    interval: 1m
    rules:
      # Step 1: materialise the per-second rate (counter -> gauge-like).
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))

      # Step 2: aggregate the recorded rate over time WITHOUT a subquery.
      #         Because job:http_requests:rate5m is now a stored series,
      #         a plain range selector works and is cheap.
      - record: job:http_requests:rate5m:max_over_time_30m
        expr: max_over_time(job:http_requests:rate5m[30m])

  - name: availability.slo
    interval: 1m
    rules:
      # Fraction of time the target reported up, over 30 days.
      # avg of a 0/1 gauge over time == uptime ratio.
      - record: instance:up:availability_ratio_30d
        expr: avg_over_time(up[30d])
```

### 3.3 Alerting rules usando agregación over-time

`aggregation_alerts.yml`:

```yaml
groups:
  - name: over-time.alerts
    rules:
      # Sustained high load: mean over 10m, damped against single-scrape noise.
      - alert: NodeLoadHighSustained
        expr: avg_over_time(node_load1[10m]) > 8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Sustained high load on {{ $labels.instance }}"
          description: "10m avg load1 is {{ $value | printf \"%.2f\" }} (>8) on {{ $labels.instance }}."

      # Transient spike detection: any single sample above threshold in 5m.
      - alert: NodeLoadSpike
        expr: max_over_time(node_load1[5m]) > 20
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Load spike on {{ $labels.instance }}"
          description: "Peak load1 in the last 5m reached {{ $value | printf \"%.2f\" }}."

      # Data-presence alert: the series stopped reporting for 10m.
      - alert: NodeMetricAbsent
        expr: absent_over_time(node_load1{instance="node1:9100"}[10m])
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "node_load1 absent from node1 for 10m"
          description: "No samples for node_load1{instance=node1:9100} in the last 10m."

      # Availability SLO breach over the rolling 30d window.
      - alert: TargetAvailabilityBelowSLO
        expr: instance:up:availability_ratio_30d < 0.995
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} below 99.5% availability (30d)"
          description: "30d availability is {{ $value | humanizePercentage }}."
```

### 3.4 Equivalente CRD de Prometheus Operator (`PrometheusRule`)

Para despliegues de Kubernetes las mismas reglas se distribuyen como un CRD que el Operator reconcilia en un ConfigMap de reglas:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: over-time-aggregations
  namespace: monitoring
  labels:
    app.kubernetes.io/part-of: kube-prometheus-stack
    prometheus: k8s          # must match the Prometheus CR ruleSelector
    role: alert-rules
spec:
  groups:
    - name: node-load.over-time
      interval: 1m
      rules:
        - record: instance:node_load1:avg_over_time_5m
          expr: avg_over_time(node_load1[5m])
        - record: instance:node_load1:max_over_time_1h
          expr: max_over_time(node_load1[1h])
    - name: over-time.alerts
      rules:
        - alert: NodeLoadHighSustained
          expr: avg_over_time(node_load1[10m]) > 8
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Sustained high load on {{ $labels.instance }}"
```

---

## 4. Comandos de CLI y salida real de terminal

### 4.1 Validar la sintaxis de las reglas antes de desplegar

```console
$ promtool check rules /etc/prometheus/rules/aggregation_recording.yml
Checking /etc/prometheus/rules/aggregation_recording.yml
  SUCCESS: 7 rules found
```

### 4.2 Instant query — gauge suavizado (nombre de métrica descartado)

```console
$ promtool query instant http://localhost:9090 'avg_over_time(node_load1[5m])'
{instance="node1:9100", job="node"} => 0.42 @[1754640000]
{instance="node2:9100", job="node"} => 1.07 @[1754640000]
{instance="node3:9100", job="node"} => 0.18 @[1754640000]
```

Compará con `last_over_time`, que **conserva** el nombre de la métrica:

```console
$ promtool query instant http://localhost:9090 'last_over_time(node_load1[5m])'
node_load1{instance="node1:9100", job="node"} => 0.39 @[1754640000]
node_load1{instance="node2:9100", job="node"} => 1.11 @[1754640000]
```

### 4.3 Range query — mostrando pico vs crudo sobre una ventana

```console
$ promtool query range --start=1754639700 --end=1754640000 --step=60 \
      http://localhost:9090 'max_over_time(node_load1{instance="node1:9100"}[5m])'
{instance="node1:9100", job="node"} =>
0.55 @[1754639700]
0.61 @[1754639760]
2.34 @[1754639820]
0.48 @[1754639880]
0.47 @[1754639940]
0.51 @[1754640000]
```

El `2.34` en `1754639820` es un pico que un gráfico de valores crudos a este step de 60s habría perdido por completo — `max_over_time` lo hace visible.

### 4.4 Verificar la densidad de scrape con `count_over_time`

Con un intervalo de scrape de 15s, una ventana de 1 hora debería contener ~240 muestras:

```console
$ promtool query instant http://localhost:9090 'count_over_time(up{job="node"}[1h])'
{instance="node1:9100", job="node"} => 240 @[1754640000]
{instance="node2:9100", job="node"} => 240 @[1754640000]
{instance="node3:9100", job="node"} => 173 @[1754640000]   # <-- 28% samples missing
```

`node3` muestra 173/240 → fallos de scrape intermitentes. `count_over_time` es tu sonda de completitud de datos.

### 4.5 Ratio de disponibilidad sobre 30 días

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
       --data-urlencode 'query=avg_over_time(up{instance="node1:9100"}[30d])' | jq .
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": { "instance": "node1:9100", "job": "node" },
        "value": [ 1754640000, "0.9987" ]
      }
    ]
  }
}
```

`0.9987` → 99.87% de disponibilidad sobre 30 días.

### 4.6 Subquery: pico de tasa de 5 minutos sobre los últimos 30 minutos

```console
$ promtool query instant http://localhost:9090 \
      'max_over_time(sum by (job) (rate(http_requests_total[5m]))[30m:1m])'
{job="api"} => 1423.6 @[1754640000]
{job="web"} =>  318.9 @[1754640000]
```

### 4.7 Testeo unitario de reglas over-time con `promtool test rules`

`aggregation_test.yml` — notá el caso de borde deliberado en `t=0`:

```yaml
rule_files:
  - aggregation_recording.yml

evaluation_interval: 1m

tests:
  - interval: 1m
    input_series:
      # Samples at t = 0m,1m,2m,3m,4m,5m with values 1,2,3,4,5,6
      - series: 'node_load1{instance="node1:9100", job="node"}'
        values: '1 2 3 4 5 6'

    promql_expr_test:
      # A range selector is LEFT-OPEN, RIGHT-CLOSED: (T-5m, T].
      # At eval_time 5m the window (0m, 5m] EXCLUDES the t=0 sample (value 1)
      # and includes t=1..5m (values 2,3,4,5,6). Mean = 20/5 = 4.
      - expr: avg_over_time(node_load1[5m])
        eval_time: 5m
        exp_samples:
          - labels: '{instance="node1:9100", job="node"}'
            value: 4

      - expr: max_over_time(node_load1[5m])
        eval_time: 5m
        exp_samples:
          - labels: '{instance="node1:9100", job="node"}'
            value: 6

      - expr: min_over_time(node_load1[5m])
        eval_time: 5m
        exp_samples:
          - labels: '{instance="node1:9100", job="node"}'
            value: 2

      - expr: count_over_time(node_load1[5m])
        eval_time: 5m
        exp_samples:
          - labels: '{instance="node1:9100", job="node"}'
            value: 5

      # last_over_time keeps the __name__ label.
      - expr: last_over_time(node_load1[5m])
        eval_time: 5m
        exp_samples:
          - labels: 'node_load1{instance="node1:9100", job="node"}'
            value: 6
```

```console
$ promtool test rules aggregation_test.yml
Unit Testing:  aggregation_test.yml
  SUCCESS
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 El piso ventana-de-rango / intervalo-de-scrape — "empty result"

La falla más frecuente: **la ventana de rango es más corta que (o comparable a) el intervalo de scrape**, por lo que el intervalo abierto por izquierda `(T-d, T]` captura muy pocas muestras — o ninguna.

- `metric[10s]` con un scrape de 15s puede seleccionar **cero** muestras en algunos momentos de evaluación → la serie *desaparece silenciosamente* del resultado.
- **Regla:** hacé que el rango sea al menos `4 × scrape_interval` para que contenga de forma confiable ≥3–4 muestras. Para un scrape de 15s, `[1m]` es el mínimo práctico.

Diagnosticá con `count_over_time`:

```console
$ promtool query instant http://localhost:9090 'count_over_time(node_load1[20s])'
# (empty result — window too small)

$ promtool query instant http://localhost:9090 'count_over_time(node_load1[1m])'
{instance="node1:9100", job="node"} => 4 @[1754640000]
```

### 5.2 La staleness acorta tu ventana

Si un target se cae (o una serie deja de exponerse), Prometheus escribe un **marcador de staleness** y la serie se considera *ausente* después de `--query.lookback-delta` (por defecto **5m**). Dentro de una ventana `*_over_time` que cruza el límite de staleness, las muestras posteriores al último scrape real **no** se cuentan — tu `avg_over_time(...[1h])` puede en realidad promediar mucho menos de una hora de datos. Siempre acompañá las ventanas largas con `count_over_time` para confirmar que el conteo de muestras es el esperado.

### 5.3 Mal uso de contadores — la respuesta silenciosamente incorrecta

`sum_over_time`/`avg_over_time` sobre un contador pasa toda verificación libre (la URL resuelve, el YAML parsea, la regla carga) y produce un número — uno *incorrecto*. Verificación: asegurá el tipo de la métrica.

```console
$ curl -s http://node1:9100/metrics | grep -A1 '^# TYPE http_requests_total'
# TYPE http_requests_total counter        # <-- counter: do NOT *_over_time the raw value
```

Si es un contador, el patrón correcto es `rate()` primero, luego agregar la tasa (recording rule o subquery).

### 5.4 Estallidos de memoria / costo en ventanas anchas × alta cardinalidad

`avg_over_time(some_metric[30d])` sobre 100k series a 15s = ~172,800 muestras/serie × 100k ≈ **17 mil millones de muestras** materializadas por evaluación. Síntomas: consultas lentas, `query timed out`, picos en tiempo de evaluación sobre el proceso de Prometheus.

Diagnosticá:

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
       --data-urlencode 'query=avg_over_time(node_cpu_seconds_total[30d])' \
       -w '\n%{time_total}s\n' -o /dev/null
30.004s        # hit the default 30s query timeout

# Confirm cardinality of the selector:
$ promtool query instant http://localhost:9090 'count(node_cpu_seconds_total)'
{} => 96 @[1754640000]
```

Remedio: preagregá con una recording rule a un `interval` grueso, luego consultá la serie registrada (de baja cardinalidad, baja frecuencia) sobre la ventana larga.

### 5.5 Verificar que una recording rule realmente se pobló

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
       --data-urlencode 'query=instance:node_load1:avg_over_time_5m' | jq '.data.result | length'
3
```

Cero aquí significa que el grupo de reglas aún no se evaluó (esperá un `interval`), que la expresión está vacía (ver §5.1), o que el grupo falló al cargar — revisá la vista de runtime:

```console
$ curl -s http://localhost:9090/api/v1/rules | \
      jq '.data.groups[].rules[] | select(.health!="ok") | {name, health, lastError}'
```

### 5.6 Confirmar la convención de intervalo cuando una muestra de borde "desaparece"

Si un test unitario o una media calculada a mano está desviada exactamente por una muestra de borde, se trata de la convención **abierta por izquierda `(T-d, T]`** (§4.7). Una ventana `[5m]` en `T` **no** incluye la muestra sellada en `T-5m`. Volvé a derivar los valores esperados teniendo en cuenta ese borde antes de asumir un bug.

---

## 6. Referencias

- Prometheus — Query functions (`avg_over_time`, `min_over_time`, `max_over_time`, `sum_over_time`, `count_over_time`, `quantile_over_time`, `stddev_over_time`, `stdvar_over_time`, `last_over_time`, `present_over_time`, `mad_over_time`, `absent_over_time`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — Querying basics (instant vs range vectors, range selectors, `offset`, `@` modifier): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — Subquery syntax: https://prometheus.io/docs/prometheus/latest/querying/basics/#subquery
- Prometheus — Aggregation operators (aggregation over dimensions, for contrast): https://prometheus.io/docs/prometheus/latest/querying/operators/#aggregation-operators
- Prometheus — Recording rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — Alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus — Staleness and `--query.lookback-delta`: https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness
- Prometheus — HTTP API (`/api/v1/query`, `/api/v1/query_range`, `/api/v1/rules`): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — `promtool` unit testing for rules: https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus — Feature flags (`--enable-feature=promql-experimental-functions`): https://prometheus.io/docs/prometheus/latest/feature_flags/
- Prometheus Operator — `PrometheusRule` API reference: https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PrometheusRule
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf