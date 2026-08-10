# 5.4 — Estructuración y nombrado de métricas

> **Dominio 5 · Peso en el examen: 4**
> Nivel: Principal Platform Architect / Senior SRE
> Idioma de autoría: inglés (términos técnicos conservados en inglés)

El nombrado de métricas es la única decisión de diseño en un despliegue de Prometheus que es simultáneamente (a) trivialmente fácil de arruinar, (b) extremadamente cara de cambiar una vez que dashboards, alertas, recording rules y la federación downstream dependen de ella, y (c) la palanca individual más grande sobre el costo del TSDB y el rendimiento de las queries. El nombre de una métrica y su conjunto de labels son un *contrato de API pública* entre el workload instrumentado y cada consumidor — paneles de Grafana, reglas de alerting, receptores de `remote_write` y el ingeniero de guardia corriendo una query ad-hoc de PromQL a las 3 de la mañana. Este tema trata sobre diseñar ese contrato de forma que sea agregable, descubrible, consistente en unidades y seguro en cardinalidad.

---

## 1. Motivación: el problema arquitectónico en producción

### 1.1 Por qué el nombrado es una preocupación arquitectónica, no una preferencia de estilo

Prometheus almacena cada time series como un conjunto de pares clave/valor. Una time series se identifica de forma única por su **nombre de métrica más el conjunto exacto de pares nombre/valor de label**. Internamente no existe tal cosa como un "nombre de métrica" separado de un label — el nombre es simplemente un label reservado:

```
http_requests_total{method="GET", code="200", job="api", instance="10.0.3.4:8080"}
```

se almacena como:

```
{__name__="http_requests_total", method="GET", code="200", job="api", instance="10.0.3.4:8080"}
```

Dos consecuencias se desprenden directamente de este modelo de datos, y ambas son críticas para el examen:

1. **Cada combinación distinta de valores de label es una *nueva* time series independiente** con su propio chunk en el head block, su propia entrada en el índice invertido y su propia huella de memoria (~1–4 KB de RAM residente por serie activa). Las decisiones de nombrado/labelling *son* decisiones de planificación de capacidad.
2. **Un nombre de métrica debe tener un único significado consistente a lo largo de todas sus dimensiones de label**, porque los consumidores harán `sum()`, `avg()` y `rate()` a lo largo de esas dimensiones sin conocer el significado físico. Si `temperature_celsius` a veces significa temperatura de CPU y a veces temperatura ambiente según un label, entonces `avg(temperature_celsius)` es un sinsentido — pero PromQL lo va a computar felizmente.

### 1.2 Los modos de falla que un buen esquema de nombrado previene

| Modo de falla | Causa raíz | Radio de impacto |
|---|---|---|
| **Explosión de cardinalidad / TSDB con OOMKilled** | Valor de label sin acotar (user ID, email, path de URL completo, request ID) colocado en un label | Servidor Prometheus completo caído; todo el alerting a ciegas |
| **Métrica no agregable** | El mismo nombre de métrica significa cosas distintas según el label; o mezcla de unidades en una métrica | Números incorrectos silenciosos en dashboards y SLOs |
| **`rate()` roto** | Counter sin el sufijo `_total`, o un gauge que puede decrecer nombrado como un counter | Las alertas se disparan con los resets o nunca se disparan |
| **Ambigüedad de unidades** | `latency` (¿es ms? ¿s? ¿µs?) o `memory` (¿bytes? ¿MB? ¿páginas?) | Dashboards entre equipos silenciosamente desfasados por 1000× |
| **Colisiones de dos puntos con recording rules** | El exporter emite `job:foo:rate` directamente | Namespace de recording rules contaminado; riesgo de sobrescritura |
| **Métricas no descubribles** | Sin un prefijo `namespace_subsystem_name` consistente | Los ingenieros no encuentran las métricas; instrumentación duplicada |

El resto de este documento es el conjunto de reglas y herramientas de verificación que eliminan cada fila.

---

## 2. La anatomía del nombre de una métrica

### 2.1 Gramática (restricciones estrictas impuestas por el parser)

Esto no son convenciones — el parser de exposición y el TSDB **rechazan** las violaciones.

| Elemento | Regex permitida | Notas |
|---|---|---|
| Nombre de métrica | `[a-zA-Z_:][a-zA-Z0-9_:]*` | Los dos puntos `:` están **reservados para recording rules** y NO deben usarse en métricas instrumentadas directamente / de exporters |
| Nombre de label | `[a-zA-Z_][a-zA-Z0-9_]*` | Ningún dos puntos en los nombres de label |
| Prefijo de label reservado | `__` | Los nombres de label con doble guion bajo (`__name__`, `__address__`, `__meta_*`) están reservados para uso interno/de relabeling — nunca los emitas desde un exporter |
| Valor de label | cualquier UTF-8 válido | El valor vacío `""` es semánticamente idéntico a que el label esté ausente |

> Desde Prometheus 2.x con el feature flag de UTF-8 / OpenMetrics 1.0, los nombres *pueden* contener UTF-8 arbitrario cuando están entre comillas (`{"http.request.duration"}`), pero para el PCA y por portabilidad asumís el **charset legacy de arriba**. Ceñirse a ASCII en `snake_case` es el valor por defecto seguro y universalmente compatible.

### 2.2 La estructura convencional: `namespace_subsystem_name_unit_suffix`

```
        prometheus_http_request_duration_seconds_bucket
        └────────┘ └──┘ └──────────────┘ └─────┘ └────┘
        namespace  sub  name             unit    _bucket (type suffix)
```

- **namespace / prefijo de aplicación** — una sola palabra que identifica el software o la librería que expone la métrica (`prometheus_`, `node_`, `process_`, `go_`, `http_`, `etcd_`). Previene colisiones cuando muchos exporters son scrapeados por un mismo servidor. En las client libraries esto se define una vez como `Namespace`.
- **subsystem** — agrupación lógica opcional dentro de la app (`http`, `grpc`, `db`, `queue`).
- **name** — lo que se está midiendo, describiendo el *subsistema completo de la aplicación*, no una instancia de él. El separador entre componentes del nombre de la métrica es `_`.
- **unit** — la unidad base como palabra (`seconds`, `bytes`, `ratio`, `celsius`). Siempre en singular para la unidad, describiendo la unidad base.
- **sufijo de tipo** — `_total` (counter), `_bucket`/`_sum`/`_count` (histogram), `_info`, etc. (§2.4).

### 2.3 Unidades base — usá siempre unidades base del SI, nunca escaladas ni con prefijo

Prometheus almacena samples float64 crudos y no fija **ninguna unidad**. La convención es instrumentar siempre en unidades base y dejar que la *capa de visualización* (Grafana, las funciones `humanize`) escale. Esto hace que cada métrica de una familia sea directamente comparable y que la aritmética entre equipos sea segura.

| Familia de magnitud | Unidad base (sufijo) | NO usar |
|---|---|---|
| Tiempo / duración | `seconds` | milisegundos, microsegundos, nanosegundos, minutos, días |
| Tamaño de datos | `bytes` | bits, kilobytes, megabytes, KiB, MiB |
| Throughput de red | `bytes` (luego `rate()` → bytes/s) | bits, Mbps |
| Ratio / fracción / utilización | `ratio` (valores `0`–`1`) | porcentaje (`0`–`100`) |
| Temperatura | `celsius` | fahrenheit, kelvin |
| Longitud | `meters` | — |
| Voltaje | `volts` | — |
| Corriente eléctrica | `amperes` | — |
| Energía | `joules` | — |
| Potencia | exponé energía en `joules`; derivá potencia vía `rate()` | watts (evitar crudo) |
| Masa | `grams` | kilogramos (evita un prefijo de unidad) |

**Regla práctica:** si alguna vez te encontrás dividiendo por 1000 o multiplicando por 100 en una query de PromQL, nombraste la métrica con la unidad equivocada.

### 2.4 Sufijos reservados y reglas de nombrado por tipo

| Tipo de métrica | Regla de nombrado | Sufijos reservados que genera | ¿`rate()`-able? |
|---|---|---|---|
| **Counter** | DEBE terminar en `_total`. Monótonamente creciente; solo sube o se resetea a 0. | `_total` (y `_created` bajo OpenMetrics) | Sí — ese es todo el punto |
| **Gauge** | Sin `_total`. Un valor instantáneo que puede subir y bajar. Nombrá lo medido + unidad. | ninguno | No — usá el valor crudo, `delta`, `deriv` |
| **Histogram** | Nombre base + `_seconds`/`_bytes`; el cliente genera tres familias de series | `_bucket{le="…"}`, `_sum`, `_count` | Sí en `_bucket`, `_sum`, `_count` |
| **Summary** | Nombre base + unidad; el cliente computa los quantiles | `{quantile="…"}`, `_sum`, `_count` | Sí en `_sum`, `_count`; **no** en los quantiles |
| **Info** | Termina en `_info`; un gauge siempre `= 1` que lleva metadata como labels | `_info` | No — hacé join con `group_left` |
| **Stateset / Enum** | una serie por cada estado posible, valor `0`/`1` | — | No |

Sufijos reservados que **nunca** debés adjuntar al tipo equivocado: `_total`, `_sum`, `_count`, `_bucket`, `_bucket` son estructurales — adjuntar `_sum` a un gauge simple, u omitir `_total` de un counter, rompe el tooling y los idioms de PromQL (`rate(x_total[5m])`, `histogram_quantile(0.99, rate(x_bucket[5m]))`).

El label **`le`** (cota superior del bucket del histogram, inclusiva, `less-or-equal`) y el label **`quantile`** (summary) están reservados y son obligatorios para esos tipos; todo histogram debe incluir un bucket `+Inf` que iguale a `_count`.

### 2.5 Nombre de métrica vs label: cuándo dividir en una métrica nueva

Una decisión de diseño frecuente: ¿una dimensión nueva se convierte en un **label** de la métrica existente, o en un **nombre de métrica nuevo**?

Prueba de decisión — **la regla de invariancia ante agregación**: *cuando sumás o promediás esta métrica a lo largo del label, ¿el resultado sigue teniendo sentido y con la misma unidad?*

- **Sí → hacelo un label.** p. ej. `http_requests_total{code="200"}` vs `{code="500"}` — sumar da el total de requests. ✅
- **No → hacelo un nombre de métrica separado.** p. ej. NO hagas `node_metric{type="cpu_seconds"}` vs `{type="memory_bytes"}` — estas tienen unidades distintas y sumarlas no tiene sentido. Usá nombres distintos `node_cpu_seconds_total` y `node_memory_bytes`. ❌

| Enfoque | Ejemplo | ¿Agregable? | Cardinalidad | Veredicto |
|---|---|---|---|---|
| Dividir por label | `http_requests_total{code=…}` | `sum` = total de requests ✔ | Acotada (pocos codes) | ✅ Correcto |
| Dividir por label, unidades mezcladas | `resource_usage{kind="cpu\|mem"}` | `sum` mezcla seconds+bytes ✖ | Acotada | ❌ Incorrecto |
| Dividir por nombre de métrica | `..._cpu_seconds_total`, `..._memory_bytes` | N/A (métricas distintas) | Acotada | ✅ Correcto |
| Codificar el valor en el nombre | `http_requests_200_total`, `http_requests_500_total` | No se puede `sum by (code)` fácilmente | Acotada pero rígida | ⚠️ Anti-patrón — preferí un label |

---

## 3. Cardinalidad: la asesina de producción

La cardinalidad es la cantidad de time series activas. Es **multiplicativa** a lo largo de los labels:

```
series(metric) = Π (distinct values of each label) × 1 (the metric name)
```

Ejemplo — una métrica HTTP con estas cardinalidades de label:

```
http_request_duration_seconds_bucket
  method:   6   (GET,POST,PUT,DELETE,PATCH,HEAD)
  code:    15   (200,201,204,301,400,401,403,404,409,422,429,500,502,503,504)
  handler:120   (route templates)
  le:      12   (histogram buckets incl +Inf)
  instance:40  (pods)
= 6 × 15 × 120 × 12 × 40 = 5,184,000 active series
```

Eso son ~5–20 GB de RAM del head-block para **una sola familia de métricas**. Ahora imaginá que alguien pone el `path` crudo (con IDs) en vez del `handler` con plantilla:

```
  path: unbounded (e.g. /users/8f3a…/orders/9921)
```

→ la cardinalidad crece sin límite hasta que el servidor recibe `OOMKilled`. Esta es la causa número uno de incidentes en producción en Prometheus.

### 3.1 Anti-patrones de labels de alta cardinalidad (nunca pongas esto en un label)

- User IDs, direcciones de email, customer IDs, session/request IDs, trace IDs
- Paths de URL completos con IDs embebidos (usá una **ruta con plantilla**: `/users/:id`)
- Mensajes de error crudos / stack traces (usá un `error_code`/`reason` acotado)
- Timestamps, epochs, o cualquier cosa sin acotar y creciente
- SHAs de imágenes de contenedor, nombres de pod con sufijos aleatorios (usá `deployment`/`app`)
- UIDs de Kubernetes

### 3.2 Controles de gobernanza

| Control | Dónde | Propósito |
|---|---|---|
| `sample_limit` | scrape config | Tope duro; descarta el scrape completo si un target supera N series |
| `label_limit`, `label_value_length_limit`, `label_name_length_limit` | scrape config | Rechaza targets patológicos |
| `metric_relabel_configs` `action: drop`/`labeldrop` | scrape config | Poda métricas/labels conocidos como malos en el ingest |
| Recording rules | archivos de reglas | Pre-agregan para eliminar la cardinalidad cruda de los dashboards |
| `--storage.tsdb.retention.*`, sharding | flags del servidor | Contienen el costo a posteriori |

---

## 4. Histogram vs Summary — el trade-off adyacente al nombrado

Ambos miden distribuciones de duraciones/tamaños y ambos consumen el mismo nombre base + unidad, pero generan series distintas y tienen propiedades de agregación opuestas. Elegir mal es una decisión del contrato de nombrado porque los nombres de las series emitidas difieren (`_bucket` vs `quantile`).

| Dimensión | **Histogram** | **Summary** |
|---|---|---|
| Series emitidas | `_bucket{le}`, `_sum`, `_count` | `{quantile}`, `_sum`, `_count` |
| Quantile computado | **Del lado del servidor** en tiempo de query vía `histogram_quantile()` | **Del lado del cliente**, fijado en tiempo de scrape |
| Agregable entre instancias | **Sí** — los buckets son aditivos; `sum by (le)(rate(..._bucket[5m]))` y luego `histogram_quantile` | **No** — no podés promediar quantiles; `avg(quantile="0.99")` es estadísticamente inválido |
| Precisión del quantile | Acotada por los buckets `le` elegidos; requiere una buena disposición de buckets | Exacta por instancia dentro de una ventana deslizante |
| Costo de CPU del cliente | Bajo | Mayor (estimación de quantiles en streaming) |
| ¿Elegir buckets en tiempo de instrumentación? | Sí (hay que planear de antemano los límites de los buckets) | No (en su lugar se eligen objectives) |
| Histograms nativos/exponenciales (2.40+) | Buckets que se auto-escalan, footprint diminuto, sin explosión de `le` | N/A |
| **Usar cuando** | Necesitás latencia de SLO agregable entre pods/regiones | Necesitás un quantile exacto por target y no podés agregar |

**Valor por defecto para SRE: histograms** (y native histograms donde estén disponibles), porque los SLOs y dashboards deben agregar entre réplicas. Los summaries son para el caso raro en el que necesitás un quantile exacto de un único target y nunca vas a agregar.

---

## 5. Manifests completos, listos para producción

### 5.1 Instrumentación correcta — client library de Go (nombrado aplicado)

```go
// file: internal/metrics/metrics.go
package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Namespace/subsystem enforce the `payments_http_...` prefix on every metric.
const (
	namespace = "payments"
	subsystem = "http"
)

var (
	// COUNTER — monotonically increasing → mandatory `_total` suffix.
	// Labels are all BOUNDED: method (~6), code (~15), handler is a
	// TEMPLATED route, never the raw path.
	RequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "requests_total", // → payments_http_requests_total
			Help:      "Total number of HTTP requests processed, by method, route template and response code.",
		},
		[]string{"method", "handler", "code"},
	)

	// HISTOGRAM — base unit is SECONDS (never milliseconds). Buckets
	// chosen around the SLO (250ms) so histogram_quantile is accurate there.
	RequestDurationSeconds = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "request_duration_seconds", // → payments_http_request_duration_seconds_{bucket,sum,count}
			Help:      "HTTP request latency in seconds.",
			Buckets:   []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
			// NativeHistogramBucketFactor: 1.1, // enable exponential/native histogram
		},
		[]string{"method", "handler"},
	)

	// GAUGE — snapshot that goes up and down → NO `_total`. Unit = bytes.
	InflightRequests = promauto.NewGauge(
		prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "inflight_requests", // → payments_http_inflight_requests
			Help:      "Number of HTTP requests currently being served.",
		},
	)

	// INFO metric — constant gauge = 1 carrying build metadata as labels.
	// Consumed via a group_left join, never aggregated.
	BuildInfo = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Namespace: namespace,
			Name:      "build_info", // → payments_build_info
			Help:      "Build metadata; value is always 1.",
		},
		[]string{"version", "revision", "goversion"},
	)
)
```

Exposición resultante en `/metrics` (notá los sufijos reservados auto-generados y el bucket `+Inf` igual a `_count`):

```text
# HELP payments_http_requests_total Total number of HTTP requests processed, by method, route template and response code.
# TYPE payments_http_requests_total counter
payments_http_requests_total{code="200",handler="/v1/charge",method="POST"} 48213
payments_http_requests_total{code="422",handler="/v1/charge",method="POST"} 137

# HELP payments_http_request_duration_seconds HTTP request latency in seconds.
# TYPE payments_http_request_duration_seconds histogram
payments_http_request_duration_seconds_bucket{handler="/v1/charge",method="POST",le="0.005"} 12
payments_http_request_duration_seconds_bucket{handler="/v1/charge",method="POST",le="0.25"} 47901
payments_http_request_duration_seconds_bucket{handler="/v1/charge",method="POST",le="+Inf"} 48350
payments_http_request_duration_seconds_sum{handler="/v1/charge",method="POST"} 5123.44
payments_http_request_duration_seconds_count{handler="/v1/charge",method="POST"} 48350

# HELP payments_http_inflight_requests Number of HTTP requests currently being served.
# TYPE payments_http_inflight_requests gauge
payments_http_inflight_requests 7

# HELP payments_build_info Build metadata; value is always 1.
# TYPE payments_build_info gauge
payments_build_info{goversion="go1.22.3",revision="a1b2c3d",version="2.4.1"} 1
```

### 5.2 Scrape config con guardrails de cardinalidad e higiene de metric_relabel

```yaml
# file: prometheus/scrape/payments.yml
scrape_configs:
  - job_name: payments-api
    scrape_interval: 15s
    metrics_path: /metrics
    # --- Cardinality guardrails: fail the scrape rather than the server ---
    sample_limit: 100000            # drop whole scrape if target exceeds this
    label_limit: 30                 # max labels per series
    label_name_length_limit: 200
    label_value_length_limit: 400
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: payments
        action: keep
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: instance
    metric_relabel_configs:
      # Drop a known high-cardinality metric leaking raw paths.
      - source_labels: [__name__]
        regex: payments_http_requests_by_raw_path_total
        action: drop
      # Strip an accidental unbounded label if it ever appears.
      - regex: (request_id|session_id|user_email)
        action: labeldrop
```

### 5.3 Recording rules — la convención de nombrado `level:metric:operations`

Las recording rules son el **único** lugar donde se permiten dos puntos `:` en el nombre de una métrica. La convención `level:metric:operations` comunica la agregación aplicada, y precomputarlas reduce la cardinalidad/latencia de los dashboards.

```yaml
# file: prometheus/rules/payments-recording.yml
groups:
  - name: payments-slo
    interval: 30s
    rules:
      # level = job (aggregation level) : metric : operation
      - record: job:payments_http_requests:rate5m
        expr: sum by (job) (rate(payments_http_requests_total[5m]))

      # 5xx error ratio, dimensionless (ratio 0–1), pre-aggregated per job.
      - record: job:payments_http_requests_errors:ratio_rate5m
        expr: |
          sum by (job) (rate(payments_http_requests_total{code=~"5.."}[5m]))
          /
          sum by (job) (rate(payments_http_requests_total[5m]))

      # p99 latency aggregated across all pods (histograms ARE aggregatable).
      - record: job:payments_http_request_duration_seconds:p99_5m
        expr: |
          histogram_quantile(
            0.99,
            sum by (job, le) (rate(payments_http_request_duration_seconds_bucket[5m]))
          )
```

### 5.4 `ServiceMonitor` del Prometheus Operator (refleja §5.2 en forma de CRD)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: payments-api
  namespace: payments
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: payments
  sampleLimit: 100000
  labelLimit: 30
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 15s
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: payments_http_requests_by_raw_path_total
          action: drop
        - regex: (request_id|session_id|user_email)
          action: labeldrop
```

---

## 6. Comandos de CLI y salida real de terminal

### 6.1 Inspeccionar qué expone realmente un target

```console
$ curl -s http://localhost:8080/metrics | grep '^payments_http_requests_total'
payments_http_requests_total{code="200",handler="/v1/charge",method="POST"} 48213
payments_http_requests_total{code="422",handler="/v1/charge",method="POST"} 137
```

### 6.2 Chequear (lint) las convenciones de nombrado con `promtool check metrics`

`promtool check metrics` lee la exposición desde **stdin** y reporta violaciones de nombrado/tipo — corrélo en CI contra un dump capturado de `/metrics`.

```console
$ curl -s http://localhost:8080/metrics | promtool check metrics
$ echo "exit=$?"
exit=0
```

Ahora alimentalo con un archivo mal nombrado para ver dispararse el linter:

```console
$ cat bad_metrics.prom
# TYPE http_requests counter
http_requests{code="200"} 5
# TYPE queue_depth_total gauge
queue_depth_total 12
# TYPE latencyMillis gauge
latencyMillis 42

$ promtool check metrics < bad_metrics.prom
http_requests counter metrics should have "_total" suffix
queue_depth_total non-counter metrics should not have "_total" suffix
latencyMillis metric names should be written in 'snake_case' not 'camelCase'
latencyMillis use base unit "seconds" instead of "millis"
$ echo "exit=$?"
exit=1
```

### 6.3 Validar nombres de recording rules (con dos puntos)

```console
$ promtool check rules prometheus/rules/payments-recording.yml
Checking prometheus/rules/payments-recording.yml
  SUCCESS: 3 rules found
```

### 6.4 Medir la cardinalidad desde el servidor en ejecución (estado del TSDB)

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:5]'
[
  { "name": "payments_http_request_duration_seconds_bucket", "value": 5184000 },
  { "name": "payments_http_requests_total",                  "value": 5400 },
  { "name": "apiserver_request_duration_seconds_bucket",     "value": 240000 },
  { "name": "go_gc_duration_seconds",                        "value": 3200 },
  { "name": "payments_http_inflight_requests",               "value": 40 }
]
```

Encontrá qué **label** está impulsando la cardinalidad:

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb \
    | jq '.data.labelValueCountByLabelName[] | select(.value > 1000)'
{ "name": "handler",     "value": 120 }
{ "name": "le",          "value": 12 }
{ "name": "__name__",    "value": 8421 }
{ "name": "path",        "value": 918273 }   # <-- unbounded label; this is the leak
```

Contá el total de series activas y los principales infractores vía PromQL:

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=topk(5, count by (__name__)({__name__=~".+"}))' \
    | jq -r '.data.result[] | "\(.value[1])\t\(.metric.__name__)"'
5184000	payments_http_request_duration_seconds_bucket
918273	payments_http_requests_by_raw_path_total
240000	apiserver_request_duration_seconds_bucket
5400	payments_http_requests_total
3200	go_gc_duration_seconds
```

### 6.5 Confirmar que una métrica agrega y hace `rate()` correctamente

```console
$ promtool query instant http://localhost:9090 \
    'sum by (job) (rate(payments_http_requests_total[5m]))'
payments_http_requests_total{job="payments-api"} => 331.4 @[1754870400]

$ promtool query instant http://localhost:9090 \
    'histogram_quantile(0.99, sum by (le)(rate(payments_http_request_duration_seconds_bucket[5m])))'
{} => 0.238 @[1754870400]
```

---

## 7. Guía de verificación y diagnóstico de fallas

Una escalera desde los chequeos estáticos más baratos/gratuitos hasta la confirmación en runtime.

| Síntoma | Comando de diagnóstico | Causa raíz probable | Solución |
|---|---|---|---|
| Falla el lint de nombrado en CI | `promtool check metrics < dump.prom` | Counter sin `_total`; camelCase; unidad equivocada; `_sum`/`_bucket` en el tipo equivocado | Renombrar según §2.4; usar unidad base §2.3 |
| RSS de Prometheus subiendo, `OOMKilled` | `curl .../status/tsdb \| jq .data.labelValueCountByLabelName` | Label sin acotar (path/id/email) | Poné plantilla a la ruta; `labeldrop` / `metric_relabel_configs` §5.2 |
| El scrape muestra `up{}==1` pero 0 samples para una métrica | `curl .../targets` → revisá `lastError`; revisá `sample_limit` | El scrape superó `sample_limit` y se descartó completo | Subir el límite *y* recortar la cardinalidad; investigar al infractor |
| `rate()` devuelve picos enormes / negativos absorbidos mal | Consultá el counter crudo; buscá caídas no monótonas | El counter en realidad es un gauge (el nombre miente sobre el tipo) | Renombrar a un gauge; quitar `_total`; o arreglar la instrumentación |
| `avg`/`sum` da valores absurdos | Inspeccioná los labels de la métrica y `# HELP`/`# TYPE` | El mismo nombre de métrica, unidades/significado mezclados entre labels | Dividir en nombres de métrica distintos §2.5 |
| `histogram_quantile` devuelve `NaN`/incorrecto | Verificá que exista el bucket `+Inf` y que los buckets crezcan; asegurá `sum by (le)` | Falta `+Inf`, buckets no acumulativos, o agregado sin `le` | Usar la client library (autocorrige los buckets); mantener `le` en la agregación |
| Dos métricas colisionan / se sobrescriben | `count by (__name__)`; buscá un `:` en la salida del exporter | El exporter emitió un nombre `level:metric:op` (de recording rule) | Quitar los dos puntos de la instrumentación directa §2.1 |
| La métrica info cuenta doble en el join | Revisá si el valor de `payments_build_info` ≠ 1 o si hay labels de más | La métrica info usada como valor, no como portadora de labels con `group_left` | Mantener el valor `=1`; hacer join con `* on(instance) group_left(version)` |

**Flujo estático primero (todo gratuito, se corre en CI):**

```console
$ promtool check metrics < <(curl -s localhost:8080/metrics)   # naming/type lint
$ promtool check rules prometheus/rules/*.yml                  # recording/alert names + colons
$ promtool check config prometheus.yml                         # scrape limits, relabel syntax
```

Solo después de que pasan los chequeos gratuitos gastás runtime/RAM confirmando la cardinalidad vía `/api/v1/status/tsdb`.

---

## 8. Referencias

- Nombrado de métricas y labels (unidades base, sufijos, convenciones) — https://prometheus.io/docs/practices/naming/
- Modelo de datos (gramática de nombres/labels, labels reservados `__`) — https://prometheus.io/docs/concepts/data_model/
- Tipos de métricas (counter/gauge/histogram/summary) — https://prometheus.io/docs/concepts/metric_types/
- Buenas prácticas de instrumentación (labels, cardinalidad, `_total`) — https://prometheus.io/docs/practices/instrumentation/
- Histograms y summaries (trade-offs de agregación) — https://prometheus.io/docs/practices/histograms/
- Recording rules y el nombrado `level:metric:operations` — https://prometheus.io/docs/practices/rules/
- Escribir exporters (nombrado/unidades para exporters) — https://prometheus.io/docs/instrumenting/writing_exporters/
- Formatos de exposición — https://prometheus.io/docs/instrumenting/exposition_formats/
- Especificación de OpenMetrics (sufijos reservados, `_info`, `_created`) — https://github.com/OpenMetrics/OpenMetrics/blob/main/specification/OpenMetrics.md
- Histograms nativos/exponenciales — https://prometheus.io/docs/specs/native_histograms/
- `promtool` (check metrics/rules/config) — https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- API de estado del TSDB (inspección de cardinalidad) — https://prometheus.io/docs/prometheus/latest/querying/api/#tsdb-stats
- Client library de Go — https://github.com/prometheus/client_golang
- Currícula del Prometheus Certified Associate — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf