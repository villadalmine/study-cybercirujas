# PCA — Domain 2: Prometheus Fundamentals
## Topic 2.1 — System Architecture · Guided Exercises

> **Format.** Each exercise is a numbered runbook you execute on a real Prometheus. After each block there are **comprehension questions**; the answers live in the collapsible `<details>` section at the end. Everything is designed to run on a single Linux host with no cluster.
>
> **Sources cited throughout:**
> - Overview & architecture diagram — https://prometheus.io/docs/introduction/overview/
> - Configuration reference — https://prometheus.io/docs/prometheus/latest/configuration/configuration/
> - Storage / TSDB — https://prometheus.io/docs/prometheus/latest/storage/
> - HTTP API — https://prometheus.io/docs/prometheus/latest/querying/api/
> - Data model — https://prometheus.io/docs/concepts/data_model/
> - Alerting overview — https://prometheus.io/docs/alerting/latest/overview/
> - Federation — https://prometheus.io/docs/prometheus/latest/federation/
> - PCA curriculum — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf

---

## Exercise 0 — Lab setup

You need three moving parts to *see* the architecture rather than read about it: the **Prometheus server** (which contains the scraper, the TSDB and the query engine), one **exporter** (an HTTP target that exposes `/metrics`), and the **Pushgateway** (to contrast pull vs. push). We install all three as static binaries.

```bash
# 1. Prometheus server (adapt the version to the latest 3.x release you find)
VER=3.1.0
wget -q https://github.com/prometheus/prometheus/releases/download/v${VER}/prometheus-${VER}.linux-amd64.tar.gz
tar xzf prometheus-${VER}.linux-amd64.tar.gz
cd prometheus-${VER}.linux-amd64/

# 2. node_exporter — a real target that exposes host metrics
NVER=1.8.2
wget -q https://github.com/prometheus/node_exporter/releases/download/v${NVER}/node_exporter-${NVER}.linux-amd64.tar.gz
tar xzf node_exporter-${NVER}.linux-amd64.tar.gz

# 3. Pushgateway — the bridge for the push model
PVER=1.9.0
wget -q https://github.com/prometheus/pushgateway/releases/download/v${PVER}/pushgateway-${PVER}.linux-amd64.tar.gz
tar xzf pushgateway-${PVER}.linux-amd64.tar.gz
```

Start the exporter and the pushgateway in the background; they are just HTTP servers:

```bash
./node_exporter-${NVER}.linux-amd64/node_exporter >/tmp/node.log 2>&1 &   # :9100
./pushgateway-${PVER}.linux-amd64/pushgateway     >/tmp/pgw.log  2>&1 &   # :9091
```

Confirm each one *is nothing more than* an HTTP endpoint serving the exposition format:

```bash
curl -s localhost:9100/metrics | head -n 5
```

Expected shape (values will differ):

```
# HELP go_gc_duration_seconds A summary of the wall-time pause (stop-the-world) duration of garbage collection cycles.
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} 1.9008e-05
go_gc_duration_seconds{quantile="0.25"} 3.6717e-05
go_gc_duration_seconds{quantile="0.5"} 5.4917e-05
```

**Comprehension check 0**
1. The exporter you just started is only reachable when *you* call `curl`. Which component in the Prometheus architecture is responsible for actually collecting these numbers, and how does it reach the exporter?
2. Nothing has been "sent" to Prometheus yet — in fact Prometheus is not even running. What does that tell you about where a metric physically lives before its first scrape?

---

## Exercise 1 — Dissect the server's internal components

The single `prometheus` binary is not monolithic in behaviour; internally it is **Retrieval (scrape manager)** → **TSDB (local storage + WAL)** → **PromQL engine** → **HTTP/Web API**, plus a **Rule manager** and a **Service Discovery manager**. You will expose each subsystem through its own status endpoint.

1. Write a minimal config that scrapes Prometheus itself plus the node_exporter:

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    monitor: pca-lab

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: node
    static_configs:
      - targets: ["localhost:9100"]
```

2. Validate the config *before* starting — this is `promtool`, the offline linter that ships in the same tarball:

```bash
./promtool check config prometheus.yml
```

Expected:

```
Checking prometheus.yml
 SUCCESS: prometheus.yml is valid prometheus config file syntax
```

3. Launch the server, enabling the lifecycle API so you can hot-reload later:

```bash
./prometheus \
  --config.file=prometheus.yml \
  --storage.tsdb.path=./data \
  --storage.tsdb.retention.time=15d \
  --web.enable-lifecycle \
  >/tmp/prom.log 2>&1 &
```

4. Probe the two health/readiness split endpoints — note that Prometheus distinguishes *liveness* from *readiness* exactly like a Kubernetes pod would:

```bash
curl -s localhost:9090/-/healthy   # process is alive
curl -s localhost:9090/-/ready     # WAL replayed, ready to serve
```

Expected:

```
Prometheus Server is Healthy.
Prometheus Server is Ready.
```

5. Interrogate the four status APIs, one per subsystem:

```bash
curl -s localhost:9090/api/v1/status/buildinfo  | jq .data.version
curl -s localhost:9090/api/v1/status/runtimeinfo | jq '{startTime,storageRetention,reloadConfigSuccess,goroutineCount}'
curl -s localhost:9090/api/v1/status/flags       | jq '."storage.tsdb.retention.time"'
curl -s localhost:9090/api/v1/status/config      | jq -r .data.yaml | head -n 6
```

Representative output of `runtimeinfo`:

```json
{
  "startTime": "2026-08-08T11:02:17.441Z",
  "storageRetention": "15d",
  "reloadConfigSuccess": true,
  "goroutineCount": 71
}
```

6. Prove Prometheus scrapes *itself*: the server exposes its own internals as metrics on `/metrics`, and those metrics are named after the subsystems above.

```bash
curl -s localhost:9090/metrics | grep -E '^prometheus_(tsdb_head_series|sd_discovered_targets|rule_group_iterations_total|engine_query_duration_seconds_count) ' | head
```

Expected (values differ):

```
prometheus_tsdb_head_series 1284
prometheus_sd_discovered_targets{config="node",name="scrape"} 1
prometheus_engine_query_duration_seconds_count{...} 42
```

**Comprehension check 1**
1. `/-/healthy` returned OK the instant the process started, but on a server with a large WAL `/-/ready` can stay *not ready* for minutes. What work happens between "healthy" and "ready", and why must a load balancer route on the second, not the first?
2. Which subsystem does each metric prefix map to: `prometheus_tsdb_*`, `prometheus_sd_*`, `prometheus_rule_*`, `prometheus_engine_*`?
3. You ran `promtool check config` before starting. Name one class of error `promtool` catches that a running Prometheus would only reveal at reload time — and one it *cannot* catch.

---

## Exercise 2 — The pull model, and where push fits

Prometheus **pulls**: the server opens an HTTP `GET /metrics` against each target on a timer. This is a deliberate architectural choice — the server owns the schedule, service discovery drives the target list, and a target that disappears is *observable* (the synthetic `up` metric goes to 0) instead of merely silent.

1. Look at the target list as the scrape manager sees it:

```bash
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job:.labels.job, url:.scrapeUrl, health, lastScrape, scrapeInterval}'
```

Expected:

```jsonl
{"job":"prometheus","url":"http://localhost:9090/metrics","health":"up","lastScrape":"2026-08-08T11:05:02.11Z","scrapeInterval":"15s"}
{"job":"node","url":"http://localhost:9100/metrics","health":"up","lastScrape":"2026-08-08T11:05:04.90Z","scrapeInterval":"15s"}
```

2. Observe the three metrics Prometheus **synthesises** for every scrape (they are added by the server, not by the target). Query the API:

```bash
curl -s 'localhost:9090/api/v1/query?query=up' | jq -r '.data.result[] | "\(.metric.job)=\(.value[1])"'
curl -s 'localhost:9090/api/v1/query?query=scrape_duration_seconds' | jq -r '.data.result[] | "\(.metric.job)=\(.value[1])s"'
```

Expected:

```
prometheus=1
node=1
prometheus=0.004
node=0.019
```

3. Now break a target and watch the model react. Kill node_exporter and wait one scrape interval:

```bash
pkill node_exporter
sleep 20
curl -s 'localhost:9090/api/v1/query?query=up{job="node"}' | jq -r '.data.result[0].value[1]'
```

Expected:

```
0
```

The target is still *known* (still in the config), so `up` exists and equals 0 — a failed pull is data, not absence. Restart it:

```bash
./node_exporter-1.8.2.linux-amd64/node_exporter >/tmp/node.log 2>&1 &
```

4. Now the push side. Batch and cron jobs are too short-lived to be scraped, so they **push** to the Pushgateway, which holds the last value until the next push and is *itself* scraped by Prometheus. Add the job:

```yaml
  - job_name: pushgateway
    honor_labels: true
    static_configs:
      - targets: ["localhost:9091"]
```

Hot-reload (thanks to `--web.enable-lifecycle`) and push a sample:

```bash
curl -s -X POST localhost:9090/-/reload
echo 'batch_job_last_success_timestamp_seconds 1.7549e9' \
  | curl -s --data-binary @- localhost:9091/metrics/job/nightly_backup
curl -s 'localhost:9090/api/v1/query?query=batch_job_last_success_timestamp_seconds' | jq '.data.result'
```

**Comprehension check 2**
1. `up{job="node"}` became `0` but did not disappear. Contrast that with what happens to `up` if you *remove* the node job from the config entirely and reload. Why does the pull model make the first case an alertable event and the second case a silent one?
2. `honor_labels: true` is set on the pushgateway job but not the others. What problem does it solve, given that the Pushgateway re-exposes metrics that already carry a `job` label from whoever pushed them?
3. A colleague proposes pushing *all* application metrics through the Pushgateway "to avoid opening ports for scraping." Give two architectural reasons the Prometheus docs warn against using the Pushgateway as a general push proxy.

---

## Exercise 3 — Service discovery and relabeling

In production you never hand-write target lists. **Service Discovery (SD)** produces a stream of targets, each carrying `__meta_*` metadata labels; **relabeling** then filters and rewrites that stream into final targets and labels. This is the one place the architecture lets you reshape *what gets scraped* before a single byte is stored.

1. Switch the node job to **file-based SD** so you can edit targets without touching `prometheus.yml`:

```yaml
  - job_name: node
    file_sd_configs:
      - files: ["targets/*.yml"]
        refresh_interval: 10s
    relabel_configs:
      # promote the SD-provided "dc" meta-label into a real target label
      - source_labels: [__meta_filepath]
        target_label: sd_file
      # drop any target explicitly marked disabled
      - source_labels: [__meta_enabled]
        regex: "false"
        action: drop
```

2. Create the target file:

```bash
mkdir -p targets
cat > targets/node.yml <<'EOF'
- targets: ["localhost:9100"]
  labels:
    dc: home-lab
    __meta_enabled: "true"
EOF
```

3. Reload and inspect both the *discovered* and the *final* labels of the target:

```bash
curl -s -X POST localhost:9090/-/reload
curl -s localhost:9090/api/v1/targets | \
  jq '.data.activeTargets[] | select(.labels.job=="node") | {discovered:.discoveredLabels, final:.labels}'
```

You will see `discoveredLabels` still holds `__address__`, `__scheme__`, `__metrics_path__`, `__meta_filepath` and your custom `dc`/`__meta_enabled`, while `labels` holds only the surviving, non-`__`-prefixed set after relabeling.

4. Prove SD is dynamic. Add a second target *without restarting anything*:

```bash
cat >> targets/node.yml <<'EOF'
- targets: ["localhost:9100"]
  labels:
    dc: edge
    __meta_enabled: "false"
EOF
sleep 12
curl -s localhost:9090/api/v1/targets | jq '[.data.activeTargets[] | select(.labels.job=="node")] | length'
```

Expected: `1` — the second target was **dropped** by the relabel rule before it ever became an active target.

**Comprehension check 3**
1. Labels beginning with `__` (double underscore) behave differently from ordinary labels at the end of relabeling. What happens to them, and why is `__address__` special?
2. In the target JSON, what is the precise difference between `discoveredLabels` and `labels`? At which stage of the pipeline does one become the other?
3. You used `action: drop` on `__meta_enabled="false"`. Where in the architecture does this filtering happen relative to the scrape — before or after the HTTP `GET /metrics`? What does that imply for the cost of a dropped target?

---

## Exercise 4 — Local storage: WAL, head block, and compaction

The TSDB is the component most people treat as a black box. Its job is to ingest samples into an in-memory **head block**, durably append them to a **write-ahead log (WAL)** first, and periodically flush closed 2-hour ranges into immutable on-disk **blocks** that later **compact** together.

1. Look at the on-disk layout:

```bash
ls -R data | head -n 25
```

Representative (young server may have no numbered blocks yet):

```
data:
01J9Q2 K...   chunks_head   wal   lock   queries.active

data/wal:
00000000  00000001  checkpoint.00000000

data/chunks_head:
000001
```

Once blocks exist, each is a directory:

```
data/01J9Q2K.../
├── chunks/000001        # the compressed sample chunks
├── index                # inverted index: label pairs → series
├── meta.json            # time range, series/sample counts, compaction level
└── tombstones           # deletion markers
```

2. Read one block's `meta.json`:

```bash
cat data/01J*/meta.json 2>/dev/null | jq '{minTime,maxTime,stats:.stats,level:.compaction.level}' | head -n 20
```

Expected shape:

```json
{
  "minTime": 1754640000000,
  "maxTime": 1754647200000,
  "stats": {"numSamples": 1839200, "numSeries": 1284, "numChunks": 15410},
  "level": 1
}
```

3. Ask the TSDB about its **head** (the in-memory, not-yet-flushed window) via the API — this is the cardinality dashboard every SRE lives in:

```bash
curl -s localhost:9090/api/v1/status/tsdb | jq '{numSeries:.data.headStats.numSeries, chunkCount:.data.headStats.chunkCount, minTime:.data.headStats.minTime, maxTime:.data.headStats.maxTime}'
curl -s localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[0:3]'
```

Expected:

```
{"numSeries":1284,"chunkCount":1284,"minTime":1754647200110,"maxTime":1754648103110}
[{"name":"node_cpu_seconds_total","value":112},
 {"name":"go_gc_duration_seconds","value":40},
 {"name":"node_scrape_collector_duration_seconds","value":38}]
```

4. Inspect blocks offline with `promtool` (works even while Prometheus runs, but only on flushed blocks):

```bash
./promtool tsdb list ./data
```

Expected:

```
BLOCK               MIN TIME             MAX TIME             DURATION   NUM SAMPLES  NUM CHUNKS  NUM SERIES
01J9Q2K...          2026-08-08 09:00     2026-08-08 11:00     2h0m0s     1839200      15410       1284
```

**Comprehension check 4**
1. Order these on the write path of a single sample: *append to WAL*, *acknowledge the scrape*, *insert into head block*, *flush to a persistent block*. Which of these survives a `kill -9`, and which does not?
2. `headStats.numSeries` is the metric you page on. Explain why a deployment that puts a unique `request_id` in a label will crash Prometheus even though total request *volume* is unchanged.
3. The retention flag was `--storage.tsdb.retention.time=15d`. Retention deletes whole *blocks*, not individual samples. What does that granularity imply about how precisely Prometheus honours "15 days," and why is block-level deletion the right trade-off for a TSDB?

---

## Exercise 5 — The alerting pipeline: server evaluates, Alertmanager routes

Alerting is split across **two** components on purpose. The **Prometheus server** *evaluates* alerting rules on `evaluation_interval` and, when an expression stays true past its `for:` duration, fires an alert **to** Alertmanager. **Alertmanager** — a separate process — then dedups, groups, routes, silences and inhibits, and finally emits notifications. The server never sends an email.

1. Add a rule file and wire Alertmanager into the config:

```yaml
# prometheus.yml additions
alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]

rule_files:
  - "rules/*.yml"
```

```yaml
# rules/pca.yml
groups:
  - name: architecture-demo
    rules:
      - alert: NodeExporterDown
        expr: up{job="node"} == 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "node_exporter target {{ $labels.instance }} is down"
```

2. Lint the rules (again, offline):

```bash
./promtool check rules rules/pca.yml
```

Expected:

```
Checking rules/pca.yml
  SUCCESS: 1 rules found
```

3. Reload, then trip the rule by killing the exporter and watch the alert traverse the **inactive → pending → firing** state machine:

```bash
curl -s -X POST localhost:9090/-/reload
pkill node_exporter
# within 30s it is "pending"; after the `for:` elapses it is "firing"
sleep 45
curl -s localhost:9090/api/v1/alerts | jq '.data.alerts[] | {name:.labels.alertname, state, activeAt}'
```

Expected:

```json
{"name":"NodeExporterDown","state":"firing","activeAt":"2026-08-08T11:20:14.9Z"}
```

4. Observe that a firing alert is *also just a metric*: the rule manager writes the synthetic `ALERTS` series into the TSDB.

```bash
curl -s 'localhost:9090/api/v1/query?query=ALERTS{alertname="NodeExporterDown"}' | jq '.data.result[0].metric'
```

Expected:

```json
{"__name__":"ALERTS","alertname":"NodeExporterDown","alertstate":"firing","instance":"localhost:9100","job":"node","severity":"critical"}
```

Restart the exporter; the alert clears and `ALERTS` disappears within an evaluation cycle.

**Comprehension check 5**
1. Draw the boundary: which of these is done by the **Prometheus server** and which by **Alertmanager** — evaluating `expr`, honouring `for:`, grouping 400 alerts into one notification, applying a silence, sending to PagerDuty, applying an inhibition rule?
2. The `for: 30s` clause changed the alert's lifecycle. Describe the `pending` state and give the operational reason `for:` exists (what failure mode does it suppress?).
3. Alertmanager is designed to run as a **cluster of ≥3 replicas**, but Prometheus is told about all of them via `static_configs`. Given that each Prometheus sends *every* firing alert to *every* Alertmanager, which component is responsible for making sure the on-call human gets **one** page and not three? Name the mechanism.

---

## Exercise 6 — Long-term storage and the multi-server topology

A single Prometheus is intentionally a **local, standalone, non-clustered** store — that is an architectural decision, not a limitation to fix by clustering the TSDB. Scale and durability come from *composition*: **remote_write** ships samples to an external long-term store, and **federation** lets a higher-level Prometheus scrape aggregated series from lower-level ones.

1. Inspect the federation endpoint your server already exposes — it is a special scrape URL that returns selected series in exposition format, meant to be scraped *by another Prometheus*:

```bash
curl -s -G 'http://localhost:9090/federate' \
  --data-urlencode 'match[]={job="node"}' \
  --data-urlencode 'match[]=up' | head -n 6
```

Expected (note the injected `instance`/`job` and the trailing timestamp):

```
# TYPE up untyped
up{instance="localhost:9100",job="node",monitor="pca-lab"} 1 1754648220000
node_load1{instance="localhost:9100",job="node",monitor="pca-lab"} 0.14 1754648220000
```

2. Read the remote_write knobs without needing a backend — the flags tell you the durability model:

```bash
curl -s localhost:9090/api/v1/status/flags | jq 'to_entries[] | select(.key|startswith("storage.remote"))'
```

3. Reason about the topology from `external_labels`. You set `monitor: pca-lab` in Exercise 1; confirm it is stamped onto every federated/remote-written series (it appears in the `/federate` output above). This label is what keeps two Prometheis' data distinguishable once merged in a global store.

**Comprehension check 6**
1. `external_labels` are *not* attached to series in local storage but *are* attached on the way out (federation, remote_write, alerts). Why does the architecture add them only at the egress boundary?
2. Federation and remote_write both move data off a Prometheus, but they answer different questions. State the intended use of each: *"hierarchical federation"* vs. *"remote long-term storage."* Which one is pull and which is push?
3. Someone asks you to make Prometheus "highly available" by pointing two servers at the same TSDB directory on shared storage. Explain, from what you saw of the WAL and head block in Exercise 4, why this corrupts data — and what the *correct* HA pattern is instead.

---

<details>
<summary><strong>Answers</strong></summary>

### Check 0
1. The **scrape manager (Retrieval)** inside the Prometheus server does the collection, by performing an HTTP `GET /metrics` against `localhost:9100` on the scrape schedule — the exporter is passive and never initiates a connection. This is the **pull model**.
2. Before its first scrape the metric lives **only inside the exporter's process memory**, recomputed on demand each time `/metrics` is requested. There is no history and no storage in the exporter; it holds a single current value. Persistence begins only when Prometheus scrapes and writes to its TSDB. (https://prometheus.io/docs/introduction/overview/)

### Check 1
1. Between *healthy* and *ready*, Prometheus **replays the WAL** to reconstruct the in-memory head block, reloads the config, and brings the scrape/rule managers up. `/-/healthy` only says the process hasn't wedged; `/-/ready` says queries and scrapes will actually work. A load balancer (or Kubernetes readiness probe) must gate on `/-/ready`, otherwise it routes queries to a server whose head is still empty, returning wrong/partial results.
2. `prometheus_tsdb_*` → local **storage/TSDB**; `prometheus_sd_*` → **service discovery** manager; `prometheus_rule_*` → **rule** (recording/alerting) manager; `prometheus_engine_*` → **PromQL query engine**.
3. `promtool` catches **syntax and schema errors** (unknown fields, malformed YAML, invalid durations/regex, bad rule expressions). It **cannot** catch **runtime/semantic** problems: a target that is unreachable, a `bearer_token_file` that doesn't exist on disk, an SD backend that returns nothing, or a rule that is syntactically valid but logically wrong. Those surface only when Prometheus runs.

### Check 2
1. When the target *fails to respond*, it is still in the config, so `up{job="node"}` **exists and equals 0** — an alertable event. When you *delete the job and reload*, the target is no longer discovered, so the `up` series simply **stops receiving samples and goes stale/absent** — no signal to alert on. The pull model turns "target present but broken" into explicit data; it cannot, by itself, alert on "target intentionally removed."
2. Metrics pushed to the Pushgateway already carry their own `job`/`instance` labels. Without `honor_labels: true`, Prometheus would **overwrite** those with the pushgateway job's own labels (`job="pushgateway"`), collapsing every pushed metric onto the gateway's identity. `honor_labels: true` tells the scrape to **keep the labels already on the exposed metrics** rather than relabeling them to the scraping job.
3. Two reasons from the docs: (a) The Pushgateway is a **single point of failure and a bottleneck** — you lose the per-target `up` health signal (you only get the gateway's `up`), and a failed instance's stale value **persists forever** until explicitly deleted, masking outages. (b) It defeats Prometheus's model: it is meant only for **service-level batch-job results**, not for turning a pull system into a push proxy for long-running services. (https://prometheus.io/docs/practices/pushing/)

### Check 3
1. Labels starting with `__` are **internal/meta labels**; they are used during relabeling but are **dropped before ingestion**, so they never appear on stored series. `__address__` is special because it holds the **`host:port` the scraper will actually connect to**; combined with `__scheme__` and `__metrics_path__` it *builds the scrape URL*. You rewrite `__address__` via relabeling to redirect a scrape.
2. `discoveredLabels` is the **raw target as SD produced it**, including all `__meta_*` and `__address__` entries. `labels` is the **final label set after `relabel_configs` ran** and after internal `__` labels were stripped. The transformation happens in the **relabeling stage**, between service discovery and the scrape.
3. The drop happens **before the HTTP `GET /metrics`** — relabeling runs on the target list at discovery time, so a dropped target is **never scraped at all**. Cost is effectively zero: no connection, no samples, no series, no cardinality. (This is why relabel-drop is the correct tool for excluding targets, not post-scrape filtering.)

### Check 4
1. Write path order: **append to WAL → insert into head block → acknowledge the scrape**; **flush to a persistent block** happens later, asynchronously (roughly every 2 hours). The **WAL survives `kill -9`** (it's fsync'd to disk and replayed on restart to rebuild the head); the **head block's in-memory state does not** survive on its own — it is reconstructed *from* the WAL.
2. `numSeries` counts **unique label-set combinations**, and a unique `request_id` per request means **every request creates a brand-new series**. This is unbounded **cardinality explosion**: the head block, the inverted index, and memory grow without limit regardless of request rate, eventually OOM-killing Prometheus. Volume is fine; *distinct series* is the scaling axis.
3. Because deletion is **block-granular** (default block ≈ 2 h, up to ~10 % of retention after compaction), Prometheus keeps data until the **entire block** falls outside the window, so you may retain up to roughly one block-duration **beyond** the nominal 15 days. That's the right trade-off: blocks are **immutable** (cheap, sequential I/O; no rewriting), so deleting whole immutable files is far cheaper than surgically removing individual samples from a live index.

### Check 5
1. **Prometheus server:** evaluating `expr`, honouring `for:` (pending→firing), writing `ALERTS`, sending the firing alert to Alertmanager. **Alertmanager:** grouping 400 alerts into one notification, applying silences, sending to PagerDuty, applying inhibition rules.
2. `pending` means the expression is **currently true but has not yet been true for the full `for:` duration**. If it stops being true before `for:` elapses, it returns to inactive and never notifies. `for:` exists to suppress **flapping / transient spikes** — it requires the condition to persist, so a single bad scrape doesn't page anyone.
3. **Alertmanager**, via its **gossip-based clustering / deduplication**: the replicas form a cluster, coordinate over the notification pipeline, and **deduplicate identical alerts** so exactly one notification is sent even though each Prometheus fired the alert to all replicas. Prometheus's job is only to *fan the alert out to every* Alertmanager (for redundancy); dedup is Alertmanager's responsibility. (https://prometheus.io/docs/alerting/latest/overview/)

### Check 6
1. `external_labels` identify **this Prometheus among many**. Adding them to local storage would be redundant (a server already knows its own data) and would bloat every series; the labels only matter once data **leaves** the server and gets **merged** with other Prometheis' data (in a global store, a federating parent, or Alertmanager), where you must be able to tell the sources apart. Hence they're stamped at the **egress boundary** only.
2. **Hierarchical federation** = a higher-level Prometheus **pulls** a *selected, aggregated* subset of series from lower-level Prometheis via `/federate` (drill-down/roll-up topologies). **Remote long-term storage** via `remote_write` = Prometheus **pushes** *all* samples to an external durable backend (e.g. for retention beyond local disk and global query). Federation is **pull**; remote_write is **push**.
3. Two Prometheus processes cannot share one TSDB directory: each has its **own in-memory head block and its own WAL**, and both would append to the same WAL segments and block files, producing **interleaved, corrupt writes** (the `lock` file is exactly there to prevent two servers opening the same dir). The correct HA pattern is **two independent Prometheus servers, each with its own storage, scraping the same targets in parallel**, both feeding a **clustered Alertmanager** that deduplicates — redundancy by running *identical, independent* replicas, not by sharing state. (https://prometheus.io/docs/prometheus/latest/storage/)

</details>