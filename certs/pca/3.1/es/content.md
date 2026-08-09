# 3.1 Metrics

> **Domain:** Observability Concepts / Prometheus Fundamentals · **Exam weight:** 3
> **Level:** Production SRE / Platform Architect

---

## 1. Motivación: el problema arquitectónico que resuelven las métricas

Una plataforma en producción que corre miles de pods a lo largo de decenas de
nodos emite un flujo de eventos efectivamente infinito. No podés almacenar,
indexar ni consultar cada evento en cada capa y aun así responder "¿está sano el
servicio de checkout *ahora mismo*?" en menos de un segundo. Esta es la tensión
central de la observabilidad a escala: **fidelidad frente a costo y latencia de
consulta.**

Las métricas son la respuesta a una porción específica de ese problema: una
**métrica es una medición numérica de un sistema, muestreada a intervalos
regulares y agregada a lo largo de dimensiones.** En vez de "el usuario 8831
recibió un HTTP 500 en `/checkout` a las 12:04:07.812", una métrica registra "el
handler `checkout` devolvió 34 respuestas `5xx` en los últimos 15s". La identidad
individual se descarta; la *forma* del sistema a lo largo del tiempo se preserva.

Esa pérdida deliberada de identidad por evento es precisamente lo que hace que
las métricas sean baratas y rápidas:

- Una muestra de Prometheus se comprime a aproximadamente **1–2 bytes en disco**
  (codificación Gorilla / double-delta + XOR-of-floats). Una línea de log
  estructurada ocupa de cientos de bytes a kilobytes.
- Las métricas están **preagregadas por dimensión** (labels), de modo que una
  consulta sobre un mes de datos toca chunks compactos y ordenados en vez de
  escanear eventos crudos.
- Son **predecibles en cardinalidad** — *si* las diseñás correctamente. Este "si"
  es el modo de falla operacional más grande y tiene su propia sección (§6).

El rol arquitectónico de las métricas dentro de la tríada de observabilidad:

| Signal | Question it answers | Cardinality profile | Cost per unit info | Retention |
|---|---|---|---|---|
| **Metrics** | *Is it broken? How broken? Trending which way?* | Bounded, low | Very low | Long (weeks–years) |
| **Logs** | *What exactly happened in this event?* | Unbounded, high | Medium–high | Medium (days–weeks) |
| **Traces** | *Where in the request path did latency/error occur?* | Very high (per-request) | High | Short (hours–days), sampled |

La disciplina de producción: **alertá y armá dashboards sobre métricas, y después
pivoteá a logs y traces para el incidente específico.** Las métricas te dicen
*que* el SLO se está quemando; los otros dos te dicen *por qué*. Los exemplars
(§5) son el puente que permite que una métrica lleve un trace ID para que el
pivote sea un solo clic, no una correlación manual.

---

## 2. El modelo de datos de Prometheus: anatomía de una métrica

Toda métrica de Prometheus es un conjunto de **time series**. Una time series se
identifica de forma única por un **nombre de métrica más un conjunto de pares
clave/valor (labels)**:

```
<metric_name>{<label_name>="<label_value>", ...}
```

Internamente, el nombre de la métrica es simplemente el label reservado
`__name__`. Estas dos representaciones son idénticas:

```
http_requests_total{method="POST", handler="/api/v1/users", code="500"}
{__name__="http_requests_total", method="POST", handler="/api/v1/users", code="500"}
```

Una **sample** adjunta a esa series es un par `(float64 value, int64
timestamp_ms)`. Así que el modelo mental completo es:

```
identity  = __name__ + sorted(label set)      # the time series
data      = stream of (timestamp, float64)     # the samples
```

**Consecuencia crítica para el diseño:** *cada combinación distinta de valores de
label es una time series separada con su propia huella de memoria y
almacenamiento.* El conteo total de series es el producto cartesiano de las
cardinalidades de los labels. Agregar un label `user_id` con 1M de usuarios a una
métrica que ya tiene 5 methods × 20 handlers convierte 100 series en 100
*millones*. Esto no es una perilla de ajuste — es la restricción definitoria de
todo el sistema (§6).

Los nombres de métrica válidos coinciden con `[a-zA-Z_:][a-zA-Z0-9_:]*` (los dos
puntos están **reservados para las recording rules** — nunca los uses en métricas
instrumentadas directamente). Los nombres de label coinciden con
`[a-zA-Z_][a-zA-Z0-9_]*`; los nombres con prefijo `__` están reservados para los
internos de Prometheus.

---

## 3. Los cuatro tipos de métrica

Las bibliotecas cliente de Prometheus exponen cuatro tipos. El tipo es
**metadata orientativa** en la exposición (`# TYPE`) — el servidor almacena todo
como series float64 — pero elegir el tipo equivocado produce consultas sin
sentido.

### 3.1 Counter

Un valor acumulativo **monótonamente creciente** que **se reinicia a cero solo al
reiniciarse el proceso**. Ejemplos: total de requests servidas, total de bytes
enviados, total de errores.

**Nunca graficás el valor crudo** de un counter — su número absoluto no tiene
sentido (depende de cuánto tiempo lleva arriba el proceso). Siempre aplicás una
función de rate, que además maneja de forma transparente el reinicio a cero:

```promql
rate(http_requests_total[5m])          # per-second average over the window
increase(http_requests_total[1h])      # total increase over the window
```

Por convención (y *requerido* por OpenMetrics) los counters terminan en `_total`.

### 3.2 Gauge

Un valor que puede **subir y bajar**. Ejemplos: uso de memoria actual,
profundidad de cola, número de requests en vuelo, temperatura. Los gauges se
grafican directamente y soportan funciones que asumen movimiento arbitrario:

```promql
node_memory_MemAvailable_bytes                 # instantaneous value
delta(cpu_temp_celsius[1h])                     # change over window
predict_linear(node_filesystem_free_bytes[6h], 4*3600)   # extrapolate 4h ahead
```

**Regla práctica de diseño:** si `rate()` de él alguna vez fuera significativo, es
un counter; si te importa su nivel actual, es un gauge.

### 3.3 Histogram

Un histogram muestrea observaciones (típicamente duraciones de request o tamaños
de respuesta) en **buckets acumulativos preconfigurados**, y además expone una
suma y un conteo corrientes. Un histogram lógico produce múltiples series:

- `<name>_bucket{le="<upper_bound>"}` — un **counter por bucket**, acumulativo:
  `le="0.5"` cuenta todas las observaciones ≤ 0.5s (incluyendo todo lo que está
  por debajo).
- `<name>_sum` — un counter de la suma de todos los valores observados.
- `<name>_count` — un counter del número de observaciones (idéntico al bucket
  `le="+Inf"`).

Como los buckets son counters, los cuantiles se computan **del lado del servidor
en tiempo de consulta** con `histogram_quantile()`, que interpola linealmente
*dentro* del bucket que coincide:

```promql
histogram_quantile(
  0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)
```

La ventaja arquitectónica clave: **los histograms son agregables.** Como los
conteos crudos viven del lado del servidor, podés hacer `sum by (le)` a lo largo
de cada pod, región o versión y *después* computar un p99 global correcto. No
podés hacer esto con un Summary.

El trade-off clave: **tenés que elegir los límites de los buckets por
adelantado.** Un cuantil que cae en un bucket sin límites cercanos interpola
mal. Buckets demasiado gruesos → cuantiles imprecisos; demasiado finos → costo de
cardinalidad (cada bucket es una series).

### 3.4 Summary

Un summary también rastrea un `_sum` y un `_count`, pero en vez de buckets computa
**φ-cuantiles del lado del cliente sobre una ventana de tiempo deslizante**:

- `<name>{quantile="0.5"}`, `{quantile="0.9"}`, `{quantile="0.99"}` — cuantiles
  precomputados.
- `<name>_sum`, `<name>_count`.

La ventaja: el cuantil reportado es **exacto para esa única instancia** sin
necesitar buckets bien ubicados, y consultar es barato (sin interpolación del
lado del servidor). La limitación fatal: **los cuantiles no pueden agregarse.** El
promedio del p99 de tres pods *no* es el p99 de la flota, y no hay forma correcta
de recuperarlo. En un servicio escalado horizontalmente — es decir, todo servicio
en producción — esto hace que los summaries sean mucho menos útiles para los SLOs
de latencia.

### 3.5 Native histograms (la opción moderna)

Los histograms clásicos fuerzan el trade-off cardinalidad-vs-precisión sobre el
operador vía la elección de buckets. **Los native histograms** (experimentales
desde Prometheus **v2.40**, nov 2022; habilitados con
`--enable-feature=native-histograms`) almacenan observaciones en **buckets
espaciados exponencialmente generados automáticamente a alta resolución**, como
una *única* series con un tipo de sample especial — cardinalidad drásticamente
menor *y* mejor precisión, agregables como los histograms clásicos. Esta es la
dirección estratégica; los histograms clásicos siguen siendo el default seguro y
universalmente soportado para el examen y para la mayoría de los parques de
producción hoy.

### Histogram vs Summary — la tabla de decisión

| Dimension | Histogram | Summary |
|---|---|---|
| Quantile computed | Server-side, at query time (`histogram_quantile`) | Client-side, ahead of time |
| **Aggregatable across instances** | **Yes** (`sum by (le)`) | **No** — mathematically incorrect |
| Bucket/quantile choice | Buckets chosen ahead of time | Quantiles (φ) chosen ahead of time |
| Accuracy | Depends on bucket placement + interpolation | Exact for the instance, within configured error |
| Query-time CPU cost | Higher (interpolation over buckets) | Lower (value is precomputed) |
| Client CPU/memory cost | Lower | Higher (sliding-window quantile estimation) |
| Can change target quantile after the fact | **Yes** (any φ, any time) | No — must re-instrument |
| **Recommended default** | **Yes, for latency/size SLOs** | Only single-instance, non-aggregated cases |

**Guía de producción:** usá histograms por defecto. Recurrí a un summary solo
cuando necesites un cuantil exacto por instancia que nunca vaya a agregarse, y
conozcas el φ objetivo de antemano.

---

## 4. Formato de exposición y OpenMetrics

Prometheus scrapea un endpoint de texto plano (convencionalmente `/metrics`)
sobre HTTP. El formato es orientado a líneas: metadata opcional `# HELP` y
`# TYPE`, luego líneas de sample `name{labels} value [timestamp]`.

Una exposición completa y válida que cubre los cuatro tipos:

```text
# HELP http_requests_total Total number of HTTP requests processed.
# TYPE http_requests_total counter
http_requests_total{method="GET",handler="/api/v1/users",code="200"} 8027
http_requests_total{method="POST",handler="/api/v1/users",code="201"} 412
http_requests_total{method="POST",handler="/api/v1/users",code="500"} 3

# HELP process_resident_memory_bytes Resident memory size in bytes.
# TYPE process_resident_memory_bytes gauge
process_resident_memory_bytes 5.8236928e+07

# HELP http_request_duration_seconds Request latency in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{handler="/api/v1/users",le="0.05"} 6521
http_request_duration_seconds_bucket{handler="/api/v1/users",le="0.1"}  24054
http_request_duration_seconds_bucket{handler="/api/v1/users",le="0.5"}  33444
http_request_duration_seconds_bucket{handler="/api/v1/users",le="1"}    34001
http_request_duration_seconds_bucket{handler="/api/v1/users",le="+Inf"} 34039
http_request_duration_seconds_sum{handler="/api/v1/users"}   8734.212
http_request_duration_seconds_count{handler="/api/v1/users"} 34039

# HELP rpc_duration_seconds Backend RPC latency in seconds.
# TYPE rpc_duration_seconds summary
rpc_duration_seconds{service="billing",quantile="0.5"}  0.012
rpc_duration_seconds{service="billing",quantile="0.9"}  0.045
rpc_duration_seconds{service="billing",quantile="0.99"} 0.121
rpc_duration_seconds_sum{service="billing"}   17560.473
rpc_duration_seconds_count{service="billing"} 26934
```

Invariantes que vale la pena memorizar para el examen y para el debugging:

- El bucket `+Inf` **debe** existir y **debe ser igual** a `_count`.
- Los buckets son **acumulativos** y se reportan ordenados por `le`.
- `_sum` *puede* decrecer entre scrapes para histograms/summaries si son posibles
  las observaciones negativas; de lo contrario se comporta como un counter.
- Los timestamps provistos por el cliente son legales pero desaconsejados — dejá
  que Prometheus estampe en tiempo de scrape.

**OpenMetrics** (CNCF, la especificación sucesora que Prometheus negocia vía
`Content-Type`) endurece esto: sufijo `_total` obligatorio para counters, un
terminador `# EOF` explícito, `# UNIT` opcional, y — crucialmente —
**exemplars**:

```text
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.1"} 24054 # {trace_id="a1b2c3d4e5f6"} 0.087 1699920000.123
```

El `# {trace_id=...} value timestamp` final es un exemplar — un puntero desde un
bucket de métrica agregada hacia un trace concreto. Esta es la implementación del
pivote métricas→traces de §1.

---

## 5. Referencia de instrumentación (cliente Go)

Los tipos de métrica vienen de la biblioteca cliente, no del servidor. Una
instrumentación Go mínima pero con forma de producción que muestra la selección
correcta de tipo, las unidades base y un histogram con buckets explícitos:

```go
package main

import (
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	// Counter: monotonic, _total suffix, labels bounded to enum-like values.
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "Total number of HTTP requests processed.",
	}, []string{"method", "handler", "code"}) // NEVER user_id / request_id here.

	// Gauge: current in-flight requests, moves up and down.
	inFlight = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "http_requests_in_flight",
		Help: "Number of HTTP requests currently being served.",
	})

	// Histogram: base unit seconds, buckets chosen for the service's SLO band.
	reqDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency in seconds.",
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
	}, []string{"handler"})
)

func instrument(handler string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		inFlight.Inc()
		defer inFlight.Dec()
		start := time.Now()

		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next(rec, r)

		reqDuration.WithLabelValues(handler).Observe(time.Since(start).Seconds())
		httpRequests.WithLabelValues(r.Method, handler,
			http.StatusText(rec.status)).Inc()
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func main() {
	http.HandleFunc("/api/v1/users",
		instrument("/api/v1/users", func(w http.ResponseWriter, _ *http.Request) {
			w.Write([]byte("ok"))
		}))
	http.Handle("/metrics", promhttp.Handler()) // exposes /metrics
	http.ListenAndServe(":8080", nil)
}
```

**Reglas de nombrado incorporadas en lo anterior** (mejores prácticas de nombrado
de Prometheus):

- Usá **unidades base**: `seconds` no `milliseconds`, `bytes` no `kilobytes`.
- Sufijá con la unidad (`_seconds`, `_bytes`, `_total`).
- No codifiques el tipo de la métrica en el nombre (`_count` en un gauge es
  engañoso).
- Mantené los labels en dimensiones **acotadas y enumerables**. Los labels `code`
  y `method` son seguros (conjuntos finitos); un label `user_id` es una bomba de
  cardinalidad.

---

## 6. Cardinalidad: el asesino de producción

La cardinalidad es el número de time series activas. Prometheus mantiene el
índice de cada series activa y su chunk más reciente **en RAM** (el head block).
La memoria escala aproximadamente de forma lineal con las series activas — una
cifra de campo común es del orden de unos pocos KB de memoria del head por series
activa una vez que se cuenta el overhead de índice + chunk. Una explosión de
cardinalidad es la forma más común de matar por OOM a un servidor de Prometheus.

Cardinalidad = **producto de los conteos de valores de label**. Dos reglas
previenen el desastre:

1. **Nunca pongas un valor no acotado o de alta cardinalidad en un label.**
   Prohibidos: `user_id`, `email`, `request_id`, `trace_id` (como label), URL
   completa con IDs, mensajes de error crudos, timestamps, container IDs,
   direcciones IP en la mayoría de los contextos.
2. **Acotá los que conservás.** Normalizá `/api/v1/users/8831` al template de ruta
   `/api/v1/users/:id` antes de que se convierta en un valor de label.

Ejemplo trabajado de la trampa:

| Metric | method | handler | code | user_id | Series |
|---|---|---|---|---|---|
| Safe | 5 | 20 | 15 | — | **1,500** |
| Bombed | 5 | 20 | 15 | 1,000,000 | **1.5 billion** |

La segunda fila no va a entrar en ningún servidor único. Prometheus provee
guardrails en tiempo de scrape (§9) — `sample_limit`, `label_limit`,
`target_limit` — para hacer fallar un scrape en vez de ingerir una bomba, pero el
arreglo real es la disciplina de instrumentación.

---

## 7. Metodologías de métricas

Tres frameworks complementarios deciden *qué* métricas emitir. Son material de
examen y práctica diaria.

| Method | Author / source | Scope | Signals |
|---|---|---|---|
| **Four Golden Signals** | Google SRE Book | User-facing systems | Latency, Traffic, Errors, Saturation |
| **RED** | Tom Wilkie (Grafana) | Request-driven services | **R**ate, **E**rrors, **D**uration |
| **USE** | Brendan Gregg | Resources (CPU, disk, NIC…) | **U**tilization, **S**aturation, **E**rrors |

- **RED** mapea casi 1:1 sobre la instrumentación de §5: `rate()` del counter =
  Rate; el rate filtrado por `code=~"5.."` = Errors; el histogram = Duration.
- **USE** es el complemento del lado de los recursos: usalo para nodos, discos,
  colas de red — cosas que node_exporter/cAdvisor exponen.
- **Golden Signals** es el encuadre superconjunto para todo el servicio;
  Saturation ("qué tan lleno está el recurso más restringido") es el que RED
  omite.

El patrón de producción: **RED para cada servicio, USE para cada recurso, Golden
Signals como principio organizador del dashboard.**

---

## 8. Manifiestos de infraestructura completos

### 8.1 Config del servidor Prometheus (`prometheus.yml`)

Config completa y sintácticamente válida con static targets, Kubernetes SD,
guardas de cardinalidad en tiempo de scrape, y `metric_relabel_configs` que
descarta un label de alta cardinalidad en la ingesta:

```yaml
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 15s
  external_labels:
    cluster: prod-eu-west-1
    replica: A

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  # 1) Static target — the app from §5.
  - job_name: users-api
    metrics_path: /metrics
    static_configs:
      - targets: ["users-api.default.svc:8080"]
        labels:
          team: payments
    # Guardrails: reject a scrape that would ingest a cardinality bomb.
    sample_limit: 50000
    label_limit: 30
    label_value_length_limit: 2048
    target_limit: 200

  # 2) Kubernetes pod discovery via annotations.
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # Only scrape pods annotated prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      # Honour a custom metrics path annotation.
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      # Honour a custom port annotation on the pod IP.
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      # Promote useful k8s metadata to real labels.
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
    metric_relabel_configs:
      # Post-scrape: drop a label that would explode cardinality.
      - regex: user_id
        action: labeldrop
      # Drop an entire noisy metric family we do not use.
      - source_labels: [__name__]
        regex: go_gc_duration_seconds.*
        action: drop
```

### 8.2 Deployment + Service instrumentados (descubrimiento basado en anotaciones)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: users-api
  namespace: default
  labels:
    app: users-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: users-api
  template:
    metadata:
      labels:
        app: users-api
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: users-api
          image: registry.example.com/users-api:1.7.2
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
          readinessProbe:
            httpGet: { path: /metrics, port: 8080 }
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: users-api
  namespace: default
  labels:
    app: users-api
spec:
  selector:
    app: users-api
  ports:
    - name: http
      port: 8080
      targetPort: http
```

### 8.3 `ServiceMonitor` del Prometheus Operator

La alternativa declarativa y seleccionada por labels al scraping por anotaciones,
usada por kube-prometheus-stack:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: users-api
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # matched by the Prometheus CR's serviceMonitorSelector
spec:
  namespaceSelector:
    matchNames: ["default"]
  selector:
    matchLabels:
      app: users-api                 # selects the Service in §8.2
  endpoints:
    - port: http                     # references the Service port *name*
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      metricRelabelings:
        - regex: user_id
          action: labeldrop
```

### 8.4 Recording & alerting rules

Las recording rules **precomputan expresiones costosas/agregadas** en nuevas
series (fijate en el `:` del nombre — reservado exactamente para esto). Así es
como mantenés los dashboards rápidos sin explotar la cardinalidad cruda:

```yaml
groups:
  - name: users-api.rules
    interval: 30s
    rules:
      # Recording rule: fleet-wide error ratio, precomputed.
      - record: job:http_requests:error_ratio5m
        expr: |
          sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))
            /
          sum by (job) (rate(http_requests_total[5m]))

      # Recording rule: aggregatable p99 latency across all pods.
      - record: job:http_request_duration_seconds:p99_5m
        expr: |
          histogram_quantile(0.99,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m])))

      # Alert built on the recording rule.
      - alert: UsersApiHighErrorRatio
        expr: job:http_requests:error_ratio5m{job="users-api"} > 0.05
        for: 10m
        labels:
          severity: page
        annotations:
          summary: "users-api 5xx ratio above 5% for 10m"
          description: "Error ratio is {{ $value | humanizePercentage }}."
```

---

## 9. Comandos de CLI y salida real de terminal

**Scrapeá la exposición cruda y confirmá el formato:**

```console
$ curl -s http://users-api.default.svc:8080/metrics | head -n 8
# HELP http_requests_total Total number of HTTP requests processed.
# TYPE http_requests_total counter
http_requests_total{code="OK",handler="/api/v1/users",method="GET"} 8027
http_requests_total{code="Created",handler="/api/v1/users",method="POST"} 412
http_requests_total{code="Internal Server Error",handler="/api/v1/users",method="POST"} 3
# HELP http_request_duration_seconds HTTP request latency in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{handler="/api/v1/users",le="0.005"} 4120
```

**Lintéa la exposición (nombrado, consistencia de tipo, sanidad de unidad):**

```console
$ curl -s http://localhost:8080/metrics | promtool check metrics
http_request_duration_seconds_bucket use base unit "seconds" ... OK
No metric problems detected
```

**Validá la config del servidor y los archivos de reglas antes de recargar:**

```console
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
 SUCCESS: 1 rule files found
 SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

Checking /etc/prometheus/rules/users-api.yml
 SUCCESS: 3 rules found
```

**Corré una consulta PromQL desde la línea de comandos contra un servidor en
vivo:**

```console
$ promtool query instant http://localhost:9090 \
    'sum by (code) (rate(http_requests_total{job="users-api"}[5m]))'
{code="Created"} => 4.13333 @[1699920000.000]
{code="Internal Server Error"} => 0.03333 @[1699920000.000]
{code="OK"} => 89.26667 @[1699920000.000]
```

**Computá un p99 de la forma correcta (agregable):**

```console
$ promtool query instant http://localhost:9090 \
    'histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))'
{} => 0.412 @[1699920000.000]
```

**Analizá la cardinalidad de la TSDB (el diagnóstico al que recurre todo SRE):**

```console
$ promtool tsdb analyze /prometheus
Block ID: 01HF8Z3K2QW7...
Duration: 2h0m0s
Series: 184213
Label names: 142
Postings (unique label pairs): 39204

Highest cardinality metric names:
   88213  http_request_duration_seconds_bucket
   14022  http_requests_total
    9210  go_memstats_alloc_bytes

Highest cardinality labels:
   41022  le
   12894  handler
    9231  pod
```

Esa primera tabla es exactamente cómo cazás una métrica descontrolada antes de
que mate por OOM al servidor.

---

## 10. Verificación y diagnóstico de fallas

### 10.1 ¿El target está siendo scrapeado siquiera?

La métrica sintética `up` es `1` si el último scrape tuvo éxito, `0` si falló.
Combinala con la UI `/targets` y las métricas de salud de scrape:

```console
$ promtool query instant http://localhost:9090 'up{job="users-api"}'
{instance="10.1.2.7:8080", job="users-api"} => 1 @[...]
{instance="10.1.2.9:8080", job="users-api"} => 0 @[...]   # <-- this pod is down

$ promtool query instant http://localhost:9090 \
    'scrape_samples_scraped{job="users-api"}'
{instance="10.1.2.7:8080"} => 214 @[...]

$ promtool query instant http://localhost:9090 \
    'scrape_duration_seconds{job="users-api"} > 0.9 * 10'   # near scrape_timeout
```

| Symptom | Likely cause | Confirm with |
|---|---|---|
| `up == 0` | Target unreachable, wrong port, TLS/auth | `/targets` "Error" column; `kubectl exec … curl :8080/metrics` |
| `up == 1` but no series | Wrong `metrics_path`, empty endpoint | `curl /metrics` directly |
| `scrape_samples_scraped` dropped to 0 | `sample_limit` hit, exporter crash | Prometheus log: `sample limit exceeded` |
| `scrape_duration_seconds` ≈ timeout | Exporter too slow / too many series | reduce cardinality, raise `scrape_timeout` |

### 10.2 Explosión de cardinalidad

```console
# Total active series in the head block:
$ promtool query instant http://localhost:9090 'prometheus_tsdb_head_series'
{} => 1842137 @[...]                      # trending up sharply = investigate

# Series count per metric name (find the offender):
$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:3]'
[
  {"name":"http_request_duration_seconds_bucket","value":882130},
  {"name":"apiserver_request_duration_seconds_bucket","value":410221},
  {"name":"container_network_receive_bytes_total","value":98221}
]

# Which label is doing the damage:
$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.labelValueCountByLabelName[:3]'
[
  {"name":"le","value":41022},
  {"name":"id","value":38911},          # <-- unbounded label: cardinality bomb
  {"name":"handler","value":12894}
]
```

Remediación: `labeldrop` del label ofensor en `metric_relabel_configs` (§8.1),
arreglá la instrumentación, y forzá `sample_limit`.

### 10.3 Reinicios de counter, staleness y errores de tipo

- **Reinicio de counter:** si ves un gráfico de latencia/rate que pega un pico a
  un valor enorme, un proceso se reinició y su counter volvió a 0.
  `rate()`/`increase()` manejan esto automáticamente — un `delta()` crudo sobre
  un counter **no**. Usar la función equivocada es el bug, no el reinicio.
- **Staleness:** cuando una series deja de ser scrapeada (pod eliminado),
  Prometheus inserta un *staleness marker* después de ~5 minutos para que la
  series ya no devuelva un valor, evitando que datos rancios se grafiquen como
  actuales. Si ves una métrica "trabada" en un valor viejo, chequeá si el target
  realmente se fue (`up`, `/targets`) versus genuinamente plana.
- **El p99 del histogram es una línea recta / obviamente erróneo:** tus buckets no
  encierran la latencia real (p. ej. todo el tráfico cae por encima del bucket
  finito más grande, así que todo queda en `+Inf` y la interpolación no tiene
  sentido). Agregá buckets alrededor de la banda de latencia observada y
  reinstrumentá.
- **El p99 del summary a lo largo de pods se ve demasiado bajo/alto:** agregaste
  cuantiles de summary — matemáticamente inválido. Cambiá la métrica a un
  histogram.

### 10.4 Checklist rápido de extremo a extremo

```console
# 1. Exposition is valid and well-named
curl -s $TARGET/metrics | promtool check metrics
# 2. Config and rules parse
promtool check config /etc/prometheus/prometheus.yml
# 3. Target is up and fresh
promtool query instant $PROM 'up{job="users-api"}'
promtool query instant $PROM 'time() - timestamp(up{job="users-api"}) < 30'
# 4. Cardinality is sane and not trending
promtool query instant $PROM 'prometheus_tsdb_head_series'
promtool tsdb analyze /prometheus | head -n 20
# 5. The SLO query returns a sane value
promtool query instant $PROM 'job:http_request_duration_seconds:p99_5m'
```

---

## 11. References

- Prometheus — Data model: https://prometheus.io/docs/concepts/data_model/
- Prometheus — Metric types: https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Metric & label naming best practices: https://prometheus.io/docs/practices/naming/
- Prometheus — Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- Prometheus — Instrumentation best practices: https://prometheus.io/docs/practices/instrumentation/
- Prometheus — Exposition formats: https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — `histogram_quantile()` function: https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile
- Prometheus — Storage / TSDB: https://prometheus.io/docs/prometheus/latest/storage/
- Prometheus — Native histograms: https://prometheus.io/docs/specs/native_histograms/
- Prometheus — Configuration (`scrape_configs`, relabeling, limits): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — `promtool` / TSDB tooling: https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- OpenMetrics specification: https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
- Prometheus Operator — `ServiceMonitor` / API reference: https://prometheus-operator.dev/docs/api-reference/api/
- Google SRE Book — Monitoring Distributed Systems (Four Golden Signals): https://sre.google/sre-book/monitoring-distributed-systems/
- Brendan Gregg — The USE Method: https://www.brendangregg.com/usemethod.html
- Tom Wilkie / Grafana — The RED Method: https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services-for-monitoring/
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf