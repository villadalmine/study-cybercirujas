# 5.3 Exporters

> **Domain 5 — Instrumentation & Exporters · Exam weight: 4**
> Target profile: SRE / Platform Architect. This unit assumes you already understand the pull model, the `/metrics` endpoint, and basic PromQL. Here we treat exporters as first-class production infrastructure: their failure modes, deployment topologies, cardinality footprint, and the relabeling machinery that makes multi-target exporters work.

---

## 1. The architectural problem: why exporters exist

Prometheus scrapes. It issues an HTTP `GET /metrics` against a target and expects a text payload in the Prometheus/OpenMetrics exposition format. That is the entire data-ingestion contract. A component participates in the Prometheus ecosystem the moment it can answer that request — and refuses to participate if it cannot.

This creates a hard boundary in production:

- **Systems you control and can recompile** — your own services — get **direct instrumentation**. You link a client library (`client_golang`, `prometheus-client` for Python, `micrometer` for JVM, etc.), register metrics in-process, and expose `/metrics` yourself. The metrics reflect the true internal state of the process.
- **Systems you do *not* control** — PostgreSQL, Redis, a Cisco switch speaking SNMP, the Linux kernel, a black-box HTTPS endpoint, a legacy app emitting StatsD — will never speak the Prometheus exposition format natively. You cannot recompile the Linux kernel to add a `/metrics` handler.

An **exporter** is the adapter that closes this gap. It is a standalone process (or sidecar) that:

1. Speaks the *native* protocol of the target system on one side — the MySQL wire protocol, `/proc` and `/sys`, SNMP GET, the Redis `INFO` command, an HTTP probe.
2. Translates that state into the Prometheus exposition format on the other side, served at `/metrics`.

```
┌─────────────┐   native protocol   ┌────────────┐   /metrics (pull)   ┌────────────┐
│  Target     │◄───────────────────►│  Exporter  │◄───────────────────►│ Prometheus │
│ (MySQL,     │  (SQL, SNMP, /proc, │ (adapter)  │  text exposition    │  server    │
│  kernel, …) │   Redis INFO, …)    │            │  format             │            │
└─────────────┘                     └────────────┘                     └────────────┘
```

**The key architectural consequence**: the exporter, not the target, becomes the scrape target. Prometheus never talks to MySQL; it talks to `mysqld_exporter`, which talks to MySQL. This indirection is the source of most production surprises — the exporter can be up while the target is down, the exporter can be down while the target is healthy, and the scrape latency you measure is the exporter's latency, not the target's.

### 1.1 Collection timing: scrape-time vs. cached

There are two internal designs, and knowing which one your exporter uses changes how you reason about staleness and load:

- **Collect-on-scrape (synchronous)**: the exporter queries the target *at the moment Prometheus scrapes*. `node_exporter`, `blackbox_exporter`, and `mysqld_exporter` work this way. Consequence: a slow target makes the scrape slow, and a scrape that times out returns *no* data for that interval. It also means every extra Prometheus replica that scrapes the exporter issues a fresh query against the target.
- **Background-collect + cache (asynchronous)**: the exporter polls the target on its own schedule and serves the last cached snapshot on `/metrics`. This decouples target load from scrape frequency but introduces a staleness window equal to the poll interval. Some database exporters offer this via a caching flag.

> **Production rule**: for collect-on-scrape exporters, `scrape_timeout` must be *larger* than the exporter's worst-case collection time against the target, or you will silently lose the most expensive-to-collect metrics under load — exactly when you need them.

### 1.2 The exposition format (what an exporter actually emits)

Every exporter, regardless of what it wraps, emits the same line-based format. Understanding it is non-negotiable for diagnosing exporters:

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

Rules an exporter must obey (the parser is strict):

| Element | Rule |
|---|---|
| `# HELP <name> <text>` | Optional, one per metric family, human description. |
| `# TYPE <name> <type>` | `counter`, `gauge`, `histogram`, `summary`, or `untyped`/`unknown`. |
| Sample line | `metric_name{label="value",…} value [timestamp]` |
| Histogram | expands to `_bucket{le=…}` (cumulative), `_sum`, `_count`. Must include `le="+Inf"`. |
| Summary | expands to `{quantile=…}`, `_sum`, `_count`. |
| Counter suffix | OpenMetrics counters carry a `_total` suffix. |
| Content-Type | Prometheus text: `text/plain; version=0.0.4`. OpenMetrics: `application/openmetrics-text; version=1.0.0`. |

A malformed line — a duplicate label, a `le` bucket out of order, a NaN where a float is expected — causes Prometheus to reject the **entire** scrape, not just the bad line. This is the single most common "my exporter is up but has no data" root cause.

---

## 2. Taxonomy and technical comparison

### 2.1 The common exporter catalogue

| Exporter | Wraps | Default port | Collection model | Multi-target? |
|---|---|---|---|---|
| `node_exporter` | Linux/BSD host (`/proc`, `/sys`) | 9100 | scrape-time | No (one per host) |
| `windows_exporter` | Windows host (WMI/perflib) | 9182 | scrape-time | No |
| `blackbox_exporter` | HTTP/HTTPS/TCP/ICMP/DNS probes | 9115 | scrape-time (probe) | **Yes** |
| `snmp_exporter` | SNMP-speaking network gear | 9116 | scrape-time (walk) | **Yes** |
| `mysqld_exporter` | MySQL / MariaDB | 9104 | scrape-time (SQL) | Optional |
| `postgres_exporter` | PostgreSQL | 9187 | scrape-time (SQL) | Optional |
| `redis_exporter` | Redis / Valkey | 9121 | scrape-time (`INFO`) | **Yes** (`?target=`) |
| `kube-state-metrics` (KSM) | K8s API object state | 8080 (metrics) / 8081 (self) | watch + cache | No |
| `cAdvisor` | Container resource usage | 8080 (or via kubelet) | background + cache | No |
| `statsd_exporter` | StatsD UDP/TCP stream | 9102 (metrics) / 9125 (ingest) | push→pull bridge | No |
| `jmx_exporter` | JVM via JMX (usually as agent) | app-defined | scrape-time (JMX) | No |

> **Port allocation note**: the community maintains a canonical port-allocation registry so exporters don't collide (9100 = node, 9115 = blackbox, 9104 = mysqld, …). When you deploy a custom exporter, claim a port from that list rather than inventing one.

### 2.2 Direct instrumentation vs. exporter

| Dimension | Direct instrumentation | Exporter |
|---|---|---|
| Requires source access | Yes (recompile/link) | No |
| Metric fidelity | Highest — true internal state | Limited to what the native protocol exposes |
| Extra moving part | None | A separate process to run, monitor, patch |
| Failure independence | Metric death ⇒ app death | Exporter can die while target lives (and vice-versa) |
| `up` semantics | `up=1` means the app is serving | `up=1` means the *exporter* answered, **not** that the target is healthy |
| Best for | Your own services | Third-party & OS-level systems |

The `up` semantics row is the exam-critical trap. `up{job="mysql"} == 1` tells you `mysqld_exporter` responded — the database could be in a crash loop behind it. You need the exporter's *target-health* metric (e.g. `mysql_up`, `pg_up`, `probe_success`, `redis_up`) to assert the real system is healthy.

### 2.3 Deployment topology trade-offs

| Pattern | Where it runs | Use when | Trade-off |
|---|---|---|---|
| **Sidecar** | Same Pod as the target, shares network namespace | Per-instance targets (a DB replica, an app) | 1:1 lifecycle coupling; N exporters for N Pods; localhost access to target |
| **DaemonSet** | One per node | Host-level metrics (`node_exporter`, `cAdvisor`) | Requires host mounts / `hostNetwork`; exactly one per node |
| **Centralized Deployment** | Standalone, reaches targets over the network | Stateless multi-target exporters (`blackbox`, `snmp`) | Single scaling unit; must not become a SPOF or a scrape bottleneck |
| **Multi-target (one exporter, many targets via `?target=`)** | Standalone | Probing hundreds of endpoints/devices | Relabeling complexity; exporter concurrency limits |

---

## 3. `node_exporter` — the canonical host exporter

`node_exporter` reads `/proc`, `/sys`, and other kernel interfaces and translates them into `node_*` metrics. It is composed of **collectors** — one per subsystem (CPU, filesystem, netdev, diskstats, meminfo…). Collectors are individually toggleable, and *collector selection is a production decision*: each collector adds scrape cost and cardinality.

### 3.1 Collector control

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

Every collector self-reports whether it succeeded, which is how you detect a *partial* exporter failure (the exporter is up, but one collector is broken):

```text
# TYPE node_scrape_collector_success gauge
node_scrape_collector_success{collector="filesystem"} 1
node_scrape_collector_success{collector="systemd"} 0        # <-- broken collector
# TYPE node_scrape_collector_duration_seconds gauge
node_scrape_collector_duration_seconds{collector="filesystem"} 0.00214
```

An alert on `node_scrape_collector_success == 0` catches the "up but blind" case that `up == 1` masks.

### 3.2 The textfile collector — extending an exporter without forking it

The textfile collector is the sanctioned escape hatch for exposing metrics that `node_exporter` doesn't natively produce (backup age, cron job outcomes, hardware sensor scripts). A cron job writes a `.prom` file **atomically** (write to temp, then `mv` — a half-written file corrupts the scrape):

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

The metric then appears in `node_exporter`'s output and can drive an alert like `time() - backup_last_success_timestamp_seconds > 86400`.

### 3.3 Production DaemonSet manifest

`node_exporter` must see the *host's* namespaces, not the container's. That means `hostNetwork`, `hostPID`, host filesystem mounts, and the `--path.*` flags rooted at the mount points. Skipping `--path.rootfs` is the classic bug that makes filesystem metrics report the container's overlay FS instead of the node's disks.

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

The `mount-points-exclude` / `fs-types-exclude` regexes are not cosmetic: without them, `node_exporter` emits a `node_filesystem_*` series for every ephemeral container overlay and kubelet bind mount, exploding cardinality on a busy node.

### 3.4 Discovery: `ServiceMonitor` (Prometheus Operator)

If you run the Prometheus Operator, you don't edit `prometheus.yml`; you declare a `ServiceMonitor` and the operator generates the scrape config:

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

## 4. The multi-target exporter pattern (`blackbox_exporter`)

Single-target exporters embed the target in their own config. **Multi-target exporters take the target as a URL parameter** — `GET /probe?target=<x>&module=<y>` — so *one* exporter instance probes thousands of endpoints. `blackbox_exporter` (HTTP/TCP/ICMP/DNS) and `snmp_exporter` are the archetypes. Mastering the relabeling for this pattern is a core PCA skill.

### 4.1 Module configuration

The exporter's own config defines *modules* — reusable probe recipes. It does **not** list targets; Prometheus supplies those.

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

### 4.2 The relabeling handshake (the crux)

The scrape config performs a four-step relabel dance so that Prometheus scrapes the *exporter* but passes the *real endpoint* as `?target=`:

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

Without step 3, Prometheus tries to scrape `/probe` on `example.com` itself, which obviously fails. Without step 2, every series is labelled `instance="blackbox-exporter:9115"` and you cannot tell the endpoints apart.

### 4.3 What a probe returns

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

`probe_ssl_earliest_cert_expiry` is the metric behind every "TLS certificate expires in N days" alert:

```promql
# Certificate expires in under 14 days
(probe_ssl_earliest_cert_expiry - time()) / 86400 < 14
```

### 4.4 Deployment

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

> **Scaling caveat**: with `blackbox_exporter` doing collect-on-scrape probing, a probe that hangs on a dead endpoint holds a goroutine for the full `timeout`. Probing thousands of targets at a short interval can exhaust the exporter — size `scrape_interval` and `timeout` against target count, and shard across replicas if needed.

---

## 5. Writing a custom exporter

When no exporter exists for your system, you write one with a client library. The idiomatic exporter pattern is a **custom collector** whose `collect()` method is invoked *at scrape time* — you query the target inside `collect()` and yield fresh metric families. Do **not** use module-level `Gauge`/`Counter` objects updated by a background thread for an exporter that adapts external state; the custom-collector pattern guarantees the values are consistent as of the scrape and avoids stale state.

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

**Exporter authoring checklist** (each item prevents a real production incident):

- Always emit an `<x>_up` target-health metric, even (especially) when the target is unreachable — a scrape that returns *only* `queue_up 0` is far more useful than a failed scrape that returns nothing.
- Never turn an unbounded target attribute (request path, user ID, full URL) into a label — this is the cardinality bomb that OOMs Prometheus.
- Counters only ever go up; reset semantics are handled by `rate()`. Don't reset a counter to reflect target state — use a gauge.
- Keep labels stable across scrapes; a label that appears/disappears creates staleness gaps.

---

## 6. Securing exporters (exporter-toolkit)

An exporter's `/metrics` endpoint leaks operational intelligence — hostnames, filesystem layout, connection counts, cert expiries. Prometheus exporters that use the shared `exporter-toolkit` library (node, blackbox, and most first-party exporters) support TLS and basic auth via a `--web.config.file`:

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

The matching Prometheus scrape config must present the credentials and trust the CA:

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

> In Kubernetes, an alternative is to leave the exporter plaintext but bind it to `localhost`/Pod network only and enforce access with a `NetworkPolicy` that permits ingress on the metrics port **solely** from the Prometheus Pods — defense in depth rather than either/or.

---

## 7. The exception: Pushgateway (and why it is not an exporter)

Batch/cron jobs are the one case the pull model cannot cover: the job exits before Prometheus can scrape it. The **Pushgateway** is a push→pull bridge — the job `POST`s its final metrics, the gateway caches them, and Prometheus scrapes the gateway.

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

Critical distinctions from a real exporter, and why you should reach for it *only* for service-level batch jobs:

- The gateway **never expires** pushed metrics; a job that ran once leaves stale series until explicitly `DELETE`d. `up` reflects the *gateway's* health, not the job's — so it cannot detect that a job failed to run at all.
- Prometheus must scrape it with `honor_labels: true`, so the `job`/`instance` the pusher set survive instead of being overwritten with the gateway's own.
- It is **not** for capturing metrics from services that could be scraped — using it that way discards the pull model's liveness signal.

---

## 8. Verification & failure diagnosis

### 8.1 First-principles checks

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

### 8.2 Failure-mode reference table

| Symptom | Likely cause | Where to look / fix |
|---|---|---|
| Target `DOWN`, `lastError: connection refused` | Exporter process not listening / wrong port | `ss -lntp \| grep 9100`; check `--web.listen-address` |
| Target `DOWN`, `401/403` | TLS/auth mismatch | Align `web-config.yml` bcrypt hash with scrape `basic_auth` |
| Target `UP` but **no metrics** appear | One malformed line rejects whole scrape | `promtool check metrics`; look for out-of-order `le`, dup labels, NaN |
| Target `UP`, `<x>_up == 0` | Exporter healthy, **target** unreachable | Check exporter→target creds/network (DSN, SNMP community, DB user grants) |
| `context deadline exceeded` on scrape | Collection slower than `scrape_timeout` | Raise `scrape_timeout`; disable expensive collectors; enable caching |
| Metrics present but **stale/frozen** | Cached exporter not re-polling, or crashed collector | Check `node_scrape_collector_success`; restart; verify background poll |
| Prometheus RAM/TSDB churn after adding an exporter | Cardinality explosion from unbounded labels | `topk(10, count by (__name__)({__name__=~".+"}))`; add label drops |
| Filesystem metrics show container FS, not host | Missing `--path.rootfs` / host mounts | Fix DaemonSet `--path.*` flags and `hostPath` volumes |
| blackbox multi-target scrapes the endpoint, not the exporter | Missing relabel step 3 | Add the `__address__` → exporter replacement relabel rule |

### 8.3 Cardinality audit (the exporter capacity killer)

An exporter is the most common source of a cardinality incident because it maps *external* state you don't fully control into labels. Audit before and after rollout:

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

The fix is at the exporter (collector excludes, label allowlists) or in the scrape config via `metric_relabel_configs` with a `drop` action — applied *before* ingestion so the series never hit the TSDB:

```yaml
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'node_(scrape_collector_duration_seconds|softnet_.*)'
        action: drop
```

---

## 9. References

- Prometheus — *Exporters and integrations* (official catalogue): https://prometheus.io/docs/instrumenting/exporters/
- Prometheus — *Writing exporters* (design guidelines, naming, `_up` convention): https://prometheus.io/docs/instrumenting/writing_exporters/
- Prometheus — *Exposition formats* (text format & OpenMetrics): https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — *Default port allocations* wiki: https://github.com/prometheus/prometheus/wiki/Default-port-allocations
- `node_exporter` repository & collector list: https://github.com/prometheus/node_exporter
- Prometheus — *Monitoring Linux host metrics with the Node Exporter*: https://prometheus.io/docs/guides/node-exporter/
- `blackbox_exporter` repository & configuration: https://github.com/prometheus/blackbox_exporter
- Prometheus — *Understanding and using the multi-target exporter pattern*: https://prometheus.io/docs/guides/multi-target-exporter/
- `snmp_exporter` repository: https://github.com/prometheus/snmp_exporter
- `exporter-toolkit` (TLS & auth for exporters): https://github.com/prometheus/exporter-toolkit/blob/master/docs/web-configuration.md
- Pushgateway repository & "when (not) to use it": https://github.com/prometheus/pushgateway
- `kube-state-metrics` repository: https://github.com/kubernetes/kube-state-metrics
- Prometheus Python client (`prometheus_client`, custom collectors): https://github.com/prometheus/client_python
- Prometheus Operator — `ServiceMonitor`/`Probe` API: https://prometheus-operator.dev/docs/operator/api/
- CNCF — *Prometheus Certified Associate (PCA) Curriculum*: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf