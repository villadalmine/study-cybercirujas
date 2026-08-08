# Histogramas — PCA 1.6 (Prometheus Certified Associate)

> Análisis a fondo de un tipo de métrica: histogramas clásicos (acumulativos), `histogram_quantile()`, semántica de agregación, histogramas nativos (exponenciales dispersos) y sus concesiones en producción. Nivel: SRE / Arquitecto de Plataforma.

---

## 1. Motivación — el problema de producción que resuelven los histogramas

El número más engañoso en un panel de latencia es `avg(latency)`. Un servicio puede mantener una media de 40 ms mientras el 1 % de los usuarios espera 4 s, y el promedio nunca se moverá lo suficiente como para alertar a nadie. Los SLOs se escriben contra **colas** ("99 % de las solicitudes por debajo de 300 ms"), y las colas requieren **distribuciones**, no tendencias centrales.

Tenés tres opciones arquitectónicas para capturar una distribución en un sistema basado en pull como Prometheus:

1. **Enviar cada observación** (registro de eventos / tracing). Fidelidad perfecta, cardinalidad y almacenamiento no acotados. No es un problema de métricas.
2. **Calcular el cuantil en el cliente** (Summary). Barato de consultar, *imposible de agregar* entre réplicas — no podés promediar p99s.
3. **Contar las observaciones en buckets en el cliente y calcular el cuantil en tiempo de consulta** (Histogram). Costo acotado, *agregable*, los cuantiles son estimaciones acotadas por el ancho del bucket.

Los histogramas de Prometheus son la opción 3. La propiedad decisiva para un sistema distribuido es la **agregabilidad**: los conteos de los buckets son contadores simples, así que `sum by (le)` sobre 200 pods es aritméticamente válido, y *luego* estimás el cuantil de la flota. Esa es la propiedad que los Summaries no pueden ofrecer, y es por eso que los histogramas son el instrumento por defecto para la latencia RED/USE y para los presupuestos de error de SLO.

El costo que pagás es que **el layout de los buckets es una decisión de diseño tomada en el momento de la instrumentación**, y un layout mal elegido limita silenciosamente la precisión de cada cuantil que alguna vez calcules a partir de él. Los histogramas nativos (Sección 6) existen para eliminar exactamente esa decisión de diseño.

---

## 2. Anatomía de un histograma clásico

Un único histograma llamado `<base>` se expande en **N+2 series temporales** en cada scrape:

| Serie | Significado |
|---|---|
| `<base>_bucket{le="<upper_bound>"}` | Conteo **acumulativo** de observaciones ≤ `upper_bound`. Una por bucket. |
| `<base>_bucket{le="+Inf"}` | Conteo de *todas* las observaciones. Siempre igual a `_count`. |
| `<base>_sum` | Suma acumulada de todos los valores observados. |
| `<base>_count` | Número total de observaciones. |

Dos hechos que confunden a casi todo el mundo:

- **Los buckets son acumulativos, no disjuntos.** `le` significa *menor-o-igual-que*. Una solicitud de 0.07 s incrementa **todos** los buckets con `le ≥ 0.07`. El conteo en la banda "0.1 a 0.25" es `bucket{le="0.25"} − bucket{le="0.1"}`, calculado en tiempo de consulta — nunca se almacena.
- **El bucket `+Inf` es obligatorio.** Sin él, `histogram_quantile()` no puede conocer el total y devuelve `NaN`.

Vista en texto de la forma acumulativa (cada barra incluye todo lo que está a su izquierda):

```
observation = 0.07s  ─► increments le=0.1, 0.25, 0.5, 1, 2.5, 5, 10, +Inf

le:    0.005  0.01  0.025  0.05  0.1   0.25  0.5   1     +Inf
count:   3     8     19     44   210   980  1180  1195   1200   (cumulative, monotonic non-decreasing)
         └──────────────── strictly non-decreasing left→right ────────────┘
```

### Los buckets por defecto difieren según la librería cliente — un peligro real de agregación

| Cliente | Buckets por defecto (segundos) |
|---|---|
| Go (`prometheus.DefBuckets`) | `.005 .01 .025 .05 .1 .25 .5 1 2.5 5 10` |
| Python (`prometheus_client`) | `.005 .01 .025 .05 .075 .1 .25 .5 .75 1.0 2.5 5.0 7.5 10.0 +Inf` |

Si un servicio en Go y un servicio en Python exponen `http_request_duration_seconds` con estos valores por defecto y hacés `sum by (le)`, los conjuntos de `le` **no se alinean** — los límites exclusivos de Python (`.075`, `.75`, `7.5`) se convierten en sumas parciales y tu cuantil de flota queda silenciosamente mal. **Estandarizá los layouts de buckets en todos los servicios que comparten un nombre de métrica.**

---

## 3. `histogram_quantile()` — mecánica, interpolación y sus filos peligrosos

```promql
histogram_quantile(φ scalar, b instant-vector)
```

Lee las etiquetas `le` de `b` como límites superiores de los buckets y devuelve el cuantil φ estimado. Dentro del bucket que contiene el cuantil, asume una **distribución lineal (uniforme)** e interpola. Esa suposición de linealidad es la fuente entera del error de estimación: cuanto más ancho el bucket, más puede alejarse la estimación de la realidad.

### La consulta canónica de cuantil de latencia

Casi nunca consultás buckets crudos — son contadores acumulativos que se reinician al reiniciar. Envolvelos en `rate()`, luego agregá **preservando `le`**:

```promql
histogram_quantile(
  0.95,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)
```

p99 por ruta, manteniendo las dimensiones que te importan:

```promql
histogram_quantile(
  0.99,
  sum by (le, route) (rate(http_request_duration_seconds_bucket[5m]))
)
```

**El orden de operaciones no es negociable:** `rate()` primero (por serie, maneja los reinicios de contador), luego `sum by (le)`, luego `histogram_quantile()` al final. Invertilo y estás promediando cuantiles — estadísticamente sin sentido.

### Comportamiento documentado en casos límite (memorizar para el examen)

| Condición | Resultado |
|---|---|
| `b` tiene menos de dos buckets | `NaN` |
| El `le` del bucket más alto **no** es `+Inf` | `NaN` |
| El vector tiene 0 observaciones | `NaN` |
| φ < 0 | `-Inf` |
| φ > 1 | `+Inf` |
| El cuantil cae en el bucket **más alto** (`+Inf`) | devuelve el **límite superior del segundo bucket más alto** (no puede interpolar hacia el infinito) → *señal de que tu bucket superior es demasiado bajo* |
| El cuantil cae en el bucket **más bajo**, y el límite superior de ese bucket > 0 | se asume que el límite inferior es **0**, se aplica interpolación lineal |

**Interpretación para operadores:** si `histogram_quantile(0.99, …)` sigue devolviendo exactamente tu segundo límite más alto (por ejemplo, siempre `5` cuando el bucket real superior es `le="5"` y luego `+Inf`), tu p99 está *por encima* del bucket finito superior y el histograma literalmente no puede verlo. Agregá buckets más altos.

### El error de estimación del cuantil, cuantificado

El resultado solo puede ser uno de los valores interpolados de los límites de los buckets. Si el p99 real es 380 ms pero tus buckets saltan `0.25 → 0.5`, la estimación queda fijada en algún punto de `[0.25, 0.5]` bajo una suposición uniforme — potencialmente errada por ±60 ms. **Poné un límite de bucket donde está tu umbral de SLO.** Para un SLO de 300 ms, `le="0.3"` debe existir.

### Los promedios son exactos (a diferencia de los cuantiles)

`_sum` y `_count` te dan la media verdadera gratis — sin interpolación:

```promql
rate(http_request_duration_seconds_sum[5m])
/
rate(http_request_duration_seconds_count[5m])
```

### Fracción SLO / Apdex — "qué porción del tráfico cumplió el objetivo"

Como los buckets son conteos, la fracción por debajo de un umbral es una división, no se necesita `histogram_quantile()`. Esto es **más preciso** que derivar un cuantil, y es la primitiva correcta para los presupuestos de error:

```promql
# Fraction of requests served in ≤ 300ms over the last 5m (needs le="0.3" to exist)
  sum(rate(http_request_duration_seconds_bucket{le="0.3"}[5m]))
/ sum(rate(http_request_duration_seconds_count[5m]))
```

Apdex (satisfechos dentro de T, tolerando hasta 4T):

```promql
(
    sum(rate(http_request_duration_seconds_bucket{le="0.3"}[5m]))
  + sum(rate(http_request_duration_seconds_bucket{le="1.2"}[5m]))
) / 2
/   sum(rate(http_request_duration_seconds_count[5m]))
```

---

## 4. Tablas de concesiones

### 4.1 Histogram vs Summary

| Dimensión | **Histogram** | **Summary** |
|---|---|---|
| Dónde se calcula el cuantil | Tiempo de consulta (`histogram_quantile`) | Cliente, en el momento de la observación |
| Series expuestas | `_bucket{le}` × N, `_sum`, `_count` | `{quantile}` × K, `_sum`, `_count` |
| **Agregable entre instancias** | **Sí** (`sum by (le)`) | **No** — promediar cuantiles es inválido |
| Qué cuantiles disponibles | **Cualquier φ, elegido en tiempo de consulta** | Solo los K cuantiles preconfigurados en tiempo de compilación |
| Factor de precisión | Layout de buckets (error de interpolación) | Error-φ configurado / ventana deslizante |
| Costo de CPU en el cliente | Bajo (incrementos de contador) | Más alto (estimador de cuantiles por streaming) |
| Costo de consulta | Más alto (interpolación sobre N buckets) | Trivial (leer el valor) |
| Fracción de umbral / Apdex | **Sí** — división de buckets | No (solo los cuantiles preelegidos) |
| Cardinalidad | N buckets por conjunto de etiquetas | K cuantiles por conjunto de etiquetas |
| Precisión sub-segundo en un φ fijo | Necesita un límite de bucket coincidente | Preciso por construcción |

**Regla práctica:** usá un **Histogram** por defecto (agregación + fracciones de SLO). Usá un **Summary** solo cuando necesitás un cuantil fijo preciso en una **única instancia no replicada** y no podés preubicar los buckets — por ejemplo, el p99 por corrida de un trabajo batch que nunca se suma entre máquinas.

### 4.2 Histograma clásico vs nativo

| Dimensión | **Histograma clásico** | **Histograma nativo (disperso, exponencial)** |
|---|---|---|
| Límites de los buckets | Fijos, elegidos en el momento de la instrumentación | Automáticos, exponenciales, autoajustables |
| Series por histograma | 1 por bucket + `_sum` + `_count` | **1 única serie temporal** (los buckets son internos) |
| Almacenamiento / cardinalidad | Alto (N series × conjuntos de etiquetas) | Bajo (disperso, solo se almacenan los buckets poblados) |
| Resolución | La que hayas fijado a mano | Controlada por `schema` (factor de bucket `2^(2^-schema)`) |
| Alineación entre servicios | Frágil (los conjuntos de `le` deben coincidir exactamente) | Uniforme por construcción (misma matemática de schema) |
| Formato de exposición | Texto u OpenMetrics | Protobuf (nativo); el texto clásico puede scrapearse en paralelo |
| Estado | Estable | **Experimental** — flag de servidor `--enable-feature=native-histograms` |
| Funciones de consulta | `histogram_quantile` sobre buckets `le` | `histogram_quantile`, `histogram_fraction`, `histogram_count`, `histogram_sum`, `histogram_avg`, `histogram_stddev`, `histogram_stdvar` |

---

## 5. Manifiestos de instrumentación (sin recortar)

### 5.1 Go — clásico + nativo en un solo instrumento

```go
package main

import (
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var httpDuration = promauto.NewHistogramVec(
	prometheus.HistogramOpts{
		Name: "http_request_duration_seconds",
		Help: "Duration of HTTP requests in seconds.",

		// --- Classic buckets: a boundary sits exactly on the 0.3s SLO target ---
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2.5, 5, 10},

		// --- Native histogram: enable exponential auto-buckets (factor 1.1 ≈ schema 3) ---
		// The client picks the finest schema whose factor is <= the requested factor.
		NativeHistogramBucketFactor:     1.1,
		NativeHistogramMaxBucketNumber:  160,             // cap sparse-bucket growth
		NativeHistogramMinResetDuration: time.Hour,       // bound memory on runaway spread
	},
	[]string{"method", "route", "code"},
)

func instrument(route string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next(rec, r)
		httpDuration.
			WithLabelValues(r.Method, route, http.StatusText(rec.status)).
			Observe(time.Since(start).Seconds())
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(c int) { s.status = c; s.ResponseWriter.WriteHeader(c) }

func main() {
	http.HandleFunc("/api", instrument("/api", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok"))
	}))
	http.Handle("/metrics", promhttp.Handler())
	http.ListenAndServe(":8080", nil)
}
```

### 5.2 Python — buckets explícitos alineados al mismo SLO

```python
from prometheus_client import Histogram, start_http_server
import time

# Bucket set MUST match the Go service's boundaries for valid cross-service sum by (le).
HTTP_DURATION = Histogram(
    "http_request_duration_seconds",
    "Duration of HTTP requests in seconds.",
    ["method", "route", "code"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2.5, 5, 10),
)

def handle(method: str, route: str):
    start = time.perf_counter()
    try:
        # ... do work ...
        code = "OK"
    finally:
        HTTP_DURATION.labels(method, route, code).observe(time.perf_counter() - start)

if __name__ == "__main__":
    start_http_server(8080)
```

### 5.3 Configuración de scrape de Prometheus (`prometheus.yml`) — histogramas nativos habilitados

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

# Server must be started with:  --enable-feature=native-histograms
# With that flag, Prometheus negotiates the Protobuf exposition format automatically,
# so native histograms are ingested where the target exposes them.

scrape_configs:
  - job_name: api
    # Also keep the classic _bucket series alongside the native one during migration:
    always_scrape_classic_histograms: true
    static_configs:
      - targets: ["api.default.svc:8080"]
        labels:
          service: api
```

### 5.4 Kubernetes — Deployment + Service + ServiceMonitor (Prometheus Operator)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: shop
  labels: { app: api }
spec:
  replicas: 3
  selector:
    matchLabels: { app: api }
  template:
    metadata:
      labels: { app: api }
    spec:
      containers:
        - name: api
          image: registry.example.com/shop/api:1.8.2
          ports:
            - name: http-metrics
              containerPort: 8080
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: shop
  labels: { app: api }
spec:
  selector: { app: api }
  ports:
    - name: http-metrics
      port: 8080
      targetPort: http-metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api
  namespace: shop
  labels: { release: kube-prometheus-stack }
spec:
  selector:
    matchLabels: { app: api }
  endpoints:
    - port: http-metrics
      interval: 15s
      path: /metrics
```

Para ingerir histogramas nativos vía el Operator, habilitá la característica en el CR de `Prometheus` (se requiere protobuf para la exposición nativa):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: main
  namespace: monitoring
spec:
  enableFeatures:
    - native-histograms
  scrapeProtocols:
    - PrometheusProto          # native histograms need the protobuf protocol
    - OpenMetricsText1.0.0
    - PrometheusText0.0.4
  serviceMonitorSelector:
    matchLabels: { release: kube-prometheus-stack }
```

### 5.5 Reglas de recording + alertas (`PrometheusRule`)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: api-latency
  namespace: monitoring
  labels: { release: kube-prometheus-stack, role: alert-rules }
spec:
  groups:
    - name: api.latency.recording
      interval: 30s
      rules:
        # Pre-aggregate buckets ONCE, preserving le, so quantiles are cheap downstream.
        - record: job_route:http_request_duration_seconds_bucket:rate5m
          expr: |
            sum by (job, route, le) (
              rate(http_request_duration_seconds_bucket[5m])
            )

        - record: job_route:http_request_duration_seconds:p99
          expr: |
            histogram_quantile(
              0.99,
              job_route:http_request_duration_seconds_bucket:rate5m
            )

        # SLO good-event ratio: fraction served within the 300ms target.
        - record: job:http_request_slo_ratio:rate5m
          expr: |
              sum by (job) (rate(http_request_duration_seconds_bucket{le="0.3"}[5m]))
            / sum by (job) (rate(http_request_duration_seconds_count[5m]))

    - name: api.latency.alerts
      rules:
        - alert: ApiP99LatencyHigh
          expr: job_route:http_request_duration_seconds:p99 > 0.5
          for: 10m
          labels: { severity: warning }
          annotations:
            summary: "p99 latency > 500ms on {{ $labels.route }}"
            description: "p99 is {{ $value | humanizeDuration }} for job {{ $labels.job }} route {{ $labels.route }}."

        # Multi-window, multi-burn-rate error-budget burn (99.9% target → budget 0.001).
        - alert: ApiLatencySLOBurnFast
          expr: |
            (1 - job:http_request_slo_ratio:rate5m) > (14.4 * 0.001)
            and
            (1 - (
                sum by (job) (rate(http_request_duration_seconds_bucket{le="0.3"}[1h]))
              / sum by (job) (rate(http_request_duration_seconds_count[1h]))
            )) > (14.4 * 0.001)
          for: 2m
          labels: { severity: critical }
          annotations:
            summary: "Fast latency-SLO burn (14.4x) on {{ $labels.job }}"
```

---

## 6. Histogramas nativos — la palanca de diseño

Los histogramas nativos reemplazan el "elegí tus buckets y rezá" con una única serie autoescalable. Los límites de los buckets son exponenciales: para un `schema` dado s, el factor de crecimiento entre buckets adyacentes es `2^(2^-s)`.

| `schema` | Factor de bucket `2^(2^-s)` | Carácter |
|---|---|---|
| 0 | 2.000 | cada bucket duplica al anterior |
| 3 | 1.0905 | ≈ pasos del 9 % (coincide con el factor de cliente 1.1) |
| 5 | 1.0219 | ≈ pasos del 2.2 % |
| 8 | 1.0027 | resolución muy alta |

Internamente, un histograma nativo lleva **buckets positivos**, **buckets negativos** y un **bucket cero** (observaciones dentro de `zero_threshold` de 0). Por eso los histogramas nativos manejan valores negativos y valores que abarcan muchos órdenes de magnitud que los buckets fijos clásicos no pueden.

Las funciones de consulta operan directamente sobre la muestra del histograma nativo — **sin etiqueta `le`**:

```promql
# p99 straight from a native histogram
histogram_quantile(0.99, sum(rate(http_request_duration_seconds[5m])))

# Fraction of requests in [0, 0.3] — the SLO ratio, no manual bucket picking
histogram_fraction(0, 0.3, sum(rate(http_request_duration_seconds[5m])))

# Exact mean, count, sum, stddev
histogram_avg(rate(http_request_duration_seconds[5m]))
histogram_count(rate(http_request_duration_seconds[5m]))
histogram_sum(rate(http_request_duration_seconds[5m]))
histogram_stddev(rate(http_request_duration_seconds[5m]))
```

**Patrón de migración:** ejecutá `always_scrape_classic_histograms: true` para que ambas representaciones coexistan; los paneles y las alertas migran de a un panel por vez; descartá los buckets clásicos solo después de que la versión nativa sea confiable.

---

## 7. Verificación por CLI y terminal

### 7.1 Leer la exposición cruda — histograma clásico

```console
$ curl -s http://localhost:8080/metrics | grep '^http_request_duration_seconds'
# HELP http_request_duration_seconds Duration of HTTP requests in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.005"} 3
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.01"} 8
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.025"} 19
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.05"} 44
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.1"} 210
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.2"} 940
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.3"} 1088
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="0.5"} 1180
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="1"} 1195
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="2.5"} 1199
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="5"} 1200
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="10"} 1200
http_request_duration_seconds_bucket{method="GET",route="/api",code="OK",le="+Inf"} 1200
http_request_duration_seconds_sum{method="GET",route="/api",code="OK"} 156.34
http_request_duration_seconds_count{method="GET",route="/api",code="OK"} 1200
```

Chequeos de sanidad que podés verificar a ojo: los buckets son **monótonos no decrecientes**, `le="+Inf"` (1200) **es igual a `_count`** (1200), y los conteos suben abruptamente a través de `le="0.2"→"0.3"` diciéndote que la masa del tráfico vive alrededor de los 150–250 ms.

### 7.2 Ver la presencia negociada del protobuf del histograma nativo

```console
$ curl -s -H 'Accept: application/vnd.google.protobuf;proto=io.prometheus.client.MetricFamily;encoding=delimited' \
       http://localhost:8080/metrics | protoc --decode_raw | head
# (binary protobuf; native histograms are only exposed over this format)

$ promtool query instant http://localhost:9090 \
    'histogram_count(rate(http_request_duration_seconds[5m]))'
http_request_duration_seconds{method="GET", route="/api"} => 80.0 @[1754640000]
```

### 7.3 Evaluar el cuantil contra el servidor

```console
$ promtool query instant http://localhost:9090 \
    'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))'
{} => 0.2743 @[1754640000.000]

$ promtool query instant http://localhost:9090 \
    'histogram_quantile(0.99, sum by (le, route) (rate(http_request_duration_seconds_bucket[5m])))'
{route="/api"}   => 0.4821 @[1754640000.000]
{route="/login"} => 0.9210 @[1754640000.000]
```

### 7.4 Lintear las reglas y hacer pruebas unitarias de la lógica del cuantil

```console
$ promtool check rules api-latency.rules.yaml
Checking api-latency.rules.yaml
  SUCCESS: 5 rules found
```

`histogram.test.yaml`:

```yaml
rule_files:
  - api-latency.rules.yaml

evaluation_interval: 1m

tests:
  - interval: 1m
    input_series:
      - series: 'http_request_duration_seconds_bucket{job="api", route="/api", le="0.3"}'
        values: '0+30x10'      # 30 obs/min ≤ 300ms
      - series: 'http_request_duration_seconds_bucket{job="api", route="/api", le="+Inf"}'
        values: '0+40x10'      # 40 obs/min total  → 10/min are slow
      - series: 'http_request_duration_seconds_count{job="api", route="/api"}'
        values: '0+40x10'
    promql_expr_test:
      - expr: job:http_request_slo_ratio:rate5m
        eval_time: 5m
        exp_samples:
          - labels: 'job:http_request_slo_ratio:rate5m{job="api"}'
            value: 0.75        # 30/40 within target
```

```console
$ promtool test rules histogram.test.yaml
Unit Testing:  histogram.test.yaml
  SUCCESS
```

---

## 8. Guía de verificación y diagnóstico de fallas

| Síntoma | Causa raíz | Solución |
|---|---|---|
| `histogram_quantile(...)` devuelve **`NaN`** | No hay bucket `+Inf` en el vector, o `<2` buckets, o 0 observaciones en la ventana | Asegurate de que la exposición incluya `le="+Inf"`; confirmá que la métrica se scrapea; ampliá el rango si el tráfico es escaso |
| p99 está **fijado al segundo límite más alto** y no se mueve | El cuantil real está por encima de tu bucket finito superior (caso del bucket `+Inf`) | Agregá buckets más altos (por ejemplo, `20`, `60`) para que la cola sea medible |
| El cuantil se ve **cuantizado / escalonado** entre dos valores | Buckets demasiado anchos alrededor del cuantil; la interpolación no tiene nada que interpolar | Agregá límites cerca de la región de interés; poné uno exactamente en el umbral de SLO |
| `sum by (le)` entre servicios da cuantiles **erróneos / con picos** | Distintos servicios exponen **distintos conjuntos de `le`** (por ejemplo, defaults de Go vs Python) | Estandarizá la lista exacta de buckets en todos los productores de esa métrica |
| p99 **baja de golpe tras un deploy** y luego se recupera | Los buckets son contadores; reinicio de restart — te olvidaste de `rate()`/`increase()` | Usá siempre `rate(..._bucket[...])` antes de agregar |
| p99 es **inverosímilmente bajo** vs los traces | Promediando cuantiles: `avg(histogram_quantile(...))` en vez de cuantil-de-suma | Agregá los buckets primero (`sum by (le)`), aplicá `histogram_quantile` **al final** |
| `le="+Inf"` ≠ `_count` | Exporter roto / reescritura que descarta la etiqueta `le` | Inspeccioná el `/metrics` crudo; verificá que `metric_relabel_configs` no esté quitando `le` |
| Las consultas de histograma nativo devuelven vacío, las clásicas funcionan | El servidor se inició sin `--enable-feature=native-histograms`, o el target no se scrapea sobre protobuf | Habilitá el feature flag; configurá `scrapeProtocols` para incluir `PrometheusProto` |
| Estallido de cardinalidad / memoria de TSDB en un histograma | N buckets × etiquetas de alta cardinalidad (por ejemplo, `user_id`, `path` crudo) | Descartá etiquetas no acotadas; reducí buckets; migrá a histogramas nativos |
| La alerta oscila en el límite del SLO | El umbral queda entre dos buckets gruesos | Agregá un límite de bucket exactamente en el valor del SLO, o usá `histogram_fraction` sobre un histograma nativo |

**Chequeo independiente del conteo** (una serie debe satisfacer la invariante del histograma en cada scrape):

```promql
# Should be exactly 0 everywhere; any non-zero means a broken exporter.
http_request_duration_seconds_count
  - ignoring(le) http_request_duration_seconds_bucket{le="+Inf"}
```

**Heatmap de Grafana** (visualización nativa de buckets de toda la distribución a lo largo del tiempo):

```promql
sum by (le) (rate(http_request_duration_seconds_bucket[$__rate_interval]))
```
Tipo de panel *Heatmap*, formato *Heatmap*, unidad del eje Y *seconds* — lee la etiqueta `le` como el eje de buckets.

---

## 9. Referencias

- Metric types — Histogram & Summary: https://prometheus.io/docs/concepts/metric_types/
- Instrumentation best practices — Histograms and quantile errors: https://prometheus.io/docs/practices/histograms/
- `histogram_quantile()` and native-histogram functions: https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile
- Native histograms concept: https://prometheus.io/docs/concepts/native_histograms/
- Native histograms specification: https://prometheus.io/docs/specs/native_histograms/
- Metric and label naming: https://prometheus.io/docs/practices/naming/
- Go client library (`HistogramOpts`, `DefBuckets`, native options): https://pkg.go.dev/github.com/prometheus/client_golang/prometheus#HistogramOpts
- Python client library (`Histogram`): https://prometheus.github.io/client_python/instrumenting/histogram/
- OpenMetrics specification (histogram exposition): https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
- `promtool` unit testing rules: https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus Operator API (`Prometheus`, `ServiceMonitor`, `PrometheusRule`): https://prometheus-operator.dev/docs/api-reference/api/
- Google SRE Workbook — Alerting on SLOs (multiwindow burn-rate): https://sre.google/workbook/alerting-on-slos/
- PCA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf