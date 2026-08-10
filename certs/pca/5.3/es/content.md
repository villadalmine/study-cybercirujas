# 5.3 Exporters

> **Dominio 5 — Instrumentación y Exporters · Peso en el examen: 4**
> Perfil objetivo: SRE / Arquitecto de Plataforma. Esta unidad asume que ya entendés el modelo pull, el endpoint `/metrics` y PromQL básico. Acá tratamos a los exporters como infraestructura de producción de primera clase: sus modos de falla, topologías de despliegue, huella de cardinalidad y la maquinaria de relabeling que hace funcionar a los exporters multi-target.

---

## 1. El problema arquitectónico: por qué existen los exporters

Prometheus hace scraping. Emite un `GET /metrics` por HTTP contra un target y espera un payload de texto en el formato de exposición Prometheus/OpenMetrics. Ese es todo el contrato de ingesta de datos. Un componente participa del ecosistema Prometheus en el momento en que puede responder esa petición — y se niega a participar si no puede.

Esto crea un límite duro en producción:

- **Sistemas que controlás y podés recompilar** — tus propios servicios — reciben **instrumentación directa**. Enlazás una biblioteca cliente (`client_golang`, `prometheus-client` para Python, `micrometer` para JVM, etc.), registrás métricas dentro del proceso y exponés `/metrics` vos mismo. Las métricas reflejan el verdadero estado interno del proceso.
- **Sistemas que *no* controlás** — PostgreSQL, Redis, un switch Cisco que habla SNMP, el kernel de Linux, un endpoint HTTPS de caja negra, una app legada que emite StatsD — nunca hablarán el formato de exposición Prometheus de forma nativa. No podés recompilar el kernel de Linux para agregar un handler `/metrics`.

Un **exporter** es el adaptador que cierra esta brecha. Es un proceso independiente (o sidecar) que:

1. Habla el protocolo *nativo* del sistema target de un lado — el protocolo de red de MySQL, `/proc` y `/sys`, SNMP GET, el comando `INFO` de Redis, un probe HTTP.
2. Traduce ese estado al formato de exposición Prometheus del otro lado, servido en `/metrics`.

```
┌─────────────┐   native protocol   ┌────────────┐   /metrics (pull)   ┌────────────┐
│  Target     │◄───────────────────►│  Exporter  │◄───────────────────►│ Prometheus │
│ (MySQL,     │  (SQL, SNMP, /proc, │ (adapter)  │  text exposition    │  server    │
│  kernel, …) │   Redis INFO, …)    │            │  format             │            │
└─────────────┘                     └────────────┘                     └────────────┘
```

**La consecuencia arquitectónica clave**: el exporter, no el target, se convierte en el target del scraping. Prometheus nunca le habla a MySQL; le habla a `mysqld_exporter`, que le habla a MySQL. Esta indirección es la fuente de la mayoría de las sorpresas en producción — el exporter puede estar arriba mientras el target está caído, el exporter puede estar caído mientras el target está sano, y la latencia de scraping que medís es la latencia del exporter, no la del target.

### 1.1 Timing de recolección: en el momento del scraping vs. cacheada

Hay dos diseños internos, y saber cuál usa tu exporter cambia cómo razonás sobre el staleness y la carga:

- **Recolección en el scraping (síncrona)**: el exporter consulta al target *en el momento en que Prometheus hace el scraping*. `node_exporter`, `blackbox_exporter` y `mysqld_exporter` funcionan así. Consecuencia: un target lento hace que el scraping sea lento, y un scraping que hace timeout devuelve *ningún* dato para ese intervalo. También significa que cada réplica adicional de Prometheus que le hace scraping al exporter emite una consulta nueva contra el target.
- **Recolección en segundo plano + caché (asíncrona)**: el exporter sondea al target según su propio cronograma y sirve el último snapshot cacheado en `/metrics`. Esto desacopla la carga del target de la frecuencia de scraping pero introduce una ventana de staleness igual al intervalo de sondeo. Algunos exporters de bases de datos ofrecen esto mediante un flag de caché.

> **Regla de producción**: para los exporters de recolección en el scraping, `scrape_timeout` debe ser *mayor* que el peor caso de tiempo de recolección del exporter contra el target, o vas a perder silenciosamente las métricas más costosas de recolectar bajo carga — exactamente cuando las necesitás.

### 1.2 El formato de exposición (lo que un exporter realmente emite)

Todo exporter, sin importar qué envuelva, emite el mismo formato basado en líneas. Entenderlo es innegociable para diagnosticar exporters:

```text
# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
# TYPE node_cpu_seconds_total counter
node_cpu_seconds_total{cpu="0",mode="idle"} 122178.51
node_cpu_seconds_total{cpu="0",mode="system"} 1421.32
node_cpu_seconds_total{cpu="0",mode="user"} 8412.09
# HELP node_filesystem_avail_bytes Filesystem space available to non-root users in bytes.
# TYPE node_filesystem_avail_bytes gauge
node_filesystem_avail_bytes{device="/dev/nvme0n1p2",fstype="ext4",mountpoint="/"} 8.3129088e+10
# HELP http_request_duration_seconds A histogram of request latencies.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.1"} 24054
http_request_duration_seconds_bucket{le="0.5"} 33444
http_request_duration_seconds_bucket{le="+Inf"} 34003
http_request_duration_seconds_sum 53423.12
http_request_duration_seconds_count 34003
```

Reglas que un exporter debe obedecer (el parser es estricto):

| Elemento | Regla |
|---|---|
| `# HELP <name> <text>` | Opcional, uno por familia de métricas, descripción humana. |
| `# TYPE <name> <type>` | `counter`, `gauge`, `histogram`, `summary`, o `untyped`/`unknown`. |
| Línea de muestra | `metric_name{label="value",…} value [timestamp]` |
| Histogram | se expande a `_bucket{le=…}` (acumulativo), `_sum`, `_count`. Debe incluir `le="+Inf"`. |
| Summary | se expande a `{quantile=…}`, `_sum`, `_count`. |
| Sufijo de counter | los counters de OpenMetrics llevan un sufijo `_total`. |
| Content-Type | Texto Prometheus: `text/plain; version=0.0.4`. OpenMetrics: `application/openmetrics-text; version=1.0.0`. |

Una línea malformada — una etiqueta duplicada, un bucket `le` fuera de orden, un NaN donde se espera un float — hace que Prometheus rechace el scraping **completo**, no solo la línea incorrecta. Esta es la causa raíz más común de "mi exporter está arriba pero no tiene datos".

---

## 2. Taxonomía y comparación técnica

### 2.1 El catálogo común de exporters

| Exporter | Envuelve | Puerto por defecto | Modelo de recolección | ¿Multi-target? |
|---|---|---|---|---|
| `node_exporter` | Host Linux/BSD (`/proc`, `/sys`) | 9100 | en el scraping | No (uno por host) |
| `windows_exporter` | Host Windows (WMI/perflib) | 9182 | en el scraping | No |
| `blackbox_exporter` | Probes HTTP/HTTPS/TCP/ICMP/DNS | 9115 | en el scraping (probe) | **Sí** |
| `snmp_exporter` | Equipos de red que hablan SNMP | 9116 | en el scraping (walk) | **Sí** |
| `mysqld_exporter` | MySQL / MariaDB | 9104 | en el scraping (SQL) | Opcional |
| `postgres_exporter` | PostgreSQL | 9187 | en el scraping (SQL) | Opcional |
| `redis_exporter` | Redis / Valkey | 9121 | en el scraping (`INFO`) | **Sí** (`?target=`) |
| `kube-state-metrics` (KSM) | Estado de objetos de la API de K8s | 8080 (metrics) / 8081 (self) | watch + caché | No |
| `cAdvisor` | Uso de recursos de contenedores | 8080 (o vía kubelet) | segundo plano + caché | No |
| `statsd_exporter` | Stream StatsD UDP/TCP | 9102 (metrics) / 9125 (ingest) | puente push→pull | No |
| `jmx_exporter` | JVM vía JMX (usualmente como agente) | definido por la app | en el scraping (JMX) | No |

> **Nota sobre asignación de puertos**: la comunidad mantiene un registro canónico de asignación de puertos para que los exporters no colisionen (9100 = node, 9115 = blackbox, 9104 = mysqld, …). Cuando despliegues un exporter personalizado, reclamá un puerto de esa lista en vez de inventar uno.

### 2.2 Instrumentación directa vs. exporter

| Dimensión | Instrumentación directa | Exporter |
|---|---|---|
| Requiere acceso al código fuente | Sí (recompilar/enlazar) | No |
| Fidelidad de la métrica | La más alta — verdadero estado interno | Limitada a lo que el protocolo nativo expone |
| Pieza móvil extra | Ninguna | Un proceso separado para correr, monitorear, parchear |
| Independencia de falla | Muerte de la métrica ⇒ muerte de la app | El exporter puede morir mientras el target vive (y viceversa) |
| Semántica de `up` | `up=1` significa que la app está sirviendo | `up=1` significa que el *exporter* respondió, **no** que el target está sano |
| Mejor para | Tus propios servicios | Sistemas de terceros y a nivel de SO |

La fila de la semántica de `up` es la trampa crítica del examen. `up{job="mysql"} == 1` te dice que `mysqld_exporter` respondió — la base de datos podría estar en un crash loop detrás de él. Necesitás la métrica de *salud del target* del exporter (por ejemplo `mysql_up`, `pg_up`, `probe_success`, `redis_up`) para afirmar que el sistema real está sano.

### 2.3 Trade-offs de la topología de despliegue

| Patrón | Dónde corre | Usá cuando | Trade-off |
|---|---|---|---|
| **Sidecar** | Mismo Pod que el target, comparte namespace de red | Targets por instancia (una réplica de BD, una app) | Acoplamiento de ciclo de vida 1:1; N exporters para N Pods; acceso localhost al target |
| **DaemonSet** | Uno por nodo | Métricas a nivel de host (`node_exporter`, `cAdvisor`) | Requiere host mounts / `hostNetwork`; exactamente uno por nodo |
| **Deployment centralizado** | Independiente, alcanza los targets por la red | Exporters multi-target sin estado (`blackbox`, `snmp`) | Unidad de escalado única; no debe convertirse en un SPOF ni en un cuello de botella de scraping |
| **Multi-target (un exporter, muchos targets vía `?target=`)** | Independiente | Sondear cientos de endpoints/dispositivos | Complejidad de relabeling; límites de concurrencia del exporter |

---

## 3. `node_exporter` — el exporter de host canónico

`node_exporter` lee `/proc`, `/sys` y otras interfaces del kernel y las traduce en métricas `node_*`. Está compuesto de **collectors** — uno por subsistema (CPU, filesystem, netdev, diskstats, meminfo…). Los collectors se pueden activar y desactivar individualmente, y *la selección de collectors es una decisión de producción*: cada collector agrega costo de scraping y cardinalidad.

### 3.1 Control de collectors

```bash
# Enabled-by-default collectors do the common stuff (cpu, diskstats, filesystem,
# loadavg, meminfo, netdev, netstat, stat, time, uname, vmstat, ...).
# Enable an extra collector and disable a noisy one:
$ node_exporter \
    --collector.systemd \
    --collector.processes \
    --no-collector.wifi \
    --no-collector.arp \
    --collector.textfile.directory=/var/lib/node_exporter/textfile_collector \
    --web.listen-address=:9100
```

Cada collector reporta por sí mismo si tuvo éxito, que es cómo detectás una falla *parcial* del exporter (el exporter está arriba, pero un collector está roto):

```text
# TYPE node_scrape_collector_success gauge
node_scrape_collector_success{collector="filesystem"} 1
node_scrape_collector_success{collector="systemd"} 0        # <-- broken collector
# TYPE node_scrape_collector_duration_seconds gauge
node_scrape_collector_duration_seconds{collector="filesystem"} 0.00214
```

Una alerta sobre `node_scrape_collector_success == 0` captura el caso "arriba pero ciego" que `up == 1` enmascara.

### 3.2 El textfile collector — extender un exporter sin bifurcarlo

El textfile collector es la vía de escape sancionada para exponer métricas que `node_exporter` no produce de forma nativa (antigüedad de backups, resultados de trabajos cron, scripts de sensores de hardware). Un trabajo cron escribe un archivo `.prom` **atómicamente** (escribir a un temporal, luego `mv` — un archivo escrito a medias corrompe el scraping):

```bash
#!/usr/bin/env bash
# /usr/local/bin/backup-age-metric.sh — run from cron after each backup
set -euo pipefail
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
tmp="$(mktemp)"

last_backup_epoch=$(stat -c %Y /srv/backups/latest.tar.zst)

cat > "$tmp" <<EOF
# HELP backup_last_success_timestamp_seconds Unix time of the last successful backup.
# TYPE backup_last_success_timestamp_seconds gauge
backup_last_success_timestamp_seconds ${last_backup_epoch}
EOF

# Atomic publish — same filesystem so mv is a rename, never a partial read.
mv "$tmp" "${TEXTFILE_DIR}/backup.prom"
```

La métrica entonces aparece en la salida de `node_exporter` y puede impulsar una alerta como `time() - backup_last_success_timestamp_seconds > 86400`.

### 3.3 Manifiesto de DaemonSet de producción

`node_exporter` debe ver los namespaces del *host*, no los del contenedor. Eso significa `hostNetwork`, `hostPID`, montajes del filesystem del host y los flags `--path.*` enraizados en los puntos de montaje. Omitir `--path.rootfs` es el bug clásico que hace que las métricas de filesystem reporten el overlay FS del contenedor en vez de los discos del nodo.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: monitoring
  labels:
    app.kubernetes.io/name: node-exporter
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-exporter
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-exporter
    spec:
      hostNetwork: true          # scrape target = node IP:9100
      hostPID: true              # required by the processes collector
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534         # nobody
      tolerations:
        - operator: Exists       # run on control-plane / tainted nodes too
      containers:
        - name: node-exporter
          image: quay.io/prometheus/node-exporter:v1.8.2
          args:
            - --path.rootfs=/host/root
            - --path.procfs=/host/proc
            - --path.sysfs=/host/sys
            - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)
            - --collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|cgroup|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|mqueue|overlay|proc|procfs|pstore|securityfs|sysfs|tracefs)$
            - --web.listen-address=:9100
          ports:
            - name: metrics
              containerPort: 9100
              protocol: TCP
          resources:
            requests: { cpu: 50m, memory: 30Mi }
            limits:   { memory: 80Mi }
          volumeMounts:
            - { name: proc, mountPath: /host/proc, readOnly: true }
            - { name: sys,  mountPath: /host/sys,  readOnly: true }
            - { name: root, mountPath: /host/root, mountPropagation: HostToContainer, readOnly: true }
      volumes:
        - { name: proc, hostPath: { path: /proc } }
        - { name: sys,  hostPath: { path: /sys } }
        - { name: root, hostPath: { path: / } }
```

Las regex de `mount-points-exclude` / `fs-types-exclude` no son cosméticas: sin ellas, `node_exporter` emite una serie `node_filesystem_*` por cada overlay efímero de contenedor y cada bind mount del kubelet, explotando la cardinalidad en un nodo ocupado.

### 3.4 Descubrimiento: `ServiceMonitor` (Prometheus Operator)

Si corrés el Prometheus Operator, no editás `prometheus.yml`; declarás un `ServiceMonitor` y el operator genera la configuración de scraping:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: node-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-exporter
  endpoints:
    - port: metrics          # named port from the backing Service
      interval: 30s
      scrapeTimeout: 10s
      relabelings:
        - action: replace
          sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node   # attach the node name as a first-class label
```

---

## 4. El patrón de exporter multi-target (`blackbox_exporter`)

Los exporters de un solo target embeben el target en su propia configuración. **Los exporters multi-target toman el target como un parámetro de URL** — `GET /probe?target=<x>&module=<y>` — de modo que *una* instancia de exporter sondea miles de endpoints. `blackbox_exporter` (HTTP/TCP/ICMP/DNS) y `snmp_exporter` son los arquetipos. Dominar el relabeling para este patrón es una habilidad central de la PCA.

### 4.1 Configuración de módulos

La propia configuración del exporter define *módulos* — recetas de probe reutilizables. **No** lista targets; Prometheus los provee.

```yaml
# blackbox.yml
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []          # empty ⇒ any 2xx is a success
      method: GET
      follow_redirects: true
      fail_if_ssl: false
      fail_if_not_ssl: true           # enforce HTTPS
      preferred_ip_protocol: "ip4"
  tcp_connect:
    prober: tcp
    timeout: 5s
  icmp_ping:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: "ip4"
  dns_soa:
    prober: dns
    timeout: 5s
    dns:
      query_name: "example.com"
      query_type: "SOA"
```

### 4.2 El handshake de relabeling (el meollo)

La configuración de scraping realiza una danza de relabeling de cuatro pasos para que Prometheus haga scraping del *exporter* pero pase el *endpoint real* como `?target=`:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'blackbox-http'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - https://example.com
          - https://api.internal.svc:8443/healthz
    relabel_configs:
      # 1. The listed target becomes the ?target= URL parameter.
      - source_labels: [__address__]
        target_label: __param_target
      # 2. Preserve the real endpoint as the human-readable `instance` label.
      - source_labels: [__param_target]
        target_label: instance
      # 3. Rewrite __address__ so Prometheus actually connects to the exporter.
      - target_label: __address__
        replacement: blackbox-exporter.monitoring.svc:9115
```

Sin el paso 3, Prometheus intenta hacer scraping de `/probe` en `example.com` mismo, lo cual obviamente falla. Sin el paso 2, cada serie queda etiquetada como `instance="blackbox-exporter:9115"` y no podés distinguir los endpoints entre sí.

### 4.3 Qué devuelve un probe

```bash
$ curl -s 'http://localhost:9115/probe?target=https://example.com&module=http_2xx'
# HELP probe_success Displays whether or not the probe was a success
# TYPE probe_success gauge
probe_success 1
# HELP probe_duration_seconds Returns how long the probe took to complete in seconds
# TYPE probe_duration_seconds gauge
probe_duration_seconds 0.183
# HELP probe_http_status_code Response HTTP status code
# TYPE probe_http_status_code gauge
probe_http_status_code 200
# HELP probe_ssl_earliest_cert_expiry Returns last SSL chain expiry in unixtime
# TYPE probe_ssl_earliest_cert_expiry gauge
probe_ssl_earliest_cert_expiry 1.774224e+09
# HELP probe_http_ssl Indicates if SSL was used for the final redirect
# TYPE probe_http_ssl gauge
probe_http_ssl 1
```

`probe_ssl_earliest_cert_expiry` es la métrica detrás de toda alerta de "el certificado TLS expira en N días":

```promql
# Certificate expires in under 14 days
(probe_ssl_earliest_cert_expiry - time()) / 86400 < 14
```

### 4.4 Despliegue

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blackbox-exporter
  namespace: monitoring
spec:
  replicas: 2                      # HA: probing is stateless, scale freely
  selector:
    matchLabels: { app: blackbox-exporter }
  template:
    metadata:
      labels: { app: blackbox-exporter }
    spec:
      containers:
        - name: blackbox-exporter
          image: quay.io/prometheus/blackbox-exporter:v0.25.0
          args:
            - --config.file=/etc/blackbox/blackbox.yml
          ports:
            - { name: http, containerPort: 9115 }
          securityContext:
            # ICMP prober needs the raw-socket capability; drop everything else.
            capabilities:
              drop: ["ALL"]
              add: ["NET_RAW"]
            readOnlyRootFilesystem: true
          volumeMounts:
            - { name: config, mountPath: /etc/blackbox, readOnly: true }
      volumes:
        - name: config
          configMap: { name: blackbox-config }
---
apiVersion: v1
kind: Service
metadata:
  name: blackbox-exporter
  namespace: monitoring
spec:
  selector: { app: blackbox-exporter }
  ports:
    - { name: http, port: 9115, targetPort: http }
```

> **Advertencia de escalado**: con `blackbox_exporter` haciendo sondeo de recolección en el scraping, un probe que se cuelga en un endpoint muerto mantiene una goroutine durante el `timeout` completo. Sondear miles de targets con un intervalo corto puede agotar el exporter — dimensioná `scrape_interval` y `timeout` en función de la cantidad de targets, y shardeá entre réplicas si hace falta.

---

## 5. Escribir un exporter personalizado

Cuando no existe un exporter para tu sistema, escribís uno con una biblioteca cliente. El patrón idiomático de exporter es un **custom collector** cuyo método `collect()` se invoca *en el momento del scraping* — consultás al target dentro de `collect()` y devolvés familias de métricas frescas. **No** uses objetos `Gauge`/`Counter` a nivel de módulo actualizados por un hilo en segundo plano para un exporter que adapta estado externo; el patrón custom-collector garantiza que los valores son consistentes al momento del scraping y evita el estado stale.

```python
#!/usr/bin/env python3
"""Minimal exporter for a hypothetical queue system, using the custom-collector pattern."""
import time
import requests
from prometheus_client import start_http_server
from prometheus_client.core import GaugeMetricFamily, CounterMetricFamily, REGISTRY

QUEUE_API = "http://queue.internal:8000/stats"

class QueueCollector:
    def collect(self):
        # Queried fresh on every /metrics scrape (collect-on-scrape).
        try:
            data = requests.get(QUEUE_API, timeout=4).json()
            up = 1
        except requests.RequestException:
            # Target-health metric — lets alerts distinguish exporter-up from target-up.
            yield GaugeMetricFamily("queue_up", "1 if the queue API is reachable", value=0)
            return

        yield GaugeMetricFamily("queue_up", "1 if the queue API is reachable", value=up)

        depth = GaugeMetricFamily(
            "queue_depth_messages", "Messages currently queued", labels=["queue"])
        for name, n in data["depths"].items():
            depth.add_metric([name], n)
        yield depth

        processed = CounterMetricFamily(
            "queue_processed_messages_total", "Messages processed since start", labels=["queue"])
        for name, n in data["processed"].items():
            processed.add_metric([name], n)
        yield processed

if __name__ == "__main__":
    REGISTRY.register(QueueCollector())
    start_http_server(9110)        # claim an unused port from the allocation list
    while True:
        time.sleep(3600)
```

```bash
$ curl -s localhost:9110/metrics | grep -E '^queue_'
queue_up 1.0
queue_depth_messages{queue="ingest"} 42.0
queue_depth_messages{queue="retry"} 3.0
queue_processed_messages_total{queue="ingest"} 1.284219e+06
```

**Checklist de autoría de exporters** (cada ítem previene un incidente de producción real):

- Emití siempre una métrica de salud del target `<x>_up`, incluso (especialmente) cuando el target es inalcanzable — un scraping que devuelve *solo* `queue_up 0` es mucho más útil que un scraping fallido que no devuelve nada.
- Nunca conviertas un atributo no acotado del target (ruta de la petición, ID de usuario, URL completa) en una etiqueta — esta es la bomba de cardinalidad que hace OOM a Prometheus.
- Los counters solo van para arriba; la semántica de reinicio la maneja `rate()`. No reinicies un counter para reflejar el estado del target — usá un gauge.
- Mantené las etiquetas estables entre scrapings; una etiqueta que aparece/desaparece crea huecos de staleness.

---

## 6. Asegurar exporters (exporter-toolkit)

El endpoint `/metrics` de un exporter filtra inteligencia operativa — nombres de host, disposición del filesystem, conteos de conexiones, expiraciones de certificados. Los exporters de Prometheus que usan la biblioteca compartida `exporter-toolkit` (node, blackbox y la mayoría de los exporters de primera parte) soportan TLS y basic auth vía un `--web.config.file`:

```yaml
# web-config.yml
tls_server_config:
  cert_file: /etc/tls/tls.crt
  key_file: /etc/tls/tls.key
  min_version: TLS12
basic_auth_users:
  # bcrypt hash — generate with: htpasswd -nBC 12 "" | tr -d ':\n'
  prometheus: $2y$12$Q6 H2z...redacted...hash
```

```bash
$ node_exporter --web.config.file=/etc/node_exporter/web-config.yml
```

La configuración de scraping de Prometheus correspondiente debe presentar las credenciales y confiar en la CA:

```yaml
scrape_configs:
  - job_name: node
    scheme: https
    basic_auth:
      username: prometheus
      password_file: /etc/prometheus/exporter_password
    tls_config:
      ca_file: /etc/prometheus/ca.crt
      insecure_skip_verify: false
    static_configs:
      - targets: ['node1.internal:9100']
```

> En Kubernetes, una alternativa es dejar el exporter en texto plano pero acotarlo a la red `localhost`/Pod únicamente y hacer cumplir el acceso con una `NetworkPolicy` que permita ingreso en el puerto de métricas **únicamente** desde los Pods de Prometheus — defensa en profundidad en lugar de una u otra opción.

---

## 7. La excepción: Pushgateway (y por qué no es un exporter)

Los trabajos batch/cron son el único caso que el modelo pull no puede cubrir: el trabajo termina antes de que Prometheus pueda hacerle scraping. El **Pushgateway** es un puente push→pull — el trabajo hace `POST` de sus métricas finales, el gateway las cachea, y Prometheus le hace scraping al gateway.

```bash
# At the end of a batch job:
$ cat <<EOF | curl --data-binary @- \
    http://pushgateway.monitoring:9091/metrics/job/nightly_etl/instance/worker-3
# TYPE etl_records_processed_total counter
etl_records_processed_total 482103
# TYPE etl_last_success_timestamp_seconds gauge
etl_last_success_timestamp_seconds $(date +%s)
EOF
```

Distinciones críticas respecto de un exporter real, y por qué deberías recurrir a él *solo* para trabajos batch a nivel de servicio:

- El gateway **nunca expira** las métricas empujadas; un trabajo que corrió una vez deja series stale hasta que se hagan `DELETE` explícitamente. `up` refleja la salud del *gateway*, no la del trabajo — así que no puede detectar que un trabajo directamente no llegó a correr.
- Prometheus debe hacerle scraping con `honor_labels: true`, para que el `job`/`instance` que fijó el pusher sobrevivan en vez de ser sobrescritos con los del propio gateway.
- **No** sirve para capturar métricas de servicios que sí podrían recibir scraping — usarlo así descarta la señal de liveness del modelo pull.

---

## 8. Verificación y diagnóstico de fallas

### 8.1 Chequeos desde primeros principios

```bash
# 1. Is the exporter serving valid exposition format at all?
$ curl -s localhost:9100/metrics | head -n 5
# HELP go_gc_duration_seconds A summary of the wall-time pause ...
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} 4.1289e-05

# 2. Validate the output parses (catches the "one bad line kills the scrape" case).
$ curl -s localhost:9100/metrics | promtool check metrics
#   (silent + exit 0 = valid; prints the offending line + exit 1 on error)

# 3. Confirm Prometheus considers the target UP and see why not.
$ curl -s 'http://prometheus:9090/api/v1/targets' \
    | jq '.data.activeTargets[] | {job:.labels.job, health, lastError, scrapeUrl}'
{
  "job": "node",
  "health": "down",
  "lastError": "server returned HTTP status 401 Unauthorized",
  "scrapeUrl": "https://node1.internal:9100/metrics"
}

# 4. Distinguish exporter-up from TARGET-up.
$ curl -s 'http://prometheus:9090/api/v1/query?query=mysql_up' | jq '.data.result'
[{ "metric": {"job":"mysql","instance":"db1:9104"}, "value": [1723296000, "0"] }]
#   up == 1 but mysql_up == 0  ⇒  exporter healthy, database unreachable.
```

### 8.2 Tabla de referencia de modos de falla

| Síntoma | Causa probable | Dónde mirar / arreglar |
|---|---|---|
| Target `DOWN`, `lastError: connection refused` | Proceso del exporter sin escuchar / puerto equivocado | `ss -lntp \| grep 9100`; revisá `--web.listen-address` |
| Target `DOWN`, `401/403` | Desajuste de TLS/auth | Alineá el hash bcrypt de `web-config.yml` con el `basic_auth` del scraping |
| Target `UP` pero **no aparecen métricas** | Una línea malformada rechaza el scraping completo | `promtool check metrics`; buscá `le` fuera de orden, etiquetas duplicadas, NaN |
| Target `UP`, `<x>_up == 0` | Exporter sano, **target** inalcanzable | Revisá credenciales/red exporter→target (DSN, community SNMP, grants del usuario de BD) |
| `context deadline exceeded` en el scraping | Recolección más lenta que `scrape_timeout` | Subí `scrape_timeout`; desactivá collectors costosos; activá caché |
| Métricas presentes pero **stale/congeladas** | Exporter cacheado que no vuelve a sondear, o collector caído | Revisá `node_scrape_collector_success`; reiniciá; verificá el sondeo en segundo plano |
| Churn de RAM/TSDB de Prometheus tras agregar un exporter | Explosión de cardinalidad por etiquetas no acotadas | `topk(10, count by (__name__)({__name__=~".+"}))`; agregá drops de etiquetas |
| Las métricas de filesystem muestran el FS del contenedor, no el del host | Falta `--path.rootfs` / host mounts | Corregí los flags `--path.*` del DaemonSet y los volúmenes `hostPath` |
| El scraping multi-target de blackbox le pega al endpoint, no al exporter | Falta el paso 3 del relabel | Agregá la regla de relabel de reemplazo `__address__` → exporter |

### 8.3 Auditoría de cardinalidad (el asesino de capacidad de los exporters)

Un exporter es la fuente más común de un incidente de cardinalidad porque mapea estado *externo* que no controlás del todo hacia etiquetas. Auditá antes y después del despliegue:

```bash
# Which metric names carry the most series?
$ curl -s 'http://prometheus:9090/api/v1/query' \
    --data-urlencode 'query=topk(10, count by (__name__)({job="node"}))' \
    | jq -r '.data.result[] | "\(.value[1])\t\(.metric.__name__)"'
84213   node_filesystem_avail_bytes     # <-- suspiciously high: overlay mounts not excluded
1204    node_cpu_seconds_total
612     node_network_receive_bytes_total

# Per-target series count (find the exporter blowing the budget):
$ curl -s 'http://prometheus:9090/api/v1/query' \
    --data-urlencode 'query=sort_desc(count by (instance)(scrape_samples_scraped))' \
    | jq -r '.data.result[] | "\(.value[1])\t\(.metric.instance)"'
```

El arreglo está en el exporter (excludes de collectors, allowlists de etiquetas) o en la configuración de scraping vía `metric_relabel_configs` con una acción `drop` — aplicada *antes* de la ingesta para que la serie nunca llegue al TSDB:

```yaml
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'node_(scrape_collector_duration_seconds|softnet_.*)'
        action: drop
```

---

## 9. Referencias

- Prometheus — *Exporters and integrations* (catálogo oficial): https://prometheus.io/docs/instrumenting/exporters/
- Prometheus — *Writing exporters* (pautas de diseño, nomenclatura, convención `_up`): https://prometheus.io/docs/instrumenting/writing_exporters/
- Prometheus — *Exposition formats* (formato de texto y OpenMetrics): https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — *Default port allocations* wiki: https://github.com/prometheus/prometheus/wiki/Default-port-allocations
- `node_exporter` repositorio y lista de collectors: https://github.com/prometheus/node_exporter
- Prometheus — *Monitoring Linux host metrics with the Node Exporter*: https://prometheus.io/docs/guides/node-exporter/
- `blackbox_exporter` repositorio y configuración: https://github.com/prometheus/blackbox_exporter
- Prometheus — *Understanding and using the multi-target exporter pattern*: https://prometheus.io/docs/guides/multi-target-exporter/
- `snmp_exporter` repositorio: https://github.com/prometheus/snmp_exporter
- `exporter-toolkit` (TLS y auth para exporters): https://github.com/prometheus/exporter-toolkit/blob/master/docs/web-configuration.md
- Pushgateway repositorio y "when (not) to use it": https://github.com/prometheus/pushgateway
- `kube-state-metrics` repositorio: https://github.com/kubernetes/kube-state-metrics
- Cliente Python de Prometheus (`prometheus_client`, custom collectors): https://github.com/prometheus/client_python
- Prometheus Operator — API `ServiceMonitor`/`Probe`: https://prometheus-operator.dev/docs/operator/api/
- CNCF — *Prometheus Certified Associate (PCA) Curriculum*: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf