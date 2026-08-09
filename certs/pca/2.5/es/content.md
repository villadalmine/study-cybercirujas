# 2.5 Formato de Exposición

> **Dominio:** Prometheus Fundamentals · **Clase de peso en el examen:** 4 (alta)
> **Temas prerequisito:** 2.3 Data Model & Labels, 2.4 Configuration & Scraping

---

## 1. El problema de producción que resuelve el formato de exposición

Prometheus es un sistema **basado en pull**. El servidor emite periódicamente un `GET` HTTP contra el endpoint `/metrics` de un target y parsea lo que sea que reciba. Esa única decisión de diseño crea un requisito arquitectónico que es fácil subestimar: **debe existir un contrato de cable (wire contract) que cualquier proceso, en cualquier lenguaje, sobre cualquier runtime, pueda implementar sin enlazar una biblioteca pesada y sin que el servidor sepa nada del target de antemano.**

El formato de exposición *es* ese contrato. Es la costura entre las dos mitades de un despliegue de Prometheus:

```
  ┌───────────────┐   HTTP GET /metrics    ┌──────────────────────┐
  │  Instrumented │  ◄───────────────────  │   Prometheus server  │
  │    target     │   text/plain body      │   (scrape + parse +  │
  │  (exporter)   │  ─────────────────►    │    ingest into TSDB) │
  └───────────────┘                        └──────────────────────┘
       exposes                                    consumes
```

Fuerzas de diseño que le dieron forma, y que tenés que poder defender en una revisión de diseño SRE:

| Fuerza | Consecuencia en el formato |
|---|---|
| **Flota políglota** — el target puede ser un servicio Go, un shell script, una app Java, un exporter de Postgres | El formato es texto UTF-8 orientado a líneas; un bucle `printf` es un exporter válido. Sin registro de esquemas, sin necesidad de codegen. |
| **Depurabilidad a las 3 de la mañana** | Un humano puede hacer `curl` al endpoint y leerlo. Esto es un requisito duro, no un lujo — es la herramienta primaria de triaje cuando un scrape se comporta mal. |
| **Scrape sin estado** | Cada scrape es un *snapshot completo* del estado actual. No hay protocolo de deltas, ni sesión, ni garantía de orden entre scrapes. El exporter mantiene el estado; el cable transporta un volcado completo en cada intervalo. |
| **Barato de producir** | Los counters son acumulativos (monótonos), así que el exporter nunca tiene que calcular tasas — eso se difiere a PromQL en tiempo de consulta. El único trabajo del exporter es imprimir los valores actuales. |
| **Autodescriptivo** | Los metadatos `# HELP` / `# TYPE` viajan en línea para que el servidor (y `promtool`) puedan hacer lint y razonar sobre la semántica sin configuración fuera de banda. |

El modelo mental crítico para el examen y para producción: **el formato de exposición es un snapshot de un estado instantáneo, no un flujo de eventos (event stream).** Si tu target se reinicia entre dos scrapes, el counter se resetea a cero y el *formato no tiene forma de decirte que eso pasó* — detectar el reset es tarea de `rate()`/`increase()` de PromQL en tiempo de consulta, ayudado por el timestamp `_created` en OpenMetrics.

---

## 2. Anatomía de una línea

Toda línea que no sea comentario sigue una gramática:

```
metric_name [ "{" label_name="label_value" ( "," label_name="label_value" )* "}" ] SP value [ SP timestamp ] LF
```

Concreto, anotado:

```
http_requests_total{method="POST",handler="/api/v1/write",code="200"} 1027 1699999999000
└────────┬────────┘└──────────────────┬──────────────────────────┘ └─┬─┘ └──────┬──────┘
   metric name              label set (the "instance vector" key)   value   optional timestamp
                                                                            (ms since epoch)
```

### 2.1 Reglas léxicas que se espera que sepas de memoria

| Elemento | Regla |
|---|---|
| **Nombre de métrica** | Regex `[a-zA-Z_:][a-zA-Z0-9_:]*`. Los dos puntos `:` están **reservados para recording rules** — nunca los uses en métricas instrumentadas directamente. |
| **Nombre de label** | Regex `[a-zA-Z_][a-zA-Z0-9_]*`. Los nombres con prefijo `__` están **reservados** para el interior de Prometheus (`__name__`, `__address__`, …) y se descartan tras el relabeling. |
| **Valor de label** | UTF-8 arbitrario. Debe escaparse (ver abajo). Un **valor de label vacío es semánticamente idéntico a que el label esté ausente** — `x{a=""}` y `x` son la misma serie. |
| **Valor** | Un `float64` de Go parseado por `strconv.ParseFloat`. Acepta `1.5e9`, `+Inf`, `-Inf`, `Nan`. Los enteros son simplemente floats sin parte fraccionaria. |
| **Timestamp** | `int64` opcional, **milisegundos** desde el epoch de Unix (formato de texto clásico). **Omitilo en casi todos los casos** — dejá que el servidor estampe el tiempo de ingesta. Los timestamps explícitos son solo para exporters de federación/proxy y están sujetos a las reglas de staleness y out-of-order del TSDB. |

### 2.2 Escapado — los dos conjuntos de reglas distintos (una fuente frecuente de bugs)

Las reglas de escapado difieren entre el texto de `HELP` y los valores de label:

| Contexto | Caracteres que DEBEN escaparse |
|---|---|
| Descripción `# HELP` | backslash `\` → `\\`, newline → `\n` |
| Valor de label | backslash `\` → `\\`, comilla doble `"` → `\"`, newline → `\n` |

Notá que en un **valor de label el newline es `\n`** pero los caracteres `#` y `=` *no* son especiales y no necesitan escaparse. Equivocarse en esto (p. ej. un blob JSON en un valor de label con comillas sin escapar) es una causa clásica de `text format parsing error`.

### 2.3 Comentarios de metadatos

Dos líneas de comentario cargan semántica; todo lo demás que empiece con `#` es un comentario libre y se ignora.

```
# HELP <metric_name> <single-line human description>
# TYPE <metric_name> <counter|gauge|histogram|summary|untyped>
```

Reglas que el parser impone:
- **Como máximo un `HELP` y un `TYPE` por nombre de métrica**, y deben aparecer **antes** de las muestras de esa métrica.
- Una segunda línea `HELP`/`TYPE` para el mismo nombre es un **error de parseo duro**.
- `untyped` (clásico) / `unknown` (OpenMetrics) significa "sin garantía semántica" — el servidor lo ingiere pero las funciones de PromQL que asumen monotonicidad (`rate`) no tienen sentido sobre él.

---

## 3. Los tipos de métrica en el cable

Solo existen **cuatro** tipos en el formato de texto clásico. La distinción vive enteramente en cómo se descompone un tipo *compuesto* en series de tiempo planas — el cable no tiene estructuras anidadas.

### 3.1 Counter y Gauge (atómicos)

```
# HELP process_cpu_seconds_total Total user and system CPU time spent in seconds.
# TYPE process_cpu_seconds_total counter
process_cpu_seconds_total 34412.7

# HELP node_memory_MemAvailable_bytes Memory available in bytes.
# TYPE node_memory_MemAvailable_bytes gauge
node_memory_MemAvailable_bytes 8.128757760e+09
```

### 3.2 Histogram (compuesto → `_bucket` + `_sum` + `_count`)

Un único histograma lógico explota en **N+2 series de tiempo**. Los buckets son **acumulativos** ("menor o igual que `le`") y el bucket `+Inf` es obligatorio y **debe igualar `_count`**.

```
# HELP http_request_duration_seconds Request latency in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.05"}  24054
http_request_duration_seconds_bucket{le="0.1"}   33444
http_request_duration_seconds_bucket{le="0.25"}  100392
http_request_duration_seconds_bucket{le="0.5"}   129389
http_request_duration_seconds_bucket{le="1"}     133988
http_request_duration_seconds_bucket{le="+Inf"}  144320
http_request_duration_seconds_sum   53423.0
http_request_duration_seconds_count 144320
```

Invariantes que un exporter correcto garantiza, y que `promtool` verificará:
- Los conteos de buckets son **monótonamente no decrecientes** a medida que crece `le`.
- El conteo del bucket `le="+Inf"` `== _count`.
- `_sum` puede *decrecer* solo si registrás observaciones negativas (raro, p. ej. temperatura) — con observaciones negativas, `rate()` sobre `_sum` deja de ser seguro.

### 3.3 Summary (compuesto → cuantiles + `_sum` + `_count`)

Los cuantiles (φ) se calculan **del lado del cliente, por instancia**, y por lo tanto **no pueden agregarse entre instancias** — la razón fundamental por la que los histogramas se prefieren en producción.

```
# HELP rpc_duration_seconds RPC latency, client-side quantiles.
# TYPE rpc_duration_seconds summary
rpc_duration_seconds{quantile="0.5"}   0.0123
rpc_duration_seconds{quantile="0.9"}   0.0489
rpc_duration_seconds{quantile="0.99"}  0.1732
rpc_duration_seconds_sum   1.7560e+04
rpc_duration_seconds_count 2.6932e+06
```

### 3.4 Histogram vs Summary — el trade-off de producción

| Dimensión | Histogram | Summary |
|---|---|---|
| Cuantil calculado | **En tiempo de consulta**, del lado del servidor, vía `histogram_quantile()` | **En tiempo de exposición**, del lado del cliente, conjunto φ fijo |
| Agregable entre instancias | **Sí** — sumá las series `_bucket`, luego calculá el cuantil | **No** — promediar cuantiles es estadísticamente sin sentido |
| Precisión | Acotada por los límites de bucket (tenés que elegir buenos cortes `le`) | Exacta para los φ configurados (dentro de la ventana deslizante del exporter) |
| Costo del exporter | Barato (incrementar un counter de bucket) | Mayor (estimador de cuantiles por streaming, memoria + CPU) |
| Cardinalidad en el cable | `buckets + 2` series por combinación de labels | `quantiles + 2` series por combinación de labels |
| ¿Cambiar el cuantil objetivo después? | Sí, reconsultá datos históricos | No — solo datos futuros, los cuantiles quedan congelados en la exposición |
| **Default de producción** | ✅ **Preferido** para SLOs de latencia/tamaño | Usar solo cuando necesitás un cuantil exacto de una sola instancia y nunca vas a agregar |

**Regla práctica para una revisión de diseño:** si la métrica alimenta un SLO calculado sobre una flota, debe ser un histograma. Los summaries son un último recurso.

### 3.5 Native (sparse) histograms — donde termina el formato de texto

Los histogramas clásicos te obligan a elegir a mano los límites `le` de antemano, cambiando cardinalidad por resolución. Los **native histograms** (Prometheus 2.40+, todavía detrás de `--enable-feature=native-histograms`) reemplazan los buckets fijos por buckets de esquema espaciados exponencialmente que se asignan dinámicamente.

Hecho crítico relevante para el examen: **los native histograms se exponen solo sobre el formato Protobuf, no sobre el formato de texto.** Son la razón más importante por la que la exposición Protobuf volvió a ser relevante después de haber sido deprecada. En text/OpenMetrics siempre vas a ver la descomposición clásica `_bucket`/`_sum`/`_count`.

---

## 4. Variantes de formato y negociación de contenido

Hay tres codificaciones de exposición en el universo Prometheus. El servidor y el target negocian vía los headers HTTP estándar `Accept`/`Content-Type`.

| Codificación | Valor de `Content-Type` | Estado | Notas |
|---|---|---|---|
| **Texto clásico** | `text/plain; version=0.0.4; charset=utf-8` | Default universal | Lo que muestra `curl`. Orientado a líneas, sin terminador. |
| **OpenMetrics** | `application/openmetrics-text; version=1.0.0; charset=utf-8` | Estándar de CNCF (evolucionado *a partir de* este formato) | Requiere `# EOF` al final; agrega exemplars, `_created`, `UNIT`, `info`/`stateset`. Timestamps en **segundos** (float). |
| **Protobuf** | `application/vnd.google.protobuf; proto=io.prometheus.client.MetricFamily; encoding=delimited` | Des-deprecado para native histograms | Binario, mensajes `MetricFamily` delimitados por longitud. Requerido para native histograms. |

### 4.1 El header Accept que envía un scraper real de Prometheus

```
Accept: application/openmetrics-text;version=1.0.0;q=0.5,text/plain;version=0.0.4;q=0.4,*/*;q=0.1
```

Con native histograms habilitados, el scraper antepone el tipo Protobuf con un `q` mayor:

```
Accept: application/vnd.google.protobuf;proto=io.prometheus.client.MetricFamily;encoding=delimited;q=0.75,application/openmetrics-text;version=1.0.0;q=0.5,text/plain;version=0.0.4;q=0.4
```

El target inspecciona `Accept` y responde con el mejor formato que puede producir, seteando `Content-Type` en consecuencia. El `promhttp.Handler()` de `client_golang` hace esto automáticamente.

### 4.2 OpenMetrics — el conjunto completo de features que le falta al formato de texto

```
# TYPE http_request_duration_seconds histogram
# UNIT http_request_duration_seconds seconds
# HELP http_request_duration_seconds A histogram of request duration.
http_request_duration_seconds_bucket{le="0.05"} 24054 # {trace_id="KOO5S4vxi0oEKfa4"} 0.032 1699999999.412
http_request_duration_seconds_bucket{le="0.1"} 33444
http_request_duration_seconds_bucket{le="+Inf"} 144320
http_request_duration_seconds_sum 53423.0
http_request_duration_seconds_count 144320
http_request_duration_seconds_created 1699900000.0
# TYPE build info
# HELP build Build metadata.
build_info{version="1.4.2",revision="a1b2c3d"} 1
# EOF
```

Diferencias respecto del texto clásico que importan en producción:

| Feature de OpenMetrics | Qué agrega | Por qué te importa |
|---|---|---|
| Terminador `# EOF` | Fin de flujo explícito | El scraper puede detectar un **cuerpo truncado** (conexión cortada a mitad del scrape) en vez de ingerir silenciosamente un snapshot parcial. |
| **Exemplars** (`# {trace_id="…"} value ts`) | Un ID de trace/span muestreado adjunto a un bucket/muestra | Correlación métricas-a-traces. Requiere `--enable-feature=exemplar-storage` en el servidor. |
| `_created` | El tiempo Unix en que la serie fue creada por primera vez | Permite que `rate()`/`increase()` detecten un reset de counter con precisión en vez de inferirlo. |
| `# UNIT` | Metadato de unidad legible por máquina | Habilita a la UI/tooling a renderizar/validar unidades (`seconds`, `bytes`). |
| Tipos `info`, `stateset` | "labels-como-valor" y estado enum de primera clase | Más limpio que el truco del gauge=1 con sufijo `_info` del texto clásico. |
| El `_total` del counter es **obligatorio** | La línea de muestra es `foo_total`, `# TYPE foo counter` | Impone la convención de nombres que el linter solo advierte. |

### 4.3 Nombres UTF-8 (Prometheus 3.0+)

Desde Prometheus 3.0, los **nombres** de métricas y labels **pueden contener UTF-8 arbitrario** (p. ej. puntos, para alinearse con OpenTelemetry). Tales nombres se exponen usando una **sintaxis entre comillas** y se negocian con un parámetro `escaping` en el header `Accept` (`allow-utf-8`, `underscores`, `dots`, `values`):

```
# HELP "http.server.request.duration" Request duration.
# TYPE "http.server.request.duration" histogram
{"http.server.request.duration",le="0.1","http.route"="/api"} 33444
```

Para un examen cuya versión es *desconocida*, tratá esto como una capacidad avanzada y a futuro: sabé que existe, que los nombres van entre comillas, y que el tooling legacy todavía espera el charset `[a-zA-Z_:][a-zA-Z0-9_:]*` a menos que se negocie UTF-8 explícitamente.

---

## 5. Ejemplos completos y ejecutables

### 5.1 Un exporter mínimo con nada más que `printf` (prueba la afirmación "cualquier lenguaje")

```bash
#!/usr/bin/env bash
# tiny_exporter.sh — a valid Prometheus target in pure shell + socat.
# Serves the classic text exposition format on :9101/metrics.
set -euo pipefail

render_metrics() {
  local load_1m mem_avail
  load_1m=$(awk '{print $1}' /proc/loadavg)
  mem_avail=$(awk '/MemAvailable/ {print $2 * 1024}' /proc/meminfo)

  cat <<EOF
# HELP node_load1 1m load average (custom shell exporter).
# TYPE node_load1 gauge
node_load1 ${load_1m}
# HELP node_memory_MemAvailable_bytes Available memory in bytes.
# TYPE node_memory_MemAvailable_bytes gauge
node_memory_MemAvailable_bytes ${mem_avail}
# HELP shell_exporter_scrapes_total Number of times metrics were rendered.
# TYPE shell_exporter_scrapes_total counter
shell_exporter_scrapes_total ${SCRAPES:-1}
EOF
}

body=$(render_metrics)
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nContent-Length: %d\r\n\r\n%s' \
  "${#body}" "$body"
```

```bash
$ socat TCP-LISTEN:9101,reuseaddr,fork EXEC:./tiny_exporter.sh &
$ curl -s localhost:9101/metrics
# HELP node_load1 1m load average (custom shell exporter).
# TYPE node_load1 gauge
node_load1 0.42
# HELP node_memory_MemAvailable_bytes Available memory in bytes.
# TYPE node_memory_MemAvailable_bytes gauge
node_memory_MemAvailable_bytes 8128757760
# HELP shell_exporter_scrapes_total Number of times metrics were rendered.
# TYPE shell_exporter_scrapes_total counter
shell_exporter_scrapes_total 1
```

### 5.2 La instrumentación idiomática de Go (lo que produce `client_golang`)

```go
package main

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var httpDuration = promauto.NewHistogramVec(
	prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "Duration of HTTP requests in seconds.",
		Buckets: prometheus.DefBuckets, // .005 .01 .025 .05 .1 .25 .5 1 2.5 5 10
	},
	[]string{"handler", "method", "code"},
)

func main() {
	// promhttp.Handler() performs content negotiation:
	// classic text, OpenMetrics, or protobuf depending on Accept.
	http.Handle("/metrics", promhttp.Handler())
	_ = http.ListenAndServe(":8080", nil)
}
```

El handler emite, automáticamente, los collectors de proceso y runtime junto con tus métricas personalizadas:

```bash
$ curl -s localhost:8080/metrics | head -n 24
# HELP go_goroutines Number of goroutines that currently exist.
# TYPE go_goroutines gauge
go_goroutines 11
# HELP go_memstats_alloc_bytes Number of bytes allocated and still in use.
# TYPE go_memstats_alloc_bytes gauge
go_memstats_alloc_bytes 2.371456e+06
# HELP http_request_duration_seconds Duration of HTTP requests in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{code="200",handler="/",method="get",le="0.005"} 12
http_request_duration_seconds_bucket{code="200",handler="/",method="get",le="0.01"} 27
http_request_duration_seconds_bucket{code="200",handler="/",method="get",le="+Inf"} 41
http_request_duration_seconds_sum{code="200",handler="/",method="get"} 0.183
http_request_duration_seconds_count{code="200",handler="/",method="get"} 41
# HELP process_cpu_seconds_total Total user and system CPU time spent in seconds.
# TYPE process_cpu_seconds_total counter
process_cpu_seconds_total 0.42
# HELP process_resident_memory_bytes Resident memory size in bytes.
# TYPE process_resident_memory_bytes gauge
process_resident_memory_bytes 1.9349504e+07
```

### 5.3 La configuración de scrape que lo consume

```yaml
# prometheus.yml — the server side of the contract
global:
  scrape_interval: 15s
  scrape_timeout: 10s

scrape_configs:
  - job_name: "shell-exporter"
    metrics_path: /metrics          # default; shown for clarity
    scheme: http
    static_configs:
      - targets: ["localhost:9101"]

  - job_name: "go-app"
    static_configs:
      - targets: ["localhost:8080"]
    # Guardrails that protect the server from a misbehaving exposition body:
    sample_limit: 100000            # abort the scrape if the body yields > N samples
    label_limit: 30                 # max labels per series
    label_name_length_limit: 200
    label_value_length_limit: 1000
    body_size_limit: 10MB           # cap the /metrics response body
    # Ask the target for OpenMetrics so we can ingest exemplars:
    # (Prometheus negotiates this automatically; exemplar storage still
    #  requires --enable-feature=exemplar-storage on the server.)
```

### 5.4 Kubernetes: cómo un Pod se convierte en un target de scrape (ServiceMonitor)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: go-app
  labels:
    app: go-app
spec:
  selector:
    app: go-app
  ports:
    - name: metrics          # named port — referenced by the ServiceMonitor
      port: 8080
      targetPort: 8080
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: go-app
  labels:
    release: kube-prometheus-stack   # matched by the Prometheus CR's serviceMonitorSelector
spec:
  selector:
    matchLabels:
      app: go-app
  endpoints:
    - port: metrics          # matches the Service's named port
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      honorLabels: false     # server-side job/instance labels win over exposed ones
```

---

## 6. Verificación y diagnóstico de fallos

El formato de exposición es donde vive en realidad una gran fracción de los incidentes reales de "mi métrica falta". Acá está la escalera de diagnóstico, del peldaño más barato primero.

### 6.1 Leé el cuerpo directamente (siempre el paso uno)

```bash
$ curl -sv localhost:8080/metrics -o /dev/null 2>&1 | grep -i content-type
< Content-Type: text/plain; version=0.0.4; charset=utf-8
```

Si el `Content-Type` es `text/html` o `application/json`, el endpoint no es un exporter — estás haciendo curl al path equivocado o a una página de error de un reverse-proxy.

### 6.2 Hacé lint con `promtool` (parseo + chequeos de convención de nombres)

`promtool check metrics` lee un cuerpo de exposición desde **stdin**, falla ante errores de parseo, y advierte sobre violaciones de la convención de nombres:

```bash
$ curl -s localhost:8080/metrics | promtool check metrics
myapp_requests: counter metrics should have "_total" suffix
myapp_temperature_celsius: non-histogram and non-summary metrics should not have "_sum" suffix

$ echo $?
3          # non-zero → CI can gate on this
```

Un target limpio:

```bash
$ curl -s localhost:9101/metrics | promtool check metrics
$ echo $?
0
```

Forzá el parseo estricto de OpenMetrics para atrapar un `# EOF` faltante:

```bash
$ curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' localhost:8080/metrics \
    | promtool check metrics
```

### 6.3 Las métricas de scrape autogeneradas — tu telemetría de caja negra

Para **cada** scrape, el servidor sintetiza estas series contra el `{job,instance}` del target. Consultalas para diagnosticar sin tocar el target:

| Serie | Significado | Qué te dice un valor malo |
|---|---|---|
| `up` | `1` scrape ok, `0` fallido | `0` → connection refused, timeout, error TLS, status no-2xx. El cuerpo nunca fue parseado. |
| `scrape_duration_seconds` | Tiempo de reloj del scrape | Cerca de `scrape_timeout` → el target es lento para renderizar `/metrics` (collectors costosos). |
| `scrape_samples_scraped` | Muestras en el cuerpo **antes** del relabeling | `0` con `up=1` → el endpoint devolvió 200 pero un cuerpo vacío/HTML. |
| `scrape_samples_post_metric_relabeling` | Muestras conservadas **después** de `metric_relabel_configs` | Mucho menor que `scraped` → tus reglas de relabel `drop` están comiéndose series. |
| `scrape_series_added` | Series nuevas en este scrape vs la rotación (churn) del target | Persistentemente alto → **explosión de cardinalidad / churn de labels** desde la exposición. |

```
# "Which targets are down right now?"
up == 0

# "Which targets are close to the sample_limit and will soon be dropped?"
scrape_samples_scraped > 90000

# "Where is cardinality churning?"
topk(10, scrape_series_added)
```

Nota: cuando `up == 0`, las métricas de scrape *distintas de `up`* pueden estar ausentes — el parseo nunca sucedió.

### 6.4 Catálogo de fallos de parseo de exposición

Estos aparecen en la página del target en la UI (`Status → Targets`) en la columna "Error", y en el log del servidor.

| Mensaje de error (representativo) | Causa raíz | Solución |
|---|---|---|
| `text format parsing error in line N: ...` | Línea malformada: float inválido, `"` sin escapar en un valor de label, whitespace suelto | Corregí la línea ofensora; volvé a correr `promtool check metrics`. |
| `second HELP line for metric name "x"` | `# HELP`/`# TYPE` duplicado para una métrica | Emití los metadatos exactamente una vez, antes de las muestras. |
| `duplicate sample for timestamp` / collector: `collected metric "x" ... was collected before with the same name and label values` | **Dos series idénticas (mismo nombre + mismo conjunto de labels)** en un scrape | Tenés un duplicado real — usualmente un bug que genera el mismo labelset dos veces. El scrape entero se rechaza. |
| `sample_limit exceeded (N)` | El cuerpo produjo más muestras que `sample_limit` | Reducí la cardinalidad (quitá labels de alta cardinalidad) o subí el límite deliberadamente. |
| `label_limit exceeded` / `label_value_length_limit exceeded` | Una serie tiene demasiados labels / un valor de label sobredimensionado | Corregí la instrumentación; nunca pongas valores no acotados (request IDs, URLs completas) en labels. |
| `server returned HTTP status 404 Not Found` | `metrics_path` equivocado | Apuntá la config de scrape al path real. |
| `unexpected end of OpenMetrics text` / `# EOF` faltante | Cuerpo truncado o productor de OpenMetrics no conforme | El guard `# EOF` hizo su trabajo — el scrape fue truncado; investigá el target / proxy. |

### 6.5 Reproduciendo la negociación de contenido para un scrape que falla

Para ver exactamente lo que ve el servidor, reproducí su header `Accept`:

```bash
$ curl -s \
    -H 'Accept: application/openmetrics-text;version=1.0.0;q=0.5,text/plain;version=0.0.4;q=0.4' \
    localhost:8080/metrics | tail -n 3
http_request_duration_seconds_count{code="200",handler="/",method="get"} 41
target_info{version="1.4.2"} 1
# EOF          # ← present ⇒ OpenMetrics was served and the body is complete
```

Si acá falta `# EOF`, el target no honró la negociación de OpenMetrics y el servidor cayó de vuelta al texto clásico — verificá el `Content-Type` devuelto antes de asumir que los exemplars se van a ingerir.

### 6.6 Verificando la integridad de un histograma a mano

```bash
$ curl -s localhost:8080/metrics \
  | awk '/http_request_duration_seconds_bucket/ && /method="get"/ {print $NF, $0}' \
  | sort -n
12  http_request_duration_seconds_bucket{...le="0.005"} 12
27  http_request_duration_seconds_bucket{...le="0.01"}  27
41  http_request_duration_seconds_bucket{...le="+Inf"}  41   # == _count ✓, monotonic ✓
```

Dos invariantes que confirmar: los conteos de buckets nunca decrecen a medida que crece `le`, y el bucket `+Inf` iguala a `_count`. Una violación significa un exporter roto y producirá resultados sin sentido de `histogram_quantile()` aguas abajo.

---

## 7. Conclusiones operativas para una revisión de diseño

- El formato de exposición es un **snapshot completo sin estado** en texto legible por humanos; los counters son acumulativos, así que la matemática de tasas se difiere a PromQL.
- **Cuatro tipos de cable** (counter, gauge, histogram, summary); los compuestos se aplanan en series `_bucket`/`_sum`/`_count` y `quantile`/`_sum`/`_count`. No hay anidamiento en el cable.
- Preferí **histogramas sobre summaries** siempre que la métrica vaya a agregarse entre instancias — los cuantiles no pueden promediarse.
- **OpenMetrics** es la evolución estandarizada: `# EOF`, exemplars, `_created`, `UNIT`. **Protobuf** es requerido específicamente para **native histograms**.
- Tu primera herramienta de diagnóstico es `curl`; la segunda es `promtool check metrics`; la tercera son las series autogeneradas `up` / `scrape_samples_*` / `scrape_series_added`.
- Protegé el servidor con `sample_limit`, `label_limit` y `body_size_limit` — un cuerpo de exposición que se comporta mal es un riesgo real de disponibilidad para el TSDB, no solo un problema de calidad de datos.

---

## Referencias

- Prometheus — Exposition formats: https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — Metric and label naming best practices: https://prometheus.io/docs/practices/naming/
- Prometheus — Metric types: https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- Prometheus — Configuration (`scrape_config`, limits, relabeling): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — `promtool` and tooling: https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- Prometheus — Native histograms: https://prometheus.io/docs/specs/native_histograms/
- Prometheus 3.0 — UTF-8 support in names: https://prometheus.io/docs/guides/utf8/
- OpenMetrics specification (v1.0.0): https://github.com/prometheus/OpenMetrics/blob/main/specification/OpenMetrics.md
- Exemplars: https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- `client_golang` (`promhttp`, `promauto`): https://github.com/prometheus/client_golang
- prometheus-operator — ServiceMonitor API: https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.ServiceMonitor
- CNCF PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf