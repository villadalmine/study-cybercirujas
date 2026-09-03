# 704.2 — Prometheus Monitoring

**Certification:** LPI DevOps Tools Engineer — Exam 701-100, syllabus version 2.0.0
**Topic:** 704 — Log Management and Monitoring · **Objective 704.2** — Prometheus Monitoring
**Exam weight:** 10 (the single heaviest objective in the exam — expect multiple questions on architecture, PromQL and alerting)

**Scope covered here** (own summary of the published objective; official wording at the LPI URL in *References*): the architecture and internal mechanics of Prometheus, its data model and metric types, scrape configuration and service discovery, exporters and instrumentation, PromQL, recording and alerting rules, Alertmanager routing, and visualization with Grafana.

---

## 1. Motivation: the architectural problem Prometheus was built to solve

### 1.1 What broke in the previous generation

Before 2012, monitoring was built around **hosts and checks**. Nagios asks "is `/dev/sda1` above 90% on `web03`?", gets back an exit code (`0/1/2/3`) and a human-readable string. That model rests on three assumptions that a container platform destroys:

| Assumption of check-based monitoring | Why it fails on a modern platform |
|---|---|
| The unit of failure is a **named host**, known in advance and long-lived | Pods are created and destroyed continuously; `web-7d9f5c-x4k2p` will not exist tomorrow. A static host list is stale before it is committed. |
| A check returns **a verdict** (OK/WARN/CRIT) | A verdict cannot be re-aggregated. You cannot ask "what is the p99 latency across the 40 replicas of this service" from 40 booleans. |
| Thresholds are **per host** | With autoscaling, per-host thresholds are meaningless. The interesting question is per *service*, sliced by version, region, endpoint. |
| State lives in the **checking agent** | The check knows only *now*. There is no history to ask "was this already degrading before the deploy?" |

Graphite and StatsD improved on this by storing numeric time series, but their identity model is a **dotted hierarchical string**: `prod.us-east-1.web.web03.http.requests.500`. That string bakes the query dimensions into a fixed order. Asking "500s across all regions for the `web` job" requires wildcard gymnastics (`prod.*.web.*.http.requests.500`), and asking "500s grouped by region **and** version" is impossible if version was never inserted into the hierarchy. Re-slicing means re-instrumenting.

### 1.2 The design decision: multi-dimensional identity + a query language

Prometheus (Matt T. Proud and Julius Volz at SoundCloud, 2012; second project to graduate from the CNCF after Kubernetes) changes the identity of a time series from a *path* to a *metric name plus an unordered set of key/value labels*:

```
http_requests_total{job="api", instance="10.2.4.11:8080", method="POST", handler="/v1/orders", status="500", region="us-east-1", version="1.14.2"}
```

Every label is an independent query dimension. Aggregation is decided **at query time**, not at instrumentation time. That single decision is what makes PromQL possible, and PromQL is what makes SLO-based alerting possible:

```promql
# Error budget burn rate over 1h for an SLO of 99.9% availability
(
  sum(rate(http_requests_total{job="api", status=~"5.."}[1h]))
  /
  sum(rate(http_requests_total{job="api"}[1h]))
) / (1 - 0.999)
```

No Nagios check can express that. This is the architectural point the exam is testing: **Prometheus is not a check runner, it is a dimensional time-series database with a scraper attached.**

### 1.3 What Prometheus deliberately is *not*

An SRE must know the boundaries, because half of production incidents with Prometheus come from using it as something it is not:

- **Not durable billing-grade storage.** Local TSDB is designed for weeks, not years, and a single node's disk is a single point of failure. Long-term durability is delegated to `remote_write` targets (Thanos, Mimir, Cortex, VictoriaMetrics).
- **Not 100% accurate.** Scraping is sampling. A counter increment between two scrapes is captured, but the exact instant is not. It is explicitly documented as unsuitable for per-request billing.
- **Not clustered.** A Prometheus server is a single process with local disk. High availability means *running two identical servers in parallel*, not a consensus cluster.
- **Not an event/log store.** Cardinality is the currency; a `user_id` label will destroy the server. Logs go to Loki/Elasticsearch; traces to Tempo/Jaeger.

---

## 2. Architecture and internal mechanics

### 2.1 Component map

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

Note the split that the exam likes to probe: **Prometheus evaluates the alerting rule and decides `firing`; Alertmanager decides *who gets told, when, grouped how, and whether it is suppressed*.** Prometheus never sends an email.

### 2.2 Pull vs push — the trade-off table

Prometheus **pulls** (scrapes) over HTTP. This is the most frequently misunderstood design decision.

| Dimension | Pull (Prometheus) | Push (StatsD, Graphite, OTel push) |
|---|---|---|
| Target discovery | Server must discover targets; SD is mandatory infrastructure | Targets must know the collector address; collector needs no SD |
| "Is it up?" | Free: the `up` metric is synthesized on every scrape | Requires a separate heartbeat convention |
| Firewall/NAT | Server must reach targets — hard across NAT/edge | Works from anywhere outbound |
| Overload behaviour | Server controls rate; a target storm cannot overwhelm it | A retry storm from clients can DDoS the collector |
| Debuggability | `curl http://target:9100/metrics` reproduces exactly what the server sees | Opaque; you must inspect the collector |
| Short-lived jobs (batch/cron) | **Broken** — the process dies before the scrape. Needs Pushgateway | Natural fit |
| Multiple consumers | N Prometheus servers can scrape the same target independently | Requires fan-out at the collector |
| Sample timestamps | Assigned by the server at scrape time (unless `honor_timestamps`) | Assigned by the client — clock skew becomes your problem |

**Rule for the exam and for production:** use pull for everything that lives longer than a scrape interval; use Pushgateway *only* for service-level batch jobs, never as a general push proxy.

### 2.3 The TSDB: what actually happens on disk

Understanding this is what separates "I can install Prometheus" from "I can operate Prometheus".

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

Life of a sample:

1. **Scrape** → sample appended to the **WAL** (durability) and to the in-memory **head block**.
2. **Head block** accumulates ~2 hours of data. Chunks are memory-mapped out to `chunks_head/` once full (120 samples per chunk by default) so the heap holds only the *active* chunk per series.
3. Every **2 hours** the head is cut and persisted as an immutable block; the WAL is truncated and a **checkpoint** written.
4. **Compaction** merges adjacent blocks into larger ones (levels), deduplicating the index. Max block size defaults to 10% of retention, capped at 31 days.
5. **Retention** deletes whole blocks older than `--storage.tsdb.retention.time` (default `15d`) or when `--storage.tsdb.retention.size` is exceeded. *Retention operates on blocks, never on individual samples* — which is why disk usage is sawtooth-shaped, not linear.

**Compression.** Timestamps use delta-of-delta encoding; values use the Gorilla XOR encoding. In practice a sample costs **~1.7–2 bytes** on disk. This gives the standard capacity formula:

```
disk_bytes ≈ retention_seconds × ingested_samples_per_second × bytes_per_sample
```

Worked example — 1,200,000 active series scraped every 15 s, retained 30 days:

```
samples/s      = 1_200_000 / 15            = 80_000
retention_s    = 30 × 86400                = 2_592_000
disk           = 2_592_000 × 80_000 × 2 B  ≈ 414 GB
```

Add ~15–20% for the index and headroom for compaction (compaction needs free space to write the new block before deleting the old). Provision ~500 GB.

**Memory.** The dominant term is active series × ~4–5 KB (head chunks + index + label strings). 1.2 M series ≈ 6–8 GB RSS with headroom for query execution. Memory is driven by **series count**, not by scrape interval.

### 2.4 Availability model

There is no clustering. The production patterns are:

| Pattern | How | Trade-off |
|---|---|---|
| **HA pair** | Two identical Prometheus servers, same config, both scraping everything | Simple; but the two have slightly different sample timestamps → graph "flapping" when a load balancer alternates between them |
| **HA pair + Thanos Querier / Mimir** | Same, plus a deduplicating query layer using an `external_labels` replica label | Correct dedup, global view, object-storage retention. Operational cost of a second system |
| **Functional sharding** | Split by team/region/job via `relabel_configs` `hashmod`, federate the aggregates upward | Scales horizontally; loses cross-shard queries unless federated |
| **Agent mode** | `prometheus --agent` — scrape + `remote_write` only, no local TSDB, no querying, no rules | Cheap edge collector; you *cannot* query it or run alerting rules locally |

Both members of an HA pair send alerts to **both** Alertmanagers; Alertmanager's gossip mesh deduplicates identical alerts so the on-call is paged once.

---

## 3. The data model and exposition format

### 3.1 Series identity

A **time series** is uniquely identified by the full set of its label pairs, including the special label `__name__` which holds the metric name. These two are the same series:

```promql
http_requests_total{method="GET"}
{__name__="http_requests_total", method="GET"}
```

A **sample** is a `(float64 value, int64 millisecond timestamp)` pair. That is the entire data model. There are no strings, no booleans, no events. (Prometheus 2.40+ additionally supports *native histograms*, a compound sample type — see §4.4.)

**Naming conventions** (exam-relevant, and enforced socially by every exporter):

- `<namespace>_<subsystem>_<name>_<unit>_<suffix>` — e.g. `node_filesystem_avail_bytes`, `http_request_duration_seconds`.
- **Base units only**: seconds, bytes, ratios (0–1), not milliseconds, megabytes, percent.
- Counters end in `_total`.
- The metric name identifies *what is measured*; labels identify *which instance of it*. Never `http_requests_get_total` / `http_requests_post_total` — use a `method` label.
- Valid characters historically `[a-zA-Z_:][a-zA-Z0-9_:]*` for names and `[a-zA-Z_][a-zA-Z0-9_]*` for labels. Colons are **reserved for recording rules** and must never be produced by an exporter. (Prometheus 3.0 adds opt-in UTF-8 names using the quoted syntax `{"my.metric", label="x"}`; the classic charset is what the exam expects.)
- Labels starting with `__` are **internal** and are dropped before ingestion.

### 3.2 Automatically generated series

Every scrape produces these, whatever the target says:

| Series | Meaning |
|---|---|
| `up{job,instance}` | `1` if the scrape succeeded, `0` if it failed (connection refused, timeout, bad content type). **The most important metric in the system.** |
| `scrape_duration_seconds` | Wall time of the scrape |
| `scrape_samples_scraped` | Samples exposed by the target |
| `scrape_samples_post_metric_relabeling` | Samples actually ingested after `metric_relabel_configs` |
| `scrape_series_added` | New series in this scrape — the churn detector |
| `scrape_body_size_bytes` | Size of the response body |

A missing target (SD no longer returns it) yields **no `up` series at all** — which is why `absent()` and `up == 0` are different alerts, and you usually need both.

### 3.3 Exposition format

Text over HTTP, one sample per line, `# HELP` and `# TYPE` metadata:

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

Two wire formats exist:

| Format | Content-Type | Notes |
|---|---|---|
| Prometheus text 0.0.4 | `text/plain; version=0.0.4; charset=utf-8` | Universal baseline |
| **OpenMetrics 1.0** | `application/openmetrics-text; version=1.0.0` | CNCF/IETF standardization of the above. Adds `# EOF` terminator, exemplars, `_created` series, native `Info`/`StateSet` types |

Content negotiation happens via the `Accept` header; `scrape_protocols` in the scrape config controls the preference order. Exemplars (trace IDs attached to a sample, used to jump from a latency spike to a trace in Tempo/Jaeger) require OpenMetrics **and** `--enable-feature=exemplar-storage`:

```
http_request_duration_seconds_bucket{le="0.25",handler="/api/v1/orders"} 1027 # {trace_id="4bf92f3577b34da6a3ce929d0e0e4736"} 0.242 1725360000.000
```

---

## 4. Metric types and their production trade-offs

The type lives only in `# TYPE` metadata — the TSDB stores every type as float samples. The type tells *you* which functions are legal.

### 4.1 Counter

Monotonically increasing, resets to 0 on process restart. **Never graph a counter raw.** Always `rate()`/`increase()`, which detect and correct resets.

```
# TYPE http_requests_total counter
http_requests_total{status="200"} 1029481
```

### 4.2 Gauge

Arbitrary up/down value: temperature, queue depth, memory in use, replica count. Legal functions: `avg_over_time`, `max_over_time`, `delta`, `deriv`, `predict_linear`. **Illegal**: `rate()` on a gauge silently produces garbage, because it will treat every decrease as a counter reset.

### 4.3 Classic Histogram vs Summary

Both measure distributions; they differ in *where the quantile is computed*, and this is the classic exam question.

A histogram exposes **cumulative buckets** (`_bucket{le="..."}`) plus `_sum` and `_count`:

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

A summary exposes **client-computed quantiles**:

```
# TYPE rpc_duration_seconds summary
rpc_duration_seconds{quantile="0.5"}  0.0324
rpc_duration_seconds{quantile="0.9"}  0.1032
rpc_duration_seconds{quantile="0.99"} 0.4291
rpc_duration_seconds_sum   17.83
rpc_duration_seconds_count 2693
```

| Criterion | Histogram | Summary |
|---|---|---|
| Quantile computed | **Server-side, at query time** (`histogram_quantile`) | **Client-side, at observation time** |
| Aggregatable across instances | **Yes** — sum the buckets, then compute the quantile | **No.** Averaging the p99 of 40 pods is mathematically meaningless |
| Quantile choice | Any quantile, retroactively | Fixed at instrumentation time; changing it requires a redeploy |
| Accuracy | Limited by bucket boundaries; interpolation error inside a bucket | Configurable φ-error, accurate per instance |
| Client CPU cost | Cheap (increment a counter) | Expensive (streaming quantile estimation, sliding windows) |
| Series count | `len(buckets) + 2` per label combination | `len(quantiles) + 2` |
| Query cost | Higher (many series to aggregate) | Trivial (read the value) |
| Time window | Query-time, arbitrary (`[5m]`, `[1h]`) | Fixed client-side sliding window (typically 10 min) |

**Default to histograms.** Use a summary only when you need an accurate per-instance quantile that you will never aggregate, or when the client cannot afford bucket cardinality.

**Bucket choice matters more than anything else.** `histogram_quantile` linearly interpolates within a bucket, so a p99 that falls inside `le="1"` when the previous bound is `le="0.5"` can be wrong by 500 ms. Buckets must straddle your SLO threshold:

```promql
# p99 latency across every replica of the api job, per handler
histogram_quantile(
  0.99,
  sum by (le, handler) (rate(http_request_duration_seconds_bucket{job="api"}[5m]))
)
```

Note the shape: `rate()` **first**, then `sum by (le, ...)`, then `histogram_quantile`. Any other order is wrong.

For SLOs, prefer the exact ratio over an interpolated quantile — it has no bucket error:

```promql
# fraction of requests served under 250 ms (an SLI, not an estimate)
  sum(rate(http_request_duration_seconds_bucket{job="api", le="0.25"}[5m]))
/ sum(rate(http_request_duration_seconds_count{job="api"}[5m]))
```

### 4.4 Native histograms (Prometheus 2.40+, stable-ish in 3.x)

Classic histograms force a trade between resolution and cardinality. Native histograms use **exponentially spaced buckets generated on demand** with a configurable schema (resolution factor), stored as a single compound sample. One series replaces 12–20, with far better resolution.

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

Querying is the same function with a simpler argument:

```promql
histogram_quantile(0.99, sum by (handler) (rate(http_request_duration_seconds[5m])))
```

Trade-off table:

| | Classic | Native |
|---|---|---|
| Series per histogram | 12–20 | 1 |
| Resolution | Fixed at instrumentation | Exponential, ~1–5% relative error |
| Remote write | Universally supported | Requires Remote Write 2.0 |
| Ecosystem support | Total | Growing; some tooling still lags |
| Recording rules / Grafana | Everywhere | Recent versions only |

---

## 5. Configuring the server: a complete `prometheus.yml`

This is a full, syntactically valid production configuration. Every block is annotated.

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

A `file_sd` target file:

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

### 5.1 Command line and unit file

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

Key flags to memorize:

| Flag | Effect |
|---|---|
| `--config.file` | Default `prometheus.yml` in cwd |
| `--storage.tsdb.path` | Default `data/` |
| `--storage.tsdb.retention.time` | Default `15d` |
| `--storage.tsdb.retention.size` | Byte-based retention; whichever triggers first wins |
| `--web.listen-address` | Default `0.0.0.0:9090` |
| `--web.enable-lifecycle` | Enables `POST /-/reload` and `/-/quit`. **Off by default** |
| `--web.enable-admin-api` | Enables `delete_series`, `snapshot`, `clean_tombstones`. **Off by default** |
| `--web.external-url` | Public URL used in alert `generatorURL` and links — set it behind a reverse proxy |
| `--web.route-prefix` | Path prefix when served under a subpath |
| `--query.max-samples` | Kills queries that would load more than N samples into memory (OOM guard) |
| `--enable-feature=` | Comma-separated experimental features |
| `--agent` | Agent mode: scrape + remote_write only |

**Reload without restarting** (a restart replays the WAL and can take minutes on a large TSDB):

```
$ sudo systemctl reload prometheus          # sends SIGHUP
$ curl -sf -X POST http://localhost:9090/-/reload && echo reloaded
reloaded
```

---

## 6. Service discovery and relabeling

### 6.1 The discovery mechanisms

| SD | Typical use | Key meta labels |
|---|---|---|
| `static_configs` | Fixed infra, the server itself | — |
| `file_sd_configs` | CMDB/Ansible-generated; **the universal integration point**. Reloaded via inotify | any labels you write |
| `kubernetes_sd_configs` | Kubernetes. Roles: `node`, `service`, `pod`, `endpoints`, `endpointslice`, `ingress` | `__meta_kubernetes_pod_*`, `__meta_kubernetes_namespace`, … |
| `consul_sd_configs` | Consul service catalog | `__meta_consul_service`, `__meta_consul_tags`, … |
| `dns_sd_configs` | SRV/A/AAAA records — works where nothing else does | `__meta_dns_name`, `__meta_dns_srv_record_target` |
| `ec2_sd_configs`, `azure_sd_configs`, `gce_sd_configs` | Cloud instance inventory | `__meta_ec2_tag_<name>`, `__meta_ec2_private_ip`, … |
| `http_sd_configs` | Any HTTP endpoint returning the SD JSON schema — write your own | whatever you return |
| `docker_sd_configs`, `dockerswarm_sd_configs` | Container hosts | `__meta_docker_container_label_*` |

Compare `file_sd` and `http_sd`, since both are "bring your own inventory":

| | `file_sd` | `http_sd` |
|---|---|---|
| Update latency | Instant (inotify) | `refresh_interval` (default 60s) |
| Failure mode | Stale file = stale targets, silent | HTTP error = SD keeps last good set, `prometheus_sd_http_failures_total` increments |
| Deployment | Requires filesystem access to the Prometheus host | Network only — works for a Prometheus you do not own |
| Debuggability | `cat` the file | `curl` the endpoint |

### 6.2 Relabeling — the single most important operational skill

Every target begins life as a set of **`__`-prefixed meta labels**. Relabeling is a small rewriting pipeline applied in order; whatever `__`-labels survive at the end are discarded, and `__address__` determines where the HTTP request goes.

**Two distinct stages:**

| Stage | Runs | Operates on | Purpose |
|---|---|---|---|
| `relabel_configs` | **before** the scrape | *target* labels | select which targets to scrape, rewrite address/scheme/path, build `job`/`instance` |
| `metric_relabel_configs` | **after** the scrape, before ingestion | *every sample's* labels | drop expensive metrics, rename, strip high-cardinality labels |

A third stage, `write_relabel_configs`, filters what goes to `remote_write`. A fourth, `alert_relabel_configs`, rewrites alert labels on the way to Alertmanager.

**Actions:**

| Action | Behaviour |
|---|---|
| `replace` (default) | If `regex` matches the concatenated `source_labels`, set `target_label` to `replacement` (with `$1`, `$2` expansion) |
| `keep` | Discard the target/metric if the regex does **not** match |
| `drop` | Discard the target/metric if the regex **does** match |
| `keepequal` / `dropequal` | Keep/drop when `source_labels` concatenation equals `target_label` — no regex |
| `hashmod` | `target_label = hash(source_labels) % modulus` — the sharding primitive |
| `labelmap` | Copy every label whose **name** matches the regex to a new name from `replacement` |
| `labeldrop` / `labelkeep` | Remove/retain labels whose **name** matches the regex |
| `lowercase` / `uppercase` | Case-fold the concatenated source into `target_label` |

Defaults worth memorizing: `separator: ";"`, `regex: "(.*)"`, `replacement: "$1"`, `action: replace`. The regex is **fully anchored** — `regex: foo` means `^foo$`.

**Special target labels:**

| Label | Meaning |
|---|---|
| `__address__` | `host:port` actually connected to; becomes `instance` if `instance` is unset |
| `__scheme__` | `http` (default) or `https` |
| `__metrics_path__` | Default `/metrics` |
| `__param_<name>` | Adds `?<name>=<value>` to the scrape URL |
| `__scrape_interval__`, `__scrape_timeout__` | Per-target override |
| `__tmp_*` | Convention for scratch labels; never persisted anyway |

**Canonical Kubernetes annotation-driven discovery** — the pattern every platform team ships:

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

**Cardinality surgery with `metric_relabel_configs`** — the emergency brake when a team ships a `user_id` label at 03:00:

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

### 7.1 Expression types

| Type | Example | Notes |
|---|---|---|
| **Instant vector** | `node_load1` | One sample per series at the evaluation instant |
| **Range vector** | `node_load1[5m]` | A slice of samples per series. Cannot be graphed directly |
| **Scalar** | `42`, `time()` | A single number |
| **String** | `"foo"` | Legal only as a function argument |

The single most common beginner error: `node_cpu_seconds_total[5m]` in a graph panel. A range vector must be reduced by a function (`rate`, `avg_over_time`, `max_over_time`, …) before it can be plotted.

### 7.2 Selectors and matchers

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

Regexes are RE2, **fully anchored**, and never match a `\n`. An empty matcher `{job=""}` also matches series where the label is absent — this is how you find series *missing* a label.

`@` and negative `offset` (stable since 2.x) let you compare a series to itself in the past inside one expression:

```promql
# today's traffic vs the same moment last week, as a ratio
sum(rate(http_requests_total[5m])) / sum(rate(http_requests_total[5m] offset 1w))
```

### 7.3 `rate` vs `irate` vs `increase` vs `delta`

This table is worth memorizing verbatim.

| Function | Input | Computes | Use for |
|---|---|---|---|
| `rate(v[5m])` | counter | Per-second average over the whole window, extrapolated to the window edges, counter-reset corrected | **Default for counters.** Graphs, alerts, SLOs |
| `irate(v[5m])` | counter | Per-second rate from the **last two** samples only | Fast-moving, volatile signals on a high-resolution graph. **Never in alerts** — it is aliasing-prone and hides spikes when the step is large |
| `increase(v[1h])` | counter | Total increase over the window = `rate() × window_seconds`. Also extrapolated | "How many errors in the last hour" |
| `delta(v[1h])` | **gauge** | Difference between first and last, extrapolated, **no reset correction** | Gauge change: disk free delta, temperature drift |
| `idelta(v[5m])` | gauge | Difference of the last two samples | Rarely needed |
| `deriv(v[1h])` | gauge | Least-squares per-second derivative | Trend of a noisy gauge |
| `resets(v[1h])` | counter | Number of counter resets = process restarts | Crash-loop detection |
| `changes(v[1h])` | gauge | Number of times the value changed | Leader elections, config flaps |

**Extrapolation is why `increase()` returns non-integers.** `rate()` and `increase()` extrapolate to the exact window boundaries because samples rarely align with them. `increase(x[1h])` legitimately returns `3.0000000000000004` or `47.8`. Since Prometheus 2.x the extrapolation is clamped so it cannot exceed what is physically possible at the observed rate, but non-integers remain normal and correct.

**The 4× rule:** the range must contain at least **4 scrape intervals** for `rate()` to be resilient to a single missed scrape. With `scrape_interval: 15s`, use `[1m]` minimum; `[5m]` is the safe default. `rate()` over a range containing fewer than 2 samples returns **nothing** — the classic "my alert never fires" bug.

### 7.4 Aggregation operators

```promql
sum by (job, status) (rate(http_requests_total[5m]))
sum without (instance, pod) (rate(http_requests_total[5m]))
```

`by` keeps only the listed labels; `without` keeps everything except the listed ones. **Prefer `without`** in reusable rules: it survives the addition of a new label, whereas `by` silently discards it.

| Operator | Notes |
|---|---|
| `sum`, `min`, `max`, `avg`, `group`, `count` | Standard |
| `stddev`, `stdvar` | Population statistics |
| `count_values("version", build_info)` | Counts series per *value* — histogram of values |
| `topk(5, ...)` / `bottomk(5, ...)` | Return the N largest/smallest **series**, keeping all their labels |
| `quantile(0.9, ...)` | φ-quantile **over the series dimension** — not over time, not over buckets |
| `limitk(5, ...)` / `limit_ratio(0.1, ...)` | Sample a subset of series (2.50+) — for exploring huge result sets cheaply |

`avg()` of a rate across instances is almost always wrong in an alert: it hides one broken replica among nine healthy ones. Use `max()`, or aggregate the numerator and denominator separately.

### 7.5 Binary operators and vector matching

Arithmetic and comparison between two instant vectors match **series with identical label sets** by default.

```promql
# one-to-one: identical labels on both sides
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
```

When label sets differ, you must say how to match:

```promql
# ignore the labels that differ
rate(errors_total[5m]) / ignoring(status) rate(requests_total[5m])

# or list exactly the labels to join on
rate(errors_total[5m]) / on(job, instance) rate(requests_total[5m])
```

**Many-to-one joins** need `group_left` / `group_right`. The canonical case is enriching a metric with metadata from an `_info` series:

```promql
# attach the application version to every request rate.
# The "many" side is the left (many series per job/instance);
# group_left pulls the `version` label in from the "one" side.
  sum by (job, instance) (rate(http_requests_total[5m]))
* on (job, instance) group_left(version)
  app_build_info
```

`group_left(<labels>)` means: the left side is the "many" side, and copy `<labels>` from the right. `group_right` is the mirror image. Getting this backwards produces `Error executing query: found duplicate series for the match group ...` — one of the most common PromQL errors in production.

Comparison operators **filter** by default and can be made to return 0/1 with `bool`:

```promql
up == 0                      # returns only the down targets
up == bool 0                 # returns 1 for down, 0 for up, for every target
```

Set operators: `and`, `or`, `unless` (set difference). `unless` is how you write exceptions:

```promql
# fire for every instance with high load, except those in maintenance
(node_load5 > 20) unless on(instance) node_maintenance_mode == 1
```

### 7.6 `_over_time` functions and subqueries

Over a range vector: `avg_over_time`, `min_over_time`, `max_over_time`, `sum_over_time`, `count_over_time`, `quantile_over_time`, `stddev_over_time`, `last_over_time`, `present_over_time`, `absent_over_time`, `mad_over_time`.

A **subquery** turns an instant-vector expression into a range vector so you can apply these to a computed value:

```promql
# peak per-second request rate observed at any point in the last 24 hours,
# evaluated at 1-minute resolution
max_over_time(  sum(rate(http_requests_total[5m]))[24h:1m]  )
```

Syntax: `<instant_vector_expr>[<range>:<resolution>]`. Subqueries are **expensive** — the engine evaluates the inner expression once per resolution step (1440 times above). Anything you run repeatedly belongs in a recording rule.

### 7.7 Prediction, absence and staleness

```promql
# will / (root fs) fill up within the next 4 hours, judged on the last 6h trend?
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 4*3600) < 0

# fires when a series that should exist has vanished entirely
absent(up{job="payments"})

# fires when the series existed but had no samples in the last hour
absent_over_time(up{job="payments"}[1h])
```

**Staleness.** A series with no sample in the last **5 minutes** (`--query.lookback-delta`) returns nothing at query time. When a target disappears from SD, Prometheus writes an explicit **stale marker**, so the series stops resolving *immediately* rather than lingering for 5 minutes. This is why `up == 0` (target is there and failing) and `absent(up{...})` (target no longer exists) are genuinely different alerts and you need both.

### 7.8 A PromQL cheat sheet for real production questions

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

## 8. Recording rules and alerting rules

Both live in `rule_files`, in groups. **Rules within a group run sequentially, in file order; groups run in parallel.** Ordering matters: a rule that depends on another's output must come after it in the same group.

### 8.1 Recording rules

Purpose: precompute expensive expressions so dashboards and alerts read a single cheap series.

**Naming convention** — `level:metric:operations`, using the reserved colon:

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

Rules to follow:
- A recording rule **must not** change the meaning of the data. Do not `avg` a rate across instances in a recording rule and then alert on it.
- `histogram_quantile` belongs in the **query**, not the recording rule — record the bucket rates, compute the quantile at read time. Recording a quantile destroys aggregatability.
- Keep group evaluation under the interval. If `prometheus_rule_group_last_duration_seconds > prometheus_rule_group_interval_seconds`, your rules are falling behind and gaps appear in the recorded series.

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

**Semantics you must know:**

| Field | Meaning |
|---|---|
| `expr` | Evaluated every `interval`. Every series it returns becomes one alert instance |
| `for` | The alert stays **pending** until the expression has returned that series continuously for this long, then becomes **firing**. If the expression stops returning it, the timer resets to zero |
| `keep_firing_for` | Keeps the alert firing for this long *after* the expression stops matching — damps flapping (Prometheus 2.42+) |
| `labels` | **Part of the alert's identity.** Templated. Used for routing in Alertmanager |
| `annotations` | **Not** part of the identity. Templated. Human-facing text: `summary`, `description`, `runbook_url` |

Templating variables: `{{ $labels.<name> }}`, `{{ $value }}`, `{{ $externalLabels.<name> }}`. Formatting functions: `humanize`, `humanize1024`, `humanizeDuration`, `humanizePercentage`, `printf "%.2f"`.

**Alert state is exposed as metrics**, which lets you alert on your alerts:

```promql
ALERTS{alertname="TargetDown", alertstate="firing"}
ALERTS_FOR_STATE            # unix timestamp when the alert entered pending
```

`ALERTS_FOR_STATE` is what Prometheus persists so that a restart does not reset every `for:` timer.

### 8.3 Unit-testing rules

`promtool test rules` runs rules against synthetic series. This is how you prove an alert fires *before* the incident.

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

A failing run is explicit about what differed:

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

The `values` mini-language: `1+0x9` = value 1, increment 0, repeated 9 more times (10 samples). `0+10x5` = 0,10,20,30,40,50. `_` = a gap (missing sample). `stale` = an explicit stale marker.

---

## 9. Alertmanager

### 9.1 The pipeline

An alert arriving at `/api/v2/alerts` passes through, in order:

```
receive → deduplicate (across HA senders) → group (by group_by)
        → inhibit (suppress by rule) → silence (suppress by matcher)
        → route to receiver → notify (with repeat_interval)
```

**Grouping** is the feature that makes alerting survivable. Without it, a rack failure sends 200 pages. With `group_by: [alertname, cluster]`, it sends one notification containing 200 alerts.

| Timer | Default | Meaning |
|---|---|---|
| `group_wait` | `30s` | After the **first** alert of a new group arrives, wait this long to collect siblings before the first notification. Keep it short (30s) for pages |
| `group_interval` | `5m` | Minimum time before sending an *updated* notification for a group that has gained or lost alerts |
| `repeat_interval` | `4h` | How long before re-notifying about an unchanged, still-firing group. Anything under 1h trains people to ignore alerts |

### 9.2 Complete `alertmanager.yml`

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

**Note on `matchers` vs `match`/`match_re`:** `match` and `match_re` are deprecated. The modern `matchers:` list uses PromQL-style syntax (`=`, `!=`, `=~`, `!~`) and is what current documentation and the exam's version window expect.

### 9.3 Notification templates

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

### 9.4 High availability

Alertmanager **does** cluster, via a gossip mesh (HashiCorp memberlist) on port `9094`. It shares silences, notification-log entries and the "who has already notified" state, so N replicas fed by N Prometheus servers page exactly once.

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

Verify the mesh formed:

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

**Anti-pattern:** putting Alertmanager replicas behind a load balancer and pointing Prometheus at the VIP. Prometheus must send to **every** replica — list them all in `alerting.alertmanagers`. The mesh, not the LB, does the deduplication.

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

## 10. Exporters and instrumentation

### 10.1 The exporter landscape

| Exporter | Port | Exposes | Notes |
|---|---|---|---|
| `node_exporter` | 9100 | Linux/BSD host metrics: CPU, memory, disk, filesystem, network, systemd, hwmon | The baseline. Run on every host |
| `windows_exporter` | 9182 | Windows equivalent | |
| `blackbox_exporter` | 9115 | Probes HTTP(S), TCP, ICMP, DNS, gRPC from outside | Multi-target pattern |
| `pushgateway` | 9091 | Buffer for batch jobs | Use sparingly |
| `cAdvisor` | 8080 | Per-container CPU/memory/network | Built into the kubelet |
| `kube-state-metrics` | 8080/8081 | Kubernetes **object state** (replicas desired vs ready, pod phase, job status) | Not resource usage — that is cAdvisor |
| `mysqld_exporter` | 9104 | MySQL/MariaDB | |
| `postgres_exporter` | 9187 | PostgreSQL | |
| `redis_exporter` | 9121 | Redis | |
| `snmp_exporter` | 9116 | Network gear via SNMP | Multi-target pattern like blackbox |
| `process-exporter` | 9256 | Per-process-group metrics | |
| `statsd_exporter` | 9102 (scrape) / 9125 (statsd) | Bridge from StatsD push to Prometheus pull | Migration tool |

### 10.2 `node_exporter` in production

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

**The textfile collector** is how you expose anything that has no exporter — cron results, hardware state, package counts. Write `*.prom` files atomically (write to a temp file, then `mv` — a partially written file yields a parse error and a failed scrape):

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

Then alert on staleness rather than on failure — this catches "the cron job never ran", which a failure metric cannot:

```promql
time() - backup_last_success_timestamp_seconds > 26 * 3600
```

`node_textfile_scrape_error` is set to `1` when a `.prom` file fails to parse; always alert on it.

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

The exporter is stateless: it probes on demand, when Prometheus passes `?target=`. Test it directly:

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

Add `&debug=true` to get a full trace of the probe (DNS resolution, TLS handshake, redirects) — the fastest way to diagnose a failing synthetic check.

The two alerts that pay for themselves:

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

### 10.4 Pushgateway: what it is, and what it is not

Pushgateway is a **cache**, not a proxy. It holds pushed metrics forever until they are explicitly deleted, and Prometheus scrapes *it*.

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

| Property | Consequence |
|---|---|
| Metrics persist across the pushing job's death | That is the point — you can see the last run's result |
| Metrics persist across *your* forgetting to delete them | A decommissioned job's metrics alert forever. **You must DELETE.** |
| Pushgateway itself becomes a single point of failure | And its own `up` is the only liveness signal |
| Timestamps are the **scrape** time, not the push time | Which is why the idiom is a `*_last_success_timestamp_seconds` gauge, never a "time since" gauge |
| `honor_labels: true` is mandatory in the scrape config | Otherwise the pushed `job`/`instance` are overwritten by the gateway's own |

**Use it only for service-level batch jobs.** Do not use it to make pull "work" for services behind NAT — use a Prometheus agent there instead.

### 10.5 Direct instrumentation

Application code should expose metrics natively. Python (`prometheus_client`):

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

**The cardinality rule, stated precisely:** total series for a metric = the product of the number of distinct values of each of its labels. `handler` (50) × `method` (5) × `status` (8) = 2,000 series — fine. Add `user_id` (2,000,000) and you have 4 billion — the server dies. Labels must have **bounded, low-cardinality** value sets: never user IDs, request IDs, session IDs, email addresses, full URLs, timestamps, or error messages.

---

## 11. Kubernetes: the Prometheus Operator

On Kubernetes, hand-editing `prometheus.yml` is an anti-pattern — the Operator generates it from CRDs, so application teams declare their own scraping without touching the platform config.

| CRD | Purpose |
|---|---|
| `Prometheus` | The server itself: replicas, retention, storage, resource limits, which selectors to honour |
| `ServiceMonitor` | Scrape the endpoints behind a `Service` (the common case) |
| `PodMonitor` | Scrape pods directly, no Service required |
| `Probe` | Blackbox-style probing of static targets or Ingresses |
| `PrometheusRule` | Recording and alerting rules |
| `Alertmanager` / `AlertmanagerConfig` | The Alertmanager cluster, and per-namespace routing |
| `ScrapeConfig` (v1alpha1) | Raw scrape config for targets outside the cluster |

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

Note the RBAC the server needs — without it, `kubernetes_sd` silently returns zero targets:

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

Install with `kube-prometheus-stack`, which bundles Prometheus, Alertmanager, Grafana, node_exporter, kube-state-metrics and a curated rule set:

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

**The `serviceMonitorSelectorNilUsesHelmValues=false` flag is the #1 gotcha:** by default the chart makes Prometheus select only ServiceMonitors carrying the chart's release label, so your own ServiceMonitors are silently ignored.

---

## 12. Scaling beyond one server

| Approach | Mechanism | When to use | Trade-off |
|---|---|---|---|
| **Federation** | A "global" Prometheus scrapes `/federate?match[]=` on leaf servers, pulling only aggregated recording rules | Small hierarchies; cross-datacenter roll-ups | Pull-based and synchronous: a slow leaf slows the global. Never federate raw series — you will recreate the leaf's cardinality centrally |
| **Functional sharding** | `hashmod` relabeling splits targets across N servers; each is independent | Scale scraping linearly | Cross-shard queries require a query layer |
| **`remote_write` → Thanos Receive / Mimir / Cortex** | Prometheus pushes every sample to a horizontally scalable, object-storage-backed system | The default modern answer for long retention and global view | Another distributed system to run |
| **Thanos Sidecar** | Sidecar uploads TSDB blocks to object storage; Thanos Querier fans out over sidecars + store gateway | Long retention with minimal change to Prometheus | Query latency over object storage; needs downsampling (Compactor) |
| **Agent mode** | `--agent`: scrape + remote_write only, WAL-only, no query, no rules | Edge/CI/ephemeral clusters | Cannot query or alert locally |

Federation configuration, done correctly (aggregates only):

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

Grafana is the visualization layer; it holds no data of its own. Everything should be provisioned as code — a hand-clicked dashboard is an outage waiting to happen.

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

**`$__rate_interval` is the single most important Grafana/Prometheus detail.** Grafana computes it as `max(4 × scrape_interval, $__interval + scrape_interval)`. Always write `rate(x[$__rate_interval])` — never `rate(x[5m])` and never `rate(x[$__interval])`. `$__interval` alone shrinks when you zoom in and eventually contains fewer than 2 samples, at which point the graph silently goes blank. This is the cause of the classic "my dashboard is empty when I zoom in" bug, and `timeInterval` in the datasource is what makes the calculation correct.

---

## 14. Securing the stack

Prometheus, Alertmanager and the exporters ship **unauthenticated by default**. A `/metrics` endpoint leaks your entire topology; the admin API can delete data.

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

Then scrape configs pointing at TLS-protected targets need:

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
- Keep `--web.enable-admin-api` and `--web.enable-lifecycle` **off** unless a deployment pipeline needs them, and then restrict them at the reverse proxy.
- Bind exporters to a management interface or use a NetworkPolicy; `node_exporter` on `0.0.0.0:9100` on a public host is an information disclosure.
- Alertmanager silences are unauthenticated by default — anyone who can reach `:9093` can silence your pager. Put SSO in front of it.
- Never put secrets in labels. Every label value is world-readable to anyone who can query.

---

## 15. Verification and failure diagnosis

### 15.1 The pre-flight ladder — always in this order

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

A syntax error is explicit about file and line:

```
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
  FAILED: parsing YAML file /etc/prometheus/prometheus.yml: yaml: unmarshal errors:
  line 34: field scrape_intervals not found in type config.ScrapeConfig
```

Validate an exporter's output before wiring it up:

```
$ curl -s http://localhost:9100/metrics | promtool check metrics
node_scrape_collector_success non-histogram and non-summary metrics should not have "_sum" suffix
```

### 15.2 Runtime health and state

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

### 15.3 Target diagnosis

```
$ curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[]
           | select(.health!="up")
           | [.labels.job, .scrapeUrl, .health, .lastError] | @tsv'
node	http://web03.prod.internal:9100/metrics	down	Get "http://web03.prod.internal:9100/metrics": dial tcp 10.2.4.13:9100: connect: connection refused
api	https://api-7f9c.prod:8443/metrics	down	Get "https://api-7f9c.prod:8443/metrics": x509: certificate signed by unknown authority
kafka	http://kafka02.prod:9308/metrics	down	server returned HTTP status 500 Internal Server Error
```

**Why is a target missing entirely?** Check what SD returned *before* relabeling:

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

Here `__meta_kubernetes_pod_annotation_prometheus_io_scrape` is absent → the `keep` rule dropped the target. That is the answer, and no amount of restarting will change it.

**Dry-run relabeling offline** before shipping a config change:

```
$ promtool check service-discovery /etc/prometheus/prometheus.yml kubernetes-pods
```

Also available in the web UI at **Status → Service Discovery**, which shows discovered labels next to the post-relabeling result side by side — the fastest way to debug a relabel chain.

### 15.4 Querying from the CLI

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

### 15.5 Cardinality forensics — the #1 production failure

The Prometheus process OOMs, or ingestion stops. The cause is almost always a new unbounded label. **Do not run `count by (__name__)({__name__=~".+"})` on a dying server** — it will finish the job. Use the offline analyzer:

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

`request_id` at 884,301 distinct values is the culprit. Immediate mitigation, no application deploy needed:

```yaml
    metric_relabel_configs:
      - regex: 'request_id'
        action: labeldrop
```

```
$ sudo systemctl reload prometheus
```

Then reclaim the disk (requires `--web.enable-admin-api`):

```
$ curl -s -X POST -g \
  'http://localhost:9090/api/v1/admin/tsdb/delete_series?match[]={__name__=~"http_.*",request_id!=""}'
$ curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/clean_tombstones
```

Prevention is `sample_limit` and `label_limit` in the scrape config: the scrape fails loudly (`sample limit exceeded`) instead of the server dying quietly.

### 15.6 Failure catalogue

| Symptom | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| `up == 0`, `connect: connection refused` | Exporter down, wrong port, firewall | `curl http://target:9100/metrics` from the Prometheus host; `ss -lntp \| grep 9100` on the target | Start the exporter / open the port |
| `up == 0`, `context deadline exceeded` | Target slower than `scrape_timeout`; too many series | `time curl -s target/metrics \| wc -l` | Raise `scrape_timeout` (≤ `scrape_interval`), or reduce exposed metrics |
| `up == 0`, `x509: certificate signed by unknown authority` | Missing `ca_file` in `tls_config` | `openssl s_client -connect target:8443 -showcerts` | Add the CA; never `insecure_skip_verify: true` in production |
| Target absent from `/targets` entirely | Relabeling dropped it, or SD returned nothing | `?state=dropped`; Status → Service Discovery | Fix the `keep`/`drop` regex or the SD credentials/RBAC |
| `sample limit exceeded` in `lastError` | Target exposes more series than `sample_limit` | `curl target/metrics \| wc -l` | `metric_relabel_configs` drop, or raise the limit deliberately |
| Query returns empty, no error | Range too short for `rate()`; series stale >5 m; typo in a label value | Strip the query back to the bare selector and add back one matcher at a time | Widen the range to ≥4× scrape interval; check `promtool query labels` |
| `found duplicate series for the match group` | Many-to-many vector match | Run each side alone and compare label sets | Add `on()`/`ignoring()` and `group_left`/`group_right` |
| Graph empty when zoomed in, fine when zoomed out | `rate(x[$__interval])` in Grafana | Inspect the panel query | Use `$__rate_interval` and set `timeInterval` on the datasource |
| Alert visible in Prometheus, never delivered | Alertmanager unreachable, route mismatch, active silence, inhibition | `prometheus_notifications_errors_total`; `amtool config routes test ...`; `amtool silence query` | Fix routing / expire the silence / correct the inhibit rule |
| Alert pending forever | Expression flaps within the `for:` window, resetting the timer | Graph the expression over the window | Shorten `for:`, smooth with a longer `rate()` range, or add `keep_firing_for` |
| Duplicate pages from an HA pair | `replica` label not stripped; Alertmanagers not clustered | `curl :9093/api/v2/status \| jq .cluster` | Add the `labeldrop` on `replica`; fix `--cluster.peer` |
| `out of order sample` in the log | Two sources writing the same series; clock skew; `honor_timestamps` | `journalctl -u prometheus \| grep 'out of order'`; `chronyc tracking` | De-duplicate the target; fix NTP; set `out_of_order_time_window` |
| `duplicate sample for timestamp` | The target exposes the same series twice in one scrape | `curl target/metrics \| sort \| uniq -d` | Fix the exporter/instrumentation |
| Restart takes many minutes | WAL replay | `journalctl -fu prometheus` shows `replaying WAL` with a progress percentage | Normal. Reduce head size (fewer series) or use `reload` instead of `restart` |
| Disk full despite retention | Retention deletes whole blocks only; compaction needs headroom | `du -sh /var/lib/prometheus/*`; check `meta.json` time ranges | Set `--storage.tsdb.retention.size` to ~80% of the volume |
| `remote_write` falling behind | Endpoint slow, shards capped, network | `prometheus_remote_storage_shards` vs `..._shards_max`; `..._samples_failed_total` | Raise `max_shards`, drop series with `write_relabel_configs`, fix the receiver |
| Rules evaluating late / gaps in recorded series | Group takes longer than its interval | `prometheus_rule_group_last_duration_seconds > prometheus_rule_group_interval_seconds` | Split into more groups (they run in parallel), simplify expressions, raise `interval` |

### 15.7 Live profiling

When the server is unhealthy and nothing above explains it:

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

That last file is the smoking gun after an OOM: it names the query that killed the server.

### 15.8 End-to-end smoke test

The pipeline is only proven when an alert reaches a human. Fire a synthetic alert straight into Alertmanager:

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

And keep a permanent **Watchdog** alert firing at all times, routed to an external dead-man's-switch service. It is the only alert that detects "the entire monitoring stack is down" — because a broken Prometheus cannot alert about itself.

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

## 16. Exam quick reference

**Default ports:** Prometheus `9090` · Alertmanager `9093` (cluster gossip `9094`) · Pushgateway `9091` · node_exporter `9100` · blackbox_exporter `9115` · snmp_exporter `9116` · Grafana `3000` · cAdvisor `8080`

**Key HTTP endpoints:** `/metrics` · `/-/healthy` · `/-/ready` · `/-/reload` (POST, needs `--web.enable-lifecycle`) · `/api/v1/query` · `/api/v1/query_range` · `/api/v1/targets` · `/api/v1/rules` · `/api/v1/alerts` · `/api/v1/status/tsdb` · `/federate` · `/debug/pprof/`

**Files:** `prometheus.yml` · `alertmanager.yml` · `blackbox.yml` · rule files under `rule_files:` · TSDB at `--storage.tsdb.path` (default `data/`)

**Defaults:** `scrape_interval` 15 s (config default 1 m if unset) · `evaluation_interval` 1 m · retention 15 d · lookback-delta 5 m · `group_wait` 30 s · `group_interval` 5 m · `repeat_interval` 4 h · `resolve_timeout` 5 m

**Reflexes:**
- `rate()` for counters, never for gauges; range ≥ 4 × scrape interval.
- `rate()` before `sum`, always.
- `histogram_quantile(φ, sum by (le) (rate(..._bucket[5m])))` — that exact shape.
- Histograms aggregate; summaries do not.
- `relabel_configs` selects targets; `metric_relabel_configs` filters samples.
- `honor_labels: true` for Pushgateway and federation.
- Prometheus decides *firing*; Alertmanager decides *notification*.
- Labels must be bounded in cardinality. Always.

---

## Referencias

**Official exam objectives**
- LPI — Exam 701 Objectives (DevOps Tools Engineer, 701-100 v2.0): https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI — DevOps Tools Engineer certification overview: https://www.lpi.org/our-certifications/devops-overview/

**Prometheus — concepts and architecture**
- Overview and architecture: https://prometheus.io/docs/introduction/overview/
- Data model: https://prometheus.io/docs/concepts/data_model/
- Metric types: https://prometheus.io/docs/concepts/metric_types/
- Jobs and instances: https://prometheus.io/docs/concepts/jobs_instances/
- Comparison to alternatives: https://prometheus.io/docs/introduction/comparison/
- Storage and the TSDB: https://prometheus.io/docs/prometheus/latest/storage/
- Feature flags: https://prometheus.io/docs/prometheus/latest/feature_flags/
- Native histograms: https://prometheus.io/docs/specs/native_histograms/

**Configuration**
- Full configuration reference: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Recording rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Unit testing rules: https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- HTTPS and authentication: https://prometheus.io/docs/prometheus/latest/configuration/https/
- Command-line flags: https://prometheus.io/docs/prometheus/latest/command-line/prometheus/
- `promtool` reference: https://prometheus.io/docs/prometheus/latest/command-line/promtool/

**Querying**
- PromQL basics: https://prometheus.io/docs/prometheus/latest/querying/basics/
- Operators and vector matching: https://prometheus.io/docs/prometheus/latest/querying/operators/
- Functions: https://prometheus.io/docs/prometheus/latest/querying/functions/
- Query examples: https://prometheus.io/docs/prometheus/latest/querying/examples/
- HTTP API: https://prometheus.io/docs/prometheus/latest/querying/api/

**Alerting**
- Alertmanager: https://prometheus.io/docs/alerting/latest/alertmanager/
- Alertmanager configuration: https://prometheus.io/docs/alerting/latest/configuration/
- Notification template reference: https://prometheus.io/docs/alerting/latest/notifications/
- Notification examples: https://prometheus.io/docs/alerting/latest/notification_examples/
- Alerting overview: https://prometheus.io/docs/alerting/latest/overview/

**Instrumentation and exporters**
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

**Scaling and federation**
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

**Visualization**
- Grafana Prometheus data source: https://grafana.com/docs/grafana/latest/datasources/prometheus/
- Grafana provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/
- Grafana query editor and `$__rate_interval`: https://grafana.com/docs/grafana/latest/datasources/prometheus/query-editor/

**Standards and SRE practice**
- OpenMetrics: https://openmetrics.io/
- Google SRE Workbook — Alerting on SLOs: https://sre.google/workbook/alerting-on-slos/
- Google SRE Book — Monitoring Distributed Systems: https://sre.google/sre-book/monitoring-distributed-systems/