# PCA 5.2 — Instrumentación

> **Dominio:** Instrumentación y Exporters · **Peso en el examen:** 4
> **Perfil:** SRE / Platform Architect — instrumentación directa de nivel productivo con las client libraries de Prometheus.

La instrumentación es la disciplina de emitir telemetría *desde dentro del código que uno posee*. Es la frontera entre "monitorear una caja negra desde afuera con un exporter" y "la aplicación describiendo su propio comportamiento en un contrato legible por máquinas". Este tema trata sobre ese contrato: los cuatro tipos de métricas, el formato de exposición, la disciplina de nombres y labels, los detalles internos de las client libraries y los modos de falla que solo aparecen a escala productiva.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 La brecha de observabilidad que cierra la instrumentación directa

Un exporter (node_exporter, blackbox_exporter, mysqld_exporter) solo puede reportar lo que un sistema *expone externamente*: `/proc`, un admin socket, un health probe. No puede ver la semántica de *tu* request path — qué handler sirvió una request, si la transacción de negocio hizo commit, cuánto tardó el p99 del checkout, qué tan profunda está la work queue interna. Esas son propiedades que solo el propio proceso conoce. La **instrumentación directa** hace que el proceso las publique.

La decisión arquitectónica es esta: Prometheus es un sistema **pull-based**. Tu aplicación no envía métricas a ningún lado. Mantiene un registro en memoria de métricas y las expone por HTTP en `/metrics` en un formato de texto de exposición. Un servidor Prometheus *scrapea* ese endpoint a intervalos (típicamente 15–60 s), muestrea los valores actuales y los almacena como time series.

```
┌────────────────────────────────────────────────────────────┐
│  Application process                                         │
│                                                              │
│   business code ──increments──▶ in-process metric registry   │
│                                    │                         │
│                                    │ render on demand        │
│                                    ▼                         │
│                               GET /metrics  (text format)    │
└──────────────────────────────────────┬─────────────────────┘
                                        │ scrape every 15s
                                        ▼
                              ┌───────────────────┐
                              │  Prometheus server │──▶ TSDB
                              └───────────────────┘
```

Esto tiene tres consecuencias que dominan cada decisión de diseño en este tema:

1. **Las métricas se muestrean, no se transmiten en streaming.** Un counter incrementado 10.000 veces entre dos scrapes se observa como un único delta. El cliente nunca envía datos por evento — mantiene agregados en curso. Por eso los counters son monótonos y por eso computás `rate()` del lado del servidor.
2. **La cardinalidad es el costo.** Cada combinación única de nombre de métrica + conjunto de labels es una time series separada con su propio ~1–3 bytes/muestra de almacenamiento, su propia entrada de índice y su propia memoria en el head block. Las decisiones de instrumentación tomadas en una sola línea de código de aplicación se multiplican a lo largo de cada scrape target y viven durante todo el período de retención. Un label con valores no acotados (un user ID, un raw URL path, un UUID) es la manera más común de tirar abajo un servidor Prometheus.
3. **El endpoint debe ser barato y estar siempre disponible.** `/metrics` es scrapeado por potencialmente muchos servidores, está en el critical path del alerting y debe responder incluso cuando la app está degradada. Renderizarlo no debe bloquear estructuras críticas del negocio ni asignar memoria sin límite.

### 1.2 Qué debe garantizar una "buena instrumentación"

| Propiedad | Por qué importa en producción | Falla si se viola |
|---|---|---|
| **Aggregatable** | Las métricas de N réplicas deben sumar/promediar correctamente a lo largo de la flota | Los quantiles del lado del cliente (Summary) no se pueden re-agregar → el p99 de la flota no tiene sentido |
| **Cardinalidad acotada** | El conteo de series debe ser predecible y finito | OOM del head block, timeouts de scrape, inflado del índice |
| **Schema estable** | Los dashboards y las alertas referencian nombres/labels | Renombrar una métrica rompe silenciosamente cada alerta |
| **Base units** | PromQL, los dashboards y las personas esperan segundos/bytes | Mezclar ms y s produce cálculos de SLO erróneos |
| **Barato de renderizar** | `/metrics` está en el critical path del alerting | Timeout de scrape → target marcado como `down` → falsas alertas |

El resto de este documento es cómo se logra cada una de estas cosas de manera concreta.

---

## 2. Los cuatro tipos de métricas — mecánica y trade-offs

Las client libraries de Prometheus exponen exactamente cuatro tipos de métricas core. Elegir correctamente es la decisión de instrumentación de mayor apalancamiento.

### 2.1 Tabla comparativa

| Tipo | Semántica del valor | En restart | Trabajo del cliente | Time series expuestas | PromQL correcto | Agregable entre instancias |
|---|---|---|---|---|---|---|
| **Counter** | Float que crece monótonamente | Se resetea a 0 | Incremento O(1) | 1 (`_total`) | `rate()`, `increase()`, `irate()` | ✅ sí |
| **Gauge** | Float arbitrario que sube/baja | El valor es arbitrario | O(1) set/add/sub | 1 | valor crudo, `delta()`, `deriv()` | ✅ (sum/avg/max, contextual) |
| **Histogram** | Counters de buckets acumulativos + sum + count | Todos se resetean a 0 | O(log n) búsqueda de bucket | N buckets + `_sum` + `_count` | `histogram_quantile()` sobre `rate(_bucket)` | ✅ sí (los buckets son aditivos) |
| **Summary** | φ-quantiles computados por el cliente + sum + count | Los quantiles se resetean | O(estimación de quantile por streaming) | N quantiles + `_sum` + `_count` | leer `{quantile=...}` directamente | ❌ **los quantiles no se pueden re-agregar** |

### 2.2 Counter

Un **Counter** representa un total acumulativo que solo crece (o se resetea a cero al reiniciar el proceso). Requests servidas, errores, bytes procesados, tasks completadas. *Nunca* graficás el valor crudo del counter — graficás su tasa por segundo. Prometheus detecta el reset (una disminución) y compensa, así que `rate()` a lo largo de un restart sigue siendo correcto.

```go
requestsTotal := promauto.NewCounterVec(
    prometheus.CounterOpts{
        Namespace: "myapp",
        Name:      "http_requests_total",   // MUST end in _total
        Help:      "Total HTTP requests, by method, handler and status code.",
    },
    []string{"method", "handler", "code"},
)
// in the handler:
requestsTotal.WithLabelValues("GET", "/orders", "200").Inc()
```

**Anti-pattern:** usar un Gauge que incrementás manualmente para contar eventos. Perdés la detección de resets y la corrección de `increase()`. Si solo sube, es un Counter.

### 2.3 Gauge

Un **Gauge** es una instantánea de algo que sube y baja: requests in-flight, profundidad de queue, temperatura, memoria en uso, tamaño del connection pool. Es el único tipo donde el *valor instantáneo* es significativo.

```go
inflight := promauto.NewGauge(prometheus.GaugeOpts{
    Namespace: "myapp",
    Name:      "http_inflight_requests",
    Help:      "In-flight HTTP requests right now.",
})
inflight.Inc()          // request start
defer inflight.Dec()    // request end
// or set an observed value:
queueDepth.Set(float64(len(workQueue)))
```

**Precaución de diseño:** un Gauge muestreado en el momento del scrape se pierde los picos entre scrapes. Si te importa el *pico* de profundidad de queue, un Gauge subcuenta; considerá un gauge compañero `_max` que reseteás en cada ventana de scrape, o un Histogram de las profundidades observadas.

### 2.4 Histogram vs Summary — el trade-off central

Ambos miden distribuciones (latencia, tamaño de respuesta). La diferencia es *dónde se computa el quantile*, y es la distinción más evaluada de este dominio.

- **Histogram** cuenta observaciones en buckets **acumulativos** predefinidos (`le` = "less than or equal"). Envía conteos crudos de buckets. Los quantiles se computan **del lado del servidor** en el momento de la query con `histogram_quantile()`. Como los conteos de buckets son enteros aditivos simples, podés hacer `sum()` de los buckets a lo largo de todas las réplicas y *después* computar un quantile de toda la flota — esto es correcto.
- **Summary** computa φ-quantiles **del lado del cliente** usando un estimador por streaming sobre una ventana de tiempo deslizante, y envía los valores de quantile ya computados. No podés promediar un p99 de la instancia A con un p99 de la instancia B y obtener el p99 de la flota — ese cálculo es inválido. Los summaries tampoco pueden exponer un quantile arbitrario que no hayas preconfigurado.

| Dimensión | Histogram | Summary |
|---|---|---|
| Quantile computado | Del lado del servidor en el momento de la query | Del lado del cliente, φ preconfigurado |
| Agregable entre instancias | ✅ sí — sumar buckets, luego `histogram_quantile` | ❌ no — los quantiles no son aditivos |
| Quantiles arbitrarios a posteriori | ✅ cualquier quantile que los buckets puedan resolver | ❌ solo el φ que elegiste |
| Precisión | Acotada por los límites de los buckets | Alta por instancia (estimación por streaming) |
| CPU en el cliente | Barato (incremento de bucket) | Más costoso (estimación de quantile) |
| Cantidad de time series | 1 por bucket + `_sum` + `_count` | 1 por quantile + `_sum` + `_count` |
| Elección de bucket/quantile | Hay que elegir los buckets por adelantado | Hay que elegir los quantiles por adelantado |
| Mejor para | Latencia/tamaño en una flota, SLOs | Instancia única, quantiles exactos por instancia |

**Regla práctica de producción:** en Kubernetes, donde corrés N réplicas detrás de un Service, **usá Histogram por defecto**. Todo el objetivo es la latencia de toda la flota, y solo un Histogram te da un p99 agregable. Recurrí a Summary solo cuando tenés una sola instancia o genuinamente necesitás un quantile preciso por instancia que nunca vas a agregar.

```go
// Histogram — buckets in SECONDS, tuned to the SLO you care about
requestDuration := promauto.NewHistogramVec(
    prometheus.HistogramOpts{
        Namespace: "myapp",
        Name:      "http_request_duration_seconds",
        Help:      "HTTP request latency in seconds.",
        // Default is prometheus.DefBuckets; override to bracket your SLO thresholds.
        Buckets:   []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
    },
    []string{"method", "handler"},
)
timer := prometheus.NewTimer(requestDuration.WithLabelValues("GET", "/orders"))
defer timer.ObserveDuration()
```

Elegir buckets es una tarea de ingeniería real: los buckets deben encuadrar las latencias sobre las que tenés SLO. Si tu SLO es "99% bajo 300 ms", *tenés* que tener un límite de bucket en o cerca de `0.3`, o `histogram_quantile` interpola linealmente dentro del bucket y tu p99 es una suposición.

### 2.5 Native (sparse) histograms

Los histogramas clásicos fuerzan por adelantado un trade-off de bucket/cardinalidad. Los **native histograms** (a.k.a. sparse histograms, feature en track a GA, `--enable-feature=native-histograms` en el servidor; soportados en `client_golang` vía `NativeHistogramBucketFactor`) usan buckets exponenciales con un factor de resolución, almacenándolos como una única serie compacta y dinámicamente bucketizada. Esto da quantiles de alta resolución a una fracción de la cardinalidad y te permite cambiar la resolución sin re-instrumentar.

```go
requestDuration := promauto.NewHistogramVec(
    prometheus.HistogramOpts{
        Name:                            "myapp_http_request_duration_seconds",
        Help:                            "Latency, native histogram.",
        NativeHistogramBucketFactor:     1.1,   // ~10% relative bucket width
        NativeHistogramMaxBucketNumber:  160,   // cap bucket count to bound memory
        NativeHistogramMinResetDuration: time.Hour,
    },
    []string{"method", "handler"},
)
```

**Trade-off:** los native histograms necesitan Prometheus 2.40+ con la feature habilitada, el protocolo remote-write v2 (o 1.x con soporte nativo) y tooling (Grafana) que los entienda. En el examen y en la mayoría de los parques productivos actuales, los histogramas clásicos con buckets siguen siendo la base; los native histograms son la dirección hacia la que se va.

---

## 3. El formato de exposición — el contrato del wire

`/metrics` renderiza un formato de texto UTF-8. Entenderlo byte por byte es lo que te permite debuggear un scrape.

```
# HELP myapp_http_requests_total Total HTTP requests, by method, handler and status code.
# TYPE myapp_http_requests_total counter
myapp_http_requests_total{method="GET",handler="/orders",code="200"} 14027
myapp_http_requests_total{method="GET",handler="/orders",code="500"} 3
# HELP myapp_http_request_duration_seconds HTTP request latency in seconds.
# TYPE myapp_http_request_duration_seconds histogram
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.005"} 8000
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.01"}  10120
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.025"} 12500
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.05"}  13400
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.1"}   13900
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.25"}  14010
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="0.5"}   14025
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="1"}     14029
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="2.5"}   14030
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="5"}     14030
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="10"}    14030
myapp_http_request_duration_seconds_bucket{method="GET",handler="/orders",le="+Inf"}  14030
myapp_http_request_duration_seconds_sum{method="GET",handler="/orders"}   1893.4
myapp_http_request_duration_seconds_count{method="GET",handler="/orders"} 14030
# HELP myapp_http_inflight_requests In-flight HTTP requests right now.
# TYPE myapp_http_inflight_requests gauge
myapp_http_inflight_requests 7
```

Invariantes del formato que debés conocer:

- Cada serie es `metric_name{label="value",...} value [timestamp]`. El timestamp casi siempre se omite — el scrape lo asigna.
- `# HELP` y `# TYPE` son líneas de metadatos, una por metric family. `# TYPE` es uno de `counter`, `gauge`, `histogram`, `summary`, `untyped`.
- Los buckets de un histogram son **acumulativos**: `le="0.01"` incluye todo lo ≤ 10 ms, así que los conteos de buckets son no decrecientes, y el último bucket `le="+Inf"` es igual a `_count`.
- Un histogram de nombre `X` sintetiza las series `X_bucket`, `X_sum`, `X_count`. Un summary sintetiza `X{quantile=...}`, `X_sum`, `X_count`. **No podés además definir una métrica plana llamada `X_count`** — colisiona.
- **OpenMetrics** es el sucesor estandarizado por la IETF, más estricto que este formato (`# EOF` obligatorio, metadatos de unidad, soporte nativo de exemplars). Los clientes lo negocian vía el header `Accept`; Prometheus lo scrapea de forma transparente.

---

## 4. Nombres y labels — la disciplina del schema

Acá es donde la instrumentación triunfa o fracasa operacionalmente. Las reglas provienen de las [naming best practices](https://prometheus.io/docs/practices/naming/) oficiales.

### 4.1 Nombres de métricas

- `snake_case`, prefijado con un **namespace** de aplicación/librería de una sola palabra: `myapp_http_requests_total`.
- El sufijo lleva la **unidad**, y las unidades son **base units**: `_seconds` (no `_milliseconds`), `_bytes` (no `_kilobytes`), `_ratio` para 0–1.
- Los counters terminan en `_total`.
- El nombre identifica *una cosa lógica* — los labels diferencian dimensiones de ella. `myapp_http_requests_total{code="200"}`, **no** `myapp_http_200_requests_total`.

### 4.2 Labels y la bomba de cardinalidad

Cada combinación distinta de label-valor es una nueva time series. Total de series para una métrica ≈ producto de las cardinalidades de sus labels × número de scrape targets.

```
series = replicas × card(method) × card(handler) × card(code)
       = 20       × 4            × 30             × 6         = 14,400 series
```

Eso está bien. Ahora agregá `user_id` (500.000 usuarios): la métrica sola se vuelve **7,2 mil millones** de series potenciales. Va a hacer OOM el head block.

| Label bueno (acotado) | Label malo (no acotado) |
|---|---|
| `method` (GET/POST/… ~7) | `user_id`, `email`, `session_id` |
| `code` (2xx/3xx/4xx/5xx, o ~40 códigos) | request path completo con IDs (`/orders/8f3a...`) |
| `handler` (route template, ~docenas) | texto crudo de queries SQL |
| nombre de `queue`, `region`, `pod` (acotado por la flota) | timestamps, UUIDs, IDs no acotados |

**Reglas prácticas:**
- Mantené la cardinalidad total por target instrumentado en los pocos miles. Una sola metric family en las decenas de miles de series es un smell.
- Usá el **route template** (`/orders/{id}`), nunca el path concreto (`/orders/8f3a`).
- Nunca pongas un valor en un label si no podés enumerar el conjunto por adelantado.
- Si genuinamente necesitás granularidad por entidad, ese es trabajo para logs o traces (alta cardinalidad por diseño), no para métricas.

Los labels `pod`, `instance`, `namespace`, `job` suelen ser **target labels** adjuntados por Prometheus en el momento del scrape vía relabeling / service discovery — **no** los hardcodeás en tu instrumentación.

---

## 5. Detalles internos de las client libraries

### 5.1 Registries y collectors

Una client library mantiene un **Registry** — un conjunto de `Collector`s. Cuando se scrapea `/metrics`, el registry llama a `Collect()` en cada collector y transmite los resultados. La mayoría de las métricas que creás se auto-registran en el **default registry** (vía `promauto` en Go), pero el código de producción suele usar un registry explícito para aislamiento y testabilidad.

```go
package main

import (
    "log"
    "net/http"
    "time"

    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/collectors"
    "github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
    // Explicit registry — no globals, testable, isolates library metrics.
    reg := prometheus.NewRegistry()

    // Add the standard Go runtime + process collectors explicitly.
    reg.MustRegister(
        collectors.NewGoCollector(),
        collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
    )

    requests := prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Namespace: "myapp",
            Name:      "http_requests_total",
            Help:      "Total HTTP requests by method, handler, code.",
        },
        []string{"method", "handler", "code"},
    )
    duration := prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Namespace: "myapp",
            Name:      "http_request_duration_seconds",
            Help:      "HTTP request latency in seconds.",
            Buckets:   []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
        },
        []string{"method", "handler"},
    )
    reg.MustRegister(requests, duration)

    mux := http.NewServeMux()
    mux.HandleFunc("/orders", func(w http.ResponseWriter, r *http.Request) {
        timer := prometheus.NewTimer(duration.WithLabelValues(r.Method, "/orders"))
        defer timer.ObserveDuration()
        // ... business logic ...
        w.WriteHeader(http.StatusOK)
        requests.WithLabelValues(r.Method, "/orders", "200").Inc()
    })

    // Expose the registry. EnableOpenMetrics lets exemplars flow.
    mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{
        EnableOpenMetrics: true,
    }))

    srv := &http.Server{
        Addr:         ":8080",
        Handler:      mux,
        ReadTimeout:  5 * time.Second,
        WriteTimeout: 10 * time.Second,
    }
    log.Fatal(srv.ListenAndServe())
}
```

El **Go collector** (métricas `go_*`: goroutines, GC pauses, heap) y el **process collector** (`process_*`: open FDs, CPU, memoria residente) son instrumentación efectivamente gratis que siempre deberías registrar.

### 5.2 El problema multiproceso (Python / servidores prefork)

Prometheus asume que un proceso por scrape target sostiene todo el estado. Esto se rompe bajo servidores WSGI prefork (gunicorn con múltiples workers, uWSGI): cada worker tiene su propio registry, pero el scrape golpea *un* worker elegido por el load balancer, así que verías los números de un worker, al azar. El cliente de Python resuelve esto con el **multiprocess mode**: los workers escriben el estado de las métricas en archivos mapeados en memoria en un directorio compartido, y un collector especial los agrega en el momento del scrape.

```python
# gunicorn.conf.py
import os
from prometheus_client import multiprocess

def child_exit(server, worker):
    # Clean up a dead worker's mmap files so counters don't leak.
    multiprocess.mark_process_dead(worker.pid)
```

```python
# app.py
import os
from prometheus_client import (
    Counter, Histogram, CollectorRegistry, multiprocess,
    generate_latest, CONTENT_TYPE_LATEST,
)

REQUESTS = Counter(
    "myapp_http_requests_total",
    "Total HTTP requests.",
    ["method", "handler", "code"],
)
LATENCY = Histogram(
    "myapp_http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["method", "handler"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
)

def metrics_app(environ, start_response):
    # Aggregate across all worker mmaps at scrape time.
    registry = CollectorRegistry()
    multiprocess.MultiProcessCollector(registry)
    data = generate_latest(registry)
    start_response("200 OK", [("Content-Type", CONTENT_TYPE_LATEST)])
    return [data]
```

Correlo con el directorio compartido exportado a cada worker:

```bash
$ export PROMETHEUS_MULTIPROC_DIR=/var/run/prometheus
$ mkdir -p "$PROMETHEUS_MULTIPROC_DIR"
$ gunicorn -c gunicorn.conf.py -w 8 -b 0.0.0.0:8080 app:wsgi
```

**Gotcha:** en multiprocess mode, los Gauges necesitan un modo de agregación explícito (`multiprocess_mode='livesum' | 'liveall' | 'min' | 'max'`), y los runtime collectors del estilo `process_*` / `go_*` no agregan de forma significativa. El directorio debe estar en `tmpfs`/emptyDir y limpiarse entre restarts.

---

## 6. Infraestructura completa de Kubernetes (manifests sin abreviar)

Lo siguiente es un deployment con forma productiva: una app instrumentada, un Service, un `ServiceMonitor` del Prometheus Operator para el scraping, una alternativa con `PodMonitor` y un Pushgateway para batch jobs.

### 6.1 Deployment + Service de la aplicación instrumentada

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: shop
  labels:
    app.kubernetes.io/name: orders-api
    app.kubernetes.io/part-of: shop
spec:
  replicas: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: orders-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: orders-api
      annotations:
        # Annotation-based scraping (used when NOT running the Operator).
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: orders-api
          image: registry.example.com/shop/orders-api:1.8.2
          ports:
            - name: http
              containerPort: 8080
            - name: metrics          # dedicated named port is best practice
              containerPort: 8080
          env:
            - name: PROMETHEUS_MULTIPROC_DIR
              value: /var/run/prometheus
          volumeMounts:
            - name: prom-multiproc
              mountPath: /var/run/prometheus
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: prom-multiproc
          emptyDir:
            medium: Memory       # tmpfs — mmap files must not hit disk
---
apiVersion: v1
kind: Service
metadata:
  name: orders-api
  namespace: shop
  labels:
    app.kubernetes.io/name: orders-api
spec:
  selector:
    app.kubernetes.io/name: orders-api
  ports:
    - name: http
      port: 80
      targetPort: http
    - name: metrics                 # ServiceMonitor selects THIS named port
      port: 8080
      targetPort: metrics
```

### 6.2 ServiceMonitor (Prometheus Operator) — el camino idiomático

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: orders-api
  namespace: shop
  labels:
    # Must match the Prometheus CR's serviceMonitorSelector, or it is ignored.
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: orders-api
  namespaceSelector:
    matchNames:
      - shop
  endpoints:
    - port: metrics                 # references the Service port NAME, not number
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      scheme: http
      honorLabels: false
      relabelings:
        # Attach a stable "pod" target label from the discovered pod name.
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
      metricRelabelings:
        # Drop a chatty Go GC series family to control cardinality.
        - sourceLabels: [__name__]
          regex: go_gc_duration_seconds.*
          action: drop
```

### 6.3 PodMonitor (cuando no hay un Service, p. ej. peers de un StatefulSet)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: orders-worker
  namespace: shop
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: orders-worker
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
```

### 6.4 Config de scrape crudo de Prometheus (sin Operator)

Si corrés Prometheus sin el Operator, el equivalente a las annotations de arriba es un job `kubernetes_sd_configs` con relabeling:

```yaml
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # Only scrape pods opting in via annotation.
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      # Override the scrape path from annotation, default /metrics.
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      # Override host:port from the annotated port.
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      # Promote useful metadata to real labels.
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
```

### 6.5 Pushgateway — solo para batch/ephemeral jobs

La instrumentación directa asume un proceso de larga duración del que Prometheus puede hacer pull. Un cron/batch job puede terminar antes de que ocurra cualquier scrape. El **Pushgateway** es una caché a la que el job *empuja* sus métricas finales, y Prometheus scrapea el gateway.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pushgateway
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels: { app: pushgateway }
  template:
    metadata:
      labels: { app: pushgateway }
    spec:
      containers:
        - name: pushgateway
          image: prom/pushgateway:v1.9.0
          args:
            - --persistence.file=/data/pushgateway.store
            - --persistence.interval=5m
          ports:
            - { name: http, containerPort: 9091 }
          volumeMounts:
            - { name: data, mountPath: /data }
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-reconcile
  namespace: shop
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: reconcile
              image: registry.example.com/shop/reconcile:1.2.0
              command: ["/bin/sh", "-c"]
              args:
                - |
                  start=$(date +%s)
                  ./reconcile.sh
                  end=$(date +%s)
                  cat <<EOF | curl --data-binary @- \
                    http://pushgateway.monitoring:9091/metrics/job/nightly_reconcile/instance/$HOSTNAME
                  # TYPE reconcile_last_success_timestamp_seconds gauge
                  reconcile_last_success_timestamp_seconds $end
                  # TYPE reconcile_duration_seconds gauge
                  reconcile_duration_seconds $((end - start))
                  # TYPE reconcile_rows_processed_total counter
                  reconcile_rows_processed_total 48213
                  EOF
```

**Anti-patterns del Pushgateway (hay que saberlos):** **no** es una manera de convertir Prometheus a push para servicios de larga duración, **no** expira las métricas pusheadas por sí solo (una métrica batch obsoleta persiste hasta que se sobrescriba o se borre), y aplana el label `instance` (las métricas llevan los target labels del `pushgateway` salvo que pongas `honor_labels: true`). Usalo solo para **batch jobs de nivel de servicio**, y emparejá las métricas de éxito con una alerta sobre `time() - reconcile_last_success_timestamp_seconds`.

---

## 7. Comandos de CLI y salida real de terminal

### 7.1 Inspeccionar la exposición cruda

```bash
$ kubectl -n shop port-forward deploy/orders-api 8080:8080 &
$ curl -s localhost:8080/metrics | grep -E '^myapp_http_requests_total'
myapp_http_requests_total{code="200",handler="/orders",method="GET"} 14027
myapp_http_requests_total{code="500",handler="/orders",method="GET"} 3
myapp_http_requests_total{code="201",handler="/orders",method="POST"} 902
```

### 7.2 Validar el formato y lintear con promtool

```bash
$ curl -s localhost:8080/metrics | promtool check metrics
myapp_http_request_duration_seconds: non-histogram/summary metric "myapp_http_request_duration_seconds_sum" ... OK
$ echo $?
0
```

`promtool check metrics` detecta violaciones de nombres (falta de `_total`, unidades que no son base units, caracteres ilegales, colisiones de `_sum`/`_count`) — conectalo a CI contra un dump `/metrics` golden.

### 7.3 Confirmar que el target está up y siendo scrapeado

```bash
$ curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[]
           | select(.labels.job=="orders-api")
           | [.scrapeUrl, .health, .lastScrape, .lastScrapeDuration] | @tsv'
http://10.244.2.31:8080/metrics   up   2026-08-10T14:03:11.412Z   0.008
http://10.244.2.44:8080/metrics   up   2026-08-10T14:03:09.887Z   0.011
http://10.244.3.9:8080/metrics    up   2026-08-10T14:03:12.004Z   0.007
http://10.244.1.77:8080/metrics   up   2026-08-10T14:03:10.550Z   0.009
```

### 7.4 Consultar las señales instrumentadas (método RED)

```bash
# Request rate per handler over the last 5 minutes:
$ curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum by (handler) (rate(myapp_http_requests_total[5m]))' \
  | jq -r '.data.result[] | [.metric.handler, .value[1]] | @tsv'
/orders   23.47

# Error ratio (5xx / all):
$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=
    sum(rate(myapp_http_requests_total{code=~"5.."}[5m]))
  / sum(rate(myapp_http_requests_total[5m]))' \
  | jq -r '.data.result[0].value[1]'
0.000213

# Fleet-wide p99 latency — only correct because it is a Histogram:
$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=
    histogram_quantile(0.99,
      sum by (le) (rate(myapp_http_request_duration_seconds_bucket[5m])))' \
  | jq -r '.data.result[0].value[1]'
0.184
```

### 7.5 Contar la cardinalidad antes de que muerda

```bash
# Series count for one metric family:
$ curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=count(myapp_http_requests_total)' \
  | jq -r '.data.result[0].value[1]'
312

# Top metrics by series count (via TSDB status):
$ curl -s 'http://localhost:9090/api/v1/status/tsdb' \
  | jq -r '.data.seriesCountByMetricName[] | [.value, .name] | @tsv' | head
184320  myapp_http_request_duration_seconds_bucket
 45201  container_cpu_usage_seconds_total
 14400  myapp_http_requests_total
```

Esa primera línea — una familia de buckets de histogram en 184k series — es la señal de alarma: revisá si hay un label accidental de alta cardinalidad.

---

## 8. Verificación y diagnóstico de fallas

### 8.1 Árbol de decisión de diagnóstico

```
Target missing / no data in Prometheus?
│
├─ Is the target listed under /api/v1/targets?
│   ├─ NO  → discovery/selector problem
│   │        · ServiceMonitor label ≠ Prometheus serviceMonitorSelector
│   │        · Service port has no NAME, or name ≠ endpoints[].port
│   │        · namespaceSelector excludes the app namespace
│   │        · (annotation mode) prometheus.io/scrape != "true"
│   │
│   └─ YES → check .health
│       ├─ down + "connection refused"  → app not listening on that port
│       ├─ down + "context deadline exceeded" → /metrics too slow → scrapeTimeout
│       ├─ down + 404                    → wrong path (/metrics vs /actuator/prometheus)
│       ├─ down + 401/403                → auth/mTLS required, no bearer/TLS config
│       └─ up but no series              → metric never incremented, or wrong name
│
├─ Series exist but values look wrong?
│   ├─ Counter graphed raw (sawtooth on restart) → wrap in rate()/increase()
│   ├─ p99 impossibly flat / capped     → SLO threshold outside bucket range
│   ├─ Fleet p99 nonsensical            → used Summary; can't aggregate quantiles
│   └─ Duplicate/last-worker values      → Python prefork w/o multiprocess mode
│
└─ Prometheus itself unhealthy (OOM, slow)?
    └─ scrape_samples_scraped / TSDB status → runaway cardinality label
```

### 8.2 Las métricas de auto-observabilidad (salud del scrape)

Prometheus adjunta métricas sintéticas a cada scrape. Alertá sobre estas:

| Métrica | Significado | Alertar cuando |
|---|---|---|
| `up` | 1 si el scrape tuvo éxito, 0 si falló | `up == 0` |
| `scrape_duration_seconds` | Cuánto tardó `/metrics` en renderizar | se acerca a `scrapeTimeout` |
| `scrape_samples_scraped` | Series devueltas en este scrape | salto repentino → fuga de cardinalidad |
| `scrape_samples_post_metric_relabeling` | Series conservadas tras los drops de relabel | verificá que los drops realmente se apliquen |
| `scrape_series_added` | Churn de series nuevas por scrape | churn alto → label con valor inestable |

```bash
# Which targets are down right now:
$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=up == 0' \
  | jq -r '.data.result[] | [.metric.job, .metric.instance] | @tsv'
orders-api   10.244.3.9:8080

# Targets whose scrape is dangerously close to timing out:
$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=scrape_duration_seconds > 0.8 * scrape_samples_limit' 2>/dev/null

# Cardinality-leak canary — a target whose series count exploded:
$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=topk(5, scrape_samples_scraped)' \
  | jq -r '.data.result[] | [.value[1], .metric.job, .metric.instance] | @tsv'
187650  orders-api   10.244.2.31:8080   ← 100x the others: leak
1874    orders-api   10.244.2.44:8080
1871    orders-api   10.244.3.9:8080
```

### 8.3 Fallas comunes y su solución

| Síntoma | Causa raíz | Solución |
|---|---|---|
| `up == 0`, "connection refused" | metrics server no iniciado / puerto equivocado | exponé `/metrics` en el container port que nombra el Service |
| Target ausente por completo (Operator) | label del ServiceMonitor ≠ `serviceMonitorSelector` | agregá el label sobre el que selecciona la Prometheus CR |
| Target ausente, mismatch de puerto | el Service port no tiene `name`, o el nombre ≠ `endpoints.port` | nombrá el Service port; referenciá el nombre |
| `context deadline exceeded` | `/metrics` renderiza lento (cardinalidad enorme, locks) | reducí las series; subí `scrapeTimeout` como parche; renderizá sin locks |
| p99 plano en el borde de un bucket | el umbral del SLO no está encuadrado por un bucket | agregá un límite de bucket cerca del valor del SLO |
| Quantile de flota equivocado | usaste Summary, agregaste sus series `{quantile}` | cambiá a Histogram + `histogram_quantile` |
| Los valores saltan por scrape | Python prefork, sin multiprocess mode | habilitá `PROMETHEUS_MULTIPROC_DIR` + `MultiProcessCollector` |
| Los resets del counter parecen caídas | graficando el counter crudo | siempre `rate()`/`increase()` |
| Las series crecen para siempre | label no acotado (user_id, raw path, UUID) | quitá el label; usá route templates; movelo a logs/traces |
| La métrica del batch job nunca aparece | proceso de vida corta que termina antes del scrape | pusheá al Pushgateway con un agrupamiento job/instance |
| La métrica batch obsoleta nunca se limpia | el Pushgateway no expira | hacé DELETE del grupo al inicio del job; alertá sobre el last-success timestamp |

### 8.4 Correlacionar métricas con traces — exemplars

Un **exemplar** adjunta un trace ID muestreado a una observación específica de un histogram, permitiéndote saltar de "el bucket de latencia p99 se disparó" al trace exacto. Requiere exposición OpenMetrics y `--enable-feature=exemplar-storage` en el servidor.

```go
// Go: record an observation with an exemplar carrying the trace ID.
if obs, ok := duration.WithLabelValues("GET", "/orders").(prometheus.ExemplarObserver); ok {
    obs.ObserveWithExemplar(elapsed.Seconds(),
        prometheus.Labels{"trace_id": traceID})
}
```

```
# Exposition (OpenMetrics) — exemplar after the '#':
myapp_http_request_duration_seconds_bucket{handler="/orders",method="GET",le="0.5"} 14025 # {trace_id="a1b2c3d4"} 0.42 1.7e9
```

---

## 9. Metodologías de instrumentación (qué instrumentar)

Decidir *qué* métricas emitir es tan importante como la mecánica. Dos métodos canónicos y complementarios:

| Método | Aplica a | Señales | Tipos de métrica |
|---|---|---|---|
| **RED** (Rate, Errors, Duration) | servicios dirigidos por requests | request rate, error rate, distribución de latencia | Counter (rate, errors), Histogram (duration) |
| **USE** (Utilization, Saturation, Errors) | recursos (CPU, disco, queue) | qué tan lleno, qué tan atascado, conteo de errores | Gauge (utilization/saturation), Counter (errors) |

Un servicio bien instrumentado expone RED para su request path y USE para sus recursos internos (thread pools, connection pools, queues). Concretamente, la instrumentación mínima viable para un servicio HTTP son exactamente las tres métricas del ejemplo en Go de arriba: `*_requests_total` (Counter → Rate + Errors) y `*_request_duration_seconds` (Histogram → Duration), más un Gauge de in-flight para saturación.

---

## Referencias

- Prometheus — Instrumentation best practices: https://prometheus.io/docs/practices/instrumentation/
- Prometheus — Metric and label naming: https://prometheus.io/docs/practices/naming/
- Prometheus — Metric types (Counter, Gauge, Histogram, Summary): https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- Prometheus — Exposition formats: https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — Writing client libraries (guidelines): https://prometheus.io/docs/instrumenting/writing_clientlibs/
- Prometheus — Pushing metrics / Pushgateway usage: https://prometheus.io/docs/practices/pushing/
- Pushgateway project (README, when to use / not use): https://github.com/prometheus/pushgateway
- Go client library (`client_golang`): https://github.com/prometheus/client_golang and https://pkg.go.dev/github.com/prometheus/client_golang/prometheus
- Python client library (incl. multiprocess mode): https://github.com/prometheus/client_python
- Native histograms (design and status): https://prometheus.io/docs/specs/native_histograms/
- OpenMetrics specification: https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
- Exemplars: https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage and https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exemplars
- Prometheus Operator — ServiceMonitor / PodMonitor API: https://prometheus-operator.dev/docs/operator/design/
- `promtool check metrics`: https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- PCA curriculum (Instrumentation and Exporters domain): https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf