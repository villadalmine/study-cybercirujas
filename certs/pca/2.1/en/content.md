# 2.1 System Architecture

> **Domain:** Prometheus Fundamentals · **Exam weight:** 4
> **Profile:** This module dissects the internal architecture of a Prometheus deployment the way you would need to reason about it while on call — component by component, byte by byte through the TSDB, and failure mode by failure mode. Prometheus is deceptively simple to `docker run`; it is unforgiving to operate at scale unless you understand *where the data lives, who pulls it, and what breaks first*.

---

## 1. Motivation: the production problem Prometheus was built to solve

Before Prometheus, the dominant monitoring model was **push-based, hierarchical, and check-oriented** (Nagios, Zabbix, StatsD/Graphite pipelines). Those systems answer *"is this host up?"* well but degrade badly in a world of ephemeral, orchestrated workloads where:

- Instances appear and disappear every few minutes (autoscaling, rolling deploys, Spot preemption). A statically configured "host list" is stale before you save the file.
- The interesting failures are **dimensional**, not binary: not *"the API is down"* but *"p99 latency for `route=/checkout` in `zone=eu-west-1c` for `version=v2.3.1` regressed 40 ms after the 14:02 rollout."* You cannot express that with a host-and-service check.
- The number of moving parts (pods, containers, sidecars) is an order of magnitude larger than the number of physical hosts, so the monitoring system itself must scale to **millions of active time series**.

Prometheus (a CNCF graduated project, the second after Kubernetes) answers this with three opinionated architectural choices, each of which is a trade-off you must be able to defend:

1. **A pull model over HTTP** — Prometheus discovers targets and scrapes their `/metrics` endpoint on a schedule, rather than receiving pushed metrics. This inverts control: the monitoring system decides *who* is monitored and *when*, and target health becomes a first-class, free signal (`up`).
2. **A multi-dimensional data model** — every sample is identified by a metric name **plus an unordered set of key/value labels**. `http_requests_total{method="POST", route="/checkout", code="500"}` is a distinct time series from the same metric with `code="200"`. This is what makes dimensional slicing possible in PromQL.
3. **A local, single-node, purpose-built TSDB** — each Prometheus server owns its data on local disk, with no clustering and no external dependencies in the hot path. This is the single most important reliability decision: *when your infrastructure is on fire, your monitoring must not depend on the thing that is burning.*

The architectural cost of these choices — no built-in horizontal scaling, no long-term durable storage, no strong consistency — is exactly what the rest of the ecosystem (Alertmanager, exporters, remote-write backends like Thanos/Cortex/Mimir) exists to compensate for. **Understanding the architecture is understanding where each of those cracks is, and which component patches it.**

---

## 2. The component map

Prometheus is not a monolith; it is a small server core surrounded by an ecosystem of independent processes that communicate over HTTP. Learn the boundaries — most production incidents are *at the boundaries*.

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

| Component | Process? | Default port | Responsibility | Where it breaks |
|---|---|---|---|---|
| **Retrieval / scrape manager** | in‑server | — | Pulls `/metrics` from targets on `scrape_interval`, applies `metric_relabel_configs`, appends samples | Scrape timeouts, target churn, cardinality bombs |
| **Service Discovery** | in‑server | — | Resolves the dynamic target set (K8s API, Consul, DNS, `file_sd`…) and feeds relabeling | Stale SD → scraping dead pods; SD API rate limits |
| **TSDB** | in‑server | — | Ingest + persist + query samples; head block, WAL, on‑disk blocks, compaction | Disk full, WAL replay slowness, high churn |
| **PromQL engine + HTTP API** | in‑server | 9090 | Query evaluation, `/api/v1/*`, web UI, federation endpoint | Expensive queries OOM the server |
| **Rule manager** | in‑server | — | Evaluates recording & alerting rules every `evaluation_interval` | Slow rules → missed evaluations, alert gaps |
| **Notifier** | in‑server | — | Ships fired alerts to Alertmanager(s) | AM unreachable → alerts buffered/dropped |
| **Alertmanager** | separate | 9093 | Dedup, grouping, routing, silencing, inhibition, notification | Cluster gossip split‑brain → duplicate/lost pages |
| **Exporters** | separate | 9100 (node), … | Translate a system's native metrics into exposition format | Exporter is a *proxy*, not a source of truth |
| **Pushgateway** | separate | 9091 | Cache for **short‑lived batch jobs** that die before a scrape | Abused as a general push endpoint → stale metrics |
| **Client libraries** | in‑app | — | Direct instrumentation (counters/gauges/histograms/summaries) | Wrong metric type, unbounded label values |

**Exam-critical distinctions:**

- **Exporters are not databases.** `node_exporter` holds no history; it computes the current values of `/proc` and `/sys` on each scrape. All history lives in Prometheus's TSDB.
- **Pushgateway is the *only* sanctioned push path**, and only for **service-level batch jobs** that terminate before Prometheus can scrape them. It is emphatically **not** a way to turn Prometheus into a push system — it does not solve the "target down" problem, it caches the last pushed value indefinitely, and it becomes a single point of failure and a cardinality sink if misused.
- **Alertmanager, not Prometheus, decides who gets paged.** Prometheus only decides *whether a rule expression is firing*. Deduplication, grouping, routing, silences and inhibition are all Alertmanager concerns. This separation is why you run **two identical Prometheus servers** for HA and let Alertmanager dedup their identical alert streams.

---

## 3. The scrape path in detail (pull model mechanics)

Every `scrape_interval`, for every active target, the scrape manager performs:

1. **HTTP GET** the target's metrics path (default `/metrics`) with a `scrape_timeout` deadline.
2. **Parse** the response body as the **Prometheus text exposition format** (or OpenMetrics / protobuf, negotiated via `Accept`). Content-Type example: `text/plain; version=0.0.4`.
3. **Apply `metric_relabel_configs`** — per-sample relabeling that can drop, keep, or rewrite labels *after* scraping (contrast with `relabel_configs`, which runs on the *target* set *before* scraping).
4. **Append** each sample to the TSDB head with the scrape timestamp, plus synthetic per-scrape series: `up` (1/0), `scrape_duration_seconds`, `scrape_samples_scraped`, `scrape_samples_post_metric_relabeling`, `scrape_series_added`.

A raw scrape of one target looks like this:

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

### 3.1 Pull vs push — the trade-off you must be able to argue

| Dimension | **Pull (Prometheus native)** | **Push (StatsD / Pushgateway / OTLP push)** |
|---|---|---|
| Target liveness | Free, first-class signal (`up == 0`) | Silence is ambiguous: dead, or just not sending? |
| Configuration authority | Central (Prometheus knows the full target set via SD) | Distributed across every client |
| Firewall / network | Prometheus must **reach** targets | Clients must **reach** the collector (better for NAT/edge) |
| Ephemeral/batch jobs | **Weak** — job may die before scrape → needs Pushgateway | **Strong** — job pushes then exits |
| Ad-hoc debugging | Just `curl` the target's `/metrics` by hand | No equivalent; you can't inspect a client on demand |
| Overload behavior | Prometheus self-limits via `scrape_interval`; can't be flooded | A misbehaving client can flood the collector |
| Cardinality control | Enforced centrally (`sample_limit`, relabel drops) | Client-side; easy to lose control |

Prometheus chooses pull and then patches the *one* genuine weakness (batch jobs) with the Pushgateway, rather than adopting push wholesale and losing central control and the `up` signal.

### 3.2 Service discovery + relabeling

Relabeling is the join point between "the world as SD sees it" (`__meta_*` labels) and "the target set Prometheus scrapes." A canonical Kubernetes pod-scraping block:

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

The two relabeling phases are a recurring exam point:

| Phase | Config key | Runs | Operates on | Typical use |
|---|---|---|---|---|
| Target relabeling | `relabel_configs` | **before** scrape | the target and its `__meta_*` / `__address__` | keep/drop targets, rewrite address/path/scheme, build labels |
| Metric relabeling | `metric_relabel_configs` | **after** scrape | each ingested sample's labels | drop noisy series, prune labels, cap cardinality |

---

## 4. Storage architecture: the TSDB internals

The single most operationally important subsystem. A time series is an append-only stream of samples; each **sample** is a `(timestamp int64 ms, value float64)` pair — 16 bytes raw — belonging to a series identified by its full label set.

### 4.1 On-disk layout

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

### 4.2 The write path: WAL → head → block → compaction

1. **WAL (Write-Ahead Log)** — every incoming sample and every new series is first appended to the `wal/` directory (128 MB segments). This is the durability guarantee: on crash, Prometheus replays the WAL to reconstruct in-memory state. Nothing is acknowledged until it's in the WAL.
2. **Head block (in memory)** — the most recent, still-open data lives in RAM as active chunks. When a chunk fills (**120 samples** or when the head is cut), it is **mmap'd to `chunks_head/`** so the kernel — not the Go heap — holds it, keeping Prometheus's own memory bounded.
3. **Head compaction → persistent block** — every **2 hours** the head is truncated: the oldest 2-hour window is written out as an immutable on-disk **block** (a ULID-named directory with `chunks/`, `index`, `meta.json`, `tombstones`), and the corresponding WAL segments are removed. Blocks are self-contained: they can be independently backed up, shipped (Thanos), or deleted.
4. **Background compaction** — over time, adjacent 2-hour blocks are merged into larger blocks (level 2, 3…), deduplicating the index and improving query efficiency. Max block size is capped at `retention.time / 10` (default cap **31 days**).
5. **Retention enforcement** — blocks whose `maxTime` is older than `--storage.tsdb.retention.time` (default **15d**), or when `--storage.tsdb.retention.size` is exceeded, are deleted whole. Retention operates on **blocks**, never individual samples.

### 4.3 Compression — why the TSDB is small

Prometheus applies the Facebook **Gorilla** encoding:

- **Timestamps**: delta-of-delta ("double-delta"). Regular scrape intervals produce a delta-of-delta of 0, encoded in a single bit.
- **Values**: XOR of consecutive float64s, storing only the changed bits.

Net effect: the 16 bytes/sample raw collapse to roughly **1–2 bytes/sample** on disk in typical workloads. This is what makes the capacity-planning formula tractable:

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

### 4.4 Local TSDB vs remote long-term storage

| Concern | **Local TSDB (built-in)** | **Remote-write to Thanos / Cortex / Mimir / VictoriaMetrics** |
|---|---|---|
| Retention | Days–weeks (disk-bound) | Months–years (object storage) |
| Scale | Single node; vertical only | Horizontal, multi-tenant |
| Query latency (recent) | Lowest (local disk) | Adds network hop |
| Global view | One server's data only | Aggregated across many Prometheus instances |
| Reliability during infra outage | **Survives** (no external deps) | Backend may be part of the outage |
| Cost | Local SSD | Object storage + compute for the backend |
| Operational complexity | Trivial | Significant (a distributed system in its own right) |

**Architecture rule:** keep short-term, high-fidelity, alerting-critical data local; ship a copy via `remote_write` for long-term/global. `remote_write` is itself **WAL-based** — it tails the same WAL, shards the stream, and buffers on backend outages. Watch `prometheus_remote_storage_samples_pending` and `prometheus_remote_storage_shards`.

### 4.5 Agent mode — an architectural variant worth knowing

`prometheus --enable-feature=agent` (or `--agent`) strips the server down to **scrape + WAL + remote_write**: no local query engine, no persistent blocks, no rules/alerting. It exists for the fan-in topology where edge clusters forward everything to a central Mimir/Thanos and never query locally. Trade-off: you gain a tiny, cheap collector; you lose local querying and local alerting.

---

## 5. High availability and scaling topologies

Prometheus has **no clustering** — a server is a single node by design. HA is achieved by *replication and dedup at the edges*, not by consensus.

| Topology | How | Pros | Cons |
|---|---|---|---|
| **Single server** | one Prometheus | simplest, lowest cost | SPOF; scale ceiling ≈ 1 node's RAM/CPU/disk |
| **Replicated pair (HA)** | two identical servers scrape the **same** targets; Alertmanager dedups | survives one node loss; no data-loss window for alerting | 2× scrape load; the two TSDBs are *not* byte-identical |
| **Functional/vertical sharding** | split scrape jobs across servers by team/service | linear scale of scrape load | no single global view; query federation needed |
| **Hashmod sharding** | `hashmod` on `__address__` to split targets N ways | scales one huge job across N servers | rebalancing on N change churns series |
| **Hierarchical federation** | a "global" Prometheus scrapes aggregated series from "leaf" servers via `/federate` | cross-shard rollups, global dashboards | global server only sees pre-aggregated data; not for raw drill-down |
| **Remote-write fan-in** | all servers `remote_write` to Thanos/Mimir | true global view + long-term | operate a distributed backend |

**Hashmod sharding** relabel snippet — the same scrape job deployed N times, each with a different `SHARD` env, splits the target set:

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

**Federation** — a global Prometheus pulling pre-aggregated recording rules from leaves:

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

## 6. Complete deployment manifests

### 6.1 Kubernetes: RBAC + ConfigMap + StatefulSet + Service (server core)

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

### 6.2 node_exporter as a DaemonSet (one exporter per node)

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

### 6.3 Alertmanager (the routing brain) — config + HA StatefulSet

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

## 7. Verification and failure diagnosis

### 7.1 Validate before you deploy

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

A hot reload without a restart (requires `--web.enable-lifecycle`):

```console
$ curl -s -XPOST http://localhost:9090/-/reload && echo "reloaded"
reloaded
# Verify the reload actually succeeded (a bad file is rejected and the OLD config stays live):
$ curl -s http://localhost:9090/api/v1/status/config | head -c 120
{"status":"success","data":{"yaml":"global:\n  scrape_interval: 15s\n  scrape_timeout: 10s\n ...
```

### 7.2 Liveness, readiness, build, and runtime flags

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

### 7.3 Are targets actually being scraped?

The `up` metric is the first thing you check. `up == 0` means "SD found this target but the scrape failed"; a *missing* `up` series means "SD never produced the target at all" — a relabeling/discovery problem, not a scrape problem.

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

### 7.4 TSDB health, cardinality and churn — the number-one production killer

The most common way a Prometheus server dies is a **cardinality explosion**: an instrumented app puts an unbounded value (a user ID, a full URL, a UUID, an error message) into a label, and the active series count runs away, exhausting RAM. Diagnose it with the built-in stats endpoint and `promtool`:

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

**Reading it:** the `path` label has 41,988 distinct values — an unbounded URL/path being used as a label. The fix is instrumentation-side (bucket the path into a fixed route template) plus a defensive `metric_relabel_configs` drop and a `sample_limit`/`label_limit` on that job so a single bad target can't take the server down.

### 7.5 Head/WAL and remote-write health signals (Prometheus scraping itself)

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

### 7.6 Failure diagnosis cheat sheet

| Symptom | Likely cause | Confirm with | Fix |
|---|---|---|---|
| `up == 0` for a target | Scrape failed (timeout, refused, TLS, auth) | `activeTargets[].lastError` | fix target/net/creds; raise `scrape_timeout` |
| Target absent entirely (no `up` series) | SD didn't produce it / relabel `keep` dropped it | `/api/v1/targets?state=dropped` | fix `relabel_configs` / SD role / RBAC |
| Prometheus OOMKilled | cardinality explosion in the head | `status/tsdb`, `promtool tsdb analyze` | drop/relabel the offending label; `sample_limit` |
| Slow restart / long WAL replay | very large head + WAL | `prometheus_tsdb_wal_...` metrics, startup logs | shard the server; reduce churn |
| Disk full | retention too long / block growth | `df`, `retention.size` flag | set `--storage.tsdb.retention.size` |
| Gaps in graphs | missed scrapes or slow rule eval | `scrape_duration_seconds`, `rule_evaluation_duration_seconds` | fewer targets/rules per server; shard |
| Duplicate pages | HA pair alerts not deduped | Alertmanager cluster status `:9093/#/status` | fix AM `--cluster.peer` gossip |
| Remote backend lag | pending samples rising | `remote_storage_samples_pending`, `_shards` | scale backend; raise `max_shards` |
| Config change not applied | reload silently rejected | `/api/v1/status/config`, logs | fix YAML; re-`POST /-/reload` |

### 7.7 Understanding Prometheus's *architectural limitations* (they are on the exam)

- **Not durable long-term storage.** Local blocks are finite; use `remote_write` for months/years.
- **Not 100% accurate.** Scraping samples over time; not suitable for **billing or per-request auditing** where you need exact event counts — use event logging for that.
- **No horizontal clustering.** Scale is vertical per server; horizontal comes from sharding + federation + a remote backend, not from Prometheus itself.
- **Push is a special case, not the norm.** Only batch jobs via Pushgateway; do not architect around push.
- **Cardinality is the hard limit.** RAM is roughly linear in active series. Label discipline is an architectural requirement, not a style preference.

---

## 8. References

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