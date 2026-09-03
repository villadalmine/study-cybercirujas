# 704.2 — Monitorización con Prometheus

**Certificación:** LPI DevOps Tools Engineer — Examen 701-100, versión de syllabus 2.0.0
**Tema:** 704 — Gestión de logs y monitorización · **Objetivo 704.2** — Monitorización con Prometheus
**Peso en el examen:** 10 (el objetivo más pesado del examen — esperá varias preguntas sobre arquitectura, PromQL y alertado)

**Alcance cubierto acá** (resumen propio del objetivo publicado; el texto oficial está en la URL de LPI en *Referencias*): la arquitectura y la mecánica interna de Prometheus, su modelo de datos y sus tipos de métrica, la configuración de scrape y el service discovery, los exporters y la instrumentación, PromQL, las reglas de recording y de alerting, el enrutamiento en Alertmanager y la visualización con Grafana.

---

## 1. Motivación: el problema arquitectónico para el que se construyó Prometheus

### 1.1 Qué se rompió en la generación anterior

Antes de 2012, la monitorización se construía alrededor de **hosts y checks**. Nagios pregunta "¿está `/dev/sda1` por encima del 90% en `web03`?", recibe de vuelta un código de salida (`0/1/2/3`) y una cadena legible por humanos. Ese modelo se apoya en tres supuestos que una plataforma de contenedores destruye:

| Supuesto de la monitorización basada en checks | Por qué falla en una plataforma moderna |
|---|---|
| La unidad de fallo es un **host con nombre**, conocido de antemano y de larga vida | Los Pods se crean y destruyen continuamente; `web-7d9f5c-x4k2p` no va a existir mañana. Una lista estática de hosts está obsoleta antes de commitearse. |
| Un check devuelve **un veredicto** (OK/WARN/CRIT) | Un veredicto no se puede re-agregar. No podés preguntar "cuál es la latencia p99 a lo largo de las 40 réplicas de este servicio" a partir de 40 booleanos. |
| Los umbrales son **por host** | Con autoescalado, los umbrales por host no significan nada. La pregunta interesante es por *servicio*, segmentada por versión, región, endpoint. |
| El estado vive en el **agente que chequea** | El check conoce solo el *ahora*. No hay historia a la que preguntarle "¿ya se estaba degradando antes del despliegue?" |

Graphite y StatsD mejoraron esto almacenando series temporales numéricas, pero su modelo de identidad es una **cadena jerárquica con puntos**: `prod.us-east-1.web.web03.http.requests.500`. Esa cadena hornea las dimensiones de consulta en un orden fijo. Preguntar "500s a lo largo de todas las regiones para el job `web`" requiere gimnasia de comodines (`prod.*.web.*.http.requests.500`), y preguntar "500s agrupados por región **y** versión" es imposible si la versión nunca se insertó en la jerarquía. Re-segmentar significa re-instrumentar.

### 1.2 La decisión de diseño: identidad multidimensional + un lenguaje de consulta

Prometheus (Matt T. Proud y Julius Volz en SoundCloud, 2012; segundo proyecto en graduarse de la CNCF después de Kubernetes) cambia la identidad de una serie temporal de una *ruta* a un *nombre de métrica más un conjunto no ordenado de labels clave/valor*:

```
http_requests_total{job="api", instance="10.2.4.11:8080", method="POST", handler="/v1/orders", status="500", region="us-east-1", version="1.14.2"}
```

Cada label es una dimensión de consulta independiente. La agregación se decide **en tiempo de consulta**, no en tiempo de instrumentación. Esa sola decisión es lo que hace posible a PromQL, y PromQL es lo que hace posible el alertado basado en SLO:

```promql
# Error budget burn rate over 1h for an SLO of 99.9% availability
(
  sum(rate(http_requests_total{job="api", status=~"5.."}[1h]))
  /
  sum(rate(http_requests_total{job="api"}[1h]))
) / (1 - 0.999)
```

Ningún check de Nagios puede expresar eso. Este es el punto arquitectónico que evalúa el examen: **Prometheus no es un ejecutor de checks, es una base de datos de series temporales dimensional con un scraper adosado.**

### 1.3 Lo que Prometheus deliberadamente *no* es

Un SRE debe conocer los límites, porque la mitad de los incidentes en producción con Prometheus vienen de usarlo como algo que no es:

- **No es almacenamiento durable de grado facturación.** La TSDB local está diseñada para semanas, no años, y el disco de un solo nodo es un único punto de fallo. La durabilidad a largo plazo se delega a destinos `remote_write` (Thanos, Mimir, Cortex, VictoriaMetrics).
- **No es 100% exacto.** El scraping es muestreo. El incremento de un contador entre dos scrapes se captura, pero el instante exacto no. Está explícitamente documentado como inadecuado para facturación por petición.
- **No es clusterizado.** Un servidor Prometheus es un único proceso con disco local. Alta disponibilidad significa *correr dos servidores idénticos en paralelo*, no un clúster con consenso.
- **No es un almacén de eventos/logs.** La cardinalidad es la moneda; un label `user_id` va a destruir el servidor. Los logs van a Loki/Elasticsearch; las trazas a Tempo/Jaeger.

---

## 2. Arquitectura y mecánica interna

### 2.1 Mapa de componentes

```
                   ┌──────────────────────────────────────────────────────┐
                   │                 PROMETHEUS SERVER                    │
   Service         │                                                      │
   Discovery ─────►│  ┌────────────┐   relabel   ┌───────────────────┐    │
  (k8s, consul,    │  │  Discovery │────────────►│  Scrape Manager   │    │
   file_sd, dns,   │  │  Manager   │  (targets)  │  (HTTP GET /metrics)   │
   ec2, azure...)  │  └────────────┘             └─────────┬─────────┘    │
                   │                                       │ samples      │
   Targets ◄───────┼───────────────────────────────────────┘              │
  (exporters,      │                              metric_relabel_configs  │
   instrumented    │                                       │              │
   apps)           │                                       ▼              │
                   │   ┌──────────────────────────────────────────────┐   │
                   │   │           TSDB (local, append-only)          │   │
                   │   │  WAL ──► Head block (2h, in-memory index)    │   │
                   │   │           └─► persisted blocks ──► compaction│   │
                   │   └───────────┬──────────────────────┬───────────┘   │
                   │               │                      │               │
                   │      ┌────────▼────────┐    ┌────────▼────────┐      │
                   │      │  PromQL Engine  │    │ remote_write /  │──────┼──► Thanos /
                   │      └────┬───────┬────┘    │  remote_read    │      │    Mimir /
                   │           │       │         └─────────────────┘      │    Cortex
                   │  ┌────────▼──┐ ┌──▼─────────────┐                    │
                   │  │ Rule      │ │ HTTP API       │◄───────────────────┼──── Grafana
                   │  │ Manager   │ │ /api/v1/query  │                    │
                   │  │ (record + │ └────────────────┘                    │
                   │  │  alert)   │                                       │
                   │  └────┬──────┘                                       │
                   └───────┼──────────────────────────────────────────────┘
                           │ HTTP POST /api/v2/alerts
                           ▼
                   ┌───────────────────┐  gossip mesh (:9094)  ┌──────────────┐
                   │  ALERTMANAGER     │◄─────────────────────►│ Alertmanager │
                   │  dedup → group →  │                       │  (replica 2) │
                   │  inhibit → silence│                       └──────────────┘
                   │       → notify    │
                   └─────────┬─────────┘
                             ▼
            PagerDuty / Slack / email / OpsGenie / webhook
```

Fijate en la división que al examen le gusta sondear: **Prometheus evalúa la regla de alerting y decide `firing`; Alertmanager decide *a quién se le avisa, cuándo, agrupado cómo, y si queda suprimido*.** Prometheus nunca envía un email.

### 2.2 Pull vs push — la tabla de compromisos

Prometheus **hace pull** (scrapea) sobre HTTP. Esta es la decisión de diseño peor entendida.

| Dimensión | Pull (Prometheus) | Push (StatsD, Graphite, OTel push) |
|---|---|---|
| Descubrimiento de targets | El servidor debe descubrir los targets; el SD es infraestructura obligatoria | Los targets deben conocer la dirección del colector; el colector no necesita SD |
| "¿Está arriba?" | Gratis: la métrica `up` se sintetiza en cada scrape | Requiere una convención de heartbeat aparte |
| Firewall/NAT | El servidor debe alcanzar los targets — difícil a través de NAT/edge | Funciona desde cualquier lado, saliente |
| Comportamiento ante sobrecarga | El servidor controla el ritmo; una tormenta de targets no puede saturarlo | Una tormenta de reintentos de clientes puede hacerle DDoS al colector |
| Depurabilidad | `curl http://target:9100/metrics` reproduce exactamente lo que ve el servidor | Opaco; hay que inspeccionar el colector |
| Jobs de vida corta (batch/cron) | **Roto** — el proceso muere antes del scrape. Necesita Pushgateway | Encaje natural |
| Múltiples consumidores | N servidores Prometheus pueden scrapear el mismo target de forma independiente | Requiere fan-out en el colector |
| Timestamps de las muestras | Asignados por el servidor en el momento del scrape (salvo `honor_timestamps`) | Asignados por el cliente — el desfase de reloj pasa a ser problema tuyo |

**Regla para el examen y para producción:** usá pull para todo lo que viva más que un intervalo de scrape; usá Pushgateway *solo* para jobs batch a nivel de servicio, nunca como proxy de push general.

### 2.3 La TSDB: qué pasa realmente en disco

Entender esto es lo que separa "sé instalar Prometheus" de "sé operar Prometheus".

```
$ tree -L 2 /var/lib/prometheus
/var/lib/prometheus
├── 01J9KM4Z2QW8XG7T5F3B0RNVHD    <- persisted block (2h or compacted)
│   ├── chunks
│   │   └── 000001                 <- 512 MiB max segment of compressed chunks
│   ├── index                      <- inverted index: label pair -> series IDs
│   ├── meta.json                  <- time range, series count, compaction level
│   └── tombstones                 <- deletion markers (delete_series API)
├── 01J9KTA6J1H4C2M0P8Y7WZ3EQK
│   └── ...
├── chunks_head                    <- memory-mapped chunks of the current head
│   ├── 000042
│   └── 000043
├── lock
├── queries.active                 <- crash forensics: queries in flight
└── wal                            <- write-ahead log, 128 MiB segments
    ├── 00000231
    ├── 00000232
    └── checkpoint.00000230
        └── 00000000
```

Vida de una muestra:

1. **Scrape** → la muestra se agrega al **WAL** (durabilidad) y al **head block** en memoria.
2. El **head block** acumula ~2 horas de datos. Los chunks se mapean a memoria hacia `chunks_head/` una vez llenos (120 muestras por chunk por defecto), de modo que el heap solo retiene el chunk *activo* por serie.
3. Cada **2 horas** el head se corta y se persiste como un bloque inmutable; el WAL se trunca y se escribe un **checkpoint**.
4. La **compactación** fusiona bloques adyacentes en bloques más grandes (niveles), deduplicando el índice. El tamaño máximo de bloque es por defecto el 10% de la retención, con tope de 31 días.
5. La **retención** elimina bloques enteros más viejos que `--storage.tsdb.retention.time` (por defecto `15d`) o cuando se excede `--storage.tsdb.retention.size`. *La retención opera sobre bloques, nunca sobre muestras individuales* — por eso el uso de disco tiene forma de diente de sierra, no lineal.

**Compresión.** Los timestamps usan codificación delta-of-delta; los valores usan la codificación XOR de Gorilla. En la práctica una muestra cuesta **~1,7–2 bytes** en disco. Esto da la fórmula de capacidad estándar:

```
disk_bytes ≈ retention_seconds × ingested_samples_per_second × bytes_per_sample
```

Ejemplo resuelto — 1.200.000 series activas scrapeadas cada 15 s, retenidas 30 días:

```
samples/s      = 1_200_000 / 15            = 80_000
retention_s    = 30 × 86400                = 2_592_000
disk           = 2_592_000 × 80_000 × 2 B  ≈ 414 GB
```

Sumá ~15–20% para el índice y margen para la compactación (la compactación necesita espacio libre para escribir el bloque nuevo antes de borrar el viejo). Aprovisioná ~500 GB.

**Memoria.** El término dominante es series activas × ~4–5 KB (head chunks + índice + cadenas de labels). 1,2 M de series ≈ 6–8 GB de RSS con margen para la ejecución de consultas. La memoria la determina el **número de series**, no el intervalo de scrape.

### 2.4 Modelo de disponibilidad

No hay clustering. Los patrones de producción son:

| Patrón | Cómo | Compromiso |
|---|---|---|
| **Par HA** | Dos servidores Prometheus idénticos, misma configuración, ambos scrapeando todo | Simple; pero los dos tienen timestamps de muestra ligeramente distintos → "parpadeo" en los gráficos cuando un balanceador alterna entre ellos |
| **Par HA + Thanos Querier / Mimir** | Lo mismo, más una capa de consulta deduplicadora que usa un label de réplica en `external_labels` | Deduplicación correcta, vista global, retención en object storage. Costo operativo de un segundo sistema |
| **Sharding funcional** | Dividir por equipo/región/job vía `relabel_configs` con `hashmod`, y federar los agregados hacia arriba | Escala horizontalmente; se pierden las consultas entre shards salvo que se federe |
| **Modo agente** | `prometheus --agent` — solo scrape + `remote_write`, sin TSDB local, sin consultas, sin reglas | Colector de borde barato; *no podés* consultarlo ni correr reglas de alerting localmente |

Ambos miembros de un par HA envían alertas a **los dos** Alertmanagers; la malla de gossip de Alertmanager deduplica las alertas idénticas para que la guardia reciba un solo aviso.

---

## 3. El modelo de datos y el formato de exposición

### 3.1 Identidad de una serie

Una **serie temporal** se identifica de forma única por el conjunto completo de sus pares de labels, incluido el label especial `__name__` que contiene el nombre de la métrica. Estas dos son la misma serie:

```promql
http_requests_total{method="GET"}
{__name__="http_requests_total", method="GET"}
```

Una **muestra** es un par `(float64 value, int64 millisecond timestamp)`. Ese es el modelo de datos completo. No hay cadenas, ni booleanos, ni eventos. (Prometheus 2.40+ soporta además *native histograms*, un tipo de muestra compuesto — ver §4.4.)

**Convenciones de nomenclatura** (relevantes para el examen, e impuestas socialmente por todos los exporters):

- `<namespace>_<subsystem>_<name>_<unit>_<suffix>` — p. ej. `node_filesystem_avail_bytes`, `http_request_duration_seconds`.
- **Solo unidades base**: segundos, bytes, ratios (0–1); no milisegundos, megabytes, porcentaje.
- Los counters terminan en `_total`.
- El nombre de la métrica identifica *qué se mide*; los labels identifican *qué instancia de eso*. Nunca `http_requests_get_total` / `http_requests_post_total` — usá un label `method`.
- Caracteres válidos históricamente `[a-zA-Z_:][a-zA-Z0-9_:]*` para nombres y `[a-zA-Z_][a-zA-Z0-9_]*` para labels. Los dos puntos están **reservados para las recording rules** y un exporter jamás debe producirlos. (Prometheus 3.0 agrega nombres UTF-8 opt-in usando la sintaxis entre comillas `{"my.metric", label="x"}`; el juego de caracteres clásico es lo que espera el examen.)
- Los labels que empiezan con `__` son **internos** y se descartan antes de la ingesta.

### 3.2 Series generadas automáticamente

Cada scrape produce estas, diga lo que diga el target:

| Serie | Significado |
|---|---|
| `up{job,instance}` | `1` si el scrape tuvo éxito, `0` si falló (conexión rechazada, timeout, content type inválido). **La métrica más importante del sistema.** |
| `scrape_duration_seconds` | Tiempo de reloj del scrape |
| `scrape_samples_scraped` | Muestras expuestas por el target |
| `scrape_samples_post_metric_relabeling` | Muestras realmente ingeridas después de `metric_relabel_configs` |
| `scrape_series_added` | Series nuevas en este scrape — el detector de churn |
| `scrape_body_size_bytes` | Tamaño del cuerpo de la respuesta |

Un target ausente (el SD ya no lo devuelve) no produce **ninguna serie `up` en absoluto** — por eso `absent()` y `up == 0` son alertas distintas, y normalmente necesitás las dos.

### 3.3 Formato de exposición

Texto sobre HTTP, una muestra por línea, con metadatos `# HELP` y `# TYPE`:

```
$ curl -s http://10.2.4.11:9100/metrics | head -20
# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
# TYPE node_cpu_seconds_total counter
node_cpu_seconds_total{cpu="0",mode="idle"} 380192.41
node_cpu_seconds_total{cpu="0",mode="iowait"} 412.88
node_cpu_seconds_total{cpu="0",mode="system"} 3021.55
node_cpu_seconds_total{cpu="0",mode="user"} 9184.02
node_cpu_seconds_total{cpu="1",mode="idle"} 379884.17
# HELP node_filesystem_avail_bytes Filesystem space available to non-root users in bytes.
# TYPE node_filesystem_avail_bytes gauge
node_filesystem_avail_bytes{device="/dev/nvme0n1p2",fstype="ext4",mountpoint="/"} 3.1259631616e+10
# HELP node_load1 1m load average.
# TYPE node_load1 gauge
node_load1 0.34
# HELP node_memory_MemAvailable_bytes Memory information field MemAvailable_bytes.
# TYPE node_memory_MemAvailable_bytes gauge
node_memory_MemAvailable_bytes 5.921579008e+09
# HELP process_cpu_seconds_total Total user and system CPU time spent in seconds.
# TYPE process_cpu_seconds_total counter
process_cpu_seconds_total 41.29
```

Existen dos formatos de cable:

| Formato | Content-Type | Notas |
|---|---|---|
| Prometheus text 0.0.4 | `text/plain; version=0.0.4; charset=utf-8` | Base universal |
| **OpenMetrics 1.0** | `application/openmetrics-text; version=1.0.0` | Estandarización CNCF/IETF de lo anterior. Agrega el terminador `# EOF`, exemplars, series `_created`, y los tipos nativos `Info`/`StateSet` |

La negociación de contenido ocurre vía la cabecera `Accept`; `scrape_protocols` en la configuración de scrape controla el orden de preferencia. Los exemplars (IDs de traza adjuntos a una muestra, usados para saltar de un pico de latencia a una traza en Tempo/Jaeger) requieren OpenMetrics **y** `--enable-feature=exemplar-storage`:

```
http_request_duration_seconds_bucket{le="0.25",handler="/api/v1/orders"} 1027 # {trace_id="4bf92f3577b34da6a3ce929d0e0e4736"} 0.242 1725360000.000
```

---

## 4. Tipos de métrica y sus compromisos en producción

El tipo vive únicamente en los metadatos `# TYPE` — la TSDB almacena todos los tipos como muestras float. El tipo te dice *a vos* qué funciones son legales.

### 4.1 Counter

Monótonamente creciente, se reinicia a 0 cuando el proceso reinicia. **Nunca grafiques un counter en crudo.** Siempre `rate()`/`increase()`, que detectan y corrigen los reinicios.

```
# TYPE http_requests_total counter
http_requests_total{status="200"} 1029481
```

### 4.2 Gauge

Valor arbitrario que sube y baja: temperatura, profundidad de cola, memoria en uso, cantidad de réplicas. Funciones legales: `avg_over_time`, `max_over_time`, `delta`, `deriv`, `predict_linear`. **Ilegal**: `rate()` sobre un gauge produce basura en silencio, porque tratará cada descenso como un reinicio de counter.

### 4.3 Histogram clásico vs Summary

Ambos miden distribuciones; se diferencian en *dónde se calcula el cuantil*, y esta es la pregunta clásica del examen.

Un histogram expone **buckets acumulativos** (`_bucket{le="..."}`) más `_sum` y `_count`:

```
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.05"} 24054
http_request_duration_seconds_bucket{le="0.1"}  33444
http_request_duration_seconds_bucket{le="0.25"} 100392
http_request_duration_seconds_bucket{le="0.5"}  129389
http_request_duration_seconds_bucket{le="1"}    133988
http_request_duration_seconds_bucket{le="+Inf"} 144320
http_request_duration_seconds_sum   53423.12
http_request_duration_seconds_count 144320
```

Un summary expone **cuantiles calculados por el cliente**:

```
# TYPE rpc_duration_seconds summary
rpc_duration_seconds{quantile="0.5"}  0.0324
rpc_duration_seconds{quantile="0.9"}  0.1032
rpc_duration_seconds{quantile="0.99"} 0.4291
rpc_duration_seconds_sum   17.83
rpc_duration_seconds_count 2693
```

| Criterio | Histogram | Summary |
|---|---|---|
| Cuantil calculado | **Del lado del servidor, en tiempo de consulta** (`histogram_quantile`) | **Del lado del cliente, en el momento de la observación** |
| Agregable entre instancias | **Sí** — sumás los buckets y después calculás el cuantil | **No.** Promediar el p99 de 40 pods es matemáticamente absurdo |
| Elección del cuantil | Cualquier cuantil, retroactivamente | Fijado en tiempo de instrumentación; cambiarlo requiere un redespliegue |
| Precisión | Limitada por los límites de los buckets; error de interpolación dentro de un bucket | Error φ configurable, preciso por instancia |
| Costo de CPU en el cliente | Barato (incrementar un counter) | Caro (estimación de cuantiles en streaming, ventanas deslizantes) |
| Cantidad de series | `len(buckets) + 2` por combinación de labels | `len(quantiles) + 2` |
| Costo de consulta | Mayor (muchas series que agregar) | Trivial (leer el valor) |
| Ventana temporal | En tiempo de consulta, arbitraria (`[5m]`, `[1h]`) | Ventana deslizante fija del lado del cliente (típicamente 10 min) |

**Por defecto, histograms.** Usá un summary solo cuando necesitás un cuantil preciso por instancia que nunca vas a agregar, o cuando el cliente no puede permitirse la cardinalidad de los buckets.

**La elección de buckets importa más que cualquier otra cosa.** `histogram_quantile` interpola linealmente dentro de un bucket, así que un p99 que cae dentro de `le="1"` cuando el límite previo es `le="0.5"` puede estar equivocado por 500 ms. Los buckets deben quedar a ambos lados del umbral de tu SLO:

```promql
# p99 latency across every replica of the api job, per handler
histogram_quantile(
  0.99,
  sum by (le, handler) (rate(http_request_duration_seconds_bucket{job="api"}[5m]))
)
```

Fijate en la forma: `rate()` **primero**, después `sum by (le, ...)`, después `histogram_quantile`. Cualquier otro orden está mal.

Para SLOs, preferí el ratio exacto por sobre un cuantil interpolado — no tiene error de bucket:

```promql
# fraction of requests served under 250 ms (an SLI, not an estimate)
  sum(rate(http_request_duration_seconds_bucket{job="api", le="0.25"}[5m]))
/ sum(rate(http_request_duration_seconds_count{job="api"}[5m]))
```

### 4.4 Native histograms (Prometheus 2.40+, más o menos estables en 3.x)

Los histograms clásicos fuerzan un compromiso entre resolución y cardinalidad. Los native histograms usan **buckets espaciados exponencialmente generados bajo demanda** con un esquema configurable (factor de resolución), almacenados como una única muestra compuesta. Una serie reemplaza a 12–20, con mucha mejor resolución.

```yaml
# prometheus.yml — enable scraping of native histograms
global:
  scrape_interval: 15s
# started with: prometheus --enable-feature=native-histograms
```

```yaml
scrape_configs:
  - job_name: api
    scrape_classic_histograms: false     # drop the classic buckets when native is present
    static_configs:
      - targets: ['api:8080']
```

Consultar es la misma función con un argumento más simple:

```promql
histogram_quantile(0.99, sum by (handler) (rate(http_request_duration_seconds[5m])))
```

Tabla de compromisos:

| | Clásico | Native |
|---|---|---|
| Series por histogram | 12–20 | 1 |
| Resolución | Fija en la instrumentación | Exponencial, ~1–5% de error relativo |
| Remote write | Soportado universalmente | Requiere Remote Write 2.0 |
| Soporte del ecosistema | Total | Creciendo; parte del tooling todavía va atrás |
| Recording rules / Grafana | En todos lados | Solo versiones recientes |

---

## 5. Configurar el servidor: un `prometheus.yml` completo

Esta es una configuración de producción completa y sintácticamente válida. Cada bloque está anotado.

```yaml
# /etc/prometheus/prometheus.yml
global:
  # How often to scrape targets by default. 15s is the industry default:
  # it keeps rate() over [1m] meaningful (4 points) without exploding storage.
  scrape_interval:     15s
  # Fail a scrape that takes longer than this. MUST be <= scrape_interval.
  scrape_timeout:      10s
  # How often to evaluate recording/alerting rules.
  evaluation_interval: 15s
  # Hard ceilings against a misbehaving target destroying the server.
  # 0 = unlimited (the default) — always set these in production.
  sample_limit:        20000
  label_limit:         40
  label_name_length_limit:  200
  label_value_length_limit: 400
  target_limit:        3000

  # Labels attached to every series leaving this server (federation,
  # remote_write, alerts). They identify WHICH Prometheus produced the data
  # and are the basis of Thanos/Mimir deduplication.
  external_labels:
    cluster:  prod-eu-west-1
    replica:  prometheus-00
    env:      production

# Rule files are globbed at load time and re-globbed on reload.
rule_files:
  - /etc/prometheus/rules/recording/*.yml
  - /etc/prometheus/rules/alerting/*.yml

# Where to ship firing alerts. Note this is discovered like any other target,
# so Alertmanager replicas can come from DNS or Kubernetes SD.
alerting:
  alert_relabel_configs:
    # Strip the replica label so the two HA Prometheus servers emit
    # byte-identical alerts and Alertmanager can deduplicate them.
    - regex:  replica
      action: labeldrop
  alertmanagers:
    - scheme: http
      timeout: 10s
      api_version: v2
      static_configs:
        - targets:
            - alertmanager-00.prod.internal:9093
            - alertmanager-01.prod.internal:9093

# Long-term storage. Prometheus keeps its local window; the durable copy
# lives elsewhere.
remote_write:
  - name: mimir-prod
    url: https://mimir.prod.internal/api/v1/push
    remote_timeout: 30s
    basic_auth:
      username: prometheus
      password_file: /etc/prometheus/secrets/mimir_password
    tls_config:
      ca_file: /etc/prometheus/certs/internal-ca.pem
      insecure_skip_verify: false
    write_relabel_configs:
      # Do not pay to store per-container Go runtime noise remotely.
      - source_labels: [__name__]
        regex: 'go_gc_.*|go_memstats_.*'
        action: drop
    queue_config:
      capacity:          10000   # per-shard in-memory queue depth
      max_shards:        200     # upper bound on parallel senders
      min_shards:        1
      max_samples_per_send: 2000
      batch_send_deadline:  5s
      min_backoff:       30ms
      max_backoff:       5s
    metadata_config:
      send: true
      send_interval: 1m

storage:
  tsdb:
    # Accept samples up to 30m older than the head max time. Required if you
    # ingest from lagging agents; costs memory. 0 (default) = strict ordering.
    out_of_order_time_window: 30m

scrape_configs:

  # ---------------------------------------------------------------------
  # 1. Prometheus scraping itself. Always present. If this job is broken,
  #    nothing else you see can be trusted.
  # ---------------------------------------------------------------------
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
        labels:
          tier: platform

  # ---------------------------------------------------------------------
  # 2. Node exporters via file-based service discovery. file_sd is the
  #    universal escape hatch: any CMDB, Ansible run or script can write
  #    these JSON/YAML files and Prometheus picks them up via inotify —
  #    no reload required.
  # ---------------------------------------------------------------------
  - job_name: node
    scrape_interval: 30s
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/node/*.yml
        refresh_interval: 5m
    relabel_configs:
      # instance defaults to host:port; make it the bare hostname.
      - source_labels: [__address__]
        regex: '([^:]+)(?::\d+)?'
        target_label: instance
        replacement: '${1}'
    metric_relabel_configs:
      # Drop per-CPU idle time on machines with 128 cores: high cardinality,
      # low value once you have the aggregate.
      - source_labels: [__name__, mode]
        regex: 'node_cpu_seconds_total;(idle|iowait|steal)'
        action: keep
      # Drop filesystem metrics for ephemeral container overlays.
      - source_labels: [__name__, mountpoint]
        regex: 'node_filesystem_.*;/(var/lib/docker|run/containerd)/.*'
        action: drop

  # ---------------------------------------------------------------------
  # 3. An instrumented application discovered through Consul.
  # ---------------------------------------------------------------------
  - job_name: consul-services
    consul_sd_configs:
      - server: 'consul.prod.internal:8500'
        datacenter: eu-west-1
        scheme: https
        tls_config:
          ca_file: /etc/prometheus/certs/internal-ca.pem
    relabel_configs:
      # Only scrape services explicitly tagged prometheus.
      - source_labels: [__meta_consul_tags]
        regex: '.*,prometheus,.*'
        action: keep
      - source_labels: [__meta_consul_service]
        target_label: job
      - source_labels: [__meta_consul_node]
        target_label: node
      - source_labels: [__meta_consul_dc]
        target_label: datacenter

  # ---------------------------------------------------------------------
  # 4. Blackbox probing. The target list is passed as an HTTP parameter and
  #    the actual scrape goes to the exporter, not to the endpoint. This
  #    __address__ swap is THE canonical relabeling exercise.
  # ---------------------------------------------------------------------
  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - https://www.example.com/healthz
          - https://api.prod.internal/readyz
    relabel_configs:
      # 1. the URL under test becomes the ?target= parameter
      - source_labels: [__address__]
        target_label: __param_target
      # 2. and also the human-visible instance label
      - source_labels: [__param_target]
        target_label: instance
      # 3. the actual HTTP request goes to the blackbox exporter
      - target_label: __address__
        replacement: blackbox-exporter.prod.internal:9115

  # ---------------------------------------------------------------------
  # 5. Pushgateway. honor_labels is MANDATORY here: without it Prometheus
  #    would overwrite the job/instance labels pushed by the batch job with
  #    the pushgateway's own.
  # ---------------------------------------------------------------------
  - job_name: pushgateway
    honor_labels: true
    static_configs:
      - targets: ['pushgateway.prod.internal:9091']

  # ---------------------------------------------------------------------
  # 6. Scrape only 1/3 of the fleet — horizontal sharding by consistent hash.
  # ---------------------------------------------------------------------
  - job_name: node-shard-0
    file_sd_configs:
      - files: ['/etc/prometheus/targets/node/*.yml']
    relabel_configs:
      - source_labels: [__address__]
        modulus:      3
        target_label: __tmp_shard
        action:       hashmod
      - source_labels: [__tmp_shard]
        regex:        '0'
        action:       keep
```

Un archivo de targets de `file_sd`:

```yaml
# /etc/prometheus/targets/node/eu-west-1.yml
- targets:
    - web01.prod.internal:9100
    - web02.prod.internal:9100
    - web03.prod.internal:9100
  labels:
    env:    production
    region: eu-west-1
    role:   web

- targets:
    - db01.prod.internal:9100
    - db02.prod.internal:9100
  labels:
    env:    production
    region: eu-west-1
    role:   database
```

### 5.1 Línea de comandos y unit file

```ini
# /etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus Time Series Database
Documentation=https://prometheus.io/docs/prometheus/latest/
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=30d \
  --storage.tsdb.retention.size=450GB \
  --web.listen-address=0.0.0.0:9090 \
  --web.external-url=https://prometheus.prod.internal \
  --web.config.file=/etc/prometheus/web.yml \
  --web.enable-lifecycle \
  --query.max-concurrency=20 \
  --query.timeout=2m \
  --query.max-samples=50000000 \
  --enable-feature=exemplar-storage,native-histograms
ExecReload=/bin/kill -HUP $MAINPID
TimeoutStopSec=600
Restart=on-failure
RestartSec=5

# Hardening — Prometheus needs nothing but its data directory.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectControlGroups=true
ReadWritePaths=/var/lib/prometheus
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Flags clave para memorizar:

| Flag | Efecto |
|---|---|
| `--config.file` | Por defecto `prometheus.yml` en el cwd |
| `--storage.tsdb.path` | Por defecto `data/` |
| `--storage.tsdb.retention.time` | Por defecto `15d` |
| `--storage.tsdb.retention.size` | Retención basada en bytes; gana la que se dispare primero |
| `--web.listen-address` | Por defecto `0.0.0.0:9090` |
| `--web.enable-lifecycle` | Habilita `POST /-/reload` y `/-/quit`. **Desactivado por defecto** |
| `--web.enable-admin-api` | Habilita `delete_series`, `snapshot`, `clean_tombstones`. **Desactivado por defecto** |
| `--web.external-url` | URL pública usada en el `generatorURL` de las alertas y en los enlaces — configurala detrás de un reverse proxy |
| `--web.route-prefix` | Prefijo de ruta cuando se sirve bajo un subpath |
| `--query.max-samples` | Mata consultas que cargarían más de N muestras en memoria (guarda contra OOM) |
| `--enable-feature=` | Funcionalidades experimentales separadas por coma |
| `--agent` | Modo agente: solo scrape + remote_write |

**Recargar sin reiniciar** (un reinicio reproduce el WAL y puede tardar minutos en una TSDB grande):

```
$ sudo systemctl reload prometheus          # sends SIGHUP
$ curl -sf -X POST http://localhost:9090/-/reload && echo reloaded
reloaded
```

---

## 6. Service discovery y relabeling

### 6.1 Los mecanismos de descubrimiento

| SD | Uso típico | Meta labels clave |
|---|---|---|
| `static_configs` | Infra fija, el propio servidor | — |
| `file_sd_configs` | Generado por CMDB/Ansible; **el punto de integración universal**. Recargado vía inotify | los labels que escribas |
| `kubernetes_sd_configs` | Kubernetes. Roles: `node`, `service`, `pod`, `endpoints`, `endpointslice`, `ingress` | `__meta_kubernetes_pod_*`, `__meta_kubernetes_namespace`, … |
| `consul_sd_configs` | Catálogo de servicios de Consul | `__meta_consul_service`, `__meta_consul_tags`, … |
| `dns_sd_configs` | Registros SRV/A/AAAA — funciona donde no funciona nada más | `__meta_dns_name`, `__meta_dns_srv_record_target` |
| `ec2_sd_configs`, `azure_sd_configs`, `gce_sd_configs` | Inventario de instancias en la nube | `__meta_ec2_tag_<name>`, `__meta_ec2_private_ip`, … |
| `http_sd_configs` | Cualquier endpoint HTTP que devuelva el esquema JSON de SD — escribí el tuyo | lo que devuelvas |
| `docker_sd_configs`, `dockerswarm_sd_configs` | Hosts de contenedores | `__meta_docker_container_label_*` |

Comparemos `file_sd` y `http_sd`, ya que ambos son "traé tu propio inventario":

| | `file_sd` | `http_sd` |
|---|---|---|
| Latencia de actualización | Instantánea (inotify) | `refresh_interval` (por defecto 60s) |
| Modo de fallo | Archivo obsoleto = targets obsoletos, en silencio | Error HTTP = el SD conserva el último conjunto bueno, se incrementa `prometheus_sd_http_failures_total` |
| Despliegue | Requiere acceso al sistema de archivos del host de Prometheus | Solo red — funciona para un Prometheus que no es tuyo |
| Depurabilidad | `cat` al archivo | `curl` al endpoint |

### 6.2 Relabeling — la habilidad operativa más importante de todas

Cada target empieza su vida como un conjunto de **meta labels con prefijo `__`**. El relabeling es un pequeño pipeline de reescritura aplicado en orden; los labels `__` que sobrevivan al final se descartan, y `__address__` determina a dónde va la petición HTTP.

**Dos etapas distintas:**

| Etapa | Se ejecuta | Opera sobre | Propósito |
|---|---|---|---|
| `relabel_configs` | **antes** del scrape | labels del *target* | seleccionar qué targets scrapear, reescribir dirección/esquema/path, construir `job`/`instance` |
| `metric_relabel_configs` | **después** del scrape, antes de la ingesta | labels de *cada muestra* | descartar métricas caras, renombrar, quitar labels de alta cardinalidad |

Una tercera etapa, `write_relabel_configs`, filtra lo que va a `remote_write`. Una cuarta, `alert_relabel_configs`, reescribe los labels de las alertas camino a Alertmanager.

**Acciones:**

| Acción | Comportamiento |
|---|---|
| `replace` (por defecto) | Si `regex` coincide con la concatenación de `source_labels`, asigna `target_label` a `replacement` (con expansión de `$1`, `$2`) |
| `keep` | Descarta el target/métrica si la regex **no** coincide |
| `drop` | Descarta el target/métrica si la regex **sí** coincide |
| `keepequal` / `dropequal` | Conserva/descarta cuando la concatenación de `source_labels` es igual a `target_label` — sin regex |
| `hashmod` | `target_label = hash(source_labels) % modulus` — la primitiva de sharding |
| `labelmap` | Copia cada label cuyo **nombre** coincida con la regex a un nombre nuevo dado por `replacement` |
| `labeldrop` / `labelkeep` | Elimina/retiene los labels cuyo **nombre** coincide con la regex |
| `lowercase` / `uppercase` | Cambia el caso de la fuente concatenada hacia `target_label` |

Valores por defecto que conviene memorizar: `separator: ";"`, `regex: "(.*)"`, `replacement: "$1"`, `action: replace`. La regex está **totalmente anclada** — `regex: foo` significa `^foo$`.

**Labels especiales de target:**

| Label | Significado |
|---|---|
| `__address__` | `host:port` al que realmente se conecta; se convierte en `instance` si `instance` no está definido |
| `__scheme__` | `http` (por defecto) o `https` |
| `__metrics_path__` | Por defecto `/metrics` |
| `__param_<name>` | Agrega `?<name>=<value>` a la URL de scrape |
| `__scrape_interval__`, `__scrape_timeout__` | Sobrescritura por target |
| `__tmp_*` | Convención para labels de trabajo temporales; de todos modos nunca se persisten |

**Descubrimiento canónico en Kubernetes dirigido por anotaciones** — el patrón que despliega todo equipo de plataforma:

```yaml
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # Opt-in: only pods annotated prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true

      # Honour prometheus.io/path
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)

      # Honour prometheus.io/port: rewrite host:oldport -> host:newport
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: '([^:]+)(?::\d+)?;(\d+)'
        replacement: '$1:$2'
        target_label: __address__

      # Honour prometheus.io/scheme
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)

      # Promote every pod label to a metric label, sanitising the name
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)

      # Standard identity labels
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_node_name]
        action: replace
        target_label: node

      # Never scrape pods that are not running
      - source_labels: [__meta_kubernetes_pod_phase]
        action: drop
        regex: (Pending|Succeeded|Failed|Completed)
```

**Cirugía de cardinalidad con `metric_relabel_configs`** — el freno de emergencia cuando un equipo despliega un label `user_id` a las 03:00:

```yaml
    metric_relabel_configs:
      # Nuke a single runaway metric entirely.
      - source_labels: [__name__]
        regex: 'app_request_by_user_id_total'
        action: drop

      # Or keep the metric but strip the offending label. Note: this MERGES
      # series that now share identity — for a counter the result is the sum
      # of unrelated counters and is NOT meaningful. Prefer drop.
      - regex: 'user_id|session_id|request_id'
        action: labeldrop

      # Rename a metric to match the org convention.
      - source_labels: [__name__]
        regex: 'legacy_http_reqs'
        target_label: __name__
        replacement: 'http_requests_total'
```

---

## 7. PromQL

### 7.1 Tipos de expresión

| Tipo | Ejemplo | Notas |
|---|---|---|
| **Instant vector** | `node_load1` | Una muestra por serie en el instante de evaluación |
| **Range vector** | `node_load1[5m]` | Una porción de muestras por serie. No se puede graficar directamente |
| **Escalar** | `42`, `time()` | Un único número |
| **Cadena** | `"foo"` | Legal solo como argumento de función |

El error de principiante más común: `node_cpu_seconds_total[5m]` en un panel de gráfico. Un range vector debe reducirse con una función (`rate`, `avg_over_time`, `max_over_time`, …) antes de poder graficarse.

### 7.2 Selectores y matchers

```promql
http_requests_total                                   # all series with this name
http_requests_total{job="api"}                        # equality
http_requests_total{job!="api"}                       # inequality
http_requests_total{status=~"5.."}                    # regex match (fully anchored)
http_requests_total{status!~"2..|3.."}                # regex not-match
{__name__=~"node_cpu_.*", mode="idle"}                # match on the name itself
http_requests_total{job="api"} offset 1w              # value one week ago
http_requests_total{job="api"} @ 1725360000           # value at an absolute timestamp
http_requests_total{job="api"} @ end()                # value at the range end
```

Las regexes son RE2, **totalmente ancladas**, y nunca coinciden con un `\n`. Un matcher vacío `{job=""}` también coincide con series donde el label está ausente — así es como encontrás series a las que *les falta* un label.

`@` y el `offset` negativo (estables desde 2.x) permiten comparar una serie consigo misma en el pasado dentro de una sola expresión:

```promql
# today's traffic vs the same moment last week, as a ratio
sum(rate(http_requests_total[5m])) / sum(rate(http_requests_total[5m] offset 1w))
```

### 7.3 `rate` vs `irate` vs `increase` vs `delta`

Esta tabla vale la pena memorizarla textualmente.

| Función | Entrada | Calcula | Usar para |
|---|---|---|---|
| `rate(v[5m])` | counter | Promedio por segundo sobre toda la ventana, extrapolado a los bordes de la ventana, corregido por reinicios de counter | **Lo predeterminado para counters.** Gráficos, alertas, SLOs |
| `irate(v[5m])` | counter | Tasa por segundo a partir de las **dos últimas** muestras solamente | Señales rápidas y volátiles en un gráfico de alta resolución. **Nunca en alertas** — es propensa al aliasing y esconde picos cuando el paso es grande |
| `increase(v[1h])` | counter | Incremento total sobre la ventana = `rate() × window_seconds`. También extrapolado | "Cuántos errores en la última hora" |
| `delta(v[1h])` | **gauge** | Diferencia entre el primero y el último, extrapolada, **sin corrección de reinicios** | Cambio de un gauge: delta de disco libre, deriva de temperatura |
| `idelta(v[5m])` | gauge | Diferencia de las dos últimas muestras | Rara vez necesaria |
| `deriv(v[1h])` | gauge | Derivada por segundo por mínimos cuadrados | Tendencia de un gauge ruidoso |
| `resets(v[1h])` | counter | Cantidad de reinicios del counter = reinicios del proceso | Detección de crash-loop |
| `changes(v[1h])` | gauge | Cantidad de veces que cambió el valor | Elecciones de líder, oscilaciones de configuración |

**La extrapolación es la razón por la que `increase()` devuelve no enteros.** `rate()` e `increase()` extrapolan a los límites exactos de la ventana porque las muestras rara vez se alinean con ellos. `increase(x[1h])` legítimamente devuelve `3.0000000000000004` o `47.8`. Desde Prometheus 2.x la extrapolación está acotada para que no pueda exceder lo físicamente posible a la tasa observada, pero los no enteros siguen siendo normales y correctos.

**La regla del 4×:** el rango debe contener al menos **4 intervalos de scrape** para que `rate()` sea resistente a un scrape perdido. Con `scrape_interval: 15s`, usá `[1m]` como mínimo; `[5m]` es el valor por defecto seguro. `rate()` sobre un rango que contenga menos de 2 muestras devuelve **nada** — el clásico bug de "mi alerta nunca dispara".

### 7.4 Operadores de agregación

```promql
sum by (job, status) (rate(http_requests_total[5m]))
sum without (instance, pod) (rate(http_requests_total[5m]))
```

`by` conserva solo los labels listados; `without` conserva todo excepto los listados. **Preferí `without`** en reglas reutilizables: sobrevive a la incorporación de un label nuevo, mientras que `by` lo descarta en silencio.

| Operador | Notas |
|---|---|
| `sum`, `min`, `max`, `avg`, `group`, `count` | Estándar |
| `stddev`, `stdvar` | Estadísticos poblacionales |
| `count_values("version", build_info)` | Cuenta series por *valor* — histograma de valores |
| `topk(5, ...)` / `bottomk(5, ...)` | Devuelven las N **series** mayores/menores, conservando todos sus labels |
| `quantile(0.9, ...)` | Cuantil φ **sobre la dimensión de series** — no sobre el tiempo, no sobre buckets |
| `limitk(5, ...)` / `limit_ratio(0.1, ...)` | Muestrean un subconjunto de series (2.50+) — para explorar conjuntos de resultados enormes de forma barata |

`avg()` de una tasa entre instancias casi siempre está mal en una alerta: esconde una réplica rota entre nueve sanas. Usá `max()`, o agregá numerador y denominador por separado.

### 7.5 Operadores binarios y emparejamiento de vectores

La aritmética y las comparaciones entre dos instant vectors emparejan **series con conjuntos de labels idénticos** por defecto.

```promql
# one-to-one: identical labels on both sides
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
```

Cuando los conjuntos de labels difieren, tenés que decir cómo emparejar:

```promql
# ignore the labels that differ
rate(errors_total[5m]) / ignoring(status) rate(requests_total[5m])

# or list exactly the labels to join on
rate(errors_total[5m]) / on(job, instance) rate(requests_total[5m])
```

Los **joins muchos-a-uno** necesitan `group_left` / `group_right`. El caso canónico es enriquecer una métrica con metadatos de una serie `_info`:

```promql
# attach the application version to every request rate.
# The "many" side is the left (many series per job/instance);
# group_left pulls the `version` label in from the "one" side.
  sum by (job, instance) (rate(http_requests_total[5m]))
* on (job, instance) group_left(version)
  app_build_info
```

`group_left(<labels>)` significa: el lado izquierdo es el lado "muchos", y copiá `<labels>` desde la derecha. `group_right` es la imagen espejo. Invertirlo produce `Error executing query: found duplicate series for the match group ...` — uno de los errores de PromQL más comunes en producción.

Los operadores de comparación **filtran** por defecto y se les puede hacer devolver 0/1 con `bool`:

```promql
up == 0                      # returns only the down targets
up == bool 0                 # returns 1 for down, 0 for up, for every target
```

Operadores de conjunto: `and`, `or`, `unless` (diferencia de conjuntos). `unless` es cómo se escriben las excepciones:

```promql
# fire for every instance with high load, except those in maintenance
(node_load5 > 20) unless on(instance) node_maintenance_mode == 1
```

### 7.6 Funciones `_over_time` y subconsultas

Sobre un range vector: `avg_over_time`, `min_over_time`, `max_over_time`, `sum_over_time`, `count_over_time`, `quantile_over_time`, `stddev_over_time`, `last_over_time`, `present_over_time`, `absent_over_time`, `mad_over_time`.

Una **subconsulta** convierte una expresión de instant vector en un range vector para poder aplicar estas funciones a un valor calculado:

```promql
# peak per-second request rate observed at any point in the last 24 hours,
# evaluated at 1-minute resolution
max_over_time(  sum(rate(http_requests_total[5m]))[24h:1m]  )
```

Sintaxis: `<instant_vector_expr>[<range>:<resolution>]`. Las subconsultas son **caras** — el motor evalúa la expresión interna una vez por paso de resolución (1440 veces arriba). Todo lo que ejecutes repetidamente pertenece a una recording rule.

### 7.7 Predicción, ausencia y staleness

```promql
# will / (root fs) fill up within the next 4 hours, judged on the last 6h trend?
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 4*3600) < 0

# fires when a series that should exist has vanished entirely
absent(up{job="payments"})

# fires when the series existed but had no samples in the last hour
absent_over_time(up{job="payments"}[1h])
```

**Staleness.** Una serie sin muestras en los últimos **5 minutos** (`--query.lookback-delta`) no devuelve nada en tiempo de consulta. Cuando un target desaparece del SD, Prometheus escribe un **marcador de stale** explícito, así que la serie deja de resolverse *de inmediato* en vez de quedar dando vueltas 5 minutos. Por esto `up == 0` (el target está y está fallando) y `absent(up{...})` (el target ya no existe) son alertas genuinamente distintas y necesitás las dos.

### 7.8 Una hoja de trucos de PromQL para preguntas reales de producción

```promql
# --- Saturation --------------------------------------------------------
# CPU utilisation per node, 0..1
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))

# Memory used fraction
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# Root filesystem used fraction (excluding pseudo filesystems)
1 - (
      node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.lxcfs|squashfs|overlay"}
    / node_filesystem_size_bytes{fstype!~"tmpfs|fuse.lxcfs|squashfs|overlay"}
    )

# Disk I/O saturation (fraction of wall time spent doing I/O)
rate(node_disk_io_time_seconds_total[5m])

# --- Traffic / Errors / Latency (the RED method) -----------------------
sum by (job) (rate(http_requests_total[5m]))                       # Rate
  sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
/ sum by (job) (rate(http_requests_total[5m]))                     # Errors
histogram_quantile(0.99,
  sum by (le, job) (rate(http_request_duration_seconds_bucket[5m])))  # Duration

# --- Availability ------------------------------------------------------
# fraction of targets up per job
avg by (job) (up)

# processes that restarted in the last hour
resets(process_start_time_seconds[1h]) > 0
# or, equivalently and more directly:
changes(process_start_time_seconds[1h]) > 0

# --- Capacity ----------------------------------------------------------
# top 10 metric names by series count (EXPENSIVE — prefer promtool tsdb analyze)
topk(10, count by (__name__) ({__name__=~".+"}))

# series churn: new series created per second
sum(rate(scrape_series_added[10m]))

# --- Self-monitoring ---------------------------------------------------
prometheus_tsdb_head_series                                    # active series
rate(prometheus_tsdb_head_samples_appended_total[5m])          # ingestion rate
prometheus_target_scrape_pool_exceeded_target_limit_total      # target_limit hits
rate(prometheus_rule_evaluation_failures_total[5m])            # broken rules
prometheus_rule_group_last_duration_seconds
  > prometheus_rule_group_interval_seconds                     # rule group overrun
rate(prometheus_remote_storage_samples_failed_total[5m])       # remote_write loss
prometheus_remote_storage_highest_timestamp_in_seconds
  - ignoring(remote_name, url) group_right
  prometheus_remote_storage_queue_highest_sent_timestamp_seconds  # remote lag (s)
```

---

## 8. Recording rules y alerting rules

Ambas viven en `rule_files`, en grupos. **Las reglas dentro de un grupo se ejecutan secuencialmente, en el orden del archivo; los grupos se ejecutan en paralelo.** El orden importa: una regla que depende de la salida de otra debe ir después de ella en el mismo grupo.

### 8.1 Recording rules

Propósito: precalcular expresiones caras para que los dashboards y las alertas lean una única serie barata.

**Convención de nomenclatura** — `level:metric:operations`, usando los dos puntos reservados:

```yaml
# /etc/prometheus/rules/recording/api.yml
groups:
  - name: api.rules
    interval: 30s          # overrides global evaluation_interval for this group
    limit: 500             # max series this group may produce (2.30+)
    rules:

      # level = the aggregation level (which labels survive)
      # metric = the source metric
      # operations = what was applied, right to left
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))

      - record: job_handler:http_request_duration_seconds_bucket:rate5m
        expr: sum by (job, handler, le) (rate(http_request_duration_seconds_bucket[5m]))

      # Build the SLI once; every burn-rate alert then reads this.
      - record: job:slo_errors:ratio_rate5m
        expr: |
             sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
           /
             sum by (job) (rate(http_requests_total[5m]))

      # Multi-window burn rates for a 99.9% SLO
      - record: job:slo_errors:ratio_rate1h
        expr: |
             sum by (job) (rate(http_requests_total{status=~"5.."}[1h]))
           /
             sum by (job) (rate(http_requests_total{status=~"5.."}[1h]) + rate(http_requests_total{status!~"5.."}[1h]))

      - record: job:slo_errors:ratio_rate6h
        expr: |
             sum by (job) (rate(http_requests_total{status=~"5.."}[6h]))
           /
             sum by (job) (rate(http_requests_total[6h]))
```

Reglas a seguir:
- Una recording rule **no debe** cambiar el significado de los datos. No hagas `avg` de una tasa entre instancias en una recording rule para después alertar sobre eso.
- `histogram_quantile` pertenece a la **consulta**, no a la recording rule — registrá las tasas de los buckets y calculá el cuantil en tiempo de lectura. Registrar un cuantil destruye la agregabilidad.
- Mantené la evaluación del grupo por debajo del intervalo. Si `prometheus_rule_group_last_duration_seconds > prometheus_rule_group_interval_seconds`, tus reglas se están atrasando y aparecen huecos en las series registradas.

### 8.2 Alerting rules

```yaml
# /etc/prometheus/rules/alerting/platform.yml
groups:
  - name: node.alerts
    rules:

      # --- The alert that must always exist -----------------------------
      - alert: TargetDown
        expr: up == 0
        for: 5m
        labels:
          severity: critical
          team: platform
        annotations:
          summary: "Target {{ $labels.instance }} ({{ $labels.job }}) is down"
          description: >-
            Prometheus has failed to scrape {{ $labels.instance }} for job
            {{ $labels.job }} for more than 5 minutes.
          runbook_url: https://runbooks.internal/platform/TargetDown

      - alert: JobAbsent
        expr: absent(up{job="payments"})
        for: 10m
        labels:
          severity: critical
          team: payments
        annotations:
          summary: "No targets discovered for job payments"
          description: >-
            Service discovery returned zero targets for the payments job.
            This is different from TargetDown: the targets are not merely
            failing, they no longer exist.

      # --- Saturation ----------------------------------------------------
      - alert: NodeFilesystemFillingUp
        expr: |
          (
            node_filesystem_avail_bytes{fstype!~"tmpfs|squashfs|overlay"}
            / node_filesystem_size_bytes{fstype!~"tmpfs|squashfs|overlay"}
          ) < 0.15
          and
          predict_linear(
            node_filesystem_avail_bytes{fstype!~"tmpfs|squashfs|overlay"}[6h],
            4 * 3600
          ) < 0
        for: 30m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "{{ $labels.mountpoint }} on {{ $labels.instance }} fills up in <4h"
          description: >-
            Only {{ $value | humanizePercentage }} space left and the 6h trend
            predicts exhaustion within 4 hours.

      - alert: NodeMemoryPressure
        expr: |
          (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.90
        for: 15m
        keep_firing_for: 5m      # stay firing 5m after recovery — anti-flap
        labels:
          severity: warning
        annotations:
          summary: "Memory above 90% on {{ $labels.instance }}"

  - name: slo.alerts
    rules:
      # --- Multi-window multi-burn-rate: the Google SRE pattern ----------
      # Fast burn: 14.4x budget consumption -> 2% of a 30-day budget in 1h.
      # The short window (5m) prevents a long tail of firing after recovery.
      - alert: ErrorBudgetBurnFast
        expr: |
          (
            job:slo_errors:ratio_rate1h{job="api"} > (14.4 * 0.001)
            and
            job:slo_errors:ratio_rate5m{job="api"} > (14.4 * 0.001)
          )
        for: 2m
        labels:
          severity: critical
          team: api
          slo: availability
        annotations:
          summary: "api burning error budget 14.4x — page"
          description: >-
            1h error ratio is {{ $value | humanizePercentage }} against a
            0.1% target. At this rate the 30-day budget is gone in ~2 days.

      - alert: ErrorBudgetBurnSlow
        expr: |
          (
            job:slo_errors:ratio_rate6h{job="api"} > (6 * 0.001)
            and
            job:slo_errors:ratio_rate30m{job="api"} > (6 * 0.001)
          )
        for: 15m
        labels:
          severity: warning
          team: api
          slo: availability
        annotations:
          summary: "api burning error budget 6x — investigate during business hours"

  - name: prometheus.meta.alerts
    rules:
      # --- Monitor the monitoring ---------------------------------------
      - alert: PrometheusRuleEvaluationFailing
        expr: rate(prometheus_rule_evaluation_failures_total[5m]) > 0
        for: 15m
        labels:
          severity: critical
          team: platform
        annotations:
          summary: "Prometheus {{ $labels.instance }} failing to evaluate rules"

      - alert: PrometheusRemoteWriteBehind
        expr: |
          (
            prometheus_remote_storage_highest_timestamp_in_seconds
            - ignoring(remote_name, url) group_right
              prometheus_remote_storage_queue_highest_sent_timestamp_seconds
          ) > 120
        for: 15m
        labels:
          severity: critical
        annotations:
          summary: "remote_write to {{ $labels.url }} is {{ $value }}s behind"

      - alert: PrometheusTSDBHighSeriesChurn
        expr: sum(rate(scrape_series_added[10m])) > 500
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Series churn {{ $value }}/s — a label is probably unbounded"
```

**Semántica que tenés que saber:**

| Campo | Significado |
|---|---|
| `expr` | Se evalúa cada `interval`. Cada serie que devuelve se convierte en una instancia de alerta |
| `for` | La alerta queda **pending** hasta que la expresión devuelva esa serie de forma continua durante ese tiempo, y entonces pasa a **firing**. Si la expresión deja de devolverla, el temporizador se reinicia a cero |
| `keep_firing_for` | Mantiene la alerta en firing durante ese tiempo *después* de que la expresión deja de coincidir — amortigua el flapping (Prometheus 2.42+) |
| `labels` | **Parte de la identidad de la alerta.** Se pueden templatizar. Se usan para el enrutamiento en Alertmanager |
| `annotations` | **No** forman parte de la identidad. Se pueden templatizar. Texto para humanos: `summary`, `description`, `runbook_url` |

Variables de templating: `{{ $labels.<name> }}`, `{{ $value }}`, `{{ $externalLabels.<name> }}`. Funciones de formateo: `humanize`, `humanize1024`, `humanizeDuration`, `humanizePercentage`, `printf "%.2f"`.

**El estado de las alertas se expone como métricas**, lo que te permite alertar sobre tus alertas:

```promql
ALERTS{alertname="TargetDown", alertstate="firing"}
ALERTS_FOR_STATE            # unix timestamp when the alert entered pending
```

`ALERTS_FOR_STATE` es lo que Prometheus persiste para que un reinicio no reinicie todos los temporizadores `for:`.

### 8.3 Testeo unitario de reglas

`promtool test rules` ejecuta las reglas contra series sintéticas. Así es como probás que una alerta dispara *antes* del incidente.

```yaml
# /etc/prometheus/rules/tests/node_test.yml
rule_files:
  - ../alerting/platform.yml

evaluation_interval: 1m

tests:
  - interval: 1m
    input_series:
      - series: 'up{job="node", instance="web01:9100"}'
        # 10 minutes up, then 10 minutes down
        values: '1+0x9 0+0x9'
    alert_rule_test:
      # At minute 12 the alert is only 2 minutes old -> pending, not firing.
      - eval_time: 12m
        alertname: TargetDown
        exp_alerts:
          []
      # At minute 16 it has been down 6 minutes -> firing.
      - eval_time: 16m
        alertname: TargetDown
        exp_alerts:
          - exp_labels:
              severity: critical
              team: platform
              job: node
              instance: web01:9100
            exp_annotations:
              summary: "Target web01:9100 (node) is down"
              description: "Prometheus has failed to scrape web01:9100 for job node for more than 5 minutes."
              runbook_url: https://runbooks.internal/platform/TargetDown
```

```
$ promtool test rules /etc/prometheus/rules/tests/node_test.yml
Unit Testing:  /etc/prometheus/rules/tests/node_test.yml
  SUCCESS
```

Una ejecución fallida es explícita sobre qué difirió:

```
$ promtool test rules /etc/prometheus/rules/tests/node_test.yml
Unit Testing:  /etc/prometheus/rules/tests/node_test.yml
  FAILED:
    alertname: TargetDown, time: 16m,
        exp:[
            0:
              Labels:{alertname="TargetDown", instance="web01:9100", job="node", severity="critical", team="platform"}
              Annotations:{description="...", runbook_url="...", summary="Target web01:9100 (node) is down"}
        ],
        got:[]
```

El mini-lenguaje de `values`: `1+0x9` = valor 1, incremento 0, repetido 9 veces más (10 muestras). `0+10x5` = 0,10,20,30,40,50. `_` = un hueco (muestra faltante). `stale` = un marcador de stale explícito.

---

## 9. Alertmanager

### 9.1 El pipeline

Una alerta que llega a `/api/v2/alerts` pasa, en orden, por:

```
receive → deduplicate (across HA senders) → group (by group_by)
        → inhibit (suppress by rule) → silence (suppress by matcher)
        → route to receiver → notify (with repeat_interval)
```

El **agrupamiento** es la funcionalidad que hace que el alertado sea soportable. Sin él, una falla de rack manda 200 avisos. Con `group_by: [alertname, cluster]`, manda una notificación que contiene 200 alertas.

| Temporizador | Por defecto | Significado |
|---|---|---|
| `group_wait` | `30s` | Después de que llega la **primera** alerta de un grupo nuevo, esperar este tiempo para juntar hermanas antes de la primera notificación. Mantenelo corto (30s) para avisos de guardia |
| `group_interval` | `5m` | Tiempo mínimo antes de enviar una notificación *actualizada* de un grupo que ganó o perdió alertas |
| `repeat_interval` | `4h` | Cuánto esperar antes de volver a notificar sobre un grupo sin cambios que sigue en firing. Cualquier cosa por debajo de 1h entrena a la gente a ignorar las alertas |

### 9.2 `alertmanager.yml` completo

```yaml
# /etc/alertmanager/alertmanager.yml
global:
  resolve_timeout: 5m          # mark an alert resolved if Prometheus stops
                               # re-sending it for this long
  smtp_smarthost: 'smtp.prod.internal:587'
  smtp_from: 'alertmanager@example.com'
  smtp_auth_username: 'alertmanager'
  smtp_auth_password_file: /etc/alertmanager/secrets/smtp_password
  smtp_require_tls: true
  slack_api_url_file: /etc/alertmanager/secrets/slack_webhook
  pagerduty_url: https://events.pagerduty.com/v2/enqueue

templates:
  - /etc/alertmanager/templates/*.tmpl

route:
  # The root route is the default receiver and the default grouping.
  receiver: platform-slack
  group_by: ['alertname', 'cluster', 'namespace']
  group_wait:      30s
  group_interval:  5m
  repeat_interval: 4h

  routes:
    # ---- Anything explicitly marked as "do not notify" ------------------
    - receiver: 'null'
      matchers:
        - severity = "none"

    # ---- Watchdog / DeadMansSwitch: an always-firing alert that proves
    #      the whole pipeline works. Route it to an external heartbeat
    #      service that pages when it STOPS arriving.
    - receiver: deadmanssnitch
      matchers:
        - alertname = "Watchdog"
      group_wait:      0s
      group_interval:  5m
      repeat_interval: 5m

    # ---- Team routing. continue:false (default) means the first matching
    #      route wins and evaluation stops.
    - receiver: payments-pagerduty
      matchers:
        - team = "payments"
        - severity = "critical"
      group_by: ['alertname', 'service']
      group_wait: 10s
      routes:
        # Nested route: business-hours-only for warnings within the same team
        - receiver: payments-slack
          matchers:
            - severity =~ "warning|info"
          repeat_interval: 12h

    - receiver: platform-pagerduty
      matchers:
        - severity = "critical"
      # continue: true would ALSO evaluate subsequent sibling routes —
      # useful to mirror every page into a Slack channel.
      continue: true

    - receiver: platform-slack
      matchers:
        - severity =~ "warning|critical"

# Inhibition: when a bigger problem is firing, suppress the smaller symptoms.
inhibit_rules:
  # A critical alert suppresses the warning for the same object.
  - source_matchers:
      - severity = "critical"
    target_matchers:
      - severity = "warning"
    equal: ['alertname', 'cluster', 'instance']

  # A whole node being down suppresses every per-service alert on that node.
  - source_matchers:
      - alertname = "NodeDown"
    target_matchers:
      - severity =~ "warning|critical"
    equal: ['cluster', 'instance']

  # A cluster-wide network partition suppresses everything inside it.
  - source_matchers:
      - alertname = "ClusterNetworkPartition"
    target_matchers:
      - alertname !~ "ClusterNetworkPartition|Watchdog"
    equal: ['cluster']

# Recurring maintenance windows without creating silences by hand (0.28+).
time_intervals:
  - name: out-of-hours
    time_intervals:
      - weekdays: ['saturday', 'sunday']
      - times:
          - start_time: '18:00'
            end_time:   '24:00'
        location: 'Europe/Madrid'

receivers:
  - name: 'null'

  - name: platform-slack
    slack_configs:
      - channel: '#alerts-platform'
        send_resolved: true
        title: '{{ template "slack.title" . }}'
        text:  '{{ template "slack.text" . }}'
        actions:
          - type: button
            text: 'Runbook'
            url:  '{{ (index .Alerts 0).Annotations.runbook_url }}'
          - type: button
            text: 'Silence'
            url:  '{{ template "__alert_silence_link" . }}'

  - name: platform-pagerduty
    pagerduty_configs:
      - routing_key_file: /etc/alertmanager/secrets/pd_platform_key
        severity: '{{ if eq .CommonLabels.severity "critical" }}critical{{ else }}warning{{ end }}'
        description: '{{ .CommonAnnotations.summary }}'
        details:
          firing:       '{{ template "pagerduty.default.instances" .Alerts.Firing }}'
          cluster:      '{{ .CommonLabels.cluster }}'
          num_firing:   '{{ .Alerts.Firing | len }}'
          num_resolved: '{{ .Alerts.Resolved | len }}'

  - name: payments-pagerduty
    pagerduty_configs:
      - routing_key_file: /etc/alertmanager/secrets/pd_payments_key
        send_resolved: true

  - name: payments-slack
    slack_configs:
      - channel: '#alerts-payments'
        send_resolved: true

  - name: deadmanssnitch
    webhook_configs:
      - url_file: /etc/alertmanager/secrets/snitch_url
        send_resolved: false
```

**Nota sobre `matchers` vs `match`/`match_re`:** `match` y `match_re` están obsoletos. La lista moderna `matchers:` usa sintaxis estilo PromQL (`=`, `!=`, `=~`, `!~`) y es lo que esperan la documentación actual y la ventana de versiones del examen.

### 9.3 Plantillas de notificación

```gotemplate
{{/* /etc/alertmanager/templates/slack.tmpl */}}
{{ define "slack.title" -}}
[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .CommonLabels.alertname }} ({{ .CommonLabels.cluster }})
{{- end }}

{{ define "slack.text" -}}
{{ range .Alerts -}}
*Severity:* `{{ .Labels.severity }}`
*Summary:* {{ .Annotations.summary }}
*Description:* {{ .Annotations.description }}
*Instance:* `{{ .Labels.instance }}`
{{ if .Annotations.runbook_url }}*Runbook:* {{ .Annotations.runbook_url }}{{ end }}
*Source:* {{ .GeneratorURL }}
{{ end }}
{{- end }}
```

### 9.4 Alta disponibilidad

Alertmanager **sí** forma clúster, mediante una malla de gossip (memberlist de HashiCorp) en el puerto `9094`. Comparte los silences, las entradas del log de notificaciones y el estado de "quién ya notificó", de modo que N réplicas alimentadas por N servidores Prometheus avisan exactamente una vez.

```
$ /usr/local/bin/alertmanager \
    --config.file=/etc/alertmanager/alertmanager.yml \
    --storage.path=/var/lib/alertmanager \
    --web.listen-address=0.0.0.0:9093 \
    --web.external-url=https://alertmanager.prod.internal \
    --cluster.listen-address=0.0.0.0:9094 \
    --cluster.peer=alertmanager-00.prod.internal:9094 \
    --cluster.peer=alertmanager-01.prod.internal:9094 \
    --cluster.peer=alertmanager-02.prod.internal:9094
```

Verificá que la malla se formó:

```
$ curl -s http://localhost:9093/api/v2/status | jq '.cluster'
{
  "name": "01J9KPQ7R3TZ2XY8F0V4M6NBWE",
  "peers": [
    { "address": "10.2.1.11:9094", "name": "01J9KPQ7R3TZ2XY8F0V4M6NBWE" },
    { "address": "10.2.1.12:9094", "name": "01J9KPT4V8H2C5K7Q1S9Y0AZDM" },
    { "address": "10.2.1.13:9094", "name": "01J9KPW1X6L4N8B3G5D7J2FQRT" }
  ],
  "status": "ready"
}
```

**Antipatrón:** poner las réplicas de Alertmanager detrás de un balanceador y apuntar Prometheus a la VIP. Prometheus debe enviar a **todas** las réplicas — listalas todas en `alerting.alertmanagers`. La deduplicación la hace la malla, no el balanceador.

### 9.5 `amtool`

```
$ cat ~/.config/amtool/config.yml
alertmanager.url: http://localhost:9093
output: extended

$ amtool check-config /etc/alertmanager/alertmanager.yml
Checking '/etc/alertmanager/alertmanager.yml'  SUCCESS
Found:
 - global config
 - route
 - 3 inhibit rules
 - 6 receivers
 - 1 templates
  SUCCESS

# Which receiver would this alert reach? Test routing WITHOUT firing anything.
$ amtool config routes test --config.file=/etc/alertmanager/alertmanager.yml \
    severity=critical team=payments cluster=prod-eu-west-1
payments-pagerduty

$ amtool config routes test --config.file=/etc/alertmanager/alertmanager.yml \
    severity=warning team=platform
platform-slack

# Visualise the whole routing tree
$ amtool config routes --config.file=/etc/alertmanager/alertmanager.yml
Routing tree:
└── default-route  receiver: platform-slack
    ├── {severity="none"}  receiver: null
    ├── {alertname="Watchdog"}  receiver: deadmanssnitch
    ├── {team="payments",severity="critical"}  receiver: payments-pagerduty
    │   └── {severity=~"warning|info"}  receiver: payments-slack
    ├── {severity="critical"}  receiver: platform-pagerduty  [continue]
    └── {severity=~"warning|critical"}  receiver: platform-slack

$ amtool alert query --alertmanager.url=http://localhost:9093
Alertname                Starts At                Summary                                          State
TargetDown               2026-09-03 09:14:22 UTC  Target web03:9100 (node) is down                  active
ErrorBudgetBurnFast      2026-09-03 09:31:07 UTC  api burning error budget 14.4x — page             active
Watchdog                 2026-08-19 11:02:44 UTC  This alert always fires                           active

# Silence during a maintenance window
$ amtool silence add alertname=TargetDown instance=web03:9100 \
    --duration=2h --comment="planned kernel upgrade, INC-4412" --author="$USER"
b1f7c0e2-4a9d-4a1e-9c3f-2ad0e6f8a119

$ amtool silence query
ID                                    Matchers                                   Ends At                  Created By  Comment
b1f7c0e2-4a9d-4a1e-9c3f-2ad0e6f8a119  alertname=TargetDown instance=web03:9100   2026-09-03 12:47:10 UTC  dalmine     planned kernel upgrade, INC-4412

$ amtool silence expire b1f7c0e2-4a9d-4a1e-9c3f-2ad0e6f8a119
```

---

## 10. Exporters e instrumentación

### 10.1 El panorama de exporters

| Exporter | Puerto | Expone | Notas |
|---|---|---|---|
| `node_exporter` | 9100 | Métricas de host Linux/BSD: CPU, memoria, disco, sistema de archivos, red, systemd, hwmon | La base. Corrélo en todos los hosts |
| `windows_exporter` | 9182 | El equivalente para Windows | |
| `blackbox_exporter` | 9115 | Sondea HTTP(S), TCP, ICMP, DNS, gRPC desde afuera | Patrón multi-target |
| `pushgateway` | 9091 | Búfer para jobs batch | Usalo con moderación |
| `cAdvisor` | 8080 | CPU/memoria/red por contenedor | Integrado en el kubelet |
| `kube-state-metrics` | 8080/8081 | **Estado de los objetos** de Kubernetes (réplicas deseadas vs listas, fase del pod, estado de los jobs) | No es uso de recursos — eso es cAdvisor |
| `mysqld_exporter` | 9104 | MySQL/MariaDB | |
| `postgres_exporter` | 9187 | PostgreSQL | |
| `redis_exporter` | 9121 | Redis | |
| `snmp_exporter` | 9116 | Equipamiento de red vía SNMP | Patrón multi-target como blackbox |
| `process-exporter` | 9256 | Métricas por grupo de procesos | |
| `statsd_exporter` | 9102 (scrape) / 9125 (statsd) | Puente del push de StatsD al pull de Prometheus | Herramienta de migración |

### 10.2 `node_exporter` en producción

```
$ sudo useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
$ sudo install -m 0755 node_exporter /usr/local/bin/node_exporter
$ sudo install -d -o node_exporter -g node_exporter /var/lib/node_exporter/textfile_collector
```

```ini
# /etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=:9100 \
  --collector.systemd \
  --collector.processes \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector \
  --collector.filesystem.mount-points-exclude='^/(dev|proc|sys|run/credentials/.+|var/lib/docker/.+|var/lib/kubelet/.+)($|/)' \
  --collector.filesystem.fs-types-exclude='^(autofs|binfmt_misc|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|mqueue|nsfs|overlay|proc|procfs|pstore|securityfs|selinuxfs|squashfs|sysfs|tracefs)$' \
  --no-collector.wifi \
  --no-collector.infiniband
Restart=on-failure
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```
$ sudo systemctl daemon-reload && sudo systemctl enable --now node_exporter
$ systemctl is-active node_exporter
active
$ curl -s localhost:9100/metrics | grep -c '^[a-z]'
1247
```

**El textfile collector** es cómo exponés cualquier cosa que no tenga exporter — resultados de cron, estado de hardware, conteo de paquetes. Escribí archivos `*.prom` de forma atómica (escribí a un archivo temporal y después `mv` — un archivo escrito a medias produce un error de parseo y un scrape fallido):

```bash
#!/usr/bin/env bash
# /usr/local/bin/backup-metrics.sh — run from the backup cron job
set -euo pipefail
DIR=/var/lib/node_exporter/textfile_collector
TMP=$(mktemp "$DIR/backup.prom.XXXXXX")
trap 'rm -f "$TMP"' EXIT

start=$(date +%s)
/usr/local/bin/run-backup.sh; rc=$?
end=$(date +%s)

cat > "$TMP" <<EOF
# HELP backup_last_success_timestamp_seconds Unix time of the last successful backup.
# TYPE backup_last_success_timestamp_seconds gauge
backup_last_success_timestamp_seconds $( [ $rc -eq 0 ] && echo "$end" || echo 0 )
# HELP backup_duration_seconds Duration of the last backup run.
# TYPE backup_duration_seconds gauge
backup_duration_seconds $((end - start))
# HELP backup_exit_code Exit code of the last backup run.
# TYPE backup_exit_code gauge
backup_exit_code $rc
EOF

chmod 0644 "$TMP"
mv "$TMP" "$DIR/backup.prom"
trap - EXIT
```

Después alertá sobre la obsolescencia en vez de sobre el fallo — esto captura "el job de cron nunca se ejecutó", algo que una métrica de fallo no puede:

```promql
time() - backup_last_success_timestamp_seconds > 26 * 3600
```

`node_textfile_scrape_error` se pone en `1` cuando un archivo `.prom` no se puede parsear; alertá siempre sobre eso.

### 10.3 `blackbox_exporter`

```yaml
# /etc/blackbox_exporter/blackbox.yml
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []          # empty means 2xx
      method: GET
      follow_redirects: true
      preferred_ip_protocol: ip4
      ip_protocol_fallback: false
      fail_if_ssl: false
      fail_if_not_ssl: true
      tls_config:
        insecure_skip_verify: false

  http_post_json:
    prober: http
    timeout: 5s
    http:
      method: POST
      headers:
        Content-Type: application/json
      body: '{"probe":"synthetic"}'
      valid_status_codes: [200, 201, 202]
      fail_if_body_not_matches_regexp:
        - '"status"\s*:\s*"ok"'

  tcp_connect:
    prober: tcp
    timeout: 5s

  postgres_banner:
    prober: tcp
    tcp:
      query_response:
        - expect: "^.*PostgreSQL.*$"

  icmp_ping:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4

  dns_soa:
    prober: dns
    dns:
      query_name: example.com
      query_type: SOA
      valid_rcodes: [NOERROR]
      validate_answer_rrs:
        fail_if_not_matches_regexp:
          - 'example\.com\.\s+\d+\s+IN\s+SOA\s+ns1\.example\.com\.'
```

El exporter es sin estado: sondea bajo demanda, cuando Prometheus le pasa `?target=`. Probalo directamente:

```
$ curl -s 'http://localhost:9115/probe?target=https://www.example.com/healthz&module=http_2xx'
# HELP probe_dns_lookup_time_seconds Returns the time taken for probe dns lookup in seconds
# TYPE probe_dns_lookup_time_seconds gauge
probe_dns_lookup_time_seconds 0.004112
# HELP probe_duration_seconds Returns how long the probe took to complete in seconds
# TYPE probe_duration_seconds gauge
probe_duration_seconds 0.187433
# HELP probe_http_status_code Response HTTP status code
# TYPE probe_http_status_code gauge
probe_http_status_code 200
# HELP probe_http_ssl Indicates if SSL was used for the final redirect
# TYPE probe_http_ssl gauge
probe_http_ssl 1
# HELP probe_ssl_earliest_cert_expiry Returns last SSL chain expiry in unixtime
# TYPE probe_ssl_earliest_cert_expiry gauge
probe_ssl_earliest_cert_expiry 1.7737632e+09
# HELP probe_success Displays whether or not the probe was a success
# TYPE probe_success gauge
probe_success 1
```

Agregá `&debug=true` para obtener una traza completa del sondeo (resolución DNS, handshake TLS, redirecciones) — la forma más rápida de diagnosticar un check sintético que falla.

Las dos alertas que se pagan solas:

```yaml
      - alert: ProbeFailed
        expr: probe_success == 0
        for: 5m
        labels: { severity: critical }
        annotations:
          summary: "Probe of {{ $labels.instance }} failing"

      - alert: TLSCertExpiringSoon
        expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 21
        for: 1h
        labels: { severity: warning }
        annotations:
          summary: "TLS cert for {{ $labels.instance }} expires in {{ $value | printf \"%.0f\" }} days"
```

### 10.4 Pushgateway: qué es y qué no es

Pushgateway es una **caché**, no un proxy. Retiene las métricas pusheadas para siempre hasta que se borran explícitamente, y Prometheus lo scrapea *a él*.

```
# A batch job pushes on completion. The grouping key is the URL path.
$ cat <<'EOF' | curl --data-binary @- \
    http://pushgateway.prod.internal:9091/metrics/job/nightly_etl/instance/etl01
# TYPE etl_last_success_timestamp_seconds gauge
etl_last_success_timestamp_seconds 1756890123
# TYPE etl_records_processed_total counter
etl_records_processed_total 4821993
# TYPE etl_duration_seconds gauge
etl_duration_seconds 913.4
EOF

$ curl -s http://pushgateway.prod.internal:9091/metrics | grep etl_
etl_duration_seconds{instance="etl01",job="nightly_etl"} 913.4
etl_last_success_timestamp_seconds{instance="etl01",job="nightly_etl"} 1.756890123e+09
etl_records_processed_total{instance="etl01",job="nightly_etl"} 4.821993e+06

# Deleting a group (otherwise the metrics persist forever)
$ curl -X DELETE http://pushgateway.prod.internal:9091/metrics/job/nightly_etl/instance/etl01
```

| Propiedad | Consecuencia |
|---|---|
| Las métricas persisten más allá de la muerte del job que las pushea | Ese es el punto — podés ver el resultado de la última ejecución |
| Las métricas persisten más allá de que *vos* te olvides de borrarlas | Las métricas de un job desmantelado alertan para siempre. **Tenés que hacer DELETE.** |
| El propio Pushgateway se convierte en un único punto de fallo | Y su propio `up` es la única señal de vida |
| Los timestamps son los del **scrape**, no los del push | Por eso el modismo es un gauge `*_last_success_timestamp_seconds`, nunca un gauge de "tiempo transcurrido" |
| `honor_labels: true` es obligatorio en la configuración de scrape | Si no, los `job`/`instance` pusheados quedan sobrescritos por los del propio gateway |

**Usalo solo para jobs batch a nivel de servicio.** No lo uses para hacer que el pull "funcione" para servicios detrás de NAT — usá ahí un agente de Prometheus.

### 10.5 Instrumentación directa

El código de la aplicación debería exponer métricas de forma nativa. Python (`prometheus_client`):

```python
"""Minimal production instrumentation: RED metrics for a Flask service."""
from flask import Flask, request, Response
from prometheus_client import (
    Counter, Histogram, Gauge, Info,
    CONTENT_TYPE_LATEST, generate_latest,
)
import time

app = Flask(__name__)

REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests.",
    ["method", "handler", "status"],
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency.",
    ["method", "handler"],
    # Buckets MUST straddle the SLO threshold (250 ms here).
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)
IN_FLIGHT = Gauge(
    "http_requests_in_flight",
    "Requests currently being served.",
)
BUILD = Info("app_build", "Build metadata.")
BUILD.info({"version": "1.14.2", "revision": "9a3f1c4", "goversion": "n/a"})


@app.before_request
def _start_timer():
    request._start = time.perf_counter()
    IN_FLIGHT.inc()


@app.after_request
def _record(response):
    IN_FLIGHT.dec()
    # request.url_rule, not request.path: the path contains IDs and would
    # create one series per order. This is the cardinality discipline.
    handler = request.url_rule.rule if request.url_rule else "<unmatched>"
    elapsed = time.perf_counter() - request._start
    LATENCY.labels(request.method, handler).observe(elapsed)
    REQUESTS.labels(request.method, handler, response.status_code).inc()
    return response


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)
```

**La regla de cardinalidad, enunciada con precisión:** el total de series de una métrica = el producto de la cantidad de valores distintos de cada uno de sus labels. `handler` (50) × `method` (5) × `status` (8) = 2.000 series — está bien. Agregá `user_id` (2.000.000) y tenés 4 mil millones — el servidor se muere. Los labels deben tener conjuntos de valores **acotados y de baja cardinalidad**: nunca IDs de usuario, IDs de petición, IDs de sesión, direcciones de correo, URLs completas, timestamps ni mensajes de error.

---

## 11. Kubernetes: el Prometheus Operator

En Kubernetes, editar `prometheus.yml` a mano es un antipatrón — el Operator lo genera a partir de CRDs, de modo que los equipos de aplicación declaran su propio scraping sin tocar la configuración de la plataforma.

| CRD | Propósito |
|---|---|
| `Prometheus` | El servidor en sí: réplicas, retención, almacenamiento, límites de recursos, qué selectores respetar |
| `ServiceMonitor` | Scrapear los endpoints detrás de un `Service` (el caso común) |
| `PodMonitor` | Scrapear pods directamente, sin necesidad de un Service |
| `Probe` | Sondeo estilo blackbox de targets estáticos o de Ingresses |
| `PrometheusRule` | Reglas de recording y de alerting |
| `Alertmanager` / `AlertmanagerConfig` | El clúster de Alertmanager, y el enrutamiento por namespace |
| `ScrapeConfig` (v1alpha1) | Configuración de scrape en crudo para targets fuera del clúster |

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: k8s
  namespace: monitoring
spec:
  replicas: 2
  shards: 1
  version: v3.1.0
  image: quay.io/prometheus/prometheus:v3.1.0
  serviceAccountName: prometheus-k8s
  retention: 15d
  retentionSize: 90GB
  scrapeInterval: 30s
  evaluationInterval: 30s
  externalLabels:
    cluster: prod-eu-west-1
  enableFeatures:
    - exemplar-storage
    - native-histograms
  # Empty selectors = watch ALL namespaces for ALL ServiceMonitors.
  # In a multi-tenant cluster, restrict with matchLabels instead.
  serviceMonitorSelector: {}
  serviceMonitorNamespaceSelector: {}
  podMonitorSelector: {}
  podMonitorNamespaceSelector: {}
  probeSelector: {}
  ruleSelector:
    matchLabels:
      prometheus: k8s
      role: alert-rules
  alerting:
    alertmanagers:
      - namespace: monitoring
        name: alertmanager-main
        port: web
        apiVersion: v2
  resources:
    requests:
      cpu: "1"
      memory: 6Gi
    limits:
      memory: 10Gi
  storage:
    volumeClaimTemplate:
      spec:
        storageClassName: fast-ssd
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 120Gi
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    fsGroup: 65534
  # Never schedule both replicas on the same node — that defeats the HA pair.
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
          topologyKey: kubernetes.io/hostname
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api
  namespace: production
  labels:
    team: api
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: api
  namespaceSelector:
    matchNames: ["production"]
  endpoints:
    - port: metrics            # the NAME of the port in the Service, not the number
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      scheme: https
      tlsConfig:
        ca:
          secret:
            name: api-tls
            key: ca.crt
        serverName: api.production.svc
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: 'go_gc_duration_seconds.*'
          action: drop
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: production
  labels:
    app.kubernetes.io/name: api
spec:
  selector:
    app.kubernetes.io/name: api
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: metrics          # this name is what the ServiceMonitor references
      port: 9090
      targetPort: 9090
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: api-slo
  namespace: production
  labels:
    prometheus: k8s          # must match Prometheus.spec.ruleSelector
    role: alert-rules
spec:
  groups:
    - name: api.slo
      interval: 30s
      rules:
        - record: job:slo_errors:ratio_rate5m
          expr: |
               sum by (job) (rate(http_requests_total{job="api",status=~"5.."}[5m]))
             / sum by (job) (rate(http_requests_total{job="api"}[5m]))
        - alert: ApiHighErrorRate
          expr: job:slo_errors:ratio_rate5m{job="api"} > 0.01
          for: 10m
          labels:
            severity: critical
            team: api
          annotations:
            summary: "api 5xx ratio is {{ $value | humanizePercentage }}"
            runbook_url: https://runbooks.internal/api/HighErrorRate
---
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: public-endpoints
  namespace: monitoring
  labels:
    prometheus: k8s
spec:
  interval: 60s
  module: http_2xx
  prober:
    url: blackbox-exporter.monitoring.svc:19115
    path: /probe
  targets:
    staticConfig:
      static:
        - https://www.example.com/healthz
        - https://api.example.com/readyz
      labels:
        tier: public
```

Fijate en el RBAC que necesita el servidor — sin él, `kubernetes_sd` devuelve cero targets en silencio:

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-k8s
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/metrics", "services", "endpoints", "pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get"]
  - nonResourceURLs: ["/metrics", "/metrics/cadvisor"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-k8s
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus-k8s
subjects:
  - kind: ServiceAccount
    name: prometheus-k8s
    namespace: monitoring
```

Instalá con `kube-prometheus-stack`, que empaqueta Prometheus, Alertmanager, Grafana, node_exporter, kube-state-metrics y un conjunto curado de reglas:

```
$ helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
$ helm repo update
$ helm upgrade --install kps prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --set prometheus.prometheusSpec.retention=15d \
    --set prometheus.prometheusSpec.replicas=2 \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --wait

$ kubectl -n monitoring get pods
NAME                                              READY   STATUS    RESTARTS   AGE
alertmanager-kps-alertmanager-0                   2/2     Running   0          3m11s
kps-grafana-7d8b4c9f5d-2xk4q                      3/3     Running   0          3m11s
kps-kube-state-metrics-6b9d7c4f88-mzp7l           1/1     Running   0          3m11s
kps-prometheus-node-exporter-4jt2k                1/1     Running   0          3m11s
kps-prometheus-node-exporter-9vqxc                1/1     Running   0          3m11s
kps-operator-5f4c8d9b76-hg2wt                     1/1     Running   0          3m11s
prometheus-kps-prometheus-0                       2/2     Running   0          3m05s
prometheus-kps-prometheus-1                       2/2     Running   0          3m05s
```

**El flag `serviceMonitorSelectorNilUsesHelmValues=false` es el gotcha número 1:** por defecto el chart hace que Prometheus seleccione solo los ServiceMonitors que llevan el label de release del chart, así que tus propios ServiceMonitors se ignoran en silencio.

---

## 12. Escalar más allá de un servidor

| Enfoque | Mecanismo | Cuándo usarlo | Compromiso |
|---|---|---|---|
| **Federación** | Un Prometheus "global" scrapea `/federate?match[]=` en los servidores hoja, trayendo solo recording rules agregadas | Jerarquías pequeñas; consolidaciones entre datacenters | Basado en pull y síncrono: una hoja lenta ralentiza al global. Nunca federes series crudas — vas a recrear la cardinalidad de la hoja de forma centralizada |
| **Sharding funcional** | El relabeling con `hashmod` reparte los targets entre N servidores; cada uno es independiente | Escalar el scraping linealmente | Las consultas entre shards requieren una capa de consulta |
| **`remote_write` → Thanos Receive / Mimir / Cortex** | Prometheus empuja cada muestra a un sistema escalable horizontalmente respaldado por object storage | La respuesta moderna por defecto para retención larga y vista global | Otro sistema distribuido que operar |
| **Thanos Sidecar** | El sidecar sube los bloques de la TSDB a object storage; el Thanos Querier hace fan-out sobre los sidecars + el store gateway | Retención larga con cambios mínimos en Prometheus | Latencia de consulta sobre object storage; necesita downsampling (Compactor) |
| **Modo agente** | `--agent`: solo scrape + remote_write, solo WAL, sin consultas, sin reglas | Borde/CI/clústeres efímeros | No puede consultar ni alertar localmente |

Configuración de federación, hecha correctamente (solo agregados):

```yaml
  - job_name: federate
    scrape_interval: 60s
    honor_labels: true            # keep the leaf's job/instance labels
    metrics_path: /federate
    params:
      'match[]':
        - '{__name__=~"job:.*"}'          # recording rules only
        - '{__name__=~"cluster:.*"}'
        - 'up{job=~"node|api"}'
    static_configs:
      - targets:
          - prometheus-eu-west-1.internal:9090
          - prometheus-us-east-1.internal:9090
```

---

## 13. Grafana

Grafana es la capa de visualización; no guarda datos propios. Todo debería aprovisionarse como código — un dashboard hecho a mano con clics es una caída esperando ocurrir.

```yaml
# /etc/grafana/provisioning/datasources/prometheus.yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy               # Grafana's backend queries Prometheus, not the browser
    url: https://prometheus.prod.internal
    uid: prometheus-prod
    isDefault: true
    editable: false
    jsonData:
      httpMethod: POST          # POST allows very long queries (no URL length limit)
      timeInterval: 15s         # MUST equal the scrape interval: drives $__rate_interval
      queryTimeout: 120s
      manageAlerts: false       # rules live in Prometheus, not in Grafana
      prometheusType: Prometheus
      prometheusVersion: 3.1.0
      incrementalQuerying: true
      exemplarTraceIdDestinations:
        - name: trace_id
          datasourceUid: tempo-prod
      tlsAuthWithCACert: true
    secureJsonData:
      tlsCACert: ${PROM_CA_CERT}
      httpHeaderValue1: ${PROM_BEARER_TOKEN}
    jsonData_httpHeaderName1: Authorization
```

```yaml
# /etc/grafana/provisioning/dashboards/platform.yaml
apiVersion: 1

providers:
  - name: platform
    orgId: 1
    folder: Platform
    folderUid: platform
    type: file
    disableDeletion: true
    updateIntervalSeconds: 30
    allowUiUpdates: false        # dashboards are code; UI edits are discarded
    options:
      path: /var/lib/grafana/dashboards/platform
      foldersFromFilesStructure: true
```

**`$__rate_interval` es el detalle más importante de Grafana/Prometheus.** Grafana lo calcula como `max(4 × scrape_interval, $__interval + scrape_interval)`. Escribí siempre `rate(x[$__rate_interval])` — nunca `rate(x[5m])` y nunca `rate(x[$__interval])`. `$__interval` solo se achica cuando hacés zoom y termina conteniendo menos de 2 muestras, momento en el cual el gráfico se vacía en silencio. Esta es la causa del clásico bug de "mi dashboard queda vacío cuando hago zoom", y `timeInterval` en la datasource es lo que hace que el cálculo sea correcto.

---

## 14. Asegurar el stack

Prometheus, Alertmanager y los exporters vienen **sin autenticación por defecto**. Un endpoint `/metrics` filtra toda tu topología; la API de administración puede borrar datos.

```yaml
# /etc/prometheus/web.yml — same schema for alertmanager and the exporters
tls_server_config:
  cert_file: /etc/prometheus/certs/prometheus.crt
  key_file:  /etc/prometheus/certs/prometheus.key
  client_auth_type: RequireAndVerifyClientCert   # mTLS
  client_ca_file: /etc/prometheus/certs/internal-ca.pem
  min_version: TLS12
  cipher_suites:
    - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
    - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384

basic_auth_users:
  # bcrypt hash — generate with: htpasswd -nBC 12 "" | tr -d ':\n'
  admin: $2y$12$ZQ8k1YbF4d2X6uJv0nRl9eK7hT3sA5mW1cP8qD0gB2xN4rV6yH8Ou

http_server_config:
  http2: true
```

Después, las configuraciones de scrape que apuntan a targets protegidos con TLS necesitan:

```yaml
    scheme: https
    basic_auth:
      username: prometheus
      password_file: /etc/prometheus/secrets/scrape_password
    tls_config:
      ca_file: /etc/prometheus/certs/internal-ca.pem
      cert_file: /etc/prometheus/certs/prometheus-client.crt
      key_file:  /etc/prometheus/certs/prometheus-client.key
      insecure_skip_verify: false
```

Checklist:
- Mantené `--web.enable-admin-api` y `--web.enable-lifecycle` **desactivados** salvo que un pipeline de despliegue los necesite, y en ese caso restringilos en el reverse proxy.
- Bindeá los exporters a una interfaz de administración o usá una NetworkPolicy; `node_exporter` en `0.0.0.0:9100` en un host público es una divulgación de información.
- Los silences de Alertmanager no están autenticados por defecto — cualquiera que llegue a `:9093` puede silenciar tu guardia. Poné SSO delante.
- Nunca pongas secretos en los labels. Todo valor de label es legible por cualquiera que pueda consultar.

---

## 15. Verificación y diagnóstico de fallos

### 15.1 La escalera de preflight — siempre en este orden

```
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
 SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax
 SUCCESS: 4 rule files found
Checking /etc/prometheus/rules/recording/api.yml
 SUCCESS: 6 rules found
Checking /etc/prometheus/rules/alerting/platform.yml
 SUCCESS: 9 rules found

$ promtool check rules /etc/prometheus/rules/alerting/*.yml
Checking /etc/prometheus/rules/alerting/platform.yml
 SUCCESS: 9 rules found

$ promtool test rules /etc/prometheus/rules/tests/*.yml
Unit Testing:  /etc/prometheus/rules/tests/node_test.yml
  SUCCESS

$ amtool check-config /etc/alertmanager/alertmanager.yml
Checking '/etc/alertmanager/alertmanager.yml'  SUCCESS
```

Un error de sintaxis es explícito sobre el archivo y la línea:

```
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
  FAILED: parsing YAML file /etc/prometheus/prometheus.yml: yaml: unmarshal errors:
  line 34: field scrape_intervals not found in type config.ScrapeConfig
```

Validá la salida de un exporter antes de cablearlo:

```
$ curl -s http://localhost:9100/metrics | promtool check metrics
node_scrape_collector_success non-histogram and non-summary metrics should not have "_sum" suffix
```

### 15.2 Salud y estado en tiempo de ejecución

```
$ curl -s http://localhost:9090/-/healthy       # process is alive
Prometheus Server is Healthy.
$ curl -s http://localhost:9090/-/ready         # ready to serve queries (WAL replayed)
Prometheus Server is Ready.

$ curl -s http://localhost:9090/api/v1/status/runtimeinfo | jq
{
  "status": "success",
  "data": {
    "startTime": "2026-09-01T04:12:33.914Z",
    "CWD": "/var/lib/prometheus",
    "reloadConfigSuccess": true,
    "lastConfigTime": "2026-09-03T08:41:02Z",
    "corruptionCount": 0,
    "goroutineCount": 1284,
    "GOMAXPROCS": 8,
    "GOMEMLIMIT": 10737418240,
    "storageRetention": "30d"
  }
}

$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data | {numSeries, chunkCount, headStats}'
{
  "numSeries": 1184392,
  "chunkCount": 1341882,
  "headStats": {
    "numSeries": 1184392,
    "numLabelPairs": 41209,
    "chunkCount": 1341882,
    "minTime": 1756880400000,
    "maxTime": 1756887600000
  }
}
```

### 15.3 Diagnóstico de targets

```
$ curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[]
           | select(.health!="up")
           | [.labels.job, .scrapeUrl, .health, .lastError] | @tsv'
node	http://web03.prod.internal:9100/metrics	down	Get "http://web03.prod.internal:9100/metrics": dial tcp 10.2.4.13:9100: connect: connection refused
api	https://api-7f9c.prod:8443/metrics	down	Get "https://api-7f9c.prod:8443/metrics": x509: certificate signed by unknown authority
kafka	http://kafka02.prod:9308/metrics	down	server returned HTTP status 500 Internal Server Error
```

**¿Por qué falta un target por completo?** Revisá qué devolvió el SD *antes* del relabeling:

```
$ curl -s 'http://localhost:9090/api/v1/targets?state=dropped&scrapePool=kubernetes-pods' \
  | jq -r '.data.droppedTargets[0:3][] | .discoveredLabels'
{
  "__address__": "10.244.2.17:8080",
  "__meta_kubernetes_namespace": "default",
  "__meta_kubernetes_pod_name": "nginx-6f4d8c9b7-x2k4q",
  "__meta_kubernetes_pod_phase": "Running",
  "__scheme__": "http",
  "job": "kubernetes-pods"
}
```

Acá `__meta_kubernetes_pod_annotation_prometheus_io_scrape` está ausente → la regla `keep` descartó el target. Esa es la respuesta, y ninguna cantidad de reinicios la va a cambiar.

**Simulá el relabeling offline** antes de desplegar un cambio de configuración:

```
$ promtool check service-discovery /etc/prometheus/prometheus.yml kubernetes-pods
```

También está disponible en la UI web en **Status → Service Discovery**, que muestra los labels descubiertos junto al resultado posterior al relabeling, lado a lado — la forma más rápida de depurar una cadena de relabeling.

### 15.4 Consultar desde la CLI

```
$ promtool query instant http://localhost:9090 'up{job="node"} == 0'
up{instance="web03.prod.internal:9100", job="node"} => 0 @[1756890631.412]

$ promtool query range --start=2026-09-03T08:00:00Z --end=2026-09-03T09:00:00Z --step=5m \
    http://localhost:9090 'sum(rate(http_requests_total{job="api"}[5m]))'
{} =>
1284.31 @[1756886400]
1301.77 @[1756886700]
1298.02 @[1756887000]
...

# Which labels exist, and what values do they take? Essential for cardinality work.
$ promtool query labels http://localhost:9090 handler | head
/api/v1/orders
/api/v1/orders/{id}
/api/v1/users
/healthz
/metrics

$ promtool query series http://localhost:9090 --match='up{job="node"}'
{__name__="up", instance="web01.prod.internal:9100", job="node"}
{__name__="up", instance="web02.prod.internal:9100", job="node"}
{__name__="up", instance="web03.prod.internal:9100", job="node"}
```

### 15.5 Forense de cardinalidad — el fallo de producción número 1

El proceso de Prometheus hace OOM, o se detiene la ingesta. La causa casi siempre es un label nuevo sin cota. **No corras `count by (__name__)({__name__=~".+"})` en un servidor moribundo** — lo vas a rematar. Usá el analizador offline:

```
$ promtool tsdb analyze /var/lib/prometheus
Block ID: 01J9KM4Z2QW8XG7T5F3B0RNVHD
Duration: 2h0m0s
Series: 1184392
Label names: 187
Postings (unique label pairs): 41209
Postings entries (total label pairs): 9847221

Label pairs most involved in churning:
41221 job=api
38904 namespace=production
12044 __name__=http_request_duration_seconds_bucket

Label names with highest cumulative label value length:
2894112 request_id
 184229 pod
  99182 instance

Highest cardinality labels:
884301 request_id          <-- THE BUG
  9814 pod
   412 instance
   187 handler
    24 job

Highest cardinality metric names:
812004 http_request_duration_seconds_bucket
198221 http_requests_total
 40118 go_gc_duration_seconds
```

`request_id` con 884.301 valores distintos es el culpable. Mitigación inmediata, sin necesidad de desplegar la aplicación:

```yaml
    metric_relabel_configs:
      - regex: 'request_id'
        action: labeldrop
```

```
$ sudo systemctl reload prometheus
```

Después recuperá el disco (requiere `--web.enable-admin-api`):

```
$ curl -s -X POST -g \
  'http://localhost:9090/api/v1/admin/tsdb/delete_series?match[]={__name__=~"http_.*",request_id!=""}'
$ curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/clean_tombstones
```

La prevención son `sample_limit` y `label_limit` en la configuración de scrape: el scrape falla ruidosamente (`sample limit exceeded`) en vez de que el servidor se muera calladito.

### 15.6 Catálogo de fallos

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| `up == 0`, `connect: connection refused` | Exporter caído, puerto equivocado, firewall | `curl http://target:9100/metrics` desde el host de Prometheus; `ss -lntp \| grep 9100` en el target | Arrancar el exporter / abrir el puerto |
| `up == 0`, `context deadline exceeded` | Target más lento que `scrape_timeout`; demasiadas series | `time curl -s target/metrics \| wc -l` | Subir `scrape_timeout` (≤ `scrape_interval`), o reducir las métricas expuestas |
| `up == 0`, `x509: certificate signed by unknown authority` | Falta `ca_file` en `tls_config` | `openssl s_client -connect target:8443 -showcerts` | Agregar la CA; nunca `insecure_skip_verify: true` en producción |
| Target ausente de `/targets` por completo | El relabeling lo descartó, o el SD no devolvió nada | `?state=dropped`; Status → Service Discovery | Corregir la regex de `keep`/`drop` o las credenciales/RBAC del SD |
| `sample limit exceeded` en `lastError` | El target expone más series que `sample_limit` | `curl target/metrics \| wc -l` | Descartar con `metric_relabel_configs`, o subir el límite deliberadamente |
| La consulta devuelve vacío, sin error | Rango demasiado corto para `rate()`; serie stale por más de 5 min; typo en un valor de label | Reducí la consulta al selector desnudo y agregá un matcher a la vez | Ampliar el rango a ≥4× el intervalo de scrape; revisar con `promtool query labels` |
| `found duplicate series for the match group` | Emparejamiento de vectores muchos-a-muchos | Correr cada lado por separado y comparar los conjuntos de labels | Agregar `on()`/`ignoring()` y `group_left`/`group_right` |
| Gráfico vacío al hacer zoom, bien al alejarse | `rate(x[$__interval])` en Grafana | Inspeccionar la consulta del panel | Usar `$__rate_interval` y definir `timeInterval` en la datasource |
| Alerta visible en Prometheus, nunca entregada | Alertmanager inalcanzable, ruta que no coincide, silence activo, inhibición | `prometheus_notifications_errors_total`; `amtool config routes test ...`; `amtool silence query` | Corregir el enrutamiento / expirar el silence / corregir la regla de inhibición |
| Alerta pending para siempre | La expresión oscila dentro de la ventana `for:`, reiniciando el temporizador | Graficar la expresión a lo largo de la ventana | Acortar `for:`, suavizar con un rango de `rate()` más largo, o agregar `keep_firing_for` |
| Avisos duplicados desde un par HA | El label `replica` no fue removido; los Alertmanagers no están en clúster | `curl :9093/api/v2/status \| jq .cluster` | Agregar el `labeldrop` sobre `replica`; corregir `--cluster.peer` |
| `out of order sample` en el log | Dos fuentes escribiendo la misma serie; desfase de reloj; `honor_timestamps` | `journalctl -u prometheus \| grep 'out of order'`; `chronyc tracking` | Deduplicar el target; arreglar NTP; configurar `out_of_order_time_window` |
| `duplicate sample for timestamp` | El target expone la misma serie dos veces en un scrape | `curl target/metrics \| sort \| uniq -d` | Arreglar el exporter/la instrumentación |
| El reinicio tarda muchos minutos | Reproducción del WAL | `journalctl -fu prometheus` muestra `replaying WAL` con un porcentaje de progreso | Normal. Reducir el tamaño del head (menos series) o usar `reload` en vez de `restart` |
| Disco lleno a pesar de la retención | La retención solo borra bloques enteros; la compactación necesita margen | `du -sh /var/lib/prometheus/*`; revisar los rangos temporales de `meta.json` | Definir `--storage.tsdb.retention.size` en ~80% del volumen |
| `remote_write` atrasándose | Endpoint lento, shards al tope, red | `prometheus_remote_storage_shards` vs `..._shards_max`; `..._samples_failed_total` | Subir `max_shards`, descartar series con `write_relabel_configs`, arreglar el receptor |
| Reglas evaluándose tarde / huecos en las series registradas | El grupo tarda más que su intervalo | `prometheus_rule_group_last_duration_seconds > prometheus_rule_group_interval_seconds` | Dividir en más grupos (se ejecutan en paralelo), simplificar expresiones, subir `interval` |

### 15.7 Profiling en vivo

Cuando el servidor está enfermo y nada de lo anterior lo explica:

```
$ go tool pprof -top http://localhost:9090/debug/pprof/heap
Showing nodes accounting for 5.82GB, 91.44% of 6.36GB total
      flat  flat%   sum%        cum   cum%
    2.91GB 45.75% 45.75%     2.91GB 45.75%  github.com/prometheus/prometheus/tsdb/index.(*MemPostings).Add
    1.44GB 22.64% 68.39%     1.44GB 22.64%  github.com/prometheus/prometheus/tsdb.newMemSeries
    0.98GB 15.41% 83.80%     0.98GB 15.41%  github.com/prometheus/prometheus/model/labels.New

# Capture a full bundle for an upstream bug report
$ promtool debug all http://localhost:9090
Compiling debug information complete, all files written in "debug.tar.gz".

# What is running right now / what was running when it died?
$ cat /var/lib/prometheus/queries.active
[{"query":"topk(20, count by (__name__)({__name__=~\".+\"}))","timestamp_sec":1756890612}]
```

Ese último archivo es la prueba irrefutable después de un OOM: nombra la consulta que mató al servidor.

### 15.8 Prueba de humo de extremo a extremo

El pipeline solo está probado cuando una alerta llega a un humano. Dispará una alerta sintética directo a Alertmanager:

```
$ curl -s -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[
  {
    "labels": {
      "alertname": "PipelineSmokeTest",
      "severity": "warning",
      "team": "platform",
      "cluster": "prod-eu-west-1",
      "instance": "smoke-test"
    },
    "annotations": {
      "summary": "End-to-end notification test, ignore",
      "description": "If you can read this in Slack, the pipeline works."
    },
    "startsAt": "2026-09-03T09:00:00Z",
    "endsAt": "2026-09-03T09:10:00Z"
  }
]'

$ amtool alert query alertname=PipelineSmokeTest
Alertname          Starts At                Summary                                    State
PipelineSmokeTest  2026-09-03 09:00:00 UTC  End-to-end notification test, ignore       active
```

Y mantené una alerta **Watchdog** permanente disparando en todo momento, enrutada a un servicio externo de dead-man's-switch. Es la única alerta que detecta "todo el stack de monitorización está caído" — porque un Prometheus roto no puede alertar sobre sí mismo.

```yaml
      - alert: Watchdog
        expr: vector(1)
        labels:
          severity: none
        annotations:
          summary: >-
            This alert always fires. Its absence means the alerting pipeline
            is broken and no other alert can be trusted.
```

---

## 16. Referencia rápida para el examen

**Puertos por defecto:** Prometheus `9090` · Alertmanager `9093` (gossip de clúster `9094`) · Pushgateway `9091` · node_exporter `9100` · blackbox_exporter `9115` · snmp_exporter `9116` · Grafana `3000` · cAdvisor `8080`

**Endpoints HTTP clave:** `/metrics` · `/-/healthy` · `/-/ready` · `/-/reload` (POST, necesita `--web.enable-lifecycle`) · `/api/v1/query` · `/api/v1/query_range` · `/api/v1/targets` · `/api/v1/rules` · `/api/v1/alerts` · `/api/v1/status/tsdb` · `/federate` · `/debug/pprof/`

**Archivos:** `prometheus.yml` · `alertmanager.yml` · `blackbox.yml` · archivos de reglas bajo `rule_files:` · TSDB en `--storage.tsdb.path` (por defecto `data/`)

**Valores por defecto:** `scrape_interval` 15 s (el valor por defecto de la configuración es 1 m si no se define) · `evaluation_interval` 1 m · retención 15 d · lookback-delta 5 m · `group_wait` 30 s · `group_interval` 5 m · `repeat_interval` 4 h · `resolve_timeout` 5 m

**Reflejos:**
- `rate()` para counters, nunca para gauges; rango ≥ 4 × el intervalo de scrape.
- `rate()` antes de `sum`, siempre.
- `histogram_quantile(φ, sum by (le) (rate(..._bucket[5m])))` — exactamente esa forma.
- Los histograms agregan; los summaries no.
- `relabel_configs` selecciona targets; `metric_relabel_configs` filtra muestras.
- `honor_labels: true` para Pushgateway y federación.
- Prometheus decide *firing*; Alertmanager decide *la notificación*.
- Los labels deben tener cardinalidad acotada. Siempre.

---

## Referencias

**Objetivos oficiales del examen**
- LPI — Exam 701 Objectives (DevOps Tools Engineer, 701-100 v2.0): https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI — DevOps Tools Engineer certification overview: https://www.lpi.org/our-certifications/devops-overview/

**Prometheus — conceptos y arquitectura**
- Overview and architecture: https://prometheus.io/docs/introduction/overview/
- Data model: https://prometheus.io/docs/concepts/data_model/
- Metric types: https://prometheus.io/docs/concepts/metric_types/
- Jobs and instances: https://prometheus.io/docs/concepts/jobs_instances/
- Comparison to alternatives: https://prometheus.io/docs/introduction/comparison/
- Storage and the TSDB: https://prometheus.io/docs/prometheus/latest/storage/
- Feature flags: https://prometheus.io/docs/prometheus/latest/feature_flags/
- Native histograms: https://prometheus.io/docs/specs/native_histograms/

**Configuración**
- Full configuration reference: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Recording rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Unit testing rules: https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- HTTPS and authentication: https://prometheus.io/docs/prometheus/latest/configuration/https/
- Command-line flags: https://prometheus.io/docs/prometheus/latest/command-line/prometheus/
- `promtool` reference: https://prometheus.io/docs/prometheus/latest/command-line/promtool/

**Consultas**
- PromQL basics: https://prometheus.io/docs/prometheus/latest/querying/basics/
- Operators and vector matching: https://prometheus.io/docs/prometheus/latest/querying/operators/
- Functions: https://prometheus.io/docs/prometheus/latest/querying/functions/
- Query examples: https://prometheus.io/docs/prometheus/latest/querying/examples/
- HTTP API: https://prometheus.io/docs/prometheus/latest/querying/api/

**Alertado**
- Alertmanager: https://prometheus.io/docs/alerting/latest/alertmanager/
- Alertmanager configuration: https://prometheus.io/docs/alerting/latest/configuration/
- Notification template reference: https://prometheus.io/docs/alerting/latest/notifications/
- Notification examples: https://prometheus.io/docs/alerting/latest/notification_examples/
- Alerting overview: https://prometheus.io/docs/alerting/latest/overview/

**Instrumentación y exporters**
- Exposition formats: https://prometheus.io/docs/instrumenting/exposition_formats/
- Metric and label naming: https://prometheus.io/docs/practices/naming/
- Instrumentation practices: https://prometheus.io/docs/practices/instrumentation/
- Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- When to use the Pushgateway: https://prometheus.io/docs/practices/pushing/
- List of exporters: https://prometheus.io/docs/instrumenting/exporters/
- `node_exporter`: https://github.com/prometheus/node_exporter
- `blackbox_exporter`: https://github.com/prometheus/blackbox_exporter
- `pushgateway`: https://github.com/prometheus/pushgateway
- Python client library: https://prometheus.github.io/client_python/

**Escalado y federación**
- Federation: https://prometheus.io/docs/prometheus/latest/federation/
- Remote write specification: https://prometheus.io/docs/specs/remote_write_spec/
- Remote write 2.0 specification: https://prometheus.io/docs/specs/remote_write_spec_2_0/
- Thanos: https://thanos.io/tip/thanos/getting-started.md/
- Grafana Mimir: https://grafana.com/docs/mimir/latest/

**Kubernetes**
- Prometheus Operator: https://prometheus-operator.dev/docs/getting-started/introduction/
- Operator API reference: https://prometheus-operator.dev/docs/api-reference/api/
- `kube-prometheus`: https://github.com/prometheus-operator/kube-prometheus
- `kube-state-metrics`: https://github.com/kubernetes/kube-state-metrics
- `kube-prometheus-stack` Helm chart: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

**Visualización**
- Grafana Prometheus data source: https://grafana.com/docs/grafana/latest/datasources/prometheus/
- Grafana provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/
- Grafana query editor and `$__rate_interval`: https://grafana.com/docs/grafana/latest/datasources/prometheus/query-editor/

**Estándares y práctica SRE**
- OpenMetrics: https://openmetrics.io/
- Google SRE Workbook — Alerting on SLOs: https://sre.google/workbook/alerting-on-slos/
- Google SRE Book — Monitoring Distributed Systems: https://sre.google/sre-book/monitoring-distributed-systems/