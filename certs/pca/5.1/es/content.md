# Bibliotecas de cliente

**PCA Dominio 4 — Instrumentación y Exporters · Tema 5.1**
*Peso del examen: 4 · Nivel: SRE / Arquitecto de plataforma*

---

## 1. El problema de producción: qué resuelve realmente una biblioteca de cliente

Prometheus es un sistema **basado en pull**. El servidor no recibe métricas; periódicamente emite un `GET /metrics` HTTP contra cada target que descubre y parsea una carga útil en texto plano (o protobuf) en el *formato de exposición*. Esto invierte el habitual modelo push/agente y traslada un problema difícil al propio proceso de la aplicación: **el proceso debe, en el momento del scrape, ser capaz de serializar una instantánea globalmente consistente y thread-safe de cada métrica que posee, en un formato correcto byte a byte, con una sobrecarga inferior al milisegundo, mientras sirve tráfico de producción.**

Hacer esto a mano — concatenando strings en un handler de `/metrics` — falla en producción por razones concretas y repetibles:

- **Concurrencia.** Un counter como `http_requests_total` se incrementa desde miles de goroutines/threads simultáneamente. Un `count++` ingenuo pierde actualizaciones bajo contención. La biblioteca debe proporcionar incrementos atómicos, lock-free (o con locks particionados).
- **Consistencia en el momento del scrape.** Las series `_bucket`, `_sum` y `_count` de un Histogram deben reflejar las *mismas* observaciones. Si un scrape lee `_count` después de que otro thread actualizó `_sum`, `histogram_quantile()` produce valores imposibles (p. ej., un p99 por debajo del p50).
- **Corrección del formato.** El formato de exposición tiene reglas exactas: líneas `# HELP`/`# TYPE`, escapado de labels, labels reservadas `le`/`quantile`, bucket `+Inf`, conteos de bucket acumulativos, nomenclatura en unidades base. Una sola línea mal formada hace que Prometheus rechace el scrape **entero** (`up == 0` para ese target), no solo una métrica.
- **Ciclo de vida y registro.** Las métricas deben crearse una sola vez, registrarse exactamente una vez (el doble registro provoca panic/excepción) y ser descubribles por un registry central que el handler HTTP recorre en el momento del scrape.
- **Seguridad de cardinalidad.** Los valores de las labels se mapean 1:1 a series temporales. Las labels no controladas (IDs de usuario, rutas de request, strings de error) crean una explosión de cardinalidad que mata por OOM tanto a la app como al servidor Prometheus.

Una **biblioteca de cliente** es la implementación reutilizable de todo lo anterior. Te da los cuatro tipos de métrica, un `Registry`, una interfaz `Collector` y un handler HTTP que negocia el content type y serializa de forma atómica. Existen bibliotecas mantenidas oficialmente para **Go, Java/JVM, Python, Ruby y Rust**; docenas de bibliotecas comunitarias cubren Node.js, .NET, PHP, C++, Rust, etc.

> Regla práctica arquitectónica: **instrumentá en el proceso que es dueño de la verdad.** Si tu app conoce el número, usá una biblioteca de cliente (instrumentación directa). Si la verdad vive en un sistema que *no* controlás (una base de datos, el kernel, una NIC), escribís un **exporter** — que en sí mismo no es más que una biblioteca de cliente más un `Collector` personalizado que hace scrape del sistema de terceros bajo demanda (tema tratado en Exporters).

---

## 2. Anatomía de una biblioteca de cliente

Toda biblioteca oficial comparte el mismo modelo conceptual. Aprendé el modelo una vez; los nombres de la API difieren según el lenguaje.

```
        ┌──────────────────────────────────────────────┐
        │                Application code                │
        │   counter.Inc()   hist.Observe(0.42)   ...     │
        └───────────────────────┬──────────────────────┘
                                 │ registers
                                 ▼
        ┌──────────────────────────────────────────────┐
        │                   Registry                     │
        │  (default + optional custom registries)        │
        │  holds Collectors, enforces unique names,      │
        │  detects label/type collisions                 │
        └───────────────────────┬──────────────────────┘
                                 │ Collect() at scrape time
                                 ▼
        ┌──────────────────────────────────────────────┐
        │              HTTP exposition handler           │
        │  GET /metrics → negotiate Content-Type →       │
        │  walk registry → serialize atomic snapshot     │
        └───────────────────────┬──────────────────────┘
                                 │ HTTP GET (Accept: ...)
                                 ▼
                          Prometheus server scrape
```

**Componentes clave:**

| Componente | Responsabilidad | Ejemplo Go | Ejemplo Python |
|---|---|---|---|
| **Metric** | Un único instrumento (una familia de series). | `prometheus.Counter` | `Counter(...)` |
| **MetricVec** | Una métrica particionada por dimensiones de label; una serie hija por cada combinación de valores de label. | `CounterVec` | `Counter(..., ["method"])` |
| **Collector** | Cualquier cosa que pueda producir métricas bajo demanda vía `Collect()`. Las métricas son Collectors; los collectors personalizados te permiten muestrear estado externo en el momento del scrape. | `prometheus.Collector` | `Collector` (vía `collect()`) |
| **Registry** | Es dueño de los Collectors, garantiza la unicidad de nombres, produce la exposición. | `prometheus.NewRegistry()` | `CollectorRegistry()` |
| **Exposition/Handler** | Serializa el registry sobre HTTP, negociando texto vs OpenMetrics vs protobuf. | `promhttp.HandlerFor(reg, ...)` | `make_wsgi_app` / `start_http_server` |

**Registry por defecto vs. registry personalizado (decisión de producción).** Las bibliotecas incluyen un *registry por defecto* global precargado con collectors de runtime (`go_*`, `process_*` en Go; `process_*`, `python_*` en Python). Cómodo, pero es estado global mutable: hace que los tests unitarios dependan del orden y puede filtrar métricas entre componentes lógicos. En bibliotecas multi-tenant, sidecars, o cuando querés un `/metrics` limpio, creá un `Registry` **explícito** y registrá solo lo que te pertenece.

---

## 3. Los cuatro tipos de métrica — mecánica y compromisos

### 3.1 Counter
Un valor que crece monótonamente y se resetea a 0 solo al reiniciarse el proceso. Nunca `Dec()`. Casi nunca leés un counter directamente en PromQL — usás `rate()`/`increase()`, que son *conscientes de los resets*. Usá para: requests servidas, errores, bytes enviados, tareas completadas.

### 3.2 Gauge
Un valor que sube y baja. Se lee directamente, o con `delta()`/`deriv()`. Usá para: requests en vuelo, profundidad de cola, temperatura, memoria en uso, cantidad de réplicas.

### 3.3 Histogram
Las observaciones se cuentan en **buckets acumulativos** definidos por límites superiores (`le`, "menor o igual que"). Expone tres familias de series: `_bucket{le="..."}` (conteos acumulativos, incluyendo un `+Inf` obligatorio), `_sum` y `_count`. Los cuantiles se calculan **del lado del servidor** con `histogram_quantile()` interpolando dentro de un bucket.

### 3.4 Summary
También expone `_sum` y `_count`, pero calcula **cuantiles-φ preagregados del lado del cliente** (`quantile="0.99"`) sobre una ventana de tiempo deslizante. Sin buckets.

### Histogram vs Summary — el compromiso clásico del examen

| Propiedad | **Histogram** | **Summary** |
|---|---|---|
| Cálculo del cuantil | Del lado del servidor, en tiempo de consulta (`histogram_quantile`) | Del lado del cliente, estimación en streaming |
| **Agregable entre instancias** | **Sí** — los buckets son counters, `sum by (le)` es válido | **No** — no podés promediar cuantiles precalculados |
| Elegir los límites de bucket por adelantado | Sí (hay que conocer tu rango de latencia) | No |
| Precisión del cuantil | Limitada por la resolución de los buckets | Error configurable (`objectives`), exacto dentro de la ventana |
| Costo de CPU en el cliente | Barato (incrementar un bucket) | Más caro (algoritmo de cuantiles en streaming) |
| Series por métrica (clásico) | `#buckets + 2` | `#quantiles + 2` |
| Cuantil arbitrario a posteriori | Sí (cualquier cuantil a partir de los buckets) | No (solo los φ predeclarados) |
| Conteo de umbrales Apdex / SLO | Trivial (bucket `le="0.3"`) | No es posible |

**Guía de producción:** por defecto usá **Histogram**. La única característica que decide la mayoría de los casos reales es la *agregabilidad*: con N réplicas detrás de un balanceador de carga, querés el p99 de toda la flota, y solo los histogramas te permiten hacer `histogram_quantile(0.99, sum(rate(..._bucket[5m])) by (le))`. Recurrí a un Summary solo cuando necesitás un cuantil exacto en una **única** instancia y no podés preseleccionar los buckets.

### 3.5 Native Histograms (Prometheus 2.40+, experimental → estabilizándose)
Los histogramas clásicos fuerzan un compromiso cardinalidad/precisión mediante buckets fijos. Los **native histograms (dispersos, exponenciales)** almacenan buckets con un esquema exponencial elegido automáticamente (`NativeHistogramBucketFactor` controla la resolución, p. ej. `1.1` ≈ 10% de ancho relativo de bucket). Una métrica, una serie, límites de bucket dinámicos, scrapeados sobre protobuf u OpenMetrics. `histogram_quantile()` funciona directamente sobre ellos. Reducen drásticamente la cardinalidad de series mientras aumentan la precisión de los cuantiles — habilitalos cuando tanto tu biblioteca de cliente como tu versión de Prometheus lo soporten.

```go
// Go: opt into native histograms alongside classic buckets
prometheus.HistogramOpts{
    Name:                            "myapp_http_request_duration_seconds",
    Help:                            "Latency distribution.",
    Buckets:                         prometheus.DefBuckets, // classic fallback
    NativeHistogramBucketFactor:     1.1,                   // enable native
    NativeHistogramMaxBucketNumber:  160,                   // cap cardinality
    NativeHistogramMinResetDuration: time.Hour,
}
```

---

## 4. Cardinalidad y nomenclatura — la causa #1 por la que la instrumentación mata la producción

**Cada combinación única de un nombre de métrica y sus valores de label es una serie temporal distinta.** La cantidad de series es el recurso maestro en Prometheus (RAM, tamaño del head-block, WAL). Una sola label mala detona el servidor.

```go
// CARDINALITY BOMB — never do this
requests.WithLabelValues(userID, requestPath, err.Error()).Inc()
// userID (10^6) × path (10^4, unbounded) × error string (unbounded) = effectively infinite series
```

**Reglas para el diseño de labels:**
- Las labels deben ser **acotadas y de baja cardinalidad**: `method` (≈7), `code` (≈40), `handler` (una *plantilla de ruta fija*, no la URL cruda).
- Nunca pongas valores no acotados en las labels: IDs de usuario, email, rutas completas, SQL crudo, timestamps, mensajes de error, trace IDs (para esos usá **exemplars** — ver §7).
- El nombre de la métrica identifica *qué*; las labels identifican *dimensiones de la misma cosa*. `http_requests_total{code="500"}` — no `http_500_requests_total`.

**Convenciones de nomenclatura (impuestas culturalmente, verificadas con `promtool`):**
- `snake_case`, con la forma `namespace_subsystem_name_unit_suffix`.
- Usá **unidades base**: `seconds` (no ms), `bytes` (no KB), `ratio` en `[0,1]`.
- Los counters terminan en `_total`. `_sum`/`_count`/`_bucket` están reservados para histograms/summaries.
- El sufijo refleja la unidad: `_seconds`, `_bytes`, `_info` (para el patrón info, siempre con valor `1`).

| Antipatrón | Corrección |
|---|---|
| `latency_ms` | `request_duration_seconds` |
| `http_requests` (counter sin `_total`) | `http_requests_total` |
| label `path="/user/42/orders/9981"` | label `route="/user/:id/orders/:oid"` |
| label `error="connection refused: 10.0.0.1:5432"` | label `error_type="connection_refused"` (enum acotado) |
| una métrica por código HTTP | una métrica, label `code` |

---

## 5. Instrumentación directa — ejemplos completos y ejecutables

### 5.1 Go (`client_golang`) — la implementación de referencia

```go
// main.go
package main

import (
	"math/rand"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Package-level, created once. promauto auto-registers to the default registry.
var (
	httpRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Namespace: "myapp",
			Subsystem: "http",
			Name:      "requests_total",
			Help:      "Total HTTP requests processed, by method and response code.",
		},
		[]string{"method", "code"},
	)

	httpRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Namespace: "myapp",
			Subsystem: "http",
			Name:      "request_duration_seconds",
			Help:      "HTTP request latency distribution in seconds.",
			// DefBuckets = {.005,.01,.025,.05,.1,.25,.5,1,2.5,5,10}
			Buckets: prometheus.DefBuckets,
		},
		[]string{"route"},
	)

	httpInFlight = promauto.NewGauge(
		prometheus.GaugeOpts{
			Namespace: "myapp",
			Subsystem: "http",
			Name:      "in_flight_requests",
			Help:      "HTTP requests currently being served.",
		},
	)

	buildInfo = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Namespace: "myapp",
			Name:      "build_info",
			Help:      "Build metadata; value is always 1. Join on this in PromQL.",
		},
		[]string{"version", "revision", "go_version"},
	)
)

func instrument(route string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpInFlight.Inc()
		defer httpInFlight.Dec()

		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next(sw, r)

		elapsed := time.Since(start).Seconds()
		httpRequestDuration.WithLabelValues(route).Observe(elapsed)
		httpRequestsTotal.WithLabelValues(r.Method, http.StatusText(sw.status)).Inc()
	}
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func handleWork(w http.ResponseWriter, r *http.Request) {
	time.Sleep(time.Duration(rand.Intn(300)) * time.Millisecond)
	w.Write([]byte("ok\n"))
}

func main() {
	buildInfo.WithLabelValues("1.4.2", "abc1234", "go1.22").Set(1)

	http.HandleFunc("/work", instrument("/work", handleWork))
	// promhttp.Handler() serves the DEFAULT registry, negotiating text/OpenMetrics.
	http.Handle("/metrics", promhttp.Handler())
	http.ListenAndServe(":8080", nil)
}
```

```go
// go.mod
module myapp

go 1.22

require github.com/prometheus/client_golang v1.19.1
```

El registry por defecto incluye automáticamente los collectors `go_*` (GC, goroutines, memstats) y `process_*` (FDs abiertos, CPU, RSS) — gratis, y esenciales para las guardias (on-call).

### 5.2 Python (`prometheus_client`)

```python
# app.py
import random
import time
from prometheus_client import Counter, Gauge, Histogram, start_http_server

REQUESTS = Counter(
    "myapp_http_requests_total",
    "Total HTTP requests processed.",
    ["method", "code"],
)
LATENCY = Histogram(
    "myapp_http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
)
IN_FLIGHT = Gauge(
    "myapp_http_in_flight_requests",
    "HTTP requests currently being served.",
)


@IN_FLIGHT.track_inprogress()          # decorator manages Inc()/Dec()
@LATENCY.labels(route="/work").time()  # decorator observes wall time
def handle_work():
    time.sleep(random.random() * 0.3)
    REQUESTS.labels(method="GET", code="200").inc()
    return "ok"


if __name__ == "__main__":
    # Spins up a dedicated WSGI server exposing /metrics on :8000
    start_http_server(8000)
    while True:
        handle_work()
```

```
# requirements.txt
prometheus-client==0.20.0
```

### 5.3 Java (JVM — `client_java` 1.x, `io.prometheus.metrics`)

```java
// App.java
import io.prometheus.metrics.core.metrics.Counter;
import io.prometheus.metrics.core.metrics.Histogram;
import io.prometheus.metrics.exporter.httpserver.HTTPServer;
import io.prometheus.metrics.instrumentation.jvm.JvmMetrics;

public class App {
    static final Counter requests = Counter.builder()
        .name("myapp_http_requests_total")
        .help("Total HTTP requests processed.")
        .labelNames("method", "code")
        .register();

    static final Histogram latency = Histogram.builder()
        .name("myapp_http_request_duration_seconds")
        .help("HTTP request latency in seconds.")
        .classicUpperBounds(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10)
        .nativeInitialSchema(3)          // opt into native histogram
        .labelNames("route")
        .register();

    public static void main(String[] args) throws Exception {
        JvmMetrics.builder().register();  // jvm_* + process_* collectors

        // one observation
        long t0 = System.nanoTime();
        // ... handle work ...
        latency.labelValues("/work").observe((System.nanoTime() - t0) / 1e9);
        requests.labelValues("GET", "200").inc();

        HTTPServer.builder().port(8080).buildAndStart(); // serves /metrics
        Thread.currentThread().join();
    }
}
```

### Comparación de características de bibliotecas de cliente (para elegir / auditar)

| Característica | Go | Java (1.x) | Python | Ruby | Rust |
|---|---|---|---|---|---|
| Mantenida oficialmente | ✅ | ✅ | ✅ | ✅ | ✅ |
| Native histograms | ✅ | ✅ | parcial | ⏳ | ⏳ |
| Exemplars | ✅ | ✅ | ✅ | ⏳ | parcial |
| Métricas de runtime por defecto | `go_*`,`process_*` | `jvm_*`,`process_*` | `process_*`,`python_*` | `process_*` | opt-in |
| Modo multiproceso | N/A (proceso único) | N/A | ✅ (gunicorn/uWSGI) | ✅ | N/A |
| Push (Pushgateway) | ✅ | ✅ | ✅ | ✅ | ✅ |

> **Trampa de Python:** bajo un servidor con pre-forking (gunicorn, uWSGI) cada worker es un proceso separado con su propio registry, así que un scrape golpea un worker aleatorio y los counters parecen no monótonos. Solucionalo con el **modo multiproceso**: fijá `PROMETHEUS_MULTIPROC_DIR` a un tmpfs compartido y usá `MultiProcessCollector`. Este es un incidente de producción frecuente.

---

## 6. El formato de exposición (lo que tu biblioteca realmente emite)

Un scrape del ejemplo Go de arriba:

```
$ curl -s http://localhost:8080/metrics
# HELP myapp_build_info Build metadata; value is always 1. Join on this in PromQL.
# TYPE myapp_build_info gauge
myapp_build_info{go_version="go1.22",revision="abc1234",version="1.4.2"} 1
# HELP myapp_http_in_flight_requests HTTP requests currently being served.
# TYPE myapp_http_in_flight_requests gauge
myapp_http_in_flight_requests 3
# HELP myapp_http_request_duration_seconds HTTP request latency distribution in seconds.
# TYPE myapp_http_request_duration_seconds histogram
myapp_http_request_duration_seconds_bucket{route="/work",le="0.005"} 0
myapp_http_request_duration_seconds_bucket{route="/work",le="0.01"} 2
myapp_http_request_duration_seconds_bucket{route="/work",le="0.05"} 41
myapp_http_request_duration_seconds_bucket{route="/work",le="0.1"} 118
myapp_http_request_duration_seconds_bucket{route="/work",le="0.25"} 372
myapp_http_request_duration_seconds_bucket{route="/work",le="0.5"} 511
myapp_http_request_duration_seconds_bucket{route="/work",le="+Inf"} 511
myapp_http_request_duration_seconds_sum{route="/work"} 74.83
myapp_http_request_duration_seconds_count{route="/work"} 511
# HELP myapp_http_requests_total Total HTTP requests processed, by method and response code.
# TYPE myapp_http_requests_total counter
myapp_http_requests_total{code="OK",method="GET"} 511
# HELP go_goroutines Number of goroutines that currently exist.
# TYPE go_goroutines gauge
go_goroutines 11
# HELP process_resident_memory_bytes Resident memory size in bytes.
# TYPE process_resident_memory_bytes gauge
process_resident_memory_bytes 1.4909e+07
```

**Reglas de formato que tu biblioteca garantiza (y que no debés romper en los exporters):**
- Un `# HELP` y un `# TYPE` por familia de métricas, antes de sus samples.
- Los conteos de bucket son **acumulativos** y **monótonamente no decrecientes**; el conteo final `le="+Inf"` es igual a `_count`.
- Los valores de label son UTF-8, con `\`, `"` y `\n` escapados.
- Timestamp opcional en milisegundos al final (rara vez usado; dejá que Prometheus ponga el timestamp en el scrape).

**Negociación de Content-Type** (el handler elige según el `Accept` del scraper):

| Formato | Content-Type | Notas |
|---|---|---|
| Texto (`0.0.4`) | `text/plain; version=0.0.4; charset=utf-8` | Predeterminado universal |
| OpenMetrics | `application/openmetrics-text; version=1.0.0; charset=utf-8` | Agrega exemplars, `# EOF`, `_created` |
| Protobuf | `application/vnd.google.protobuf; ...` | Requerido para scrapear native histograms |

OpenMetrics se diferencia en que termina el stream con un `# EOF` literal y codifica los exemplars en línea:

```
myapp_http_request_duration_seconds_bucket{route="/work",le="0.1"} 118 # {trace_id="4bf92f3577b34da6"} 0.087 1723200000.123
# EOF
```

---

## 7. Exemplars — enlazando métricas con trazas

Los exemplars adjuntan un *sample* de alta cardinalidad (un trace ID) a una *única observación* dentro de un bucket, sin convertirlo en una label (así que no hay explosión de cardinalidad). Este es el puente desde un pico de latencia p99 hasta la traza exacta que lo causó.

```go
// Go: requires OpenMetrics negotiation on the handler
httpRequestDuration.WithLabelValues("/work").(prometheus.ExemplarObserver).
    ObserveWithExemplar(elapsed, prometheus.Labels{"trace_id": traceID})

// Handler must allow exemplars:
http.Handle("/metrics", promhttp.HandlerFor(
    prometheus.DefaultGatherer,
    promhttp.HandlerOpts{EnableOpenMetrics: true},
))
```

Prometheus debe iniciarse con `--enable-feature=exemplar-storage` para retenerlos.

---

## 8. Pushgateway — instrumentando batch jobs

El modelo pull se rompe para los **batch jobs de vida corta** que terminan antes de que cualquier scrape pueda alcanzarlos. El Pushgateway es una caché de métricas a la que un job de ese tipo hace push al completarse, y Prometheus scrapea el gateway en su lugar.

```
   ephemeral cron job ──push──▶  Pushgateway  ◀──scrape── Prometheus
   (exits in 8s)                 (persists last push)
```

```python
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

registry = CollectorRegistry()
g = Gauge("batch_last_success_unixtime", "Last successful run.", registry=registry)
g.set_to_current_time()

# 'job' becomes the job label; grouping key isolates instances
push_to_gateway("pushgateway.monitoring.svc:9091",
                job="nightly_etl", registry=registry)
```

```
$ echo "batch_records_processed 42815" \
    | curl --data-binary @- http://pushgateway:9091/metrics/job/nightly_etl/instance/pod-7
```

**El Pushgateway es un arma de doble filo — conocé los modos de falla (relevantes para el examen):**

| Trampa | Consecuencia | Mitigación |
|---|---|---|
| Las métricas **persisten para siempre** tras el push | Las métricas de un job muerto parecen "vivas"; las alertas nunca se limpian | Borrá el grupo al terminar el job (`DELETE .../metrics/job/...`); usá `push_time_seconds` en las alertas |
| Sin métrica `up` por job | No podés detectar un job que nunca corrió | Alertá con `time() - batch_last_success_unixtime > threshold` |
| Instancia única | SPOF y cuello de botella de fan-in | Mantenelo chico; **solo** para batch jobs a nivel de servicio |
| Mal usado como agente de push | Pierde todas las señales de salud del modelo pull | Usá exporters/pull directo para cualquier cosa de larga vida |

> Regla: usá el Pushgateway **solo** para batch jobs a nivel de servicio, nunca como un endpoint genérico de "push de las métricas de mi app".

---

## 9. Kubernetes: manifiestos completos, sin recortar

Dos mecanismos de scraping. El **Prometheus Operator** (CRDs `ServiceMonitor`/`PodMonitor`) es el estándar de producción; las **anotaciones de pod** legacy funcionan con `kubernetes_sd` de Prometheus vainilla.

### 9.1 Deployment + Service + ServiceMonitor (Operator)

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: apps
  labels:
    app.kubernetes.io/name: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: myapp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: myapp
    spec:
      containers:
        - name: myapp
          image: registry.example.com/myapp:1.4.2
          ports:
            - name: http-metrics      # named port referenced by the ServiceMonitor
              containerPort: 8080
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          readinessProbe:
            httpGet: { path: /metrics, port: http-metrics }
            initialDelaySeconds: 5
            periodSeconds: 10
---
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: apps
  labels:
    app.kubernetes.io/name: myapp
spec:
  selector:
    app.kubernetes.io/name: myapp
  ports:
    - name: http-metrics
      port: 8080
      targetPort: http-metrics
---
# servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp
  namespace: apps
  labels:
    release: kube-prometheus-stack   # MUST match Prometheus.spec.serviceMonitorSelector
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: myapp   # selects the Service above
  namespaceSelector:
    matchNames: [apps]
  endpoints:
    - port: http-metrics              # matches Service port NAME, not number
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      scheme: http
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
      metricRelabelings:
        # drop noisy Go GC series to save cardinality
        - sourceLabels: [__name__]
          regex: go_gc_duration_seconds.*
          action: drop
```

### 9.2 PodMonitor (sin necesidad de Service)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: myapp
  namespace: apps
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: myapp
  podMetricsEndpoints:
    - port: http-metrics
      interval: 15s
      path: /metrics
```

### 9.3 Basado en anotaciones legacy (Prometheus vainilla)

```yaml
# in the Pod template metadata:
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
```

### Compromisos de los mecanismos de descubrimiento

| Mecanismo | Necesita Operator | Necesita Service | Granularidad | Mejor para |
|---|---|---|---|---|
| **ServiceMonitor** | ✅ | ✅ | Por endpoint de Service | Instrumentación estándar de apps |
| **PodMonitor** | ✅ | ❌ | Por Pod | Headless/StatefulSet, sin Service |
| **Anotaciones** | ❌ | ❌ | Por Pod | Prometheus vainilla, setups legacy |

---

## 10. Verificación por CLI y diagnóstico de fallas

**Paso 1 — ¿El endpoint sirve una salida válida y bien formada?**

```
$ curl -s http://localhost:8080/metrics | head -n 5
# HELP myapp_build_info Build metadata; value is always 1. Join on this in PromQL.
# TYPE myapp_build_info gauge
myapp_build_info{go_version="go1.22",revision="abc1234",version="1.4.2"} 1

$ curl -s http://localhost:8080/metrics | wc -l
187
```

**Paso 2 — Linteá con `promtool` (detecta violaciones de nomenclatura/formato antes que Prometheus):**

```
$ curl -s http://localhost:8080/metrics | promtool check metrics
myapp_http_requests_total counter metric should have "_total" suffix   # (already ok example)
latency_ms non-histogram and non-summary metric with "_ms" suffix; use base unit "seconds"
myapp_queue_size no help text
```

Un pase limpio es silencioso (exit 0). Conectá esto a tu CI para que una métrica mala nunca llegue a producción.

**Paso 3 — Negociá OpenMetrics / verificá exemplars:**

```
$ curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' \
    http://localhost:8080/metrics | grep -A0 '# {'
myapp_http_request_duration_seconds_bucket{route="/work",le="0.1"} 118 # {trace_id="4bf9..."} 0.087 1723200000.123
```

**Paso 4 — Confirmá que el target está UP en Prometheus:**

```
$ curl -s 'http://prometheus:9090/api/v1/query?query=up{job="myapp"}' | jq '.data.result'
[
  {
    "metric": { "job": "myapp", "instance": "10.1.2.3:8080", "node": "worker-2" },
    "value": [ 1723200015.0, "1" ]
  }
]
```

`up == 1` significa que el scrape tuvo éxito y el formato se parseó. `up == 0` con el target presente significa que se lo alcanzó pero falló (formato malo, timeout, no-200). Un target **ausente** significa que el service discovery no lo seleccionó.

**Paso 5 — Inspeccioná la salud y los errores del scrape:**

```
$ curl -s 'http://prometheus:9090/api/v1/query?query=scrape_samples_scraped{job="myapp"}' \
    | jq '.data.result[0].value[1]'
"187"

# Series produced by this job (cardinality watch)
$ curl -s 'http://prometheus:9090/api/v1/query?query=count({job="myapp"})' \
    | jq '.data.result[0].value[1]'
"42"
```

**Paso 6 — ¿El target fue siquiera descubierto? (kubectl / API de targets):**

```
$ curl -s http://prometheus:9090/api/v1/targets \
    | jq '.data.activeTargets[] | select(.labels.job=="myapp") | {health, scrapeUrl, lastError}'
{
  "health": "up",
  "scrapeUrl": "http://10.1.2.3:8080/metrics",
  "lastError": ""
}

$ kubectl -n monitoring logs deploy/prometheus -c prometheus | grep -i myapp | tail -3
```

### Matriz de troubleshooting

| Síntoma | Causa raíz | Diagnóstico | Corrección |
|---|---|---|---|
| Target ausente en Prometheus | Label del ServiceMonitor ≠ `serviceMonitorSelector`, o namespace no vigilado | `kubectl get servicemonitor -A --show-labels`; revisá `Prometheus.spec.serviceMonitorSelector` | Agregá la label `release:` coincidente / corregí el `namespaceSelector` |
| `up == 0`, `lastError: server returned HTTP 404` | `path` o `port` incorrecto en el monitor | Hacé `curl` directo a la IP del pod | Corregí el `path`/`port` nombrado |
| `up == 0`, "text format parsing error" | Exposición mal formada (handler hecho a mano, escapado incorrecto) | `curl … | promtool check metrics` | Usá la biblioteca de cliente; nunca concatenes strings |
| El counter "va hacia atrás" | Servidor multiproceso (gunicorn) sin modo multiproc | Scrapeá dos veces, compará | Fijá `PROMETHEUS_MULTIPROC_DIR` + `MultiProcessCollector` |
| `duplicate metrics collector registration attempted` (panic/excepción) | Métrica creada dentro de un handler de request, no una sola vez en la init | Stack trace en el registro | Creá las métricas una sola vez en la carga del paquete/módulo |
| OOM de Prometheus tras un deploy | Bomba de cardinalidad por una label no acotada | `topk(10, count by (__name__)({...}))` | Eliminá la label; usá `metricRelabelings` con `drop`/`labeldrop` |
| La consulta de latencia p99 está vacía | Nunca se cruzaron los buckets (todas las obs > `le` máximo) o agregación `le` incorrecta | inspeccioná las series `_bucket` | Reelegí los buckets; `sum by (le)` antes de `histogram_quantile` |
| Las métricas de batch nunca se limpian | El Pushgateway retiene el último push | `curl pushgateway:9091/metrics` | `DELETE` al grupo; alertá con `push_time_seconds` |

---

## 11. Checklist de arquitectura de referencia (producción)

1. **Un registry por componente lógico**; el registry por defecto solo para servicios simples de propósito único.
2. **Métricas definidas una sola vez** en la init, nunca dentro de los handlers.
3. **Histograms antes que summaries** salvo que necesites cuantiles exactos de una única instancia.
4. **Solo labels acotadas**; plantillas de ruta, no rutas crudas; *tipos* de error, no strings de error.
5. **Unidades base** (`_seconds`, `_bytes`), `_total` en los counters, `promtool check metrics` en CI.
6. **`/metrics` detrás de un readiness probe** y, en entornos hostiles, un proxy de autenticación / network policy — el endpoint filtra la topología interna.
7. **Exemplars + OpenMetrics** para tender un puente hacia las trazas; habilitá `exemplar-storage` del lado del servidor.
8. **Pushgateway solo para batch jobs a nivel de servicio**, siempre acompañado de una alerta de obsolescencia de `last_success`.
9. **Native histograms** donde estén soportados para reducir la cardinalidad y afinar los cuantiles.
10. **Scrapeate a vos mismo primero**: verificá con `curl` + `promtool` antes de culpar al service discovery.

---

## Referencias

- Prometheus — Bibliotecas de cliente (lista oficial y descripción general): https://prometheus.io/docs/instrumenting/clientlibs/
- Prometheus — Escribir bibliotecas de cliente (especificación para autores de bibliotecas): https://prometheus.io/docs/instrumenting/writing_clientlibs/
- Prometheus — Tipos de métrica (Counter, Gauge, Histogram, Summary): https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Formatos de exposición y negociación de contenido: https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — Buenas prácticas de nomenclatura de métricas y labels: https://prometheus.io/docs/practices/naming/
- Prometheus — Buenas prácticas de instrumentación: https://prometheus.io/docs/practices/instrumentation/
- Prometheus — Histograms y summaries (agregación e `histogram_quantile`): https://prometheus.io/docs/practices/histograms/
- Prometheus — Native histograms: https://prometheus.io/docs/specs/native_histograms/
- Biblioteca de cliente Go (`client_golang`): https://github.com/prometheus/client_golang · https://pkg.go.dev/github.com/prometheus/client_golang/prometheus
- Biblioteca de cliente Python (`client_python`): https://github.com/prometheus/client_python · Modo multiproceso: https://prometheus.github.io/client_python/multiprocess/
- Biblioteca de cliente Java (`client_java`): https://github.com/prometheus/client_java · https://prometheus.github.io/client_java/
- Biblioteca de cliente Ruby: https://github.com/prometheus/client_ruby
- Biblioteca de cliente Rust: https://github.com/prometheus/client_rust
- Pushgateway (uso y antipatrones): https://github.com/prometheus/pushgateway · https://prometheus.io/docs/practices/pushing/
- Exemplars y OpenMetrics: https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage · https://openmetrics.io/
- Prometheus Operator — API de ServiceMonitor / PodMonitor: https://prometheus-operator.dev/docs/operator/api/ · https://github.com/prometheus-operator/prometheus-operator
- `promtool` (check metrics): https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- Currículum PCA: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf