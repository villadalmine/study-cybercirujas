# Guided Exercises — Topic 2.3: Understanding Prometheus Limitations

**Certification:** Prometheus Certified Associate (PCA) · **Domain:** Prometheus Fundamentals · **Exam weight:** 4%

> Every mature monitoring decision is a decision about what Prometheus *deliberately does not do*. The Prometheus authors are unusually explicit about this in the ["When does it not fit?"](https://prometheus.io/docs/introduction/overview/#when-does-it-not-fit) section of the overview: Prometheus values **reliability over 100% accuracy**, runs as a **single self-contained node**, and keeps only **short-term local data**. These exercises reproduce each limitation on your own machine so you can *see* the boundary rather than memorize it.

## Prerequisites

- Docker Engine ≥ 24 and `curl` + `jq` installed.
- ~1 GB free disk and RAM for the TSDB/cardinality labs.
- A dedicated bridge network so containers resolve each other by name:

```bash
docker network create promlab
```

- Base scrape config used throughout (`prometheus.yml`):

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
```

---

## Exercise 1 — Local storage is short-term, single-node and not durable

Goal: prove that Prometheus' local TSDB actively **deletes** old data and is bounded by retention, which is why it is *not* a long-term or system-of-record store.

### Steps

1. Start Prometheus with an intentionally tiny **size-based** retention so the deletion machinery fires quickly:

```bash
docker run -d --name prometheus --network promlab -p 9090:9090 \
  -v "$(pwd)/prometheus.yml:/etc/prometheus/prometheus.yml" \
  prom/prometheus:v2.53.0 \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.size=64MB \
  --storage.tsdb.retention.time=6h
```

2. Inspect the on-disk layout of the TSDB. Note that it is a **local directory**, not a clustered store:

```bash
docker exec prometheus ls -1 /prometheus
```

Expected (illustrative) output shortly after start:

```
chunks_head
lock
queries.active
wal
```

The `wal/` (write-ahead log) and `chunks_head/` hold the in-memory *head block*; persisted blocks (named with ULIDs like `01J4Z3P...`) only appear after the first 2-hour block is cut.

3. Read the retention counters. These increment **every time** a block is deleted for exceeding the time or size limit:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_time_retentions_total' \
  | jq -r '.data.result[0].value[1]'
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_size_retentions_total' \
  | jq -r '.data.result[0].value[1]'
```

Right after start both read `0`. Once the TSDB exceeds 64 MB, `prometheus_tsdb_size_retentions_total` starts climbing (`1`, `2`, …).

4. Observe how far back your data actually goes — the practical horizon of an unassisted Prometheus:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=(time()-prometheus_tsdb_lowest_timestamp_seconds)/3600' \
  | jq -r '.data.result[0].value[1]'
```

The number is the age (in hours) of the oldest sample still on disk — it will **never** grow past your retention window.

5. Look at the documented escape hatch. Prometheus does not solve long-term storage internally; it exposes `remote_write`. Add this block to `prometheus.yml` (a real backend such as Mimir/Thanos/VictoriaMetrics would receive it):

```yaml
remote_write:
  - url: "http://mimir:9009/api/v1/push"
    queue_config:
      capacity: 10000
      max_shards: 50
      max_samples_per_send: 2000
```

After reload, the outbound pipeline is observable through:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_remote_storage_samples_pending' \
  | jq -r '.data.result[0].value[1]'
```

**Comprehension check 1**

- **Q1.1** If you set `--storage.tsdb.retention.time=15d` on a single Prometheus, what happens to a metric sample that is 16 days old, and what does this imply for capacity planning or compliance/audit use cases?
- **Q1.2** When *both* `retention.time` and `retention.size` are set, which one triggers deletion?
- **Q1.3** Why is `remote_write` — not a bigger disk — the architecturally correct answer to "we need 13 months of history"? Name two capabilities you gain besides longer retention.

---

## Exercise 2 — Cardinality is the real scaling limit

Goal: watch active series count (and therefore memory) explode when labels carry unbounded values, and learn the built-in tools to *find* the offender.

### Steps

1. Launch [`avalanche`](https://github.com/prometheus-community/avalanche), the Prometheus community's synthetic metrics load generator. Start with a **stable, moderate** shape — 100 metrics × 20 series = 2 000 series:

```bash
docker run -d --name avalanche --network promlab -p 9001:9001 \
  quay.io/prometheuscommunity/avalanche:v0.6.0 \
  --metric-count=100 --series-count=20 --label-count=5 \
  --value-interval=15 --series-interval=3600 --metric-interval=3600 \
  --port=9001
```

2. Add the target to `prometheus.yml` and reload Prometheus (`docker kill -s HUP prometheus`):

```yaml
  - job_name: avalanche
    static_configs:
      - targets: ['avalanche:9001']
```

3. After ~30 s, read the head series count — the number of **active time series** held in memory:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_head_series' \
  | jq -r '.data.result[0].value[1]'
```

Expected (illustrative):

```
2712
```

(~2 000 from avalanche + ~700 from Prometheus' own metrics.)

4. Ask the TSDB *who* is expensive. The `/api/v1/status/tsdb` endpoint is the first-line cardinality diagnostic — the same data shown on the **Status → TSDB Stats** UI page:

```bash
curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data | {headStats, seriesCountByMetricName: .seriesCountByMetricName[:3], labelValueCountByLabelName: .labelValueCountByLabelName[:3]}'
```

Expected (illustrative):

```json
{
  "headStats": {
    "numSeries": 2712,
    "numLabelPairs": 648,
    "chunkCount": 2740,
    "minTime": 1723100000000,
    "maxTime": 1723100460000
  },
  "seriesCountByMetricName": [
    { "name": "avalanche_metric_mmmmm_0_0", "value": 20 },
    { "name": "avalanche_metric_mmmmm_0_1", "value": 20 },
    { "name": "avalanche_metric_mmmmm_0_2", "value": 20 }
  ],
  "labelValueCountByLabelName": [
    { "name": "__name__", "value": 100 },
    { "name": "series_id", "value": 20 },
    { "name": "cycle_id", "value": 1 }
  ]
}
```

5. Now **blow up cardinality** the way a naive `user_id` / `request_id` / `email` label would in production. Replace avalanche with a churning, high-fan-out shape — 500 metrics × 100 series, with labels *rotating every 10 s* so old series never stop accumulating in the head:

```bash
docker rm -f avalanche
docker run -d --name avalanche --network promlab -p 9001:9001 \
  quay.io/prometheuscommunity/avalanche:v0.6.0 \
  --metric-count=500 --series-count=100 --label-count=10 \
  --value-interval=5 --series-interval=10 --metric-interval=10 \
  --port=9001
```

6. Re-read head series over a minute:

```bash
for i in 1 2 3 4; do
  curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_head_series' \
    | jq -r '.data.result[0].value[1]'
  sleep 15
done
```

Expected (illustrative — note the churn-driven climb, then head-GC sawtooth):

```
51873
78402
103661
64890
```

7. Confirm the memory cost is real:

```bash
docker stats --no-stream prometheus
```

Expected (illustrative):

```
CONTAINER   NAME         CPU %   MEM USAGE / LIMIT
a1b2c3d4    prometheus   38.4%   612.7MiB / 7.6GiB
```

**Comprehension check 2**

- **Q2.1** Total active series ≈ (number of metric names) × (product of distinct values of every label on that metric). Given `http_requests_total` with `method` (5 values), `status` (8), `path` (200), and a newly-added `user_id` (50 000 values), how many series can this one metric alone produce?
- **Q2.2** Which two fields of `/api/v1/status/tsdb` would you read first to locate a cardinality bomb, and what does each tell you?
- **Q2.3** Why is *label churn* (values that change over time, like `pod` names or a `version` that rolls) especially dangerous even if the instantaneous cardinality looks modest?

---

## Exercise 3 — The pull model misses short-lived jobs (and the Pushgateway's own limits)

Goal: demonstrate that Prometheus scrapes on a schedule, so a job that finishes between scrapes is never observed — and that the Pushgateway is a *narrow* remedy, not a conversion of Prometheus into a push system.

### Steps

1. Simulate a batch job shorter than one scrape interval. It exposes a metric for 3 seconds, then exits:

```bash
docker run -d --name batch --network promlab \
  python:3.12-alpine sh -c \
  'echo "backup_done 1" > /tmp/m; timeout 3 python -m http.server 8000 --directory /tmp; echo gone'
```

2. Point Prometheus at it and reload. Because the container is up only ~3 s and the scrape interval is 15 s, the target is almost always `down`:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up{job="batch"}' \
  | jq -r '.data.result[]?.value[1] // "no data scraped"'
```

Expected:

```
no data scraped
```

The metric `backup_done` never lands in the TSDB — the pull scheduler and the job's lifetime never overlapped.

3. Deploy the **Pushgateway**, the sanctioned bridge for *service-level batch jobs*:

```bash
docker run -d --name pushgateway --network promlab -p 9091:9091 prom/pushgateway:v1.9.0
```

4. Scrape the Pushgateway. `honor_labels: true` is mandatory here — explain to yourself why before reading the answer:

```yaml
  - job_name: pushgateway
    honor_labels: true
    static_configs:
      - targets: ['pushgateway:9091']
```

5. Have the batch job **push** its result on completion, keyed by a grouping (`job`/`instance`):

```bash
cat <<'EOF' | curl --data-binary @- http://localhost:9091/metrics/job/db_backup/instance/db01
# TYPE db_backup_records_processed counter
db_backup_records_processed 24519
# TYPE db_backup_duration_seconds gauge
db_backup_duration_seconds 42.7
# TYPE db_backup_last_success_timestamp_seconds gauge
db_backup_last_success_timestamp_seconds 1723100500
EOF
```

6. Query Prometheus for the pushed metric. It is now present *even though the job is long gone*:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=db_backup_last_success_timestamp_seconds' \
  | jq -r '.data.result[0] | "\(.metric.job) \(.metric.instance) = \(.value[1])"'
```

Expected:

```
db_backup db01 = 1723100500
```

7. Now confront the Pushgateway's own limitation. Stop pushing and delete nothing. Wait 5 minutes and re-run step 6 — **the value is still there, unchanged**. The Pushgateway persists the last push indefinitely until explicitly deleted:

```bash
curl -X DELETE http://localhost:9091/metrics/job/db_backup/instance/db01
```

**Comprehension check 3**

- **Q3.1** Why did `up{job="batch"}` return no data — what specifically did the pull scheduler fail to line up with?
- **Q3.2** According to the official ["When to use the Pushgateway"](https://prometheus.io/docs/practices/pushing/) guidance, which single legitimate use case is it for, and what is the explicit anti-pattern it warns against?
- **Q3.3** Name two ways the Pushgateway *breaks* Prometheus' normal semantics (think: what happens to `up`, target-health, and staleness when the source disappears?).

---

## Exercise 4 — A single Prometheus does not cluster; federation is not clustering

Goal: build a two-tier federation and see that federation *pulls a selected slice* of series upward — it gives you a hierarchical rollup, not a horizontally-scaled, highly-available cluster.

### Steps

1. Start a second **"global"** Prometheus whose only job is to federate from the first. Config (`global.yml`):

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'federate'
    honor_labels: true
    metrics_path: '/federate'
    params:
      'match[]':
        - '{job="avalanche"}'
        - '{__name__=~"job:.*"}'   # convention: only pre-aggregated recording rules
    static_configs:
      - targets: ['prometheus:9090']
```

```bash
docker run -d --name prometheus-global --network promlab -p 9099:9090 \
  -v "$(pwd)/global.yml:/etc/prometheus/prometheus.yml" \
  prom/prometheus:v2.53.0 \
  --config.file=/etc/prometheus/prometheus.yml
```

2. Inspect exactly what crosses the federation boundary — hit the leaf's `/federate` endpoint directly:

```bash
curl -s -G http://localhost:9090/federate \
  --data-urlencode 'match[]={job="avalanche"}' | head -5
```

Expected (illustrative — note every sample carries an explicit timestamp):

```
# TYPE avalanche_metric_mmmmm_0_0 untyped
avalanche_metric_mmmmm_0_0{cycle_id="0",series_id="0",instance="avalanche:9001",job="avalanche"} 42 1723100500123
avalanche_metric_mmmmm_0_0{cycle_id="0",series_id="1",instance="avalanche:9001",job="avalanche"} 17 1723100500123
```

3. Compare series counts between the two tiers to see that the global tier holds a **subset**, not a replica:

```bash
echo "leaf:   $(curl -s 'http://localhost:9090/api/v1/query?query=count(count%20by%20(__name__)({__name__=~%22avalanche.%2B%22}))' | jq -r '.data.result[0].value[1]')"
echo "global: $(curl -s 'http://localhost:9099/api/v1/query?query=count(count%20by%20(__name__)({__name__=~%22avalanche.%2B%22}))' | jq -r '.data.result[0].value[1]')"
```

4. Prove there is **no automatic HA/dedup**. Run a *second identical* leaf (`prometheus-b`) scraping the same avalanche target and federate both into global. Identical series now arrive twice and you must deduplicate with an external layer (Thanos Querier, Mimir) or `honor_labels` + external labels — Prometheus will not merge them for you.

**Comprehension check 4**

- **Q4.1** In hierarchical federation, what are you *supposed* to pull to the global tier, and why is pulling `{__name__=~".+"}` (everything) an anti-pattern?
- **Q4.2** You run two identical Prometheus replicas for availability. A dashboard query now returns duplicated series. Whose job is it to deduplicate them, and why can't a single Prometheus do it?
- **Q4.3** Federation and `remote_write` both move data off one node. State the core difference in *direction and purpose* of each.

---

## Exercise 5 — Reliability over 100% accuracy: scrape resolution and aliasing

Goal: show that Prometheus samples the world at a fixed cadence, so sub-scrape events are lost — which is exactly why the docs say it is unfit for per-request billing or event-exact accounting.

### Steps

1. Reconfigure the avalanche target to change its values **every second** while Prometheus keeps scraping every 15 s. Run avalanche with a fast value churn:

```bash
docker rm -f avalanche
docker run -d --name avalanche --network promlab -p 9001:9001 \
  quay.io/prometheuscommunity/avalanche:v0.6.0 \
  --metric-count=1 --series-count=1 --label-count=1 \
  --value-interval=1 --port=9001
```

2. Over a 5-minute window, count how many **samples Prometheus actually stored** for that series:

```bash
curl -s -G 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=count_over_time(avalanche_metric_mmmmm_0_0[5m])' \
  | jq -r '.data.result[0].value[1]'
```

Expected (illustrative): about `20` — one sample per 15 s scrape.

3. Compare against reality: the source changed its value ~300 times (once per second) in those 5 minutes. **~280 of those states were never recorded.** Prometheus captured a *sample*, not the *event stream*.

4. Observe the second half of "reliability over accuracy": staleness handling. Kill the target and immediately query it:

```bash
docker stop avalanche
curl -s 'http://localhost:9090/api/v1/query?query=up{job="avalanche"}' \
  | jq -r '.data.result[0].value[1]'
```

For up to 5 minutes an instant query may still return the **last known value** with the staleness rules rather than erroring — Prometheus prefers giving you *approximately-right, available* data over failing the query. After the staleness window (default 5 min) the series goes stale and disappears.

**Comprehension check 5**

- **Q5.1** Your billing team wants to charge customers per API request using `http_requests_total` scraped every 30 s. Referencing the official "When does it not fit?" guidance, why is Prometheus the wrong system of record for this — and what *is* it good enough for?
- **Q5.2** A gauge (e.g. `queue_depth`) briefly spikes to 40 000 for 2 seconds between two 15 s scrapes and returns to 10. What will your dashboard show, and what does this teach about gauges vs. counters under sampling?
- **Q5.3** Why does `rate()` on a *counter* survive this sampling limitation far better than a raw gauge reading does?

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Exercise 1 — Local storage

- **A1.1** The 16-day sample is **permanently deleted** by the retention job; there is no way to query it back from that node. Local storage is bounded and non-authoritative, so a single Prometheus is unsuitable as an audit/compliance system of record or for long look-back capacity planning — you size the disk for the *retention window × ingestion rate*, not for "all history." Long history must live in a remote/downsampling backend.
- **A1.2** **Whichever limit is hit first.** They are independent ceilings, both enforced by dropping the oldest persisted blocks. `retention.time` deletes blocks older than the window; `retention.size` deletes oldest blocks once the on-disk TSDB exceeds the byte budget.
- **A1.3** `remote_write` streams samples to a purpose-built backend (Thanos, Cortex/Mimir, VictoriaMetrics). Besides longer retention you gain (any two of): a **global query view** across many Prometheis, **horizontal scale/sharding** of storage, **downsampling** for cheap long-range queries, and **HA deduplication** of replicated Prometheis. A bigger local disk gives none of these — it is still one node, one failure domain, one query engine. (Docs: [storage](https://prometheus.io/docs/prometheus/latest/storage/).)

### Exercise 2 — Cardinality

- **A2.1** 5 × 8 × 200 × 50 000 = **400,000,000** series from one metric name — a textbook cardinality bomb. `user_id` is unbounded/high-churn and must never be a label. (Guidance: [do not overuse labels](https://prometheus.io/docs/practices/instrumentation/#do-not-overuse-labels), [naming/cardinality](https://prometheus.io/docs/practices/naming/).)
- **A2.2** `seriesCountByMetricName` — which **metric name** owns the most series (the culprit metric); and `labelValueCountByLabelName` — which **label** has the most distinct values (the culprit dimension). Together they point to "metric X exploded because label Y is unbounded." (Also surfaced on the **Status → TSDB Stats** page.)
- **A2.3** Instantaneous cardinality can look small, but each *new* value of a churning label (`pod`, `container_id`, deployment `version`, ephemeral `ip`) creates a brand-new series that stays in the head block until it goes stale and is GC'd. Sustained churn means the **cumulative** active-series count and index size keep growing, driving memory up and query latency down even though "how many pods now?" is a small number. This is why you never label with values that rotate over time.

### Exercise 3 — Pull model & Pushgateway

- **A3.1** The scrape scheduler fires on a fixed 15 s cadence; the job existed for only ~3 s. The scrape window and the job's lifetime **never overlapped**, so Prometheus never made a successful HTTP request to it — hence no `up` sample and no metric. Pull monitoring assumes the target is up long enough to be scraped.
- **A3.2** It is for capturing the result of a **service-level batch job** (a job not tied to a single machine/instance) that is too short-lived to be scraped. The explicit anti-pattern: it is **not** a way to turn Prometheus into a push-based system for regular application metrics, and not a general event/message aggregator — normal services should still be scraped. (Docs: [When to use the Pushgateway](https://prometheus.io/docs/practices/pushing/).)
- **A3.3** Any two of: (1) It **breaks target health** — `up` reflects the Pushgateway's own health, not the job's, so a dead job still looks fine. (2) It **defeats staleness** — the last pushed value persists forever until explicitly `DELETE`d, so a metric can go dangerously stale silently. (3) It is a **single point of failure / shared aggregation point** across many jobs, and (4) `honor_labels: true` is required precisely because the pushed `job`/`instance` labels would otherwise be overwritten by the Pushgateway's own target labels.

### Exercise 4 — No clustering; federation ≠ cluster

- **A4.1** You pull **pre-aggregated, low-cardinality series** — typically the output of recording rules (`job:...` naming convention) — to the global/top tier for a cross-datacenter overview. Pulling `{__name__=~".+"}` copies *every raw series* over the network into one node, recreating the cardinality/scale problem you were trying to escape and defeating the point of hierarchical rollup.
- **A4.2** An **external layer** (Thanos Querier, Cortex/Mimir, or a dedup step keyed on `external_labels`) deduplicates replicas. A single Prometheus can't: each replica is an independent, self-contained node with no knowledge of its twin — there is no built-in clustering, gossip, or shared consensus in Prometheus. HA is achieved by running redundant scrapers and deduplicating *downstream*.
- **A4.3** **Federation** is a *pull* from a higher tier that reaches *down* into another Prometheus and copies a **selected subset** of series (rollups, cross-DC overview). **`remote_write`** is a *push* from a Prometheus *outward/upward* into a long-term, scalable storage backend for **durability, scale and global query**. Direction and intent differ: federation = selective hierarchical read; remote_write = continuous full-stream offload.

### Exercise 5 — Reliability over accuracy

- **A5.1** With a 30 s scrape, Prometheus records the counter's value twice a minute, not every request; between scrapes it interpolates via `rate()`/`increase()` and it may miss data during a scrape failure. The docs state plainly: *"If you need 100% accuracy, such as for per-request billing, Prometheus is not a good choice as the collected data will likely not be detailed and complete enough."* It **is** good enough for trends, SLOs, alerting thresholds and capacity signals — where "approximately right and always available" beats "perfect but fragile." ([When does it not fit?](https://prometheus.io/docs/introduction/overview/#when-does-it-not-fit))
- **A5.2** The dashboard shows `queue_depth` ≈ **10** the whole time — the 40 000 spike fell *between* scrapes and was never sampled, so it is invisible. Lesson: a **gauge under sampling only captures its value at scrape instants**; transient peaks are aliased away. To catch peaks you need a histogram/`max_over_time` on a higher-resolution counter, a shorter scrape interval (at cardinality/cost), or event-based tooling — not a plain gauge.
- **A5.3** A **counter** is monotonic and cumulative: every increment between scrapes is still reflected in the *difference* between two scraped values, so `rate()`/`increase()` recover the average per-second activity across the interval even though individual events weren't sampled. A raw **gauge** only carries its instantaneous value at scrape time, so anything that happened between scrapes is lost entirely. This is why request/error *rates* survive Prometheus' sampling while instantaneous gauge peaks do not.

</details>

---

### Sources

- Prometheus — Overview, *"When does it not fit?"*: https://prometheus.io/docs/introduction/overview/#when-does-it-not-fit
- Prometheus — Storage (local TSDB, retention, `remote_write`/`remote_read`): https://prometheus.io/docs/prometheus/latest/storage/
- Prometheus — Instrumentation best practices, *"Do not overuse labels"* (cardinality): https://prometheus.io/docs/practices/instrumentation/#do-not-overuse-labels
- Prometheus — Metric and label naming: https://prometheus.io/docs/practices/naming/
- Prometheus — *"When to use the Pushgateway"*: https://prometheus.io/docs/practices/pushing/
- Prometheus — Federation: https://prometheus.io/docs/prometheus/latest/federation/
- Prometheus — Querying basics / staleness: https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness
- `prometheus-community/avalanche` (synthetic cardinality load generator): https://github.com/prometheus-community/avalanche
- PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf