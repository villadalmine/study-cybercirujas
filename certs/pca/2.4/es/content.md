# PCA 2.4 — Modelo de Datos y Etiquetas

> **Dominio:** Prometheus Fundamentals · **Peso en el examen:** 4
> **Perfil del autor:** Principal Platform Architect / Senior SRE — profundidad de producción
> **Alcance:** la representación interna de una métrica en Prometheus, el sistema de etiquetas que le da dimensionalidad, la cardinalidad como el riesgo operativo dominante y la maquinaria de relabeling que te permite dar forma a las series *antes* de que sean ingestadas.

---

## 1. Motivación: por qué el modelo de datos es lo que decide si tu Prometheus sobrevive a producción

Todos los demás temas de esta certificación — PromQL, alerting, recording rules, federation — son consecuencia de una única decisión de diseño: **Prometheus almacena cada observación como una muestra que pertenece a una serie temporal identificada de forma única, y esa identidad es un nombre de métrica más un conjunto no ordenado de etiquetas clave/valor.**

Una única serie temporal en Prometheus es:

```
<metric_name>{<label_name>="<label_value>", ...}  ->  stream of (timestamp_ms, float64) samples
```

Concretamente, esta línea del formato de exposición:

```
http_requests_total{method="POST", handler="/api/v1/write", code="200"} 14872
```

**no** es "una métrica con tres etiquetas". Es una serie temporal específica cuya identidad completa — lo que la TSDB indexa, hashea y sobre lo que deduplica — es el conjunto entero de etiquetas *incluyendo el nombre de la métrica*. Internamente Prometheus almacena el nombre de la métrica como una etiqueta reservada llamada `__name__`. Así que la serie de arriba es idéntica a:

```
{__name__="http_requests_total", method="POST", handler="/api/v1/write", code="200"}
```

Esa equivalencia es el hecho más importante de este tema. Todo lo que viene después se deriva de ella:

- **La agregación es aritmética de conjuntos sobre etiquetas.** `sum by (code) (rate(http_requests_total[5m]))` funciona porque las etiquetas son las claves de agrupamiento.
- **La cardinalidad es combinatoria.** El número de series distintas es el *producto cartesiano* de los valores distintos de cada etiqueta. Una etiqueta mal elegida (un ID de usuario, un path de URL completo, un string de error crudo) multiplica tu cantidad de series sin límite.
- **El head block reside en memoria.** Cada serie activa mantiene un chunk en memoria más entradas de índice. La cantidad de series — no la cantidad de muestras, no la tasa de consultas — es el driver de primer orden del RSS de Prometheus.

### La falla de producción que este tema existe para prevenir

La caída arquetípica no es una consulta que se rompe. Es la **explosión de cardinalidad**: un desarrollador bien intencionado agrega una etiqueta cuyo valor es no acotado (`user_id`, `request_id`, `session`, `pod` para pods que rotan, una URL completa con IDs embebidos), un deploy lo lleva a producción, y durante las siguientes horas el head block de Prometheus crece de 500k series a 8M series. Síntomas, en orden de aparición:

1. `prometheus_tsdb_head_series` sube linealmente y no se aplana.
2. El RSS crece hasta que el proceso es OOM-killed por el kernel o por el `memory` limit de Kubernetes.
3. Al reiniciar, el WAL replay tarda decenas de minutos porque el WAL ahora es enorme, así que tu monitoreo está *caído durante el incidente que debería estar observando*.
4. Las consultas expiran porque las posting lists del índice invertido son enormes.

El sistema de etiquetas es por lo tanto una **superficie de planificación de capacidad**, no una conveniencia. El resto de este documento lo trata así.

---

## 2. El modelo de datos formal

### 2.1 Los cuatro constituyentes

| Constituyente | Definición | Restricciones |
|---|---|---|
| **Nombre de métrica** | Nombre legible por humanos de la magnitud medida, almacenado internamente como la etiqueta `__name__`. | Debe coincidir con `[a-zA-Z_:][a-zA-Z0-9_:]*` (legacy). Los dos puntos `:` están **reservados para recording rules** — nunca los emitas desde un exporter. |
| **Etiquetas** | Pares clave/valor que particionan un nombre de métrica en dimensiones. Junto con el nombre forman la identidad de la serie. | Los nombres coinciden con `[a-zA-Z_][a-zA-Z0-9_]*` (legacy). Los nombres que empiezan con `__` están **reservados para las internas de Prometheus**. Los valores son strings UTF-8 arbitrarios. |
| **Muestra** | Una única observación: un valor `float64` más un timestamp Unix `int64` con precisión de milisegundos. Las native histograms cargan un valor estructurado en lugar de un escalar. | Un valor de etiqueta vacío es semánticamente idéntico a que la etiqueta esté ausente. |
| **Timestamp** | `int64` milisegundos desde el epoch Unix. | Las muestras de Prometheus son casi en tiempo real; la ingestión fuera de orden es acotada y está desactivada por defecto (ver `out_of_order_time_window`). |

Formalmente, una serie temporal es el mapa:

```
identity  = { __name__: "...", label_a: "...", label_b: "...", ... }
series    = identity  ->  [ (t0, v0), (t1, v1), ... ]   monotonic in t
```

Dos muestras con la misma identidad y el mismo timestamp son un duplicado; Prometheus se queda con la primera y rechaza el resto dentro de un scrape.

### 2.2 Nombres UTF-8 (Prometheus 3.x)

Desde **Prometheus 3.0** (Nov 2024) los *nombres* de métricas y etiquetas pueden contener UTF-8 arbitrario, no solo el conjunto legacy `[a-zA-Z0-9_:]`. Esto importa en producción al scrapear datos de OpenTelemetry, donde nombres como `http.server.request.duration` y etiquetas como `service.name` son idiomáticos. Las reglas:

- El regex legacy ahora es el *esquema de validación legacy*; el *esquema UTF-8* es el default en 3.x.
- Los nombres que no son legacy-válidos deben ir entrecomillados en PromQL y en el formato de exposición:

```promql
{"http.server.request.duration", "service.name"="checkout"}
```

- Emitir nombres UTF-8 requiere la negociación de `escaping` de la exposición; los scrapers y exporters anuncian soporte vía el parámetro de content-type `escaping=allow-utf-8` del header `Accept`.

Trade-off a interiorizar: los nombres UTF-8 eliminan la capa de traducción "sanitizar puntos a guiones bajos" para los pipelines de OTel, pero fuerzan el entrecomillado en todas partes en PromQL y rompen el tooling que asumía el charset legacy. En un stack greenfield OTel-native, adoptalos; en un estate de Prometheus establecido, mantené la convención legacy (separadores `_`) para evitar una migración de reescritura de consultas.

### 2.3 El namespace reservado de etiquetas (`__`)

Estas etiquetas existen durante el descubrimiento de targets y el scraping; la mayoría se eliminan antes del almacenamiento a menos que las conserves explícitamente.

| Etiqueta | Significado | Vida útil |
|---|---|---|
| `__name__` | El nombre de la métrica. | **Persistida** — *es* el nombre. |
| `__address__` | El `host:port` que Prometheus va a scrapear. | Solo discovery/relabel; se convierte en `instance` si no lo sobreescribís. |
| `__scheme__` | `http` / `https`. | Solo discovery/relabel. |
| `__metrics_path__` | Path a scrapear (default `/metrics`). | Solo discovery/relabel. |
| `__param_<name>` | Parámetro de query URL `<name>` agregado a la petición de scrape. | Solo discovery/relabel. |
| `__meta_*` | Metadata de service-discovery (ej. `__meta_kubernetes_pod_label_app`). | Solo discovery/relabel — **nunca persistida**; debe copiarse a una etiqueta real para sobrevivir. |
| `__scrape_interval__`, `__scrape_timeout__` | Overrides por target. | Solo discovery/relabel. |
| `__tmp_*` | Convención para etiquetas de scratch que creás a mitad del relabel y querés que se ignoren. | Solo discovery/relabel. |

Las dos etiquetas que Prometheus adjunta automáticamente a cada muestra scrapeada son **`job`** (del `job_name` de la configuración de scrape) e **`instance`** (por defecto `__address__`). Estos son tus ejes de identidad primarios; todo lo demás es dimensión.

### 2.4 Tipos de métricas y cómo dan forma a las etiquetas

El tipo vive en la metadata `# TYPE`, no en la identidad — pero cada tipo impone una disciplina de etiquetas que debés respetar:

| Tipo | Huella de series | Disciplina de etiquetas |
|---|---|---|
| **counter** | 1 serie | Monotónico; sufijo `_total`. Nunca se resetea excepto al reiniciar el proceso (lo cual `rate()` maneja). |
| **gauge** | 1 serie | Sube/baja arbitrariamente. |
| **histogram** (clásico) | **`N buckets + 2`** series por conjunto de etiquetas | Emite `_bucket{le="..."}`, `_sum`, `_count`. La etiqueta `le` es una *dimensión reservada* — un histograma de 10 buckets es 12× la cardinalidad de un gauge con las mismas etiquetas. |
| **summary** | `M quantiles + 2` series | Emite `{quantile="..."}`, `_sum`, `_count`. Los cuantiles se computan del lado del cliente, no agregables entre instancias. |
| **native histogram** (3.x) | **1 serie** | Una única serie carga un esquema de buckets disperso de resolución dinámica. La respuesta de cardinalidad al bloat de buckets del histograma clásico. |

> **Nota del arquitecto:** el multiplicador del histograma clásico es la segunda causa más común de crecimiento silencioso de cardinalidad después de los valores de etiqueta no acotados. Un histograma `request_duration_seconds` con 15 buckets, a través de 4 métodos × 20 handlers × 3 codes, es `15+2 = 17` series por combinación × 240 combinaciones = **4.080 series** de una única métrica instrumentada en una instancia. Multiplicá por la cantidad de instancias. Las native histograms colapsan el `+15` a `+0`.

---

## 3. Cardinalidad: el trade-off dominante

**Cardinalidad de una métrica = la cantidad de combinaciones distintas de valores de etiqueta que produce.** Es multiplicativa entre etiquetas y aditiva entre instancias.

### 3.1 Modelo de cardinalidad trabajado

```
series(metric) = Π (distinct values of each label)   [per instance]
total_series   = Σ over instances series(metric)
```

Ejemplo — un counter de requests con etiquetas `method`, `handler`, `code`, `pod`:

| Etiqueta | Cardinalidad | ¿Acotada? |
|---|---|---|
| `method` | 5 (GET/POST/PUT/DELETE/PATCH) | ✅ conjunto cerrado |
| `handler` | 30 | ✅ conjunto cerrado (tabla de rutas) |
| `code` | 15 (2xx/3xx/4xx/5xx comunes) | ✅ acotada |
| `pod` | **crece con cada rollout** | ❌ no acotada en el tiempo |

Series por instante = 5 × 30 × 15 = **2.250**. Agregá `pod` (digamos 40 vivos) → 90.000. Ahora hacé rollout del deployment 10× al día durante una semana con una retención de 15 días y pods rotados aún indexados en el head hasta que expiren: el eje `pod` acumula silenciosamente. Por esto **`pod`, `container_id`, `image_id` se gestionan con relabel**, y por qué `user_id`/`request_id`/`email`/`full_path` crudos **nunca deben ser etiquetas** — son campos de logs/traces, no dimensiones de métricas.

### 3.2 Tabla de decisión etiqueta-buena vs etiqueta-mala

| Etiqueta candidata | Veredicto | Razón |
|---|---|---|
| `method`, `code`, `region`, `env`, `service`, `version` | ✅ | Acotada, conjunto cerrado, útil para agregación. |
| `handler`/`route` **con template** (`/users/:id`) | ✅ | Acotada a la tabla de rutas. |
| `handler`/`path` **crudo** (`/users/8134`) | ❌ | No acotada — una serie por ID. |
| `user_id`, `session_id`, `request_id`, `trace_id` | ❌❌ | No acotada, alta rotación — bomba de cardinalidad; pertenece a traces/logs. |
| `email`, `ip`, `hostname` (de clientes) | ❌ | No acotada y PII. |
| `error_message` (string crudo) | ❌ | No acotada; usá un `error_type`/`reason` acotado. |
| `le` (histogram), `quantile` (summary) | ⚠️ reservada | Gestionada por la librería cliente; no las seteás vos, pero presupuestá su multiplicador. |

**Regla general (memorizar para el examen y para el on-call):** una etiqueta es aceptable solo si podés nombrar todos los valores posibles que *alguna vez* va a tomar. Si el conjunto es abierto, no es una etiqueta.

### 3.3 Dónde se puede acotar la cardinalidad

| Capa | Mecanismo | Trade-off |
|---|---|---|
| **Instrumentación** | Elegir etiquetas acotadas; usar template en las rutas. | Lo más barato, pero requiere disciplina del desarrollador. |
| **Configuración de scrape** | `sample_limit`, `label_limit`, `label_name_length_limit`, `label_value_length_limit` — topes duros que **hacen fallar el scrape** si se exceden. | Contundente: una violación descarta el scrape del target *completo*, así que `up` va a 0. Protector pero ruidoso. |
| **`metric_relabel_configs`** | `drop`/`labeldrop`/`keep` después del scrape, antes del almacenamiento. | Quirúrgico; la herramienta estándar para domar una métrica que no controlás. |
| **Native histograms** | Reemplazan las series de buckets clásicos. | Requiere 3.x + soporte de la librería cliente + PromQL que las entienda. |
| **Recording rules + downsampling / remote write** | Pre-agregar y enviar series reducidas a almacenamiento de largo plazo (Thanos/Mimir/Cortex). | Mueve el problema, no lo borra; el costo local del head permanece. |

---

## 4. Manifiestos completos, de nivel producción

### 4.1 Configuración de scrape de Prometheus con el ciclo de vida de etiquetas completamente expresado

Este `prometheus.yml` muestra el pipeline completo de etiquetas: límites globales, Kubernetes SD, `relabel_configs` (dar forma al *target* antes de scrapear) y `metric_relabel_configs` (dar forma a las *muestras* después de scrapear, antes del almacenamiento).

```yaml
# prometheus.yml — production baseline for a Kubernetes-hosted target set
global:
  scrape_interval:     30s
  scrape_timeout:      10s
  evaluation_interval: 30s
  external_labels:
    cluster: prod-eu-west-1
    __replica__: prometheus-0        # used by Thanos/dedup; double-underscore = reserved

  # Estate-wide guardrails: a target that exceeds ANY of these fails its scrape.
  sample_limit: 50000                # max samples accepted per scrape
  label_limit: 30                    # max labels per series
  label_name_length_limit: 128
  label_value_length_limit: 512
  target_limit: 2000                 # max targets a single SD may yield

scrape_configs:
  - job_name: kubernetes-pods
    scrape_interval: 30s
    kubernetes_sd_configs:
      - role: pod

    relabel_configs:
      # 1. Only scrape pods explicitly opted-in via annotation.
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"

      # 2. Honor a custom metrics path annotation, default stays /metrics.
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)

      # 3. Rewrite __address__ to the annotated port (host:port -> host:annotatedport).
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__

      # 4. Promote useful __meta_* discovery labels into PERSISTED labels.
      #    __meta_* is stripped before storage, so copy what you want to keep.
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
        action: replace
        target_label: app
      - source_labels: [__meta_kubernetes_pod_node_name]
        action: replace
        target_label: node

      # 5. Map all pod labels generically, sanitizing '.' and '-' to '_'.
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)

      # 6. Drop the noisy internal pod-template-hash label if it leaked in.
      - action: labeldrop
        regex: pod_template_hash

    metric_relabel_configs:
      # A. Kill a known cardinality bomb: a raw-path histogram from a 3rd-party image.
      - source_labels: [__name__]
        regex: http_request_duration_seconds_bucket
        action: drop

      # B. Drop a per-request-id label that a library emits unbidden.
      - action: labeldrop
        regex: request_id

      # C. Keep only the metrics we actually alert/graph on from a chatty exporter.
      - source_labels: [__name__]
        regex: (go_gc_duration_seconds|go_goroutines|process_.*|http_requests_total|http_request_duration_seconds.*)
        action: keep
```

### 4.2 El lado del pod del contrato — anotaciones que impulsan el relabeling de arriba

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/version: "2.7.1"
spec:
  replicas: 3
  selector:
    matchLabels: { app.kubernetes.io/name: checkout }
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
        app.kubernetes.io/version: "2.7.1"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9102"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: checkout
          image: registry.example.com/checkout:2.7.1
          ports:
            - name: http-metrics
              containerPort: 9102
```

### 4.3 Instrumentación correcta — etiquetas acotadas, ruta con template, native histogram (cliente Go)

```go
package main

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	// Counter: bounded labels only. NOTE: no user_id, no raw path, no request_id.
	httpRequests = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests processed, partitioned by method, templated route and status code.",
		},
		[]string{"method", "route", "code"}, // route is the TEMPLATE, e.g. "/orders/:id"
	)

	// Native histogram: ONE series per label set, dynamic-resolution buckets.
	requestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:                            "http_request_duration_seconds",
			Help:                            "Request latency in seconds.",
			NativeHistogramBucketFactor:     1.1, // enables native histograms
			NativeHistogramMaxBucketNumber:  160,
			NativeHistogramMinResetDuration: time.Hour,
		},
		[]string{"method", "route", "code"},
	)
)

func instrument(method, route, code string, seconds float64) {
	httpRequests.WithLabelValues(method, route, code).Inc()
	requestDuration.WithLabelValues(method, route, code).Observe(seconds)
}

func main() {
	http.Handle("/metrics", promhttp.Handler())
	_ = http.ListenAndServe(":9102", nil)
}
```

La etiqueta `route` debe ser el **patrón de ruta coincidente** (`/orders/:id`), poblado desde tu router (`chi.RouteContext(r.Context()).RoutePattern()` de chi, `c.FullPath()` de gin, etc.) — *nunca* `r.URL.Path`, que carga el ID crudo y es no acotado.

---

## 5. Flujos de trabajo de CLI y terminal

### 5.1 Leer el formato de exposición directamente desde un target

```console
$ curl -s http://localhost:9102/metrics | grep -E '^http_requests_total'
# HELP http_requests_total Total HTTP requests processed, partitioned by method, templated route and status code.
# TYPE http_requests_total counter
http_requests_total{code="200",method="GET",route="/orders/:id"} 84213
http_requests_total{code="200",method="POST",route="/orders"} 12048
http_requests_total{code="404",method="GET",route="/orders/:id"} 317
http_requests_total{code="500",method="POST",route="/orders"} 6
```

Nota: el orden de las etiquetas en el formato de wire es irrelevante — `{a="1",b="2"}` y `{b="2",a="1"}` son la *misma* serie. Prometheus ordena las etiquetas internamente.

### 5.2 Inspeccionar la identidad de la serie vía la API HTTP

```console
$ curl -s -G 'http://localhost:9090/api/v1/series' \
    --data-urlencode 'match[]=http_requests_total{code="500"}' | jq .
{
  "status": "success",
  "data": [
    {
      "__name__": "http_requests_total",
      "code": "500",
      "instance": "10.42.3.17:9102",
      "job": "kubernetes-pods",
      "method": "POST",
      "namespace": "shop",
      "pod": "checkout-6f9c8b7d5c-2xk4p",
      "route": "/orders"
    }
  ]
}
```

Este es el pago del §2.1 hecho visible: la API devuelve el **mapa de identidad completo** incluyendo `__name__`, el `job`/`instance` adjuntados automáticamente, y las etiquetas que promovimos desde `__meta_*` durante el relabeling (`namespace`, `pod`).

### 5.3 Enumerar el conjunto de valores de una etiqueta — el test de olfato de cardinalidad

```console
$ curl -s 'http://localhost:9090/api/v1/label/route/values' | jq -r '.data[]' | head
/orders
/orders/:id
/health
/metrics

$ # If this returned thousands of numeric-looking values, the route label is RAW, not templated -> bomb.
```

### 5.4 Fundamentos del selector de series de PromQL

```promql
# Exact match on one label
http_requests_total{code="500"}

# Negative match
http_requests_total{code!="200"}

# Regex match / negation (fully anchored: ^...$ is implicit)
http_requests_total{route=~"/orders.*"}
http_requests_total{code!~"2.."}

# Select by metric name via __name__ (equivalent to naming it)
{__name__="http_requests_total", code="500"}

# Match a family of metrics by name regex — powerful and dangerous for cardinality
{__name__=~"http_.*", job="kubernetes-pods"}
```

Una regla de matcher vacío que al examen le gusta evaluar: **un selector debe tener al menos un matcher que no coincida con el string vacío.** `{code=~".*"}` solo es rechazado; `{__name__="x", code=~".*"}` está bien.

---

## 6. Verificación y diagnóstico de fallas

### 6.1 Dashboard de cardinalidad permanente — las cuatro consultas para mantener fijadas

```promql
# 1. Total live series in the head block (the number that OOM-kills you).
prometheus_tsdb_head_series

# 2. Series growth rate — should be ~flat in steady state; a positive slope = a leak.
deriv(prometheus_tsdb_head_series[30m])

# 3. Top metric names by series count (needs the metadata; approximate via count).
topk(10, count by (__name__)({__name__=~".+"}))

# 4. Per-job scrape sample volume — spikes precede series growth.
topk(10, scrape_samples_scraped)
```

### 6.2 El endpoint de estado de la TSDB incorporado — la primera parada en cualquier incidente de cardinalidad

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data | {numSeries, numLabelPairs, seriesCountByMetricName: .seriesCountByMetricName[0:5]}'
{
  "numSeries": 7841233,
  "numLabelPairs": 118402,
  "seriesCountByMetricName": [
    { "name": "http_request_duration_seconds_bucket", "value": 3120044 },
    { "name": "apiserver_request_duration_seconds_bucket", "value": 981220 },
    { "name": "http_requests_total", "value": 402118 },
    { "name": "container_memory_working_set_bytes", "value": 210338 },
    { "name": "go_gc_duration_seconds", "value": 88410 }
  ]
}
```

Los mismos datos se renderizan en **Status → TSDB Status** en la UI web, con cuatro tablas: *Top 10 series count by metric name*, *by label name*, *by label value pair*, y *memory usage by label name*. El infractor de arriba es obvio: un histograma `_bucket` clásico dominando con 3.1M series — el caso para un `metric_relabel_configs` drop o migrarlo a una native histogram.

### 6.3 Análisis forense offline con `promtool`

```console
$ promtool tsdb analyze /prometheus
Block ID: 01JQ8F3 V...
Duration: 2h0m0s
Series: 7841233
Label names: 214
Postings (unique label pairs): 118402

Label pairs most involved in churning series:
21134  __name__=http_request_duration_seconds_bucket
 9981  namespace=shop
 8820  le=+Inf

Highest cardinality labels:
1240233  pod
 402118  route          <-- red flag: 'route' should be bounded to the route table
   9932  le
    214  namespace

Highest cardinality metric names:
3120044  http_request_duration_seconds_bucket
 981220  apiserver_request_duration_seconds_bucket
```

`route` con 402k valores es el diagnóstico: alguien llevó a producción `r.URL.Path` en lugar del patrón con template. El eje `pod` en 1.24M es la rotación esperada (los pods van y vienen), pero si eclipsa la cantidad de pods vivos, la retención de WAL/head está manteniendo series obsoletas — chequeá `--storage.tsdb.head-chunks-write-queue-size` y la retención.

### 6.4 Verificar que un `metric_relabel_config` efectivamente tomó efecto

```console
$ # Before storage, confirm the target is discovered and its final (post-relabel) labels:
$ curl -s http://localhost:9090/api/v1/targets | \
    jq '.data.activeTargets[] | select(.labels.job=="kubernetes-pods") | {health, labels, lastError}' | head -30
{
  "health": "up",
  "labels": {
    "app": "checkout",
    "instance": "10.42.3.17:9102",
    "job": "kubernetes-pods",
    "namespace": "shop",
    "node": "ip-10-42-3-17",
    "pod": "checkout-6f9c8b7d5c-2xk4p"
  },
  "lastError": ""
}
```

`discoveredLabels` vs `labels` en este endpoint es el mejor debugger de relabel que existe: `discoveredLabels` es el conjunto `__meta_*` pre-relabel, `labels` es lo que sobrevivió para convertirse en la identidad persistida. Si falta una etiqueta que esperabas, tu regla de relabel la descartó o nunca la escribió.

### 6.5 Referencia de firmas de fallas

| Síntoma | Causa probable | Confirmar con | Solución |
|---|---|---|---|
| `up == 0` para un target que está sano | `sample_limit` / `label_limit` violado — Prometheus descarta el scrape completo | `scrape_samples_scraped` vs límite; el `lastError` del target muestra `sample limit exceeded` | Subir el límite *o* (mejor) `metric_relabel_configs: drop` de la métrica infractora |
| `numSeries` sube, nunca se aplana | Valor de etiqueta no acotado (path crudo, id, ip) | top label-value pairs de `/api/v1/status/tsdb`; `promtool tsdb analyze` | `labeldrop` de la etiqueta o arreglar la instrumentación para usar template |
| Una etiqueta desapareció después de agregar una regla | `__meta_*` no promovida, o un `labeldrop`/`replace` la aplastó | `/api/v1/targets` → comparar `discoveredLabels` vs `labels` | Agregar un `replace` para copiar `__meta_*` → etiqueta real *antes* del drop |
| `many-to-many matching not allowed` en PromQL | Dos selectores comparten identidad porque una etiqueta distinguidora fue descartada | `count by (...)` de ambos lados | Restaurar la etiqueta o usar `on()/ignoring()`/`group_left` |
| Dos series colapsaron en una | Un `replace`/`labeldrop` eliminó la única etiqueta que las distinguía → identidad duplicada → rechazo de muestra duplicada | `/api/v1/series` muestra menos series de las esperadas | Mantener una etiqueta distinguidora |
| La cantidad de series de histograma explota | Multiplicador de buckets de histograma clásico × alta cardinalidad de etiquetas | El estado de la TSDB muestra `_bucket` dominando | Reducir la cantidad de buckets, reducir las dimensiones de etiquetas, o migrar a native histograms |
| Etiquetas que difieren solo por valor vacío | `foo=""` tratado como ausente; las series se fusionan inesperadamente | `/api/v1/series` | Nunca dependas de etiquetas con string vacío como dimensión |

### 6.6 Validación pre-vuelo (atrapalo antes de que se despliegue)

```console
$ promtool check config prometheus.yml
Checking prometheus.yml
 SUCCESS: 1 rule files found
 SUCCESS: prometheus.yml is valid prometheus config file syntax

$ # Dry-run relabeling logic against a sample label set (Prometheus 2.51+):
$ promtool check config --lint-fatal prometheus.yml && echo "relabel + limits validated"
relabel + limits validated
```

---

## References

- Prometheus — Data model: https://prometheus.io/docs/concepts/data_model/
- Prometheus — Metric types: https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Metric and label naming best practices: https://prometheus.io/docs/practices/naming/
- Prometheus — Instrumentation & cardinality guidance: https://prometheus.io/docs/practices/instrumentation/
- Prometheus — Histograms and summaries (bucket cardinality): https://prometheus.io/docs/practices/histograms/
- Prometheus — Native histograms: https://prometheus.io/docs/specs/native_histograms/
- Prometheus — Configuration (`scrape_config`, limits, `relabel_configs`, `metric_relabel_configs`): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — Relabeling guide: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
- Prometheus — Querying basics (selectors, matchers, `__name__`): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — HTTP API (`/api/v1/series`, `/api/v1/labels`, `/api/v1/status/tsdb`, `/api/v1/targets`): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — Exposition formats and UTF-8 names: https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus 3.0 release notes (UTF-8 names, native histograms GA path): https://prometheus.io/blog/2024/11/14/prometheus-3-0/
- `promtool tsdb analyze` — storage docs: https://prometheus.io/docs/prometheus/latest/storage/
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf