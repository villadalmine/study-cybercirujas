# 2.1 Arquitectura del Sistema

> **Dominio:** Fundamentos de Prometheus · **Peso en el examen:** 4
> **Perfil:** Este módulo disecciona la arquitectura interna de un despliegue de Prometheus de la manera en que necesitarías razonarla mientras estás de guardia — componente por componente, byte por byte a través del TSDB, y modo de falla por modo de falla. Prometheus es engañosamente simple de levantar con `docker run`; es implacable de operar a escala a menos que entiendas *dónde vive la data, quién la extrae, y qué se rompe primero*.

---

## 1. Motivación: el problema de producción que Prometheus fue construido para resolver

Antes de Prometheus, el modelo dominante de monitoreo era **basado en push, jerárquico y orientado a checks** (Nagios, Zabbix, pipelines de StatsD/Graphite). Esos sistemas responden bien a *"¿está este host arriba?"* pero se degradan mal en un mundo de cargas de trabajo efímeras y orquestadas donde:

- Las instancias aparecen y desaparecen cada pocos minutos (autoscaling, rolling deploys, preempción de Spot). Una "lista de hosts" configurada estáticamente ya está desactualizada antes de que guardes el archivo.
- Las fallas interesantes son **dimensionales**, no binarias: no *"la API está caída"* sino *"la latencia p99 para `route=/checkout` en `zone=eu-west-1c` para `version=v2.3.1` regresó 40 ms después del rollout de las 14:02."* No podés expresar eso con un check de host-y-servicio.
- La cantidad de piezas móviles (pods, containers, sidecars) es un orden de magnitud mayor que la cantidad de hosts físicos, así que el sistema de monitoreo mismo debe escalar a **millones de series temporales activas**.

Prometheus (un proyecto graduado de la CNCF, el segundo después de Kubernetes) responde a esto con tres decisiones arquitectónicas con opinión, cada una de las cuales es un trade-off que debés poder defender:

1. **Un modelo de pull sobre HTTP** — Prometheus descubre targets y hace scrape de su endpoint `/metrics` según un cronograma, en vez de recibir métricas empujadas (pushed). Esto invierte el control: el sistema de monitoreo decide *quién* es monitoreado y *cuándo*, y la salud del target se vuelve una señal de primera clase y gratuita (`up`).
2. **Un modelo de datos multidimensional** — cada muestra (sample) se identifica por un nombre de métrica **más un conjunto desordenado de labels clave/valor**. `http_requests_total{method="POST", route="/checkout", code="500"}` es una serie temporal distinta de la misma métrica con `code="200"`. Esto es lo que hace posible el rebanado dimensional en PromQL.
3. **Un TSDB local, de un solo nodo, construido a propósito** — cada servidor Prometheus es dueño de su data en disco local, sin clustering y sin dependencias externas en el hot path. Esta es la decisión de confiabilidad más importante: *cuando tu infraestructura está en llamas, tu monitoreo no debe depender de la cosa que se está quemando.*

El costo arquitectónico de estas decisiones — sin escalamiento horizontal integrado, sin almacenamiento durable de largo plazo, sin consistencia fuerte — es exactamente lo que el resto del ecosistema (Alertmanager, exporters, backends de remote-write como Thanos/Cortex/Mimir) existe para compensar. **Entender la arquitectura es entender dónde está cada una de esas grietas, y qué componente la parcha.**

---

## 2. El mapa de componentes

Prometheus no es un monolito; es un pequeño núcleo de servidor rodeado por un ecosistema de procesos independientes que se comunican sobre HTTP. Aprendé los límites — la mayoría de los incidentes de producción están *en los límites*.

```
                        ┌────────────────────────────────────────────────────────┐
                        │                    PROMETHEUS SERVER                     │
                        │                                                          │
  Service Discovery     │   ┌──────────────┐   scrape    ┌───────────────────┐    │
  (K8s / Consul /       │   │  Retrieval   │◀────────────│  Service Discovery │    │
   file_sd / EC2 / DNS) │──▶│ (scrape mgr) │   over HTTP  │   + relabeling     │    │
                        │   └──────┬───────┘             └───────────────────┘    │
        ┌───────────┐  HTTP GET    │ append                                        │
        │ Target    │◀─────────────┘   ┌───────────────────────────────────┐       │
        │ /metrics  │──────────────────▶│           TSDB (storage)          │       │
        └───────────┘   exposition      │  Head (RAM+WAL) ─▶ blocks (disk)  │       │
                        format           └───────────┬──────────┬───────────┘       │
                        │                            │ read     │ read              │
                        │              ┌─────────────▼───┐  ┌───▼──────────────┐    │
                        │              │  Rule Manager    │  │  PromQL engine   │    │
                        │              │ (recording +     │  │  + HTTP API /    │    │
                        │              │  alerting rules) │  │  Web UI (:9090)  │    │
                        │              └────────┬─────────┘  └───▲──────────────┘   │
                        │                       │ fired alerts   │ queries          │
                        └───────────────────────┼────────────────┼──────────────────┘
                                                 │ push (HTTP)    │ PromQL over HTTP
                          remote_write ──────────┼──────┐         │
                                (WAL-based)      ▼      ▼         │
                    ┌──────────────┐   ┌──────────────────┐   ┌───┴────────┐
                    │ Long-term    │   │  Alertmanager     │   │  Grafana   │
                    │ storage      │   │ (dedup, group,    │   │ (dashboards)│
                    │(Thanos/Mimir)│   │  route, silence,  │   └────────────┘
                    └──────────────┘   │  inhibit) :9093   │
                                       └─────────┬─────────┘
                                                 ▼  Slack / PagerDuty / email / webhook
```

| Componente | ¿Proceso? | Puerto por defecto | Responsabilidad | Dónde se rompe |
|---|---|---|---|---|
| **Retrieval / scrape manager** | en el servidor | — | Extrae (pull) `/metrics` de los targets según `scrape_interval`, aplica `metric_relabel_configs`, anexa muestras | Timeouts de scrape, churn de targets, bombas de cardinalidad |
| **Service Discovery** | en el servidor | — | Resuelve el conjunto dinámico de targets (K8s API, Consul, DNS, `file_sd`…) y alimenta el relabeling | SD desactualizado → scrape de pods muertos; rate limits de la SD API |
| **TSDB** | en el servidor | — | Ingesta + persiste + consulta muestras; head block, WAL, blocks en disco, compaction | Disco lleno, lentitud en el replay del WAL, churn alto |
| **PromQL engine + HTTP API** | en el servidor | 9090 | Evaluación de consultas, `/api/v1/*`, web UI, endpoint de federación | Consultas costosas causan OOM del servidor |
| **Rule manager** | en el servidor | — | Evalúa recording & alerting rules cada `evaluation_interval` | Rules lentas → evaluaciones perdidas, gaps de alertas |
| **Notifier** | en el servidor | — | Envía las alertas disparadas a Alertmanager(s) | AM inalcanzable → alertas buffereadas/descartadas |
| **Alertmanager** | separado | 9093 | Dedup, agrupamiento, ruteo, silenciamiento, inhibición, notificación | Split-brain en el gossip del cluster → pages duplicados/perdidos |
| **Exporters** | separado | 9100 (node), … | Traducen las métricas nativas de un sistema al formato de exposición | El exporter es un *proxy*, no una fuente de verdad |
| **Pushgateway** | separado | 9091 | Caché para **batch jobs de vida corta** que mueren antes de un scrape | Abusado como endpoint de push general → métricas obsoletas |
| **Client libraries** | en la app | — | Instrumentación directa (counters/gauges/histograms/summaries) | Tipo de métrica incorrecto, valores de label no acotados |

**Distinciones críticas para el examen:**

- **Los exporters no son bases de datos.** `node_exporter` no guarda historia; computa los valores actuales de `/proc` y `/sys` en cada scrape. Toda la historia vive en el TSDB de Prometheus.
- **Pushgateway es el *único* camino de push sancionado**, y solo para **batch jobs a nivel de servicio** que terminan antes de que Prometheus pueda hacerles scrape. Enfáticamente **no** es una forma de convertir a Prometheus en un sistema de push — no resuelve el problema de "target caído", cachea el último valor empujado indefinidamente, y se convierte en un punto único de falla y en un sumidero de cardinalidad si se usa mal.
- **Alertmanager, no Prometheus, decide a quién se le hace page.** Prometheus solo decide *si una expresión de rule se está disparando*. Deduplicación, agrupamiento, ruteo, silences e inhibición son todos asuntos de Alertmanager. Esta separación es por qué corrés **dos servidores Prometheus idénticos** para HA y dejás que Alertmanager deduplique sus flujos de alertas idénticos.

---

## 3. El camino del scrape en detalle (mecánica del modelo pull)

Cada `scrape_interval`, para cada target activo, el scrape manager realiza:

1. **HTTP GET** al path de métricas del target (por defecto `/metrics`) con un deadline de `scrape_timeout`.
2. **Parsea** el cuerpo de la respuesta como el **formato de exposición de texto de Prometheus** (o OpenMetrics / protobuf, negociado vía `Accept`). Ejemplo de Content-Type: `text/plain; version=0.0.4`.
3. **Aplica `metric_relabel_configs`** — relabeling por muestra que puede descartar, mantener o reescribir labels *después* del scrape (contrastar con `relabel_configs`, que corre sobre el conjunto de *targets* *antes* del scrape).
4. **Anexa** cada muestra al head del TSDB con el timestamp del scrape, más series sintéticas por scrape: `up` (1/0), `scrape_duration_seconds`, `scrape_samples_scraped`, `scrape_samples_post_metric_relabeling`, `scrape_series_added`.

Un scrape crudo de un target se ve así:

```console
$ curl -s http://10.42.3.17:9100/metrics | head -n 18
# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
# TYPE node_cpu_seconds_total counter
node_cpu_seconds_total{cpu="0",mode="idle"} 183746.29
node_cpu_seconds_total{cpu="0",mode="system"} 4213.11
node_cpu_seconds_total{cpu="0",mode="user"} 9821.44
node_cpu_seconds_total{cpu="1",mode="idle"} 184002.71
# HELP node_filesystem_avail_bytes Filesystem space available to non-root users in bytes.
# TYPE node_filesystem_avail_bytes gauge
node_filesystem_avail_bytes{device="/dev/nvme0n1p1",fstype="ext4",mountpoint="/"} 3.4359738e+10
# HELP node_load1 1m load average.
# TYPE node_load1 gauge
node_load1 0.42
# HELP node_memory_MemAvailable_bytes Memory available in bytes.
# TYPE node_memory_MemAvailable_bytes gauge
node_memory_MemAvailable_bytes 5.83124992e+09
# HELP process_start_time_seconds Start time of the process since unix epoch in seconds.
# TYPE process_start_time_seconds gauge
process_start_time_seconds 1.7238420e+09
```

### 3.1 Pull vs push — el trade-off que debés poder argumentar

| Dimensión | **Pull (nativo de Prometheus)** | **Push (StatsD / Pushgateway / push OTLP)** |
|---|---|---|
| Liveness del target | Gratis, señal de primera clase (`up == 0`) | El silencio es ambiguo: ¿muerto, o simplemente no envía? |
| Autoridad de configuración | Central (Prometheus conoce el conjunto completo de targets vía SD) | Distribuida entre cada cliente |
| Firewall / red | Prometheus debe **alcanzar** los targets | Los clientes deben **alcanzar** el colector (mejor para NAT/edge) |
| Jobs efímeros/batch | **Débil** — el job puede morir antes del scrape → necesita Pushgateway | **Fuerte** — el job empuja y luego sale |
| Debugging ad-hoc | Simplemente `curl` al `/metrics` del target a mano | No hay equivalente; no podés inspeccionar un cliente bajo demanda |
| Comportamiento ante sobrecarga | Prometheus se auto-limita vía `scrape_interval`; no puede ser inundado | Un cliente que se porta mal puede inundar el colector |
| Control de cardinalidad | Impuesto centralmente (`sample_limit`, drops de relabel) | Del lado del cliente; fácil de perder el control |

Prometheus elige pull y luego parcha la *única* debilidad genuina (batch jobs) con el Pushgateway, en vez de adoptar push por completo y perder el control central y la señal `up`.

### 3.2 Service discovery + relabeling

El relabeling es el punto de unión entre "el mundo tal como lo ve la SD" (labels `__meta_*`) y "el conjunto de targets al que Prometheus le hace scrape." Un bloque canónico de scraping de pods de Kubernetes:

```yaml
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # 1. Only scrape pods that opt in with prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      # 2. Honor a custom metrics path annotation
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      # 3. Honor a custom port annotation, rewriting the scrape address
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      # 4. Promote pod labels into the resulting time series
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      # 5. Attach namespace / pod identity for querying
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod
    metric_relabel_configs:
      # After scraping: drop a noisy, high-cardinality Go metric we never query
      - source_labels: [__name__]
        regex: go_gc_duration_seconds.*
        action: drop
```

Las dos fases de relabeling son un punto recurrente del examen:

| Fase | Clave de config | Corre | Opera sobre | Uso típico |
|---|---|---|---|---|
| Relabeling de target | `relabel_configs` | **antes** del scrape | el target y sus `__meta_*` / `__address__` | keep/drop de targets, reescribir address/path/scheme, construir labels |
| Relabeling de métrica | `metric_relabel_configs` | **después** del scrape | los labels de cada muestra ingerida | descartar series ruidosas, podar labels, acotar cardinalidad |

---

## 4. Arquitectura de almacenamiento: los internos del TSDB

El subsistema más importante operativamente. Una serie temporal es un flujo append-only de muestras; cada **muestra** es un par `(timestamp int64 ms, value float64)` — 16 bytes crudos — perteneciente a una serie identificada por su conjunto completo de labels.

### 4.1 Layout en disco

```console
$ ls -l /prometheus
drwxr-xr-x 3 prometheus prometheus  4096 Aug  8 12:00 01J4Z8W2K3Q9V0YB7C1D2E3F4G   # persistent block
drwxr-xr-x 3 prometheus prometheus  4096 Aug  8 14:00 01J4ZG2R5S8T1U2V3W4X5Y6Z7A   # persistent block
drwxr-xr-x 2 prometheus prometheus  4096 Aug  8 14:00 chunks_head                  # mmap'd head chunks
-rw-r--r-- 1 prometheus prometheus     0 Aug  8 11:00 lock                         # single-writer lock
-rw-r--r-- 1 prometheus prometheus 20001 Aug  8 14:07 queries.active               # crash-forensics
drwxr-xr-x 2 prometheus prometheus  4096 Aug  8 14:00 wal                          # write-ahead log

$ ls -l /prometheus/01J4Z8W2K3Q9V0YB7C1D2E3F4G
drwxr-xr-x 2 prometheus prometheus 4096 Aug  8 12:00 chunks       # compressed sample chunks (segment files)
-rw-r--r-- 1 prometheus prometheus  65k Aug  8 12:00 index        # inverted index: label pairs -> series -> chunks
-rw-r--r-- 1 prometheus prometheus  287 Aug  8 12:00 meta.json    # block metadata
-rw-r--r-- 1 prometheus prometheus    0 Aug  8 12:00 tombstones   # soft-deletes (from delete_series API)

$ cat /prometheus/01J4Z8W2K3Q9V0YB7C1D2E3F4G/meta.json
{
  "ulid": "01J4Z8W2K3Q9V0YB7C1D2E3F4G",
  "minTime": 1723118400000,
  "maxTime": 1723125600000,
  "stats": { "numSamples": 41983204, "numSeries": 156234, "numChunks": 402118 },
  "compaction": { "level": 1, "sources": ["01J4Z8W2K3Q9V0YB7C1D2E3F4G"] },
  "version": 1
}
```

### 4.2 El camino de escritura: WAL → head → block → compaction

1. **WAL (Write-Ahead Log)** — cada muestra entrante y cada serie nueva se anexa primero al directorio `wal/` (segmentos de 128 MB). Esta es la garantía de durabilidad: ante un crash, Prometheus reproduce (replay) el WAL para reconstruir el estado en memoria. Nada se confirma (acknowledge) hasta que está en el WAL.
2. **Head block (en memoria)** — la data más reciente, aún abierta, vive en RAM como chunks activos. Cuando un chunk se llena (**120 muestras** o cuando el head es cortado), se hace **mmap a `chunks_head/`** para que el kernel — no el heap de Go — lo retenga, manteniendo acotada la memoria propia de Prometheus.
3. **Compaction del head → block persistente** — cada **2 horas** el head se trunca: la ventana de 2 horas más antigua se escribe como un **block** inmutable en disco (un directorio nombrado con ULID con `chunks/`, `index`, `meta.json`, `tombstones`), y los segmentos del WAL correspondientes se eliminan. Los blocks son autocontenidos: pueden respaldarse independientemente, enviarse (Thanos) o borrarse.
4. **Compaction en segundo plano** — con el tiempo, blocks adyacentes de 2 horas se fusionan en blocks más grandes (nivel 2, 3…), deduplicando el índice y mejorando la eficiencia de las consultas. El tamaño máximo de block está limitado a `retention.time / 10` (tope por defecto **31 días**).
5. **Aplicación de retención** — los blocks cuyo `maxTime` es más viejo que `--storage.tsdb.retention.time` (por defecto **15d**), o cuando se excede `--storage.tsdb.retention.size`, se eliminan enteros. La retención opera sobre **blocks**, nunca sobre muestras individuales.

### 4.3 Compresión — por qué el TSDB es pequeño

Prometheus aplica la codificación **Gorilla** de Facebook:

- **Timestamps**: delta-of-delta ("doble-delta"). Los intervalos de scrape regulares producen un delta-of-delta de 0, codificado en un solo bit.
- **Valores**: XOR de float64s consecutivos, almacenando solo los bits que cambiaron.

Efecto neto: los 16 bytes/muestra crudos colapsan a aproximadamente **1–2 bytes/muestra** en disco en cargas de trabajo típicas. Esto es lo que hace tratable la fórmula de planificación de capacidad:

```
required_disk_bytes ≈ retention_seconds × ingested_samples_per_second × bytes_per_sample
```

```console
# Example: 200k active series scraped every 15s, 15d retention, ~1.8 bytes/sample
$ python3 - <<'EOF'
series          = 200_000
scrape_interval = 15
samples_per_sec = series / scrape_interval          # 13,333 samples/s
retention_sec   = 15 * 24 * 3600                     # 1,296,000 s
bytes_per_sample= 1.8
gib = samples_per_sec * retention_sec * bytes_per_sample / (1024**3)
print(f"{samples_per_sec:,.0f} samples/s -> {gib:,.1f} GiB")
EOF
13,333 samples/s -> 29.0 GiB
```

### 4.4 TSDB local vs almacenamiento remoto de largo plazo

| Preocupación | **TSDB local (integrado)** | **Remote-write a Thanos / Cortex / Mimir / VictoriaMetrics** |
|---|---|---|
| Retención | Días–semanas (limitada por disco) | Meses–años (object storage) |
| Escala | Nodo único; solo vertical | Horizontal, multi-tenant |
| Latencia de consulta (reciente) | La más baja (disco local) | Agrega un salto de red |
| Vista global | Solo la data de un servidor | Agregada entre muchas instancias de Prometheus |
| Confiabilidad durante una caída de infra | **Sobrevive** (sin deps externas) | El backend puede ser parte de la caída |
| Costo | SSD local | Object storage + cómputo para el backend |
| Complejidad operativa | Trivial | Significativa (un sistema distribuido por derecho propio) |

**Regla de arquitectura:** mantené local la data de corto plazo, alta fidelidad y crítica para alertas; enviá una copia vía `remote_write` para largo plazo/global. El propio `remote_write` es **basado en WAL** — sigue (tail) el mismo WAL, fragmenta (shard) el flujo, y buffea ante caídas del backend. Vigilá `prometheus_remote_storage_samples_pending` y `prometheus_remote_storage_shards`.

### 4.5 Modo agent — una variante arquitectónica que vale la pena conocer

`prometheus --enable-feature=agent` (o `--agent`) reduce el servidor a **scrape + WAL + remote_write**: sin motor de consultas local, sin blocks persistentes, sin rules/alerting. Existe para la topología de fan-in donde clusters edge reenvían todo a un Mimir/Thanos central y nunca consultan localmente. Trade-off: ganás un colector diminuto y barato; perdés la consulta local y el alerting local.

---

## 5. Topologías de alta disponibilidad y escalamiento

Prometheus **no tiene clustering** — un servidor es un nodo único por diseño. La HA se logra por *replicación y dedup en los bordes*, no por consenso.

| Topología | Cómo | Pros | Contras |
|---|---|---|---|
| **Servidor único** | un Prometheus | el más simple, el de menor costo | SPOF; techo de escala ≈ RAM/CPU/disco de 1 nodo |
| **Par replicado (HA)** | dos servidores idénticos hacen scrape de los **mismos** targets; Alertmanager deduplica | sobrevive la pérdida de un nodo; sin ventana de pérdida de data para alertas | 2× carga de scrape; los dos TSDBs *no* son idénticos byte a byte |
| **Sharding funcional/vertical** | dividir jobs de scrape entre servidores por equipo/servicio | escala lineal de la carga de scrape | sin vista global única; se necesita federación de consultas |
| **Sharding por hashmod** | `hashmod` sobre `__address__` para dividir targets en N | escala un job enorme entre N servidores | rebalancear al cambiar N causa churn de series |
| **Federación jerárquica** | un Prometheus "global" hace scrape de series agregadas de servidores "leaf" vía `/federate` | rollups entre shards, dashboards globales | el servidor global solo ve data pre-agregada; no para drill-down crudo |
| **Fan-in por remote-write** | todos los servidores hacen `remote_write` a Thanos/Mimir | verdadera vista global + largo plazo | operar un backend distribuido |

**Sharding por hashmod** — snippet de relabel; el mismo job de scrape desplegado N veces, cada uno con un `SHARD` env diferente, divide el conjunto de targets:

```yaml
    relabel_configs:
      - source_labels: [__address__]
        modulus: 4                      # total number of shards
        target_label: __tmp_shard
        action: hashmod
      - source_labels: [__tmp_shard]
        regex: "0"                      # this instance owns shard 0 (templated per replica)
        action: keep
```

**Federación** — un Prometheus global extrayendo recording rules pre-agregadas de los leaves:

```yaml
  - job_name: federate
    honor_labels: true
    metrics_path: /federate
    params:
      "match[]":
        - '{__name__=~"job:.*"}'        # only scrape aggregated recording-rule series
    static_configs:
      - targets:
          - prometheus-shard-0:9090
          - prometheus-shard-1:9090
```

---

## 6. Manifiestos de despliegue completos

### 6.1 Kubernetes: RBAC + ConfigMap + StatefulSet + Service (núcleo del servidor)

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/metrics", "nodes/proxy", "services", "endpoints", "pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: monitoring
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      scrape_timeout: 10s
      evaluation_interval: 15s
      external_labels:
        cluster: prod-eu-west-1
        replica: $(POD_NAME)          # made unique per replica via __replica__ relabel below
    rule_files:
      - /etc/prometheus/rules/*.yml
    alerting:
      alertmanagers:
        - static_configs:
            - targets:
                - alertmanager-0.alertmanager.monitoring.svc:9093
                - alertmanager-1.alertmanager.monitoring.svc:9093
    scrape_configs:
      - job_name: prometheus
        static_configs:
          - targets: ["localhost:9090"]
      - job_name: kubernetes-nodes
        scheme: https
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          insecure_skip_verify: false
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        kubernetes_sd_configs:
          - role: node
        relabel_configs:
          - action: labelmap
            regex: __meta_kubernetes_node_label_(.+)
          - target_label: __address__
            replacement: kubernetes.default.svc:443
          - source_labels: [__meta_kubernetes_node_name]
            regex: (.+)
            target_label: __metrics_path__
            replacement: /api/v1/nodes/${1}/proxy/metrics
  rules.yml: |
    groups:
      - name: availability.rules
        rules:
          - alert: TargetDown
            expr: up == 0
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Target {{ $labels.instance }} of job {{ $labels.job }} is down"
          - record: job:up:ratio
            expr: avg by (job) (up)
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: monitoring
  labels:
    app: prometheus
spec:
  clusterIP: None                       # headless: stable per-replica DNS for HA pair
  selector:
    app: prometheus
  ports:
    - name: web
      port: 9090
      targetPort: 9090
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: prometheus
  namespace: monitoring
spec:
  serviceName: prometheus
  replicas: 2                           # HA: two identical servers, deduped by Alertmanager
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      serviceAccountName: prometheus
      securityContext:
        fsGroup: 65534
        runAsUser: 65534
        runAsNonRoot: true
      containers:
        - name: prometheus
          image: prom/prometheus:v2.53.0
          args:
            - "--config.file=/etc/prometheus/prometheus.yml"
            - "--storage.tsdb.path=/prometheus"
            - "--storage.tsdb.retention.time=15d"
            - "--storage.tsdb.retention.size=45GB"
            - "--web.enable-lifecycle"        # allows POST /-/reload
            - "--web.enable-admin-api=false"  # keep the destructive admin API off in prod
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          ports:
            - name: web
              containerPort: 9090
          readinessProbe:
            httpGet:
              path: /-/ready
              port: 9090
            initialDelaySeconds: 15
            timeoutSeconds: 4
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: 9090
            initialDelaySeconds: 30
            timeoutSeconds: 4
          resources:
            requests:
              cpu: "1"
              memory: 4Gi
            limits:
              memory: 8Gi
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
            - name: rules
              mountPath: /etc/prometheus/rules
            - name: data
              mountPath: /prometheus
      volumes:
        - name: config
          configMap:
            name: prometheus-config
            items:
              - key: prometheus.yml
                path: prometheus.yml
        - name: rules
          configMap:
            name: prometheus-config
            items:
              - key: rules.yml
                path: rules.yml
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 50Gi
```

### 6.2 node_exporter como DaemonSet (un exporter por nodo)

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9100"
    spec:
      hostNetwork: true                 # scrape the node's real network namespace
      hostPID: true
      tolerations:
        - operator: Exists              # run on control-plane and tainted nodes too
      containers:
        - name: node-exporter
          image: prom/node-exporter:v1.8.1
          args:
            - "--path.rootfs=/host/root"
            - "--path.procfs=/host/proc"
            - "--path.sysfs=/host/sys"
            - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)"
          ports:
            - name: metrics
              containerPort: 9100
          resources:
            requests: { cpu: 50m, memory: 30Mi }
            limits:   { memory: 64Mi }
          volumeMounts:
            - { name: proc,   mountPath: /host/proc, readOnly: true }
            - { name: sys,    mountPath: /host/sys,  readOnly: true }
            - { name: root,   mountPath: /host/root, mountPropagation: HostToContainer, readOnly: true }
      volumes:
        - { name: proc, hostPath: { path: /proc } }
        - { name: sys,  hostPath: { path: /sys } }
        - { name: root, hostPath: { path: / } }
```

### 6.3 Alertmanager (el cerebro de ruteo) — config + StatefulSet HA

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: alertmanager-config
  namespace: monitoring
data:
  alertmanager.yml: |
    global:
      resolve_timeout: 5m
    route:
      receiver: default-slack
      group_by: ["alertname", "cluster", "namespace"]
      group_wait: 30s          # buffer before first notification of a new group
      group_interval: 5m       # wait before notifying about new alerts in an existing group
      repeat_interval: 4h      # re-page cadence for an unresolved alert
      routes:
        - matchers: ['severity="critical"']
          receiver: pagerduty
          continue: false
    inhibit_rules:
      - source_matchers: ['severity="critical"']
        target_matchers: ['severity="warning"']
        equal: ["alertname", "cluster", "namespace"]   # a firing critical mutes the sibling warning
    receivers:
      - name: default-slack
        slack_configs:
          - api_url_file: /etc/alertmanager/secrets/slack-url
            channel: "#alerts"
            send_resolved: true
      - name: pagerduty
        pagerduty_configs:
          - routing_key_file: /etc/alertmanager/secrets/pd-key
            send_resolved: true
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  serviceName: alertmanager
  replicas: 2                  # gossip-clustered pair for HA dedup
  selector:
    matchLabels: { app: alertmanager }
  template:
    metadata:
      labels: { app: alertmanager }
    spec:
      containers:
        - name: alertmanager
          image: prom/alertmanager:v0.27.0
          args:
            - "--config.file=/etc/alertmanager/alertmanager.yml"
            - "--storage.path=/alertmanager"
            - "--cluster.listen-address=0.0.0.0:9094"
            - "--cluster.peer=alertmanager-0.alertmanager.monitoring.svc:9094"
            - "--cluster.peer=alertmanager-1.alertmanager.monitoring.svc:9094"
          ports:
            - { name: web,     containerPort: 9093 }
            - { name: cluster, containerPort: 9094 }
          volumeMounts:
            - { name: config, mountPath: /etc/alertmanager }
            - { name: data,   mountPath: /alertmanager }
      volumes:
        - name: config
          configMap: { name: alertmanager-config }
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources: { requests: { storage: 2Gi } }
```

---

## 7. Verificación y diagnóstico de fallas

### 7.1 Validá antes de desplegar

```console
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
 SUCCESS: 1 rule files found
 SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

Checking /etc/prometheus/rules/rules.yml
 SUCCESS: 2 rules found

$ promtool check rules /etc/prometheus/rules/rules.yml
Checking /etc/prometheus/rules/rules.yml
  SUCCESS: 2 rules found
```

Un hot reload sin un restart (requiere `--web.enable-lifecycle`):

```console
$ curl -s -XPOST http://localhost:9090/-/reload && echo "reloaded"
reloaded
# Verify the reload actually succeeded (a bad file is rejected and the OLD config stays live):
$ curl -s http://localhost:9090/api/v1/status/config | head -c 120
{"status":"success","data":{"yaml":"global:\n  scrape_interval: 15s\n  scrape_timeout: 10s\n ...
```

### 7.2 Liveness, readiness, build y flags de runtime

```console
$ curl -s http://localhost:9090/-/healthy ; echo
Prometheus Server is Healthy.
$ curl -s http://localhost:9090/-/ready ; echo
Prometheus Server is Ready.

$ prometheus --version
prometheus, version 2.53.0 (branch: HEAD, revision: 4e5b1a1c…)
  build user:       root@8b1c4e9f
  build date:       20240622-14:03:11
  go version:       go1.22.4
  platform:         linux/amd64
  tags:             netgo,builtinassets,stringlabels

$ curl -s http://localhost:9090/api/v1/status/flags | python3 -m json.tool | grep -E 'retention|tsdb.path'
        "storage.tsdb.path": "/prometheus",
        "storage.tsdb.retention.size": "45GB",
        "storage.tsdb.retention.time": "15d",
```

### 7.3 ¿Se está haciendo scrape de los targets realmente?

La métrica `up` es lo primero que revisás. `up == 0` significa "la SD encontró este target pero el scrape falló"; una serie `up` *ausente* significa "la SD nunca produjo el target en absoluto" — un problema de relabeling/discovery, no un problema de scrape.

```console
$ curl -s 'http://localhost:9090/api/v1/targets?state=active' \
    | python3 -c 'import sys,json; [print(t["labels"]["job"], t["scrapeUrl"], t["health"], t.get("lastError","")) for t in json.load(sys.stdin)["data"]["activeTargets"]]'
prometheus        http://localhost:9090/metrics             up
kubernetes-nodes  https://kubernetes.default.svc:443/...     up
kubernetes-pods   http://10.42.7.9:8080/metrics              down   Get "http://10.42.7.9:8080/metrics": context deadline exceeded

# Is the failure a scrape error, or a duration/limit problem?
$ curl -s 'http://localhost:9090/api/v1/query?query=up==0' \
    | python3 -c 'import sys,json; [print(r["metric"]) for r in json.load(sys.stdin)["data"]["result"]]'
{'__name__': 'up', 'instance': '10.42.7.9:8080', 'job': 'kubernetes-pods', 'namespace': 'payments', 'pod': 'checkout-7c9f-x2'}
```

### 7.4 Salud del TSDB, cardinalidad y churn — el asesino número uno en producción

La forma más común en que muere un servidor Prometheus es una **explosión de cardinalidad**: una app instrumentada pone un valor no acotado (un user ID, una URL completa, un UUID, un mensaje de error) en un label, y la cuenta de series activas se dispara, agotando la RAM. Diagnosticala con el endpoint de stats integrado y `promtool`:

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb | python3 -m json.tool
{
  "status": "success",
  "data": {
    "headStats": {
      "numSeries": 156234,
      "numLabelPairs": 18442,
      "chunkCount": 402118,
      "minTime": 1723118400000,
      "maxTime": 1723125600000
    },
    "seriesCountByMetricName": [
      { "name": "http_request_duration_seconds_bucket", "value": 48210 },
      { "name": "node_cpu_seconds_total",               "value": 20480 }
    ],
    "labelValueCountByLabelName": [
      { "name": "__name__",  "value": 1204 },
      { "name": "path",      "value": 41988 }          # <-- red flag: unbounded 'path' label
    ],
    "memoryInBytesByLabelName": [
      { "name": "path", "value": 5033164 }
    ]
  }
}

$ promtool tsdb analyze /prometheus | sed -n '1,22p'
Block ID: 01J4ZG2R5S8T1U2V3W4X5Y6Z7A
Duration: 2h0m0s
Total Series: 156234
Label Names: 42
Postings (unique label pairs): 18442
Postings entries (total label pairs): 1183990

Label pairs most involved in churning:
36211 job=kubernetes-pods
28104 namespace=payments

Most common label pairs:
156234 job=kubernetes-pods
 48210 __name__=http_request_duration_seconds_bucket

Highest cardinality labels:
41988 path            <-- one label alone is generating tens of thousands of series
 1204 __name__
  512 instance

Highest cardinality metric names:
48210 http_request_duration_seconds_bucket
```

**Cómo leerlo:** el label `path` tiene 41.988 valores distintos — una URL/path no acotada siendo usada como label. El arreglo es del lado de la instrumentación (bucketizar el path en un template de ruta fijo) más un `metric_relabel_configs` de drop defensivo y un `sample_limit`/`label_limit` en ese job para que un único target malo no pueda tumbar el servidor.

### 7.5 Señales de salud de head/WAL y remote-write (Prometheus haciéndose scrape a sí mismo)

```console
# WAL replay is slow on restart if the head is huge — watch these on startup:
$ curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_wal_truncations_total' | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["result"][0]["value"][1])'
27

# Head series vs. your budget:
$ curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_head_series' | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["result"][0]["value"][1])'
156234

# Remote-write backlog — pending samples climbing means the backend can't keep up:
$ curl -s 'http://localhost:9090/api/v1/query?query=prometheus_remote_storage_samples_pending' | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["result"])'
[{'metric': {'remote_name': 'mimir', 'url': 'https://mimir.example.com/api/v1/push'}, 'value': [1723125700, '842301']}]
```

### 7.6 Hoja de referencia de diagnóstico de fallas

| Síntoma | Causa probable | Confirmá con | Arreglo |
|---|---|---|---|
| `up == 0` para un target | Scrape falló (timeout, refused, TLS, auth) | `activeTargets[].lastError` | arreglar target/red/credenciales; subir `scrape_timeout` |
| Target ausente por completo (sin serie `up`) | La SD no lo produjo / el `keep` de relabel lo descartó | `/api/v1/targets?state=dropped` | arreglar `relabel_configs` / rol de SD / RBAC |
| Prometheus OOMKilled | explosión de cardinalidad en el head | `status/tsdb`, `promtool tsdb analyze` | descartar/relabel el label ofensor; `sample_limit` |
| Restart lento / replay largo del WAL | head + WAL muy grandes | métricas `prometheus_tsdb_wal_...`, logs de arranque | shardear el servidor; reducir churn |
| Disco lleno | retención demasiado larga / crecimiento de blocks | `df`, flag `retention.size` | poner `--storage.tsdb.retention.size` |
| Gaps en los gráficos | scrapes perdidos o eval lenta de rules | `scrape_duration_seconds`, `rule_evaluation_duration_seconds` | menos targets/rules por servidor; shardear |
| Pages duplicados | alertas del par HA sin deduplicar | estado del cluster de Alertmanager `:9093/#/status` | arreglar el gossip `--cluster.peer` de AM |
| Lag del backend remoto | muestras pendientes subiendo | `remote_storage_samples_pending`, `_shards` | escalar el backend; subir `max_shards` |
| Cambio de config no aplicado | reload rechazado silenciosamente | `/api/v1/status/config`, logs | arreglar el YAML; re-`POST /-/reload` |

### 7.7 Entender las *limitaciones arquitectónicas* de Prometheus (están en el examen)

- **No es almacenamiento durable de largo plazo.** Los blocks locales son finitos; usá `remote_write` para meses/años.
- **No es 100% preciso.** Muestrea (sampling) a lo largo del tiempo; no es apto para **facturación o auditoría por request** donde necesitás cuentas exactas de eventos — usá logging de eventos para eso.
- **Sin clustering horizontal.** La escala es vertical por servidor; la horizontal viene de sharding + federación + un backend remoto, no de Prometheus mismo.
- **El push es un caso especial, no la norma.** Solo batch jobs vía Pushgateway; no arquitectures alrededor del push.
- **La cardinalidad es el límite duro.** La RAM es aproximadamente lineal en series activas. La disciplina de labels es un requisito arquitectónico, no una preferencia de estilo.

---

## 8. Referencias

- Prometheus — *Overview / Architecture*: https://prometheus.io/docs/introduction/overview/
- Prometheus — *Why pull rather than push*: https://prometheus.io/docs/introduction/faq/#why-do-you-pull-rather-than-push
- Prometheus — *Storage (local TSDB, blocks, WAL, retention)*: https://prometheus.io/docs/prometheus/latest/storage/
- Prometheus — *Configuration (scrape_configs, relabeling, remote_write)*: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — *Federation*: https://prometheus.io/docs/prometheus/latest/federation/
- Prometheus — *Agent mode*: https://prometheus.io/docs/prometheus/latest/feature_flags/#prometheus-agent
- Prometheus — *Getting started / exposition format*: https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — *Pushgateway (when and when not to use)*: https://prometheus.io/docs/practices/pushing/
- Prometheus — *Management HTTP API (`/-/healthy`, `/-/ready`, `/-/reload`)*: https://prometheus.io/docs/prometheus/latest/management_api/
- Prometheus — *HTTP query & status API (`/api/v1/status/tsdb`, `/api/v1/targets`)*: https://prometheus.io/docs/prometheus/latest/querying/api/
- Node Exporter: https://github.com/prometheus/node_exporter
- Alertmanager — *Configuration (routing, grouping, inhibition, HA cluster)*: https://prometheus.io/docs/alerting/latest/configuration/
- `promtool` (part of Prometheus): https://github.com/prometheus/prometheus/tree/main/cmd/promtool
- TSDB format & Gorilla-style compression (design doc): https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/README.md
- Thanos (global view / long-term via object storage): https://thanos.io/tip/thanos/design.md/
- Grafana Mimir (horizontally scalable remote-write backend): https://grafana.com/docs/mimir/latest/references/architecture/
- CNCF PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf