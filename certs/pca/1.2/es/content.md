# PCA — Domain 1.2: Rates and Derivatives

> **Alcance.** Este tema es el núcleo analítico de PromQL. Un counter de Prometheus que solo sube nunca aporta significado operativo como número absoluto — `http_requests_total 8481920` no te dice nada. Sobre lo que un SRE realmente pagea, arma dashboards y graba en SLOs es *qué tan rápido se está moviendo ese número*. Este capítulo cubre las funciones que convierten counters monótonos y gauges fluctuantes en tasas de cambio: `rate`, `irate`, `increase`, `delta`, `idelta`, `deriv`, `predict_linear`, más las funciones de contabilidad de resets/cambios `resets` y `changes`. Cubre la mecánica de extrapolación y de reset de counters que vuelve sus resultados poco obvios, y los dos modos de falla (`sum` antes de `rate`, e `irate` en alertas) que explican la mayoría de los dashboards rotos en el campo.

---

## 1. Motivación y el problema arquitectónico de producción

Prometheus tiene exactamente dos tipos de métricas numéricas que importan acá:

- **Counter** — monótonamente no decreciente, se resetea a 0 solo cuando el proceso reinicia (`http_requests_total`, `node_cpu_seconds_total`, `node_network_receive_bytes_total`). El valor absoluto es un acumulador desde el arranque del proceso y es operativamente insignificante.
- **Gauge** — un valor que sube y baja (`node_filesystem_avail_bytes`, `node_memory_MemAvailable_bytes`, `go_goroutines`, temperatura, profundidad de cola).

El problema arquitectónico es triple:

1. **La señal vive en la pendiente, no en el nivel.** Tráfico, throughput, tasa de error, utilización de CPU, I/O — cada señal RED (Rate, Errors, Duration) y USE (Utilization, Saturation, Errors) es una *derivada*. Debés computarla del lado de la query porque almacenar rates pre-derivados pierde información y rompe la re-agregación.

2. **Los counters se resetean, y la matemática debe sobrevivirlo.** Un reinicio de pod, un OOM kill, un rolling deploy — el counter vuelve de golpe a 0 en mitad de la ventana. Una resta ingenua `last - first` sobre la ventana produciría una tasa **negativa** grande. La familia rate debe detectar y corregir los resets de forma transparente, o cada deploy dispararía falsas alertas de "el throughput colapsó".

3. **Las muestras son discretas, dispersas y desalineadas.** Con un intervalo de scrape de 15s, los bordes de la ventana de tu query casi nunca caen sobre una muestra. Una ventana `[1m]` podría contener 3 o 5 muestras según el jitter. Las funciones deben **extrapolar** hacia los bordes de la ventana para dar una respuesta estable e independiente del borde — razón por la cual `increase()` de un counter entero frecuentemente devuelve un número *fraccionario*, un resultado que sorprende a todo ingeniero exactamente una vez.

El trabajo del Domain 1.2 es hacer que estos tres problemas desaparezcan detrás de un conjunto de funciones pequeño y componible — y saber con precisión qué asume cada función para que no apliques una función de counter a un gauge (o viceversa) y despaches basura silenciosamente a un dashboard.

---

## 2. La familia de funciones: comparación técnica

### 2.1 Funciones de counter (requieren entrada monótona, manejan resets)

| Función | Computa | Usa | Reset-aware | Extrapola | Segura para alertas | Rango típico |
|---|---|---|---|---|---|---|
| `rate(c[w])` | tasa de aumento **promedio** por segundo sobre `w` | **todas** las muestras en `w` | ✅ | ✅ | ✅ (suave) | ≥ 4× intervalo de scrape |
| `irate(c[w])` | tasa **instantánea** por segundo | **últimas 2** muestras en `w` | ✅ | ❌ | ❌ (demasiado spiky) | apenas lo suficiente para contener 2 muestras |
| `increase(c[w])` | aumento **total** sobre `w` (= `rate × w` segundos) | todas las muestras en `w` | ✅ | ✅ | ✅ | ≥ 4× intervalo de scrape |

`rate` e `increase` son el mismo cómputo escalado de forma distinta: `increase(c[w]) == rate(c[w]) * w_seconds`. Usá `rate` para gráficos/alertas (unidad `/s`, invariante de escala); usá `increase` cuando un humano quiere "cuántos en la última hora".

### 2.2 Funciones de gauge (**no** manejan resets — una caída es una caída real)

| Función | Computa | Método | Caso de uso |
|---|---|---|---|
| `delta(g[w])` | diferencia entre el primer/último valor extrapolados | diferencia de extremos, extrapolada | drift de temperatura, cambio de un gauge sobre una ventana |
| `idelta(g[w])` | diferencia entre las **últimas dos** muestras | diferencia de las últimas 2 | detectar el step más reciente de un gauge |
| `deriv(g[w])` | derivada por segundo vía **regresión lineal simple** sobre todas las muestras | pendiente por mínimos cuadrados | tasa de cambio suavizada de un gauge ruidoso |
| `predict_linear(g[w], t)` | extrapolación por regresión lineal del valor `t` segundos en el futuro | proyección por mínimos cuadrados | forecasting de llenado de disco / capacidad |

### 2.3 Funciones de contabilidad

| Función | Computa | Aplica a |
|---|---|---|
| `resets(c[w])` | número de resets del counter dentro de `w` | counters (conteo de restarts/crashes) |
| `changes(g[w])` | número de veces que el valor cambió dentro de `w` | gauges (detección de flapping, ej. elecciones de líder) |

### 2.4 Suavizado (experimental en Prometheus 3.x)

`holt_winters(v, sf, tf)` fue **renombrado a `double_exponential_smoothing`** en Prometheus 3.0 y movido detrás de `--enable-feature=promql-experimental-functions`. Produce un valor suavizado usando double exponential smoothing (nivel + tendencia). Rara vez en el examen más allá de "existe y es experimental", pero conocé el rename.

### 2.5 La tabla de decisión: qué función, cuándo

| Tenés… | Querés… | Usá |
|---|---|---|
| Counter | rate suave para un dashboard o alerta | `rate` |
| Counter | rate responsivo para un gráfico de consola de alta resolución | `irate` |
| Counter | conteo absoluto sobre un período ("errores en la última 1h") | `increase` |
| Gauge | cuánto se movió sobre una ventana | `delta` |
| Gauge | tendencia / pendiente sin ruido | `deriv` |
| Gauge | cuándo va a cruzar un umbral | `predict_linear` |
| Counter | cuántos restarts ocurrieron | `resets` |
| Gauge | con qué frecuencia hizo flap | `changes` |

---

### 2.6 Mecánica #1 — Extrapolación (por qué `increase` devuelve fracciones)

`rate`, `irate`(no — `irate` no extrapola), `increase` y `delta` **extrapolan hacia los bordes de la ventana**. Prometheus nunca ve una muestra exactamente en el borde de la ventana, así que proyecta la pendiente observada hacia afuera. El algoritmo (`extrapolatedRate` en `promql/functions.go`):

1. Sea `sampledInterval` = tiempo entre la primera y la última muestra en la ventana; `avgInterval = sampledInterval / (numSamples − 1)`.
2. `durationToStart` = brecha desde el inicio de la ventana hasta la primera muestra; `durationToEnd` = brecha desde la última muestra hasta el fin de la ventana.
3. Si una brecha ≥ `1.1 × avgInterval` (el `extrapolationThreshold`), se asume que el borde está *más allá* de datos reales, así que la extrapolación se limita a `avgInterval / 2` de ese lado.
4. **Clamp de counter:** si extrapolar hacia atrás implicaría que el counter fue negativo, `durationToStart` se limita para que la línea proyectada llegue a cero, no por debajo.
5. El valor final se escala por `(sampledInterval + durationToStart + durationToEnd) / sampledInterval`.

**Ejemplo resuelto.** Counter `http_requests_total`, scrape 15s, evaluado en `t=60`, ventana `[1m]` (el rango abierto por izquierda `(0, 60]`):

```
t=15 → 130    t=30 → 160    t=45 → 190    t=60 → 220
```

- Delta crudo de muestras = 220 − 130 = **90** sobre `sampledInterval = 45s`.
- `avgInterval = 45/3 = 15s`; `durationToStart = 15s` (< 16.5s umbral, se conserva); `durationToEnd = 0`.
- Factor de escala = `(45 + 15 + 0) / 45 = 1.333…`
- `increase[1m] = 90 × 1.333 = 120`; `rate[1m] = 120 / 60 = 2 req/s`.

El `increase` extrapolado de **120** coincide con el aumento *verdadero* desde la muestra (excluida) en `t=0` (100) hasta `t=60` (220). La extrapolación no es un error — recupera la verdad alineada al borde. **Pero** cuando los scrapes tienen jitter y los bordes no encajan limpiamente, la misma matemática arroja valores como `increase(...) = 118.6`, razón por la cual nunca debés afirmar `increase(counter[1h]) == <integer>`.

---

### 2.7 Mecánica #2 — Manejo de resets de counter

`rate`/`irate`/`increase` recorren las muestras y, cada vez que `sample[i] < sample[i-1]`, lo tratan como un reset y suman el valor previo al reset como corrección:

```
values:  100, 130,  20,  50   (reset between 130 and 20)
delta = (130-100) + (50-20) + 130(carried across reset) → 30 + 30 + 130 corrective
```

El aumento total corregido es `(130−100) + (130) + (50−20) = 30 + 130 + 30`… la implementación arrastra el último valor antes de la caída hacia el acumulador para que el resultado refleje el trabajo real hecho a través del reinicio. Efecto neto: **un deploy o un crash no produce una tasa negativa.** `resets(counter[w])` reporta cuántas de esas caídas ocurrieron — combinalo con `rate` cuando querés saber "el throughput *y* cuántos restarts lo causaron".

---

### 2.8 Mecánica #3 — La regla del 4× y el dimensionamiento de la ventana

`rate` necesita **≥ 2 muestras** en la ventana para producir alguna salida. Con un scrape perdido podés bajar a 1 muestra y obtener un *resultado vacío* — una brecha silenciosa en tu gráfico y, peor, una alerta que silenciosamente no dispara.

**Regla práctica: ventana ≥ 4 × scrape_interval.** A 15s de scrape → `[1m]` mínimo. Esto tolera un scrape perdido y aún deja ≥ 2 muestras.

| Ventana relativa al scrape | Comportamiento | Modo de falla |
|---|---|---|
| `< 2×` | a menudo 1 muestra → **sin datos** | brechas, alertas que nunca disparan |
| `= 4×` (mínimo recomendado) | 2–4 muestras, responsivo | buen valor por defecto |
| muy grande (`[1h]`) | suavizado pesado, alto costo de query | los spikes desaparecen, lenta para reaccionar, cara |

`irate` esquiva la cuestión del tamaño de ventana (solo lee los últimos 2 puntos), pero es demasiado saltona para alertas — un gráfico de `irate` es un erizo. **Alertá sobre `rate`, mirá con `irate`.**

---

### 2.9 Mecánica #4 — Agregá rates, nunca rate de agregados

La regla compositiva más importante en PromQL:

```promql
# ✅ CORRECT — rate first (per-series, reset-aware), then aggregate
sum(rate(http_requests_total[5m])) by (service)

# ❌ WRONG — aggregate first, then rate
rate(sum(http_requests_total)[5m:])   # (and this even needs a subquery)
```

`sum()` colapsa muchas series por target en una. Cuando cualquier target individual reinicia, la línea sumada **cae**, y `rate()` aplicado *después* de la suma ve un decremento que solo puede interpretar como un reset — sobre-corrigiendo y produciendo un spike incorrecto. Aplicado *antes* de la suma, `rate()` ve cada counter crudo por target y maneja cada reset correctamente; sumar rates es entonces solo una adición. **Empujá `rate`/`irate`/`increase` lo más profundo posible, agregá por fuera.**

| Orden | Manejo de resets | Correctitud | Veredicto |
|---|---|---|---|
| `sum(rate(x[5m]))` | por serie, correcto | ✅ | siempre este |
| `rate(sum(x)[5m:])` | sobre el agregado, incorrecto ante cualquier restart | ❌ | nunca |

La misma regla gobierna latencia y cuantiles:

```promql
# average latency: rate the _sum and _count separately, then divide
rate(http_request_duration_seconds_sum[5m])
  /
rate(http_request_duration_seconds_count[5m])

# p99 from a classic histogram: rate the buckets first, then histogram_quantile
histogram_quantile(0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)
```

---

## 3. Manifiestos completos e infraestructura

### 3.1 Configuración de scrape (`prometheus.yml`)

```yaml
global:
  scrape_interval: 15s          # sets your minimum rate window (4× = 1m)
  scrape_timeout: 10s
  evaluation_interval: 15s      # how often recording/alerting rules run
  external_labels:
    cluster: prod-eu-west-1
    replica: A

rule_files:
  - /etc/prometheus/rules/recording.rules.yml
  - /etc/prometheus/rules/alerting.rules.yml

scrape_configs:
  - job_name: node
    kubernetes_sd_configs:
      - role: endpoints
    relabel_configs:
      - source_labels: [__meta_kubernetes_endpoints_name]
        regex: node-exporter
        action: keep

  - job_name: api
    metrics_path: /metrics
    static_configs:
      - targets: ['api-0.api:8080', 'api-1.api:8080', 'api-2.api:8080']
```

### 3.2 Recording rules — precomputar rates caros

Las queries de rate sobre ventanas anchas o selectores de alta cardinalidad son caras de correr interactivamente y de re-correr en cada refresh de dashboard. Precomputalas una vez por `evaluation_interval`.

```yaml
# recording.rules.yml
groups:
  - name: request_rates
    interval: 15s
    rules:
      # per-service request rate (rate first, then aggregate)
      - record: service:http_requests:rate5m
        expr: sum by (service) (rate(http_requests_total[5m]))

      # per-service error rate
      - record: service:http_requests_errors:rate5m
        expr: sum by (service) (rate(http_requests_total{code=~"5.."}[5m]))

      # error ratio (SLI) — division of two recording rules
      - record: service:http_requests_error_ratio:rate5m
        expr: |
          service:http_requests_errors:rate5m
            /
          service:http_requests:rate5m

      # CPU utilization per instance (counter → rate)
      - record: instance:node_cpu_utilization:rate5m
        expr: |
          1 - avg by (instance) (
            rate(node_cpu_seconds_total{mode="idle"}[5m])
          )
```

### 3.3 Alerting rules — basadas en rate, más forecasting con `predict_linear`

```yaml
# alerting.rules.yml
groups:
  - name: slo_and_capacity
    rules:
      # High 5xx ratio — rate-based, smoothed, for=10m debounces
      - alert: HighErrorRate
        expr: service:http_requests_error_ratio:rate5m > 0.05
        for: 10m
        labels:
          severity: page
        annotations:
          summary: "{{ $labels.service }} error ratio {{ $value | humanizePercentage }}"

      # Multi-window multi-burn-rate SLO alert (fast + slow burn)
      - alert: ErrorBudgetBurnFast
        expr: |
          (
            sum by (service) (rate(http_requests_total{code=~"5.."}[5m]))
              /
            sum by (service) (rate(http_requests_total[5m]))
          ) > (14.4 * 0.001)          # 14.4× burn of a 99.9% SLO
          and
          (
            sum by (service) (rate(http_requests_total{code=~"5.."}[1h]))
              /
            sum by (service) (rate(http_requests_total[1h]))
          ) > (14.4 * 0.001)
        for: 2m
        labels: { severity: page }
        annotations:
          summary: "{{ $labels.service }} is burning error budget 14.4× (page)"

      # Disk will fill in the next 4h — classic predict_linear on a GAUGE
      - alert: DiskWillFillIn4h
        expr: |
          predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 4 * 3600) < 0
          and
          node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes < 0.30
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }}:{{ $labels.mountpoint }} projected to fill within 4h"

      # Crash-looping process — resets() counts counter restarts
      - alert: ProcessRestartStorm
        expr: resets(process_start_time_seconds{job="api"}[15m]) > 3
        for: 0m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }} restarted >3 times in 15m"
```

> **Nota sobre `predict_linear`.** Corre sobre un **gauge** (`node_filesystem_avail_bytes`), usa regresión por mínimos cuadrados sobre la ventana `[6h]`, y proyecta `4 × 3600` segundos hacia adelante. `< 0` significa "la línea ajustada cruza el vacío dentro de 4h". El guard agregado `< 0.30` previene disparar sobre un disco casi vacío pero enorme cuya regresión de ruido tiende ligeramente hacia abajo.

### 3.4 CRD `PrometheusRule` de prometheus-operator (mismas reglas, nativas de Kubernetes)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: slo-and-capacity
  namespace: monitoring
  labels:
    role: alert-rules
    prometheus: k8s          # must match Prometheus CR ruleSelector
spec:
  groups:
    - name: slo_and_capacity
      rules:
        - alert: DiskWillFillIn4h
          expr: predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 4 * 3600) < 0
          for: 15m
          labels: { severity: warning }
          annotations:
            summary: "{{ $labels.instance }}:{{ $labels.mountpoint }} projected to fill within 4h"
```

---

## 4. Comandos CLI y salida real de terminal

### 4.1 Query instantánea vía `promtool` y la HTTP API

```console
$ promtool query instant http://localhost:9090 'sum(rate(http_requests_total[5m]))'
{} => 2 @[1754640000]
```

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=sum by (service) (rate(http_requests_total[5m]))' | jq .
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": { "service": "checkout" },
        "value": [ 1754640000, "42.7333333" ]
      },
      {
        "metric": { "service": "catalog" },
        "value": [ 1754640000, "318.4" ]
      }
    ]
  }
}
```

### 4.2 Query de rango (lo que un panel de Grafana realmente envía)

```console
$ curl -s 'http://localhost:9090/api/v1/query_range' \
    --data-urlencode 'query=rate(node_network_receive_bytes_total{device="eth0"}[5m])' \
    --data-urlencode 'start=1754639700' \
    --data-urlencode 'end=1754640000' \
    --data-urlencode 'step=15s' | jq '.data.result[0].values[:3]'
[
  [ 1754639700, "1048576.0" ],
  [ 1754639715, "1050112.0" ],
  [ 1754639730, "1179648.0" ]
]
```

### 4.3 Demostrando `increase` devolviendo un no-entero

```console
$ promtool query instant http://localhost:9090 'increase(http_requests_total{service="checkout"}[1h])'
{service="checkout"} => 153847.6 @[1754640000]
```

> `153847.6` — fraccionario, por la extrapolación de bordes (§2.6). Comportamiento correcto, no un bug.

### 4.4 `irate` vs `rate` lado a lado (spikiness)

```console
$ promtool query instant http://localhost:9090 'irate(http_requests_total{service="checkout"}[5m])'
{service="checkout"} => 61.3333 @[1754640000]     # last-2-samples, jumpy

$ promtool query instant http://localhost:9090 'rate(http_requests_total{service="checkout"}[5m])'
{service="checkout"} => 42.7333 @[1754640000]     # averaged over 5m, smooth
```

### 4.5 Validación estática de reglas

```console
$ promtool check rules /etc/prometheus/rules/*.yml
Checking /etc/prometheus/rules/alerting.rules.yml
  SUCCESS: 5 rules found
Checking /etc/prometheus/rules/recording.rules.yml
  SUCCESS: 4 rules found
```

### 4.6 Testeo unitario de la lógica de rate con `promtool test rules`

Este es el camino de verificación de grado producción — afirmás qué *debería* devolver `rate`/`increase`/`predict_linear` dada una serie sintética, y falla el CI si la matemática o la regla derivan.

```yaml
# rate_tests.yml
rule_files:
  - recording.rules.yml
  - alerting.rules.yml

evaluation_interval: 15s

tests:
  # A steady 10-req/scrape counter over 10 scrapes → rate ≈ 0.667/s
  - interval: 15s
    input_series:
      - series: 'http_requests_total{service="checkout", instance="a"}'
        values: '0+10x40'          # 0,10,20,…  (start 0, +10, 40 steps)
    promql_expr_test:
      - expr: rate(http_requests_total{service="checkout"}[1m])
        eval_time: 10m
        exp_samples:
          - labels: 'http_requests_total{service="checkout", instance="a"}'
            value: 0.6666666666666666

  # A counter reset must NOT produce a negative rate
  - interval: 15s
    input_series:
      - series: 'http_requests_total{service="checkout", instance="b"}'
        values: '0+10x20 0+10x20'  # rises, resets to 0, rises again
    promql_expr_test:
      - expr: rate(http_requests_total{service="checkout", instance="b"}[1m])
        eval_time: 6m
        exp_samples:
          - labels: 'http_requests_total{service="checkout", instance="b"}'
            value: 0.6666666666666666   # positive across the reset

  # predict_linear on a falling gauge fires DiskWillFillIn4h
  - interval: 1m
    input_series:
      - series: 'node_filesystem_avail_bytes{instance="n1", mountpoint="/", fstype="ext4"}'
        values: '100000000-500000x360'   # draining steadily over 6h
      - series: 'node_filesystem_size_bytes{instance="n1", mountpoint="/", fstype="ext4"}'
        values: '400000000x360'
    alert_rule_test:
      - eval_time: 6h
        alertname: DiskWillFillIn4h
        exp_alerts:
          - exp_labels: { severity: warning, instance: n1, mountpoint: /, fstype: ext4 }
```

```console
$ promtool test rules rate_tests.yml
Unit Testing:  rate_tests.yml
  SUCCESS
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Tabla síntoma → causa → arreglo

| Síntoma | Causa probable | Diagnóstico | Arreglo |
|---|---|---|---|
| `rate()` devuelve **vacío / brechas** | ventana demasiado chica; < 2 muestras | `count_over_time(metric[1m])` — ¿es ≥ 2? | ampliar la ventana a ≥ 4× scrape |
| El rate **hace spike en cada deploy** | `sum` antes de `rate` (reset visto sobre el agregado) | buscar `rate(sum(...)...)` | `sum(rate(...))`, hacé rate de la serie cruda |
| La alerta **flapea salvajemente** | `irate` en una regla de alerta | inspeccioná `expr` | cambiar a `rate` |
| `increase()` devuelve una **fracción** | extrapolación de bordes | esperado (§2.6) | no es un bug; no lo compares con un entero |
| Rate **negativo** | función de counter aplicada a un **gauge** | ¿la métrica es un gauge? | usá `delta`/`deriv`, no `rate` |
| `predict_linear` **nunca dispara** / dispara mal | aplicado a un counter, o ventana demasiado corta para la tendencia | verificá que sea gauge; chequeá que `[w]` cubra una tendencia real | usá un gauge y una ventana ≫ el ruido del horizonte de predicción |
| El rate **va atrasado respecto al tráfico real** | ventana demasiado grande, sobre-suavizada | comparar `[5m]` vs `[1m]` | acortar la ventana (respetá el piso de 4×) |
| La query **hace timeout / OOM** | ventana ancha × alta cardinalidad, corrida interactivamente | chequear el conteo de series | precomputar con una recording rule (§3.2) |

### 5.2 Queries de diagnóstico

```promql
# How many samples are actually in your window? (rate needs ≥ 2)
count_over_time(http_requests_total{service="checkout"}[1m])

# Did this counter reset during the window? (explains a rate spike)
resets(http_requests_total{service="checkout"}[15m])

# Is the target even up / being scraped?
up{job="api"}

# Is the series stale (scrape stopped)? absent() catches disappearance
absent(http_requests_total{service="checkout"})

# Confirm gauge vs counter mistake: a "counter" that ever decreases isn't one
rate(node_filesystem_avail_bytes[5m])   # returns garbage — it's a gauge!
```

### 5.3 Razonamiento sobre staleness del lado de la terminal

Prometheus inyecta un **marcador de staleness** cuando una serie deja de ser scrapeada; después de eso, `rate()` no devuelve ningún valor en lugar de arrastrar un valor viejo. Si un gráfico de rate cae en plano a "sin datos" justo cuando un pod muere, eso es la staleness funcionando correctamente — combiná la alerta de rate con una alerta `up == 0` o `absent()` para que "sin datos" nunca sea interpretado silenciosamente como "cero tráfico".

### 5.4 La escalera de verificación para este tema

1. **Estática:** `promtool check rules` — sintaxis de YAML y de expresiones.
2. **Comportamental:** `promtool test rules` — afirmar salidas exactas de rate/increase/predict_linear sobre series sintéticas (§4.6). Este es el único lugar donde la *matemática* se prueba, no se asume.
3. **En vivo:** las queries de diagnóstico en §5.2 contra el servidor corriendo.
4. **Composición:** grepeá tus reglas por `rate(sum(` e `irate(` dentro de bloques `alert:` — ambos son code smells que los chequeos estáticos pasan pero la semántica falla.

---

## 6. References

- Prometheus — Query functions (`rate`, `irate`, `increase`, `delta`, `idelta`, `deriv`, `predict_linear`, `resets`, `changes`, `double_exponential_smoothing`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — Querying basics (range/instant vectors, range selectors): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — Querying operators (aggregation, binary operators): https://prometheus.io/docs/prometheus/latest/querying/operators/
- Prometheus — Metric types (counter vs gauge vs histogram): https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Recording rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — Alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus — Unit testing rules (`promtool test rules`): https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus — Best practices, histograms & quantiles: https://prometheus.io/docs/practices/histograms/
- Prometheus — HTTP API (`/api/v1/query`, `/api/v1/query_range`): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — Staleness: https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness
- Google SRE Workbook — Alerting on SLOs (multi-window multi-burn-rate): https://sre.google/workbook/alerting-on-slos/
- prometheus-operator — `PrometheusRule` API: https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PrometheusRule
- CNCF — Prometheus Certified Associate (PCA) curriculum: https://github.com/cncf/curriculum