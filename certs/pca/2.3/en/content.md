# Understanding Prometheus Limitations

> PCA Domain 2 — Prometheus Fundamentals · Topic 2.3 · Exam weight: 4
> Level: SRE / Platform Architect · Authoring language: English

---

## 1. Motivation — the architectural contract you are actually signing

Prometheus is one binary, one local TSDB, one process, on one node. That is not an accident or an unfinished feature — it is the core design decision, and every limitation in this topic is a direct consequence of it. The project states the contract explicitly:

> "Prometheus values reliability. You can always view what statistics are available about your system, even under failure conditions. If you need 100% accuracy, such as for per-request billing, Prometheus is not a good choice."
> — *When does it fit?*, prometheus.io

The mental model an SRE must internalize: **Prometheus optimizes for being *up and answerable during an incident*, not for being *complete and durable after one*.** The moment a network partition, a downstream store, or a replica election could block a query, Prometheus chooses to keep serving what it has locally. That single priority explains why it is a pull-based, single-node, best-effort, short-retention system — and why every production deployment eventually bolts something onto it.

The architectural problem you will hit in production is therefore predictable. It arrives in this order:

1. **Retention** — your local disk fills, or 15 days of history isn't enough for capacity planning / SLO reporting over quarters.
2. **Scale** — a single Prometheus can no longer hold the active series set of a growing fleet in RAM.
3. **Availability** — a single Prometheus is a single point of observability failure; when it dies, you are blind exactly when you need to see.
4. **Global view** — you now run many Prometheis (per-cluster, per-region) and need one query surface across all of them.
5. **Accuracy** — finance asks you to bill customers off a counter, and you have to say no.

Topic 2.3 is the exam's way of making sure you can name these five walls *before* you hit them, and can name the correct escape hatch for each.

---

## 2. The limitations, categorized

### 2.1 Local storage is not durable, not clustered, not replicated

The TSDB writes 2-hour **blocks** to the local filesystem, fronted by a **WAL** (write-ahead log) and an in-memory **head block**. Older blocks are compacted into larger ones. There is no replication and no clustering of this storage: the data lives on the node's disk and nowhere else.

Retention is bounded by two flags (whichever triggers first):

| Flag | Meaning | Default |
|---|---|---|
| `--storage.tsdb.retention.time` | Delete blocks older than this | `15d` |
| `--storage.tsdb.retention.size` | Delete oldest blocks past this on-disk size | `0` (disabled) |
| `--storage.tsdb.path` | Where blocks live | `data/` |
| `--storage.tsdb.wal-compression` | Compress the WAL | enabled (recent versions) |

Consequences you must design around:

- **Node loss = data loss.** No replica has the samples. HA is achieved by running *two independent* Prometheus servers scraping the same targets — not by clustering storage.
- **Local disk sizing is a hard capacity limit.** Rough planning formula from the docs:
  `needed_disk_bytes = retention_time_seconds × ingested_samples_per_second × bytes_per_sample`
  with `bytes_per_sample` empirically ≈ **1–2 bytes** after compression.
- **Backups are non-trivial.** The head/WAL is live; you snapshot via the admin API (`/api/v1/admin/tsdb/snapshot`), not by copying files under a running process.

### 2.2 No horizontal scaling of a single server

One Prometheus scales **vertically** only. The active (head) series set must fit in RAM; more targets and more cardinality mean more memory, and eventually a single node cannot hold it. There is no native sharding of a single instance's data.

The sanctioned scaling patterns are all *external* topologies:

- **Functional sharding** — split scrape responsibility across multiple Prometheus servers by job/team/service.
- **Hierarchical federation** — a "global" Prometheus scrapes *aggregated* series from many lower-level Prometheis via `/federate`.
- **remote_write to a horizontally-scalable backend** — Thanos Receive, Cortex, Grafana Mimir, VictoriaMetrics.

### 2.3 Not 100% accurate — do not bill from it

Prometheus is a **sampling, best-effort** system. Reasons a value can be "wrong" for accounting purposes:

- **Scrapes can be missed** (target down, timeout, restart) — gaps are normal and expected.
- **`rate()` / `increase()` extrapolate** over the window and across counter resets; they estimate, they don't count.
- **Staleness handling and interpolation** mean point-in-time values are approximations.
- **Samples in flight can be lost** on crash before WAL flush.

This is by design and is *the* reason the docs single out per-request billing as a non-fit. For exact counts, emit events to a log/stream pipeline (e.g. logs → aggregation), not to a metric.

### 2.4 Cardinality is the real production killer

Every unique combination of metric name + label values is a **separate time series**, held in the head block in memory. High cardinality is the number-one cause of Prometheus OOMs and slow queries.

Cardinality-exploding anti-patterns (all forbidden as labels):

- User IDs, email addresses, session IDs
- Full request paths with IDs (`/user/12345/order/98765`)
- Timestamps, UUIDs, container IDs, pod names churning on every deploy
- Unbounded free-form strings (error messages, SQL queries)

A label with 1,000 values × another with 1,000 values on the same metric = up to **1,000,000 series** from one metric. This is why the naming/labels practices explicitly warn to keep label value sets bounded and low.

### 2.5 Pull model + short-lived jobs

Prometheus **pulls** (scrapes) targets on an interval. A batch/cron job that exits in 3 seconds may never be scraped. The prescribed workaround is the **Pushgateway** — but it is narrow, and the exam wants you to know its caveats:

- Pushgateway is an **exposition cache for service-level batch jobs**, *not* a way to push event/streaming metrics and *not* a scaling mechanism.
- It becomes a **single point of failure** and a **cardinality/staleness trap**: metrics persist until explicitly deleted, so a finished job's last value lingers and `up` no longer reflects instance health.
- One Pushgateway aggregating many machines' metrics defeats Prometheus's per-target health model.

### 2.6 Wrong tool for logs, events, and tracing

Prometheus stores **numeric time series only**. It is not a log store, not an event store, not a tracing backend, and not a general-purpose analytics database. High-cardinality, high-dimensionality, per-event data belongs in Loki/Elasticsearch (logs), Tempo/Jaeger (traces), or a columnar/event store — not in Prometheus label sets.

---

## 3. Comparative trade-off tables

### 3.1 Limitation → symptom → escape hatch

| Limitation | Production symptom | Correct solution | What it costs you |
|---|---|---|---|
| Short local retention | "History only goes back 15d" | `remote_write` → Thanos/Mimir/Cortex/VictoriaMetrics; or Thanos sidecar → object storage | Extra infra + object storage; query latency for old data |
| No storage replication | Node dies → data gone | HA pair (2× Prometheus) + long-term store | 2× scrape load; dedup at query layer |
| No horizontal scale (single server) | OOM as fleet grows | Functional sharding / federation / remote_write cluster | Operational complexity, more moving parts |
| No global query view | Many Prometheis, no single pane | Thanos Querier / Mimir / Cortex query frontend | A new query tier to run |
| Not 100% accurate | Finance wants to bill from a counter | Event pipeline (logs/stream), not metrics | Separate system; higher cost per event |
| High cardinality | OOM, slow queries, huge head | Relabeling to drop labels, `metric_relabel_configs`, naming discipline | Lose granularity you thought you wanted |
| Short-lived jobs missed | Batch metrics never scraped | Pushgateway (service-level only) | SPOF, stale metrics, manual cleanup |
| Logs/traces | Trying to store logs as labels | Loki / Tempo / OTel collector | Additional observability stack |

### 3.2 Long-term storage backends (the four you should be able to name)

| | **Thanos** | **Cortex** | **Grafana Mimir** | **VictoriaMetrics** |
|---|---|---|---|---|
| Integration model | Sidecar (uploads blocks) **or** Receive (remote_write) | remote_write (push) | remote_write (push) | remote_write (push) |
| Object storage | Yes (S3/GCS/etc.) | Yes | Yes | Own format (or S3 in cluster tiers) |
| Global query | Thanos Querier fans out | Query frontend | Query frontend | vmselect |
| Downsampling | Yes (Compactor: 5m, 1h) | Limited | Yes | Yes |
| Multi-tenancy | Add-on | Native | Native | Native (enterprise/cluster) |
| Dedup of HA pairs | Yes (at Querier) | Yes | Yes | Yes |
| Typical fit | Add long-term + global view to existing Prometheis | Large multi-tenant SaaS | Large multi-tenant, Grafana-native | High ingest, lower resource footprint |

### 3.3 Federation vs remote_write (the two most-confused scaling paths)

| | **Federation (`/federate`)** | **remote_write** |
|---|---|---|
| Direction | Global Prometheus **pulls** aggregates | Prometheus **pushes** every sample out |
| Data granularity | Aggregated/selected series only | Full-resolution stream |
| Intended use | Cross-service aggregate roll-ups; global view of *summaries* | Long-term storage; horizontal ingest into a cluster |
| Anti-pattern | Federating *all* raw series (recreates the scale problem) | Using it when you only needed a few aggregate roll-ups |
| Failure mode | Global server inherits cardinality of what it federates | Backpressure/queue growth if remote endpoint is slow |

---

## 4. Complete manifests and infrastructure (uncut)

### 4.1 `prometheus.yml` — HA-friendly config with `external_labels`, `remote_write`, and cardinality-safe relabeling

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

### 4.2 Retention tuning at process level (Deployment args)

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

### 4.3 Thanos sidecar — add long-term storage + global view without leaving Prometheus

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

### 4.4 Federation — a global server pulling only aggregates

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

### 4.5 Pushgateway — for service-level batch jobs only

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

## 5. CLI commands and real terminal output

### 5.1 Measure your on-disk footprint (the retention wall)

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

### 5.2 Inspect head-block cardinality (the RAM wall) via the TSDB status API

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

### 5.3 Deep cardinality analysis of a block with `promtool`

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

The `id` label at 481k values is the textbook cardinality problem — it must be dropped with `labeldrop`/`metric_relabel_configs` (§4.1).

### 5.4 Prove the "not 100% accurate" property with a gap

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

### 5.5 Validate config, reload, and snapshot for backup

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

### 5.6 Confirm remote_write is actually shipping (the scale escape hatch works)

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

## 6. Verification and failure diagnosis

### 6.1 Diagnosis matrix

| Symptom | Likely limitation | Confirm with | Fix |
|---|---|---|---|
| Prometheus OOMKilled / restarts | Cardinality in head block | `/api/v1/status/tsdb` `numSeries`; `promtool tsdb analyze` | `labeldrop`/`metric_relabel_configs`; raise memory only as a stopgap |
| "History stops at ~15d" | Local retention | `--storage.tsdb.retention.*`; `du -sh /prometheus` | remote_write / Thanos sidecar → object storage |
| Disk full, oldest data purged early | `retention.size` hit before `retention.time` | Compare block ages vs disk usage | Bigger PVC or offload to LTS |
| Batch job metrics never appear | Pull model + short-lived job | Target absent in `/targets`; `up` never fired | Pushgateway (service-level) or make the job long-lived enough to scrape |
| Two Prometheis show slightly different values | HA replicas, best-effort | Compare `external_labels` `replica` A vs B | Dedup at Thanos Querier / Mimir; never expect bit-identical |
| Global server itself OOMs | Federating raw series | Its own `/status/tsdb` cardinality | Federate only recording-rule aggregates |
| `remote_storage_samples_pending` climbing | Backpressure to remote store | `..._samples_pending`, `..._samples_failed_total`, `..._shards` | Scale remote store / tune `queue_config` |
| Finance disputes billed counts | Not 100% accurate | Look for `.5` extrapolation, scrape gaps | Move accounting to an event pipeline, not metrics |

### 6.2 Golden signals to alert on for these limits

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

### 6.3 Verification checklist before you declare a Prometheus "production-ready at scale"

1. `promtool check config` and `promtool check rules` both `SUCCESS`.
2. `/api/v1/status/tsdb` `numSeries` is within your memory budget, with headroom for deploy churn.
3. Top labels from `promtool tsdb analyze` contain **no** unbounded IDs.
4. A long-term store is attached (`remote_write` healthy, `samples_failed_total` flat at 0) **or** you have consciously accepted 15-day retention.
5. HA pair exists with distinct `external_labels.replica`, and a dedup layer resolves their disagreement.
6. Batch jobs use Pushgateway with `honor_labels: true`, and stale entries are cleaned up.
7. Backups: `/api/v1/admin/tsdb/snapshot` succeeds and snapshots are shipped off-node.

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