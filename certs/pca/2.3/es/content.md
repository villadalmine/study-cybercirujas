# Comprendiendo las Limitaciones de Prometheus

> PCA Dominio 2 — Fundamentos de Prometheus · Tema 2.3 · Peso en el examen: 4
> Nivel: SRE / Platform Architect · Idioma de autoría: English

---

## 1. Motivación — el contrato arquitectónico que realmente estás firmando

Prometheus es un binario, una TSDB local, un proceso, en un nodo. Eso no es un accidente ni una funcionalidad inconclusa — es la decisión de diseño central, y toda limitación de este tema es una consecuencia directa de ello. El proyecto enuncia el contrato de forma explícita:

> "Prometheus values reliability. You can always view what statistics are available about your system, even under failure conditions. If you need 100% accuracy, such as for per-request billing, Prometheus is not a good choice."
> — *When does it fit?*, prometheus.io

El modelo mental que un SRE debe internalizar: **Prometheus optimiza para estar *arriba y en condiciones de responder durante un incidente*, no para estar *completo y durable después de uno*.** En el momento en que una partición de red, un almacén downstream, o una elección de réplica pudiera bloquear una consulta, Prometheus elige seguir sirviendo lo que tiene localmente. Esa única prioridad explica por qué es un sistema pull-based, de un solo nodo, best-effort y de retención corta — y por qué toda implementación en producción termina atornillándole algo encima.

El problema arquitectónico que vas a encontrar en producción es, por lo tanto, predecible. Llega en este orden:

1. **Retención** — tu disco local se llena, o 15 días de historia no alcanzan para capacity planning / reporte de SLO a lo largo de trimestres.
2. **Escala** — un único Prometheus ya no puede mantener el conjunto de series activas de una flota creciente en RAM.
3. **Disponibilidad** — un único Prometheus es un único punto de falla de observabilidad; cuando muere, quedás ciego justo cuando necesitás ver.
4. **Vista global** — ahora corrés muchos Prometheis (por cluster, por región) y necesitás una única superficie de consulta a través de todos ellos.
5. **Exactitud** — finanzas te pide facturar a los clientes a partir de un counter, y tenés que decir que no.

El Tema 2.3 es la forma que tiene el examen de asegurarse de que puedas nombrar estas cinco paredes *antes* de chocarlas, y de que puedas nombrar la salida de emergencia correcta para cada una.

---

## 2. Las limitaciones, categorizadas

### 2.1 El almacenamiento local no es durable, ni clusterizado, ni replicado

La TSDB escribe **bloques** de 2 horas al sistema de archivos local, con un **WAL** (write-ahead log) al frente y un **head block** en memoria. Los bloques más antiguos se compactan en otros más grandes. No hay replicación ni clusterización de este almacenamiento: los datos viven en el disco del nodo y en ningún otro lado.

La retención está acotada por dos flags (el que se dispare primero):

| Flag | Significado | Default |
|---|---|---|
| `--storage.tsdb.retention.time` | Borra bloques más antiguos que esto | `15d` |
| `--storage.tsdb.retention.size` | Borra los bloques más viejos que superen este tamaño en disco | `0` (deshabilitado) |
| `--storage.tsdb.path` | Dónde viven los bloques | `data/` |
| `--storage.tsdb.wal-compression` | Comprime el WAL | habilitado (versiones recientes) |

Consecuencias que debés contemplar en el diseño:

- **Pérdida del nodo = pérdida de datos.** Ninguna réplica tiene las muestras. La HA se logra corriendo *dos* servidores Prometheus *independientes* scrapeando los mismos targets — no clusterizando el almacenamiento.
- **El dimensionamiento del disco local es un límite duro de capacidad.** Fórmula de planificación aproximada de la documentación:
  `needed_disk_bytes = retention_time_seconds × ingested_samples_per_second × bytes_per_sample`
  con `bytes_per_sample` empíricamente ≈ **1–2 bytes** después de compresión.
- **Los backups no son triviales.** El head/WAL está vivo; se hace snapshot vía la admin API (`/api/v1/admin/tsdb/snapshot`), no copiando archivos bajo un proceso en ejecución.

### 2.2 No hay escalado horizontal de un único servidor

Un Prometheus escala **verticalmente** solamente. El conjunto de series activas (head) debe entrar en RAM; más targets y más cardinalidad significan más memoria, y eventualmente un único nodo no puede contenerlo. No hay sharding nativo de los datos de una única instancia.

Los patrones de escalado sancionados son todos topologías *externas*:

- **Functional sharding** — repartir la responsabilidad de scrape entre múltiples servidores Prometheus por job/equipo/servicio.
- **Hierarchical federation** — un Prometheus "global" scrapea series *agregadas* de muchos Prometheis de nivel inferior vía `/federate`.
- **remote_write hacia un backend escalable horizontalmente** — Thanos Receive, Cortex, Grafana Mimir, VictoriaMetrics.

### 2.3 No es 100% exacto — no factures a partir de él

Prometheus es un sistema de **muestreo, best-effort**. Razones por las que un valor puede estar "mal" para propósitos contables:

- **Se pueden perder scrapes** (target caído, timeout, reinicio) — los huecos son normales y esperados.
- **`rate()` / `increase()` extrapolan** sobre la ventana y a través de los reinicios de counter; estiman, no cuentan.
- **El manejo de staleness y la interpolación** hacen que los valores puntuales sean aproximaciones.
- **Las muestras en vuelo pueden perderse** en un crash antes del flush del WAL.

Esto es por diseño y es *la* razón por la que la documentación señala explícitamente la facturación por request como algo que no encaja. Para conteos exactos, emití eventos a un pipeline de logs/stream (por ejemplo logs → agregación), no a una métrica.

### 2.4 La cardinalidad es el verdadero asesino en producción

Cada combinación única de nombre de métrica + valores de labels es una **serie temporal separada**, mantenida en el head block en memoria. La alta cardinalidad es la causa número uno de OOMs de Prometheus y de consultas lentas.

Antipatrones que explotan la cardinalidad (todos prohibidos como labels):

- User IDs, direcciones de email, session IDs
- Rutas de request completas con IDs (`/user/12345/order/98765`)
- Timestamps, UUIDs, container IDs, nombres de pods que cambian en cada deploy
- Strings de forma libre sin límite (mensajes de error, queries SQL)

Un label con 1.000 valores × otro con 1.000 valores en la misma métrica = hasta **1.000.000 de series** a partir de una sola métrica. Por eso las prácticas de naming/labels advierten explícitamente mantener acotados y bajos los conjuntos de valores de los labels.

### 2.5 Modelo pull + jobs de corta vida

Prometheus **hace pull** (scrapea) los targets a intervalos. Un job batch/cron que termina en 3 segundos puede no ser scrapeado nunca. La solución prescrita es el **Pushgateway** — pero es estrecha, y el examen quiere que conozcas sus salvedades:

- El Pushgateway es una **caché de exposición para jobs batch a nivel de servicio**, *no* una forma de pushear métricas de eventos/streaming y *no* un mecanismo de escalado.
- Se convierte en un **único punto de falla** y en una **trampa de cardinalidad/staleness**: las métricas persisten hasta que se borran explícitamente, así que el último valor de un job terminado queda dando vueltas y `up` deja de reflejar la salud de la instancia.
- Un único Pushgateway agregando las métricas de muchas máquinas anula el modelo de salud por target de Prometheus.

### 2.6 Herramienta equivocada para logs, eventos y tracing

Prometheus almacena **solo series temporales numéricas**. No es un almacén de logs, ni un almacén de eventos, ni un backend de tracing, ni una base de datos analítica de propósito general. Los datos por evento, de alta cardinalidad y alta dimensionalidad, pertenecen a Loki/Elasticsearch (logs), Tempo/Jaeger (traces), o un almacén columnar/de eventos — no a los conjuntos de labels de Prometheus.

---

## 3. Tablas comparativas de trade-offs

### 3.1 Limitación → síntoma → salida de emergencia

| Limitación | Síntoma en producción | Solución correcta | Lo que te cuesta |
|---|---|---|---|
| Retención local corta | "La historia solo llega hasta 15d atrás" | `remote_write` → Thanos/Mimir/Cortex/VictoriaMetrics; o Thanos sidecar → object storage | Infra extra + object storage; latencia de consulta para datos viejos |
| Sin replicación de almacenamiento | El nodo muere → datos perdidos | Par HA (2× Prometheus) + almacén de largo plazo | 2× carga de scrape; dedup en la capa de consulta |
| Sin escala horizontal (único servidor) | OOM a medida que crece la flota | Functional sharding / federation / cluster de remote_write | Complejidad operativa, más partes móviles |
| Sin vista de consulta global | Muchos Prometheis, sin un único panel | Thanos Querier / Mimir / Cortex query frontend | Una nueva capa de consulta que operar |
| No es 100% exacto | Finanzas quiere facturar a partir de un counter | Pipeline de eventos (logs/stream), no métricas | Sistema separado; mayor costo por evento |
| Alta cardinalidad | OOM, consultas lentas, head enorme | Relabeling para descartar labels, `metric_relabel_configs`, disciplina de naming | Perdés granularidad que creías querer |
| Jobs de corta vida perdidos | Las métricas batch nunca se scrapean | Pushgateway (solo a nivel de servicio) | SPOF, métricas obsoletas, limpieza manual |
| Logs/traces | Intentar almacenar logs como labels | Loki / Tempo / OTel collector | Stack de observabilidad adicional |

### 3.2 Backends de almacenamiento de largo plazo (los cuatro que deberías saber nombrar)

| | **Thanos** | **Cortex** | **Grafana Mimir** | **VictoriaMetrics** |
|---|---|---|---|---|
| Modelo de integración | Sidecar (sube bloques) **o** Receive (remote_write) | remote_write (push) | remote_write (push) | remote_write (push) |
| Object storage | Sí (S3/GCS/etc.) | Sí | Sí | Formato propio (o S3 en tiers de cluster) |
| Consulta global | Thanos Querier hace fan-out | Query frontend | Query frontend | vmselect |
| Downsampling | Sí (Compactor: 5m, 1h) | Limitado | Sí | Sí |
| Multi-tenancy | Add-on | Nativo | Nativo | Nativo (enterprise/cluster) |
| Dedup de pares HA | Sí (en el Querier) | Sí | Sí | Sí |
| Encaje típico | Agregar largo plazo + vista global a Prometheis existentes | SaaS multi-tenant grande | Multi-tenant grande, nativo de Grafana | Alta ingesta, menor huella de recursos |

### 3.3 Federation vs remote_write (los dos caminos de escalado más confundidos)

| | **Federation (`/federate`)** | **remote_write** |
|---|---|---|
| Dirección | El Prometheus global **hace pull** de agregados | Prometheus **pushea** cada muestra hacia afuera |
| Granularidad de datos | Solo series agregadas/seleccionadas | Stream a resolución completa |
| Uso previsto | Roll-ups agregados cross-service; vista global de *resúmenes* | Almacenamiento de largo plazo; ingesta horizontal hacia un cluster |
| Antipatrón | Federar *todas* las series crudas (recrea el problema de escala) | Usarlo cuando solo necesitabas unos pocos roll-ups agregados |
| Modo de falla | El servidor global hereda la cardinalidad de lo que federa | Crecimiento de backpressure/cola si el endpoint remoto es lento |

---

## 4. Manifiestos completos e infraestructura (sin recortar)

### 4.1 `prometheus.yml` — configuración HA-friendly con `external_labels`, `remote_write` y relabeling seguro para cardinalidad

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s
  # external_labels are attached to every series leaving this server
  # (remote_write, federation, alerts). REQUIRED for HA dedup and
  # for a long-term store to tell two replicas apart.
  external_labels:
    cluster: "prod-eu-west-1"
    replica: "A"          # the HA pair's other node uses replica: "B"

# Long-term / horizontally scalable backend. Prometheus keeps a local
# copy for `retention.time`, and streams every sample to the remote store.
remote_write:
  - url: "http://mimir-distributor.monitoring.svc:8080/api/v1/push"
    name: "mimir-prod"
    remote_timeout: 30s
    queue_config:
      capacity: 10000          # samples buffered per shard
      max_shards: 50           # upper bound on write parallelism
      min_shards: 1
      max_samples_per_send: 2000
      batch_send_deadline: 5s
      min_backoff: 30ms
      max_backoff: 5s
    # Drop known cardinality bombs BEFORE they leave this node.
    write_relabel_configs:
      - source_labels: [__name__]
        regex: "go_gc_.*|process_.*_seconds_total"
        action: drop
      # Strip a high-cardinality label instead of dropping the metric.
      - regex: "id"            # matches the label NAME "id"
        action: labeldrop

# Optional: read old data back from the same store for long-range queries.
remote_read:
  - url: "http://mimir-query-frontend.monitoring.svc:8080/prometheus/api/v1/read"
    name: "mimir-prod-read"
    read_recent: false         # only hit remote for data outside local retention

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager.monitoring.svc:9093"]

rule_files:
  - "/etc/prometheus/rules/*.yaml"

scrape_configs:
  - job_name: "kubernetes-pods"
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: "(.+)"
    # metric_relabel_configs run AFTER scrape, BEFORE ingestion into TSDB.
    # This is your last line of defense against cardinality.
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: "http_request_duration_seconds_bucket"
        action: keep          # keep histograms you actually use
      - source_labels: [path]
        regex: "/user/[0-9]+/.*"
        target_label: path
        replacement: "/user/:id/*"   # collapse per-user paths to one series
        action: replace
```

### 4.2 Ajuste de retención a nivel de proceso (args del Deployment)

```yaml
# prometheus-deployment.yaml (excerpt — container args)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
spec:
  replicas: 1        # NOTE: HA means TWO separate Deployments/StatefulSets,
                     # NOT replicas: 2 sharing storage. Storage is not clustered.
  template:
    spec:
      containers:
        - name: prometheus
          image: prom/prometheus:v2.53.0
          args:
            - "--config.file=/etc/prometheus/prometheus.yml"
            - "--storage.tsdb.path=/prometheus"
            - "--storage.tsdb.retention.time=15d"
            - "--storage.tsdb.retention.size=45GB"     # hard disk ceiling
            - "--storage.tsdb.wal-compression"
            - "--web.enable-lifecycle"                  # allows /-/reload
            - "--web.enable-admin-api"                  # needed for snapshots/delete
            - "--query.max-samples=50000000"            # guard runaway queries
          resources:
            requests:
              memory: "8Gi"     # head block lives here — cardinality = RAM
              cpu: "2"
            limits:
              memory: "12Gi"
          volumeMounts:
            - name: tsdb
              mountPath: /prometheus
```

### 4.3 Thanos sidecar — agregar almacenamiento de largo plazo + vista global sin abandonar Prometheus

```yaml
# Add as a second container in the Prometheus Pod.
# The sidecar uploads compacted 2h blocks to object storage and exposes
# a Store API the Thanos Querier fans out to.
- name: thanos-sidecar
  image: quay.io/thanos/thanos:v0.35.1
  args:
    - "sidecar"
    - "--tsdb.path=/prometheus"
    - "--prometheus.url=http://127.0.0.1:9090"
    - "--objstore.config-file=/etc/thanos/objstore.yaml"
    - "--grpc-address=0.0.0.0:10901"
    - "--http-address=0.0.0.0:10902"
  ports:
    - name: grpc
      containerPort: 10901
    - name: http
      containerPort: 10902
  volumeMounts:
    - name: tsdb
      mountPath: /prometheus
    - name: thanos-objstore
      mountPath: /etc/thanos
```

```yaml
# objstore.yaml — S3-compatible target for long-term blocks
type: S3
config:
  bucket: "prometheus-lts-eu-west-1"
  endpoint: "s3.eu-west-1.amazonaws.com"
  region: "eu-west-1"
  access_key: "${AWS_ACCESS_KEY_ID}"
  secret_key: "${AWS_SECRET_ACCESS_KEY}"
  insecure: false
```

### 4.4 Federation — un servidor global que hace pull solo de agregados

```yaml
# On the GLOBAL Prometheus: scrape /federate of each lower-level server,
# but ONLY the aggregated series (match[] with recording-rule outputs).
# Federating raw series here would recreate the exact scale problem
# federation is meant to relieve.
scrape_configs:
  - job_name: "federate"
    scrape_interval: 30s
    honor_labels: true
    metrics_path: "/federate"
    params:
      "match[]":
        - '{__name__=~"job:.*"}'          # recording-rule roll-ups only
        - '{__name__=~"instance:.*:rate5m"}'
    static_configs:
      - targets:
          - "prometheus-eu.monitoring.svc:9090"
          - "prometheus-us.monitoring.svc:9090"
```

### 4.5 Pushgateway — solo para jobs batch a nivel de servicio

```yaml
# pushgateway-deployment.yaml (excerpt)
containers:
  - name: pushgateway
    image: prom/pushgateway:v1.9.0
    args:
      - "--persistence.file=/data/pushgateway.data"   # survive restarts
      - "--persistence.interval=5m"
    ports:
      - containerPort: 9091
```

```yaml
# Scrape the Pushgateway WITH honor_labels: true so pushed job/instance
# labels are not overwritten by the scrape target's identity.
scrape_configs:
  - job_name: "pushgateway"
    honor_labels: true
    static_configs:
      - targets: ["pushgateway.monitoring.svc:9091"]
```

---

## 5. Comandos de CLI y salida real de terminal

### 5.1 Medí tu huella en disco (la pared de retención)

```console
$ du -sh /prometheus
41G     /prometheus

$ ls -1 /prometheus | head
01J2QK8R7Z9F3W6M0YAT4H5CVE
01J2QRARQ4P8K1N2D9S3XB7GTM
01J2QXVJ5C0Q7Y8H2M4T6WZR9K
chunks_head
lock
queries.active
wal

$ ls -1 /prometheus/wal | tail -3
00000418
00000419
checkpoint.00000417
```

### 5.2 Inspeccioná la cardinalidad del head block (la pared de RAM) vía la TSDB status API

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.headStats'
{
  "numSeries": 1842317,
  "numLabelPairs": 41288,
  "chunkCount": 5511042,
  "minTime": 1754640000000,
  "maxTime": 1754647200000
}

$ curl -s http://localhost:9090/api/v1/status/tsdb \
    | jq '.data.seriesCountByMetricName[:5]'
[
  { "name": "http_request_duration_seconds_bucket", "value": 312880 },
  { "name": "container_network_tcp_usage_total",     "value": 145209 },
  { "name": "apiserver_request_duration_seconds_bucket", "value": 98771 },
  { "name": "node_cpu_seconds_total",                "value": 41200 },
  { "name": "kube_pod_labels",                        "value": 38004 }
]

$ curl -s http://localhost:9090/api/v1/status/tsdb \
    | jq '.data.labelValueCountByLabelName[:5]'
[
  { "name": "__name__",  "value": 3120 },
  { "name": "id",        "value": 481233 },   # <-- cardinality bomb: drop it
  { "name": "pod",       "value": 90114 },
  { "name": "container", "value": 12055 },
  { "name": "namespace", "value": 412 }
]
```

### 5.3 Análisis profundo de cardinalidad de un bloque con `promtool`

```console
$ promtool tsdb analyze /prometheus
Block ID: 01J2QK8R7Z9F3W6M0YAT4H5CVE
Duration: 2h0m0s
Series: 1842317
Label names: 388
Postings (unique label pairs): 41288
Postings entries (total label pairs): 22118004

Label pairs most involved in churning:
115243 job=cadvisor
 98771 job=apiserver
 41200 job=node-exporter

Highest cardinality labels:
481233 id
 90114 pod
 38004 uid
 12055 container

Highest cardinality metric names:
312880 http_request_duration_seconds_bucket
145209 container_network_tcp_usage_total
 98771 apiserver_request_duration_seconds_bucket
```

El label `id` con 481k valores es el problema de cardinalidad de manual — debe descartarse con `labeldrop`/`metric_relabel_configs` (§4.1).

### 5.4 Demostrá la propiedad de "no es 100% exacto" con un hueco

```console
# rate() over a scrape gap extrapolates — it does not return the true delta.
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=up{job="payments"}' | jq '.data.result'
[]      # target was down for the last 3 scrapes — no samples, honest gap

$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=increase(http_requests_total{job="payments"}[5m])' \
    | jq '.data.result[0].value'
[1754647200, "4187.5"]   # ".5" — extrapolated, not an integer count
```

### 5.5 Validá la config, recargá y hacé snapshot para backup

```console
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
 SUCCESS: 3 rule files found
 SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

$ curl -s -X POST http://localhost:9090/-/reload -o /dev/null -w "%{http_code}\n"
200

# Consistent snapshot for backup (requires --web.enable-admin-api)
$ curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/snapshot | jq
{
  "status": "success",
  "data": { "name": "20260808T120500Z-6f0a1c2b3d4e5f60" }
}
```

### 5.6 Confirmá que remote_write realmente está enviando (la salida de emergencia de escala funciona)

```console
$ curl -s http://localhost:9090/api/v1/query \
    --data-urlencode 'query=prometheus_remote_storage_samples_pending' \
    | jq '.data.result[0].value[1]'
"3120"

$ curl -s http://localhost:9090/api/v1/query \
    --data-urlencode 'query=rate(prometheus_remote_storage_samples_failed_total[5m])' \
    | jq '.data.result[0].value[1]'
"0"
```

---

## 6. Verificación y diagnóstico de fallas

### 6.1 Matriz de diagnóstico

| Síntoma | Limitación probable | Confirmá con | Solución |
|---|---|---|---|
| Prometheus OOMKilled / reinicios | Cardinalidad en el head block | `/api/v1/status/tsdb` `numSeries`; `promtool tsdb analyze` | `labeldrop`/`metric_relabel_configs`; subir memoria solo como parche temporal |
| "La historia se corta en ~15d" | Retención local | `--storage.tsdb.retention.*`; `du -sh /prometheus` | remote_write / Thanos sidecar → object storage |
| Disco lleno, datos más viejos purgados antes de tiempo | `retention.size` alcanzado antes que `retention.time` | Comparar edad de bloques vs uso de disco | PVC más grande u offload a LTS |
| Las métricas del job batch nunca aparecen | Modelo pull + job de corta vida | Target ausente en `/targets`; `up` nunca disparó | Pushgateway (a nivel de servicio) o hacer que el job viva lo suficiente para ser scrapeado |
| Dos Prometheis muestran valores levemente distintos | Réplicas HA, best-effort | Comparar `external_labels` `replica` A vs B | Dedup en Thanos Querier / Mimir; nunca esperar valores bit-idénticos |
| El propio servidor global hace OOM | Federar series crudas | Su propia cardinalidad en `/status/tsdb` | Federar solo agregados de recording rules |
| `remote_storage_samples_pending` en aumento | Backpressure hacia el almacén remoto | `..._samples_pending`, `..._samples_failed_total`, `..._shards` | Escalar el almacén remoto / ajustar `queue_config` |
| Finanzas disputa los conteos facturados | No es 100% exacto | Buscar extrapolación `.5`, huecos de scrape | Mover la contabilidad a un pipeline de eventos, no a métricas |

### 6.2 Señales doradas sobre las que alertar para estos límites

```yaml
# rules/prometheus-limits.yaml
groups:
  - name: prometheus-self-limits
    rules:
      - alert: PrometheusHighSeriesCount
        expr: prometheus_tsdb_head_series > 3000000
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "Head series > 3M on {{ $labels.instance }}"
          description: "Approaching the RAM/cardinality wall — investigate top metrics."

      - alert: PrometheusRemoteWriteBehind
        expr: |
          rate(prometheus_remote_storage_samples_failed_total[5m]) > 0
          or prometheus_remote_storage_samples_pending > 50000
        for: 10m
        labels: { severity: critical }
        annotations:
          summary: "remote_write backpressure on {{ $labels.instance }}"

      - alert: PrometheusRetentionNearDiskLimit
        expr: |
          (prometheus_tsdb_storage_blocks_bytes
           / on(instance) node_filesystem_size_bytes{mountpoint="/prometheus"}) > 0.85
        for: 30m
        labels: { severity: warning }
        annotations:
          summary: "TSDB using >85% of its disk on {{ $labels.instance }}"
```

### 6.3 Checklist de verificación antes de declarar un Prometheus "listo para producción a escala"

1. `promtool check config` y `promtool check rules` ambos `SUCCESS`.
2. `/api/v1/status/tsdb` `numSeries` dentro de tu presupuesto de memoria, con margen para el churn de los deploys.
3. Los labels top de `promtool tsdb analyze` **no** contienen IDs sin límite.
4. Hay un almacén de largo plazo conectado (`remote_write` saludable, `samples_failed_total` plano en 0) **o** aceptaste conscientemente la retención de 15 días.
5. Existe un par HA con `external_labels.replica` distintos, y una capa de dedup resuelve su desacuerdo.
6. Los jobs batch usan Pushgateway con `honor_labels: true`, y las entradas obsoletas se limpian.
7. Backups: `/api/v1/admin/tsdb/snapshot` tiene éxito y los snapshots se envían fuera del nodo.

---

## 7. Referencias

- **When does it fit? / when it does not** — https://prometheus.io/docs/introduction/overview/#when-does-it-fit
- **Storage (TSDB, blocks, WAL, retention flags, sizing formula)** — https://prometheus.io/docs/prometheus/latest/storage/
- **remote_write / remote_read configuration** — https://prometheus.io/docs/prometheus/latest/configuration/configuration/#remote_write
- **Remote endpoints & storage integrations** — https://prometheus.io/docs/operating/integrations/#remote-endpoints-and-storage
- **Federation (`/federate`, hierarchical, cross-service)** — https://prometheus.io/docs/prometheus/latest/federation/
- **Metric and label naming (cardinality guidance)** — https://prometheus.io/docs/practices/naming/
- **When to use the Pushgateway (and when not to)** — https://prometheus.io/docs/practices/pushing/
- **Instrumentation best practices** — https://prometheus.io/docs/practices/instrumentation/
- **Pushgateway project (`honor_labels`, persistence, caveats)** — https://github.com/prometheus/pushgateway
- **`promtool` / TSDB tooling** — https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- **HTTP API — TSDB status & admin (snapshot/delete)** — https://prometheus.io/docs/prometheus/latest/querying/api/#tsdb-stats
- **Thanos design (sidecar, Querier, Store, Compactor, downsampling)** — https://thanos.io/tip/thanos/design.md/
- **Grafana Mimir architecture** — https://grafana.com/docs/mimir/latest/references/architecture/
- **Cortex architecture** — https://cortexmetrics.io/docs/architecture/
- **PCA Curriculum** — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf