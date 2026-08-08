# PCA 2.2 — Configuration and Scraping

> **Domain 2 · Prometheus Fundamentals** — Exam weight: 4
> Profile: production-grade SRE / Platform Architect depth. All manifests are syntactically complete and validated against Prometheus 2.5x semantics.

---

## 1. Motivation and the production architectural problem

Prometheus is a **pull-based** monitoring system. Nothing pushes metrics into it: the server owns the schedule, the target list, and the identity (labels) of every time series it stores. That single design decision is what makes `scrape_configs` the most operationally consequential part of `prometheus.yml` — it is simultaneously the **service discovery contract**, the **label schema authority**, and the **cardinality control plane**.

The production problem it solves:

- **In a static datacenter**, you could hardcode a list of `host:port` endpoints. Fine for 10 nodes.
- **In a Kubernetes cluster**, pods are ephemeral. IPs change on every rollout, replica counts autoscale, and a Deployment's endpoints are recreated dozens of times a day. A hardcoded target list is stale within minutes.

Prometheus resolves this with **service discovery (SD)** feeding a **relabeling pipeline**. SD answers *"what exists right now?"*; relabeling answers *"which of those do I scrape, on what path/port/scheme, and under what label identity?"*. Getting the second question wrong is the root cause of the two most expensive Prometheus incidents:

| Failure mode | Root cause in 2.2 territory | Blast radius |
|---|---|---|
| **Cardinality explosion** | A label from SD metadata (e.g. `pod_name`, `container_id`) becomes a time-series label; every pod restart mints a new series | TSDB memory OOM, WAL replay hours, query timeouts |
| **Silent scrape gaps** | Relabel `keep`/`drop` regex is too broad/narrow; targets never enter the scrape pool | Blind spots — alerts that can never fire |
| **Target churn / label instability** | `instance` label derives from an ephemeral IP instead of a stable identity | Every deploy resets counters; `rate()` produces spikes |

**The architectural insight the exam tests:** the label set attached to a series is decided *before* the scrape (via `relabel_configs`), and the samples themselves can be filtered/mutated *after* the scrape (via `metric_relabel_configs`). These are two distinct pipeline stages with different inputs, and confusing them is the classic mistake.

```
┌────────────┐   __meta_* labels    ┌──────────────────┐   target labels   ┌────────┐
│  Service   │ ───────────────────► │  relabel_configs │ ────────────────► │ SCRAPE │
│ Discovery  │  __address__, etc.   │  (target phase)  │  __address__→:port│  HTTP  │
└────────────┘                      └──────────────────┘                   └───┬────┘
                                                                               │ raw samples
                                                                               ▼
                                          stored series ◄───┬───────────────────────────┐
                                                            │  metric_relabel_configs    │
                                                            │  (sample phase, per-metric)│
                                                            └────────────────────────────┘
```

---

## 2. The `prometheus.yml` top-level structure

Everything in 2.2 lives inside one file (plus optional included files). The top-level keys, in the order they matter:

| Key | Purpose | Reloadable? |
|---|---|---|
| `global` | Defaults inherited by every scrape job; `external_labels` stamped on federation/remote-write/alerts | Yes (SIGHUP / `/-/reload`) |
| `runtime` | GC percent, mutex/block profile rates | Yes |
| `scrape_configs` | The scrape jobs (the heart of 2.2) | Yes |
| `scrape_config_files` | Glob of files with additional `scrape_configs` (modularization) | Yes |
| `rule_files` | Recording/alerting rule globs | Yes |
| `alerting` | Alertmanager discovery + relabeling | Yes |
| `remote_write` / `remote_read` | Long-term storage integration | Partially |
| `storage` | TSDB / exemplar / OOO window knobs | Some fields |
| `tracing` | OTLP tracing of the Prometheus server itself | Yes |

### `global` block — the defaults that cascade

```yaml
global:
  scrape_interval:     15s   # how often to scrape each target (default 1m)
  scrape_timeout:      10s   # must be <= scrape_interval (default 10s)
  evaluation_interval: 15s   # how often rules are evaluated (default 1m)

  # scrape_protocols negotiates the exposition format via Accept header.
  # Order = preference. PrometheusProto enables native histograms + created timestamps.
  scrape_protocols:
    - OpenMetricsText1.0.0
    - OpenMetricsText0.0.1
    - PrometheusText0.0.4

  # external_labels are NOT applied to locally-stored series. They are stamped
  # only on data LEAVING this server: remote_write, federation, and alerts.
  # This is how you disambiguate replicas in HA / global views.
  external_labels:
    cluster: prod-eu-west-1
    replica: prometheus-0

  # Global cardinality guardrails (0 = unlimited). Overridable per job.
  sample_limit: 0
  label_limit: 0
  label_name_length_limit: 0
  label_value_length_limit: 0
  target_limit: 0
  body_size_limit: 0
```

> **Exam trap:** `external_labels` do **not** appear on series stored in the local TSDB. If you `sum by (cluster) (...)` locally you get nothing — those labels only exist on the wire out.

---

## 3. Anatomy of a `scrape_config`

A single job, exhaustively annotated. This is the reference object for the whole topic.

```yaml
scrape_configs:
  - job_name: node          # REQUIRED. Becomes the `job` target label.

    # --- Timing (override global) ---
    scrape_interval: 15s
    scrape_timeout:  10s

    # --- Endpoint shape ---
    metrics_path: /metrics  # default; becomes __metrics_path__
    scheme: http            # http | https; becomes __scheme__
    params:                 # URL query params appended to every scrape
      collect[]: [cpu, meminfo]
    follow_redirects: true
    enable_http2: true

    # --- Label semantics ---
    honor_labels: false       # see §5
    honor_timestamps: true    # respect timestamps in exposition (federation!)
    track_timestamps_staleness: false

    # --- Per-job cardinality limits (override global) ---
    sample_limit: 5000        # drop the WHOLE scrape if it exposes > 5000 samples
    label_limit: 30
    label_name_length_limit: 200
    label_value_length_limit: 200
    target_limit: 100         # cap targets after relabeling

    # --- Authentication (mutually exclusive: basic_auth | authorization | oauth2) ---
    # basic_auth:
    #   username: prometheus
    #   password_file: /etc/prometheus/secrets/node-pw
    # authorization:
    #   type: Bearer
    #   credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    tls_config:
      ca_file:   /etc/prometheus/certs/ca.crt
      cert_file: /etc/prometheus/certs/client.crt
      key_file:  /etc/prometheus/certs/client.key
      insecure_skip_verify: false
      server_name: node-exporter.monitoring.svc

    # --- Service discovery (choose one or more) ---
    static_configs:
      - targets:
          - '10.0.1.10:9100'
          - '10.0.1.11:9100'
        labels:
          rack: a12

    # --- Relabeling (target phase — decides identity & whether to scrape) ---
    relabel_configs:
      - source_labels: [__address__]
        regex: '(.*):.*'
        target_label: instance
        replacement: '$1'

    # --- Metric relabeling (sample phase — filters/mutates ingested series) ---
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'go_gc_duration_seconds.*'
        action: drop
```

### Timing constraint you must be able to state

`scrape_timeout <= scrape_interval`. Prometheus **refuses to start** if a job violates it. And the effective series resolution is bounded by `scrape_interval`: a 60s interval with rules evaluated every 15s means three of four evaluations see the same sample.

---

## 4. Service discovery mechanisms — comparative

SD populates `__meta_*` labels *and* the mandatory `__address__`. Relabeling then shapes them.

| SD mechanism | Config key | Meta labels source | Reload trigger | Typical use |
|---|---|---|---|---|
| Static | `static_configs` | none (only your `labels:`) | on config reload | fixed infra, exporters on known hosts |
| File | `file_sd_configs` | `__meta_filepath` | file mtime (auto, no reload) | glue from CMDBs / scripts |
| Kubernetes | `kubernetes_sd_configs` | `__meta_kubernetes_*` (rich) | API watch (live) | pods, endpoints, nodes, services, ingress |
| Consul | `consul_sd_configs` | `__meta_consul_*` | Consul blocking queries | service mesh / VM fleets |
| DNS | `dns_sd_configs` | `__meta_dns_name` | periodic (`refresh_interval`) | headless services, SRV records |
| EC2/GCE/Azure | `*_sd_configs` | cloud instance tags | periodic API poll | cloud VM fleets |

### Kubernetes SD `role` values (high-frequency exam material)

| `role` | Targets discovered | Address default | Common pairing |
|---|---|---|---|
| `node` | Each cluster node (Kubelet) | node's `InternalIP:10250` | cAdvisor, node metrics |
| `pod` | Every pod + declared container port | pod IP + port | `prometheus.io/scrape` annotations |
| `endpoints` | Addresses behind a Service | endpoint IP + port | app services with a Service |
| `endpointslice` | Same via EndpointSlice API | endpoint IP + port | scale-friendly replacement for endpoints |
| `service` | Service clusterIP (blackbox probing) | service DNS + port | availability probing |
| `ingress` | Ingress paths | ingress host/path | blackbox probing of routes |

### Complete Kubernetes pod-discovery job (the canonical annotation pattern)

```yaml
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # 1) Scrape only pods that opted in via annotation prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"

      # 2) Override the metrics path if prometheus.io/path is set
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)

      # 3) Rewrite __address__ to use the annotated port (IP:port assembly)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: '([^:]+)(?::\d+)?;(\d+)'
        replacement: '$1:$2'
        target_label: __address__

      # 4) Promote all pod labels into series labels (label_XXX)
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)

      # 5) Stable identity labels — NOT the ephemeral pod IP
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod

      # 6) Drop pods that are not Running (avoids scraping Pending/Terminating)
      - source_labels: [__meta_kubernetes_pod_phase]
        regex: (Failed|Succeeded)
        action: drop
```

---

## 5. Relabeling — the pipeline that decides everything

Relabeling is a small transformation engine applied to a label set. Two invocation points:

- **`relabel_configs`** — runs on **target** label sets (the `__meta_*` + `__address__` bag). Output determines the target's identity and whether it is scraped at all. Labels starting with `__` are **dropped after this phase** (except they drive the scrape).
- **`metric_relabel_configs`** — runs on **each ingested sample's** label set, *after* the scrape. `__name__` is available (the metric name). Cannot bring a dropped target back; only filters/edits stored series.

### The rule fields

| Field | Default | Meaning |
|---|---|---|
| `source_labels` | `[]` | Labels concatenated (with `separator`) to form the match input |
| `separator` | `;` | Joins multiple source labels |
| `regex` | `(.*)` | RE2 regex, **fully anchored** (implicit `^...$`) |
| `target_label` | — | Destination label for `replace`/`hashmod` |
| `replacement` | `$1` | Value written; supports `$1`,`$2` or `${name}` captures |
| `modulus` | — | For `hashmod` |
| `action` | `replace` | See table below |

### Actions

| Action | Effect |
|---|---|
| `replace` | If `regex` matches the joined `source_labels`, write `replacement` (with captures) into `target_label`. No match ⇒ rule is a no-op. |
| `keep` | Keep target/series only if `regex` matches; otherwise drop it |
| `drop` | Drop target/series if `regex` matches |
| `keepequal` | Keep if `target_label` value equals the joined source labels |
| `dropequal` | Drop if `target_label` value equals the joined source labels |
| `hashmod` | `target_label = hash(source_labels) % modulus` — used for **horizontal sharding** |
| `labelmap` | Copy labels whose *name* matches `regex` to new names via `replacement` |
| `labeldrop` | Remove labels whose name matches `regex` |
| `labelkeep` | Remove all labels whose name does **not** match `regex` |
| `lowercase` / `uppercase` | Case-fold the joined source labels into `target_label` |

### Sharding pattern (`hashmod`) — horizontal scaling of a single scrape workload

Run N Prometheus replicas, each scraping ~1/N of targets:

```yaml
    relabel_configs:
      - source_labels: [__address__]
        modulus: 4                 # total shards
        target_label: __tmp_shard
        action: hashmod
      - source_labels: [__tmp_shard]
        regex: ^1$                 # this replica is shard 1 (0..3)
        action: keep
```

### Meta labels: reserved namespace and lifecycle

- `__address__` — **mandatory**; `host:port` that gets scraped.
- `__scheme__`, `__metrics_path__`, `__param_<name>` — configure the HTTP request.
- `__meta_*` — SD-provided metadata (read-only inputs).
- `__tmp_*` — convention for scratch labels you create and discard.
- After `relabel_configs`, every `__`-prefixed label is stripped; only "real" labels survive as the target's identity. If `instance` was never set, Prometheus defaults it to `__address__`.

---

## 6. Trade-off tables the exam rewards

### `relabel_configs` vs `metric_relabel_configs`

| Dimension | `relabel_configs` (target) | `metric_relabel_configs` (sample) |
|---|---|---|
| Runs | Before scrape | After scrape, before storage |
| Input | Target label set (`__meta_*`, `__address__`) | Per-sample labels incl. `__name__` |
| Can stop a scrape? | Yes (`keep`/`drop` on target) | No — scrape already happened |
| Saves scrape bandwidth? | Yes (target never contacted) | No (data fetched then discarded) |
| Reduces stored cardinality? | Yes (fewer targets) | Yes (fewer/edited series) |
| Typical use | Choose targets, set `instance`/`job`, rewrite port/path | Drop noisy metrics, strip high-cardinality labels |

### `honor_labels` behavior

| `honor_labels` | Conflict resolution when target exposes a label Prometheus also sets (e.g. `job`, `instance`) |
|---|---|
| `false` (default) | Prometheus's value wins; the exposed conflicting label is renamed to `exported_<label>` |
| `true` | The **target's** exposed value wins; Prometheus does not overwrite |

> Use `honor_labels: true` for **federation** and **Pushgateway** scrapes, where the exposed `job`/`instance` are the real identities you must preserve.

### SD choice for Kubernetes workloads

| Need | Recommended role | Why |
|---|---|---|
| Per-replica app metrics | `pod` | One target per pod; survives Service churn |
| Metrics behind a Service, dedup by endpoint | `endpointslice` | Scales better than `endpoints` at high endpoint counts |
| Kubelet / cAdvisor | `node` | Node-level `:10250` targets |
| Black-box availability of a route | `ingress` / `service` | Probe from outside via blackbox_exporter |

---

## 7. Full production-grade `prometheus.yml`

A complete file combining static exporters, Kubernetes SD, federation, remote-write, and alerting — copy-paste runnable.

```yaml
global:
  scrape_interval:     15s
  scrape_timeout:      10s
  evaluation_interval: 30s
  scrape_protocols:
    - OpenMetricsText1.0.0
    - PrometheusText0.0.4
  external_labels:
    cluster: prod-eu-west-1
    replica: $(POD_NAME)      # substituted at render time by your templating

runtime:
  gogc: 50

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_config_files:
  - /etc/prometheus/scrape.d/*.yml

alerting:
  alertmanagers:
    - kubernetes_sd_configs:
        - role: endpoints
      relabel_configs:
        - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
          regex: monitoring;alertmanager;web
          action: keep

remote_write:
  - url: https://thanos-receive.monitoring.svc:19291/api/v1/receive
    name: thanos
    remote_timeout: 30s
    queue_config:
      capacity: 10000
      max_shards: 50
      min_shards: 1
      max_samples_per_send: 2000
      batch_send_deadline: 5s
    write_relabel_configs:
      # Never ship debug/temp series to long-term storage
      - source_labels: [__name__]
        regex: '(go_|process_|prometheus_tsdb_).*'
        action: drop
    tls_config:
      ca_file: /etc/prometheus/certs/ca.crt

scrape_configs:
  # --- 1) Prometheus scraping itself ---
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  # --- 2) Node exporters via static list ---
  - job_name: node
    static_configs:
      - targets: ['10.0.1.10:9100', '10.0.1.11:9100']
        labels:
          role: worker
    relabel_configs:
      - source_labels: [__address__]
        regex: '([^:]+):.*'
        target_label: instance
        replacement: '$1'

  # --- 3) Kubernetes pods (opt-in annotations) ---
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port, __meta_kubernetes_pod_ip]
        regex: '(\d+);(.+)'
        replacement: '$2:$1'
        target_label: __address__
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
    metric_relabel_configs:
      # Cardinality guard: drop the histogram bucket series of a chatty client lib
      - source_labels: [__name__]
        regex: 'rpc_client_.*_bucket'
        action: drop

  # --- 4) Federation from a lower-tier Prometheus (honor_labels!) ---
  - job_name: federate
    honor_labels: true
    metrics_path: /federate
    params:
      'match[]':
        - '{job="node"}'
        - '{__name__=~"job:.*"}'
    static_configs:
      - targets: ['prometheus-team-a.monitoring.svc:9090']

  # --- 5) Blackbox probing of external URLs via blackbox_exporter ---
  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - https://example.com
          - https://api.internal.svc/healthz
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter.monitoring.svc:9115
```

> **Blackbox pattern to memorize:** the *probe URL* is passed as `__param_target`, `instance` is set from it, and `__address__` is rewritten to the **exporter** — Prometheus scrapes the exporter, which probes the real target on its behalf.

---

## 8. CLI, validation, and reloading

### Validate before you ship — `promtool`

```console
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
 SUCCESS: 1 rule files found
 SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

Checking /etc/prometheus/rules/node.yml
 SUCCESS: 12 rules found
```

A malformed timeout constraint fails loudly:

```console
$ promtool check config prometheus.yml
Checking prometheus.yml
  FAILED: parsing YAML file prometheus.yml: scrape timeout greater than scrape interval for scrape config with job name "node"
```

### Dry-run relabeling logic offline

```console
$ promtool check config --lint-fatal prometheus.yml
$ promtool test rules tests/node_rules_test.yml
Unit Testing:  tests/node_rules_test.yml
  SUCCESS
```

### Hot-reload without restart — two supported paths

Prometheus must be started with `--web.enable-lifecycle` for the HTTP path:

```console
$ curl -sX POST http://localhost:9090/-/reload
$ echo $?
0
```

Or via signal (always available, no flag needed):

```console
$ pkill -HUP prometheus
# or, when you know the PID:
$ kill -HUP "$(pgrep -x prometheus)"
```

Confirm the reload succeeded in the logs:

```console
$ journalctl -u prometheus --since "1 min ago" | grep -i reload
level=info ts=2026-08-08T10:14:22.881Z caller=main.go:1231 msg="Loading configuration file" filename=/etc/prometheus/prometheus.yml
level=info ts=2026-08-08T10:14:22.905Z caller=main.go:1268 msg="Completed loading of configuration file" filename=/etc/prometheus/prometheus.yml totalDuration=24.1ms
```

A failed reload keeps the **previous** config running (fail-safe):

```console
$ curl -sX POST http://localhost:9090/-/reload
failed to reload config: couldn't load configuration (--config.file="/etc/prometheus/prometheus.yml"): parsing YAML file ...: unknown field "scrape_intervall"
```

### Inspect what Prometheus actually loaded

The running config is served back (secrets redacted as `<secret>`):

```console
$ curl -s http://localhost:9090/api/v1/status/config | jq -r '.data.yaml' | head -20
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 30s
  ...
```

---

## 9. Verification and failure diagnosis

### Step 1 — Are the targets discovered and UP?

The active-targets API is your ground truth. It shows the **post-relabeling** labels, the discovered pre-relabel labels, health, and the last error.

```console
$ curl -s http://localhost:9090/api/v1/targets | \
    jq -r '.data.activeTargets[] | [.labels.job, .scrapeUrl, .health, .lastError] | @tsv'
node       http://10.0.1.10:9100/metrics        up
node       http://10.0.1.11:9100/metrics        down   connection refused
kubernetes-pods  http://10.244.2.7:8080/metrics up
```

### Step 2 — Why did a target get dropped? (relabel debugging)

Dropped targets are invisible in the UI. Query the **dropped** targets explicitly:

```console
$ curl -s 'http://localhost:9090/api/v1/targets?state=dropped' | \
    jq -r '.data.droppedTargets[].discoveredLabels.__address__' | head
10.244.3.9:9090
10.244.1.4:53
```

If a pod you expect is missing, the usual culprits:

| Symptom | Likely cause | Fix |
|---|---|---|
| Target in `droppedTargets`, not `activeTargets` | A `keep` regex didn't match (e.g. annotation missing/misspelled) | Verify `prometheus.io/scrape: "true"` on the pod, check regex anchoring |
| `activeTargets` shows `__address__` with wrong port | Port-assembly relabel regex wrong | Inspect `discoveredLabels` on the dropped/active entry |
| `job`/`instance` unexpected | Overwritten by a `replace` rule or by `honor_labels` | Trace the rule order — relabel is sequential |

### Step 3 — Scrape health from the built-in meta-metrics

Every scrape produces synthetic samples in the target's own timeline:

| Metric | Meaning | Alert on |
|---|---|---|
| `up` | 1 if the scrape succeeded, 0 otherwise | `up == 0` for N minutes |
| `scrape_duration_seconds` | How long the scrape took | approaching `scrape_timeout` |
| `scrape_samples_scraped` | Samples exposed by the target | sudden growth = cardinality risk |
| `scrape_samples_post_metric_relabeling` | Samples kept after `metric_relabel_configs` | gap vs. scraped = your drop rules |
| `scrape_series_added` | New series this scrape | high churn = unstable labels |

```console
$ curl -s 'http://localhost:9090/api/v1/query?query=up==0' | \
    jq -r '.data.result[] | [.metric.job, .metric.instance] | @tsv'
node   10.0.1.11:9100
```

### Step 4 — Diagnose the `sample_limit` / cardinality trip

When a target exceeds `sample_limit`, the **entire scrape is rejected** and `up` goes to 0 with a telltale error:

```console
$ curl -s http://localhost:9090/api/v1/targets | \
    jq -r '.data.activeTargets[] | select(.health=="down") | .lastError'
sample limit exceeded (5000)
```

Find the offenders before they OOM the server:

```promql
# Top targets by samples exposed
topk(10, scrape_samples_scraped)

# Series churn — unstable labels create new series every scrape
topk(10, scrape_series_added)
```

Diagnose *which metric* is exploding cardinality:

```console
$ curl -s http://localhost:9090/api/v1/status/tsdb | \
    jq -r '.data.seriesCountByMetricName[] | [.value, .name] | @tsv' | head
483210  rpc_client_duration_seconds_bucket
120044  http_request_duration_seconds_bucket
 51002  container_network_receive_bytes_total
```

→ Add a `metric_relabel_configs` `drop`/`labeldrop` for the top entry, reload, and re-check.

### Step 5 — Confirm a metric_relabel drop actually took effect

```console
$ curl -s 'http://localhost:9090/api/v1/query?query=count({__name__=~"rpc_client_.*_bucket"})'
{"status":"success","data":{"resultType":"vector","result":[]}}
```

Empty result ⇒ the drop rule is live. Compare `scrape_samples_scraped` vs `scrape_samples_post_metric_relabeling` to quantify what you saved:

```promql
scrape_samples_scraped - scrape_samples_post_metric_relabeling
```

### Step 6 — Staleness sanity

If a target disappears from SD, Prometheus injects a **staleness marker** and the series stops returning values ~5 minutes later (default lookback delta). A target that *keeps* returning stale values usually means it is still discovered but returning cached data — check `honor_timestamps` and the exporter's timestamps.

---

## 10. References

- Prometheus — Configuration reference: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — `<scrape_config>` and `<relabel_config>`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
- Prometheus — Kubernetes SD (`kubernetes_sd_config`): https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config
- Prometheus — Getting started / configuring scrape targets: https://prometheus.io/docs/prometheus/latest/getting_started/
- Prometheus — Federation: https://prometheus.io/docs/prometheus/latest/federation/
- Prometheus — Management API (`/-/reload`, lifecycle): https://prometheus.io/docs/prometheus/latest/management_api/
- Prometheus — Querying HTTP API (`/api/v1/targets`, `/status/tsdb`, `/status/config`): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — `promtool` (bundled with the server): https://github.com/prometheus/prometheus/tree/main/cmd/promtool
- OpenMetrics specification: https://github.com/prometheus/OpenMetrics/blob/main/specification/OpenMetrics.md
- Relabeling best practices (Robust Perception, referenced by Prometheus docs): https://www.robustperception.io/life-of-a-label/
- CNCF PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf