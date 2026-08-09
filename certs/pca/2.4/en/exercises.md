# Prometheus Certified Associate (PCA) — Domain 2.4: Data Model and Labels

## Guided Exercises

> **Scope.** These labs make the Prometheus data model tangible: how a *sample* is stored, why a metric name is really just another label, how `job`/`instance` get attached at scrape time, how histograms and summaries decompose into multiple series, how empty‑value matchers behave, and how careless labels detonate cardinality. Work through them in order — each one assumes the environment built in the setup step.
>
> Everything below is executable. Run the commands, read the *actual* output on your machine, and only then check your reasoning against the answers.

---

### Lab setup (run once)

You need a Prometheus server scraping **itself** and one `node_exporter`. The two‑target setup is deliberate: many questions about labels only make sense when more than one target and more than one job exist.

1. Create a working directory and a scrape config:

   ```bash
   mkdir -p ~/pca-2.4 && cd ~/pca-2.4
   cat > prometheus.yml <<'EOF'
   global:
     scrape_interval: 15s
     external_labels:
       monitor: pca-lab

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']

     - job_name: node
       static_configs:
         - targets: ['localhost:9100']
           labels:
             env: lab
             region: eu-west-1
   EOF
   ```

2. Start both processes (Docker shown; native binaries work identically — just point `--config.file` at the same YAML):

   ```bash
   docker run -d --name node --net host \
     quay.io/prometheus/node-exporter:latest

   docker run -d --name prom --net host \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     prom/prometheus:latest
   ```

3. Confirm both are up. The `up` metric is Prometheus' own health signal, synthesised per target on every scrape:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=up' | jq -r \
     '.data.result[] | "\(.metric.job)\t\(.metric.instance)\t\(.value[1])"'
   ```

   Expected:

   ```
   node        localhost:9100   1
   prometheus  localhost:9090   1
   ```

If both lines end in `1`, the lab is ready.

---

### Exercise 1 — Anatomy of a sample on the exposition endpoint

Prometheus stores a stream of **samples**. A sample is: a metric name, a set of labels, one `float64` value, and an `int64` millisecond timestamp. The text exposition format on `/metrics` shows you everything *except* the timestamp (Prometheus stamps the sample itself, at scrape time).

1. Pull three metric families straight from `node_exporter`, before Prometheus ever touches them:

   ```bash
   curl -s http://localhost:9100/metrics \
     | grep -E '^(# (HELP|TYPE) )?node_cpu_seconds_total|^node_filesystem_avail_bytes' \
     | head -n 12
   ```

   Representative output:

   ```
   # HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
   # TYPE node_cpu_seconds_total counter
   node_cpu_seconds_total{cpu="0",mode="idle"} 20356.54
   node_cpu_seconds_total{cpu="0",mode="system"} 245.19
   node_cpu_seconds_total{cpu="0",mode="user"} 512.33
   node_cpu_seconds_total{cpu="1",mode="idle"} 20401.12
   node_filesystem_avail_bytes{device="/dev/sda1",fstype="ext4",mountpoint="/"} 3.284...e+10
   ```

2. Notice what the exporter did **not** emit: there is no `job`, no `instance`, no `env`. Now compare against how the *same* metric looks after ingestion:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=node_cpu_seconds_total{cpu="0",mode="idle"}' \
     | jq '.data.result[0].metric'
   ```

   Expected:

   ```json
   {
     "__name__": "node_cpu_seconds_total",
     "cpu": "0",
     "mode": "idle",
     "instance": "localhost:9100",
     "job": "node",
     "env": "lab",
     "region": "eu-west-1"
   }
   ```

3. Count how many distinct series one CPU counter fans out into on this host:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count(node_cpu_seconds_total)' \
     | jq -r '.data.result[0].value[1]'
   ```

**Comprehension check**

- **Q1.1** In `node_cpu_seconds_total{cpu="0",mode="idle"} 20356.54`, name each syntactic part: the metric name, the labels, and the value. Which fourth component of a stored sample is *absent* from this line, and who supplies it?
- **Q1.2** The exporter emitted no `job` or `instance` label, yet the queried series has both. Where did `instance`, `job`, `env`, and `region` come from, and at which moment were they attached?
- **Q1.3** `node_cpu_seconds_total` is declared `# TYPE ... counter`. What invariant does a counter promise about its value over time, and which PromQL function exists precisely because raw counters are not directly useful?
- **Q1.4** If a machine has 4 logical CPUs and the exporter reports 8 CPU modes, how many `node_cpu_seconds_total` series does that single metric name produce, and what is the general rule relating labels to series count?

---

### Exercise 2 — The metric name is just a label (`__name__`)

Internally there is no privileged "name" field. The metric name is stored in the reserved label `__name__`, and the notation `foo{bar="baz"}` is pure sugar for `{__name__="foo", bar="baz"}`.

1. Select a series using **only** the reserved label, no bare name at all:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query={__name__="up", job="node"}' \
     | jq '.data.result[0].metric'
   ```

   Expected:

   ```json
   { "__name__": "up", "instance": "localhost:9100", "job": "node", "env": "lab", "region": "eu-west-1" }
   ```

2. Use a regex matcher on the name to find every metric family that describes scrape health. This is impossible if the name is *not* a label:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count by (__name__) ({__name__=~"scrape_.+"})' \
     | jq -r '.data.result[] | "\(.metric.__name__)\t\(.value[1])"'
   ```

   Expected (names may vary slightly by version):

   ```
   scrape_duration_seconds          2
   scrape_samples_post_metric_relabeling  2
   scrape_samples_scraped           2
   scrape_series_added              2
   ```

3. Now try a selector where **every** matcher can match the empty string, and read the error:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query={job=~".*"}' | jq '.error, .errorType'
   ```

   Expected:

   ```
   "vector selector must contain at least one non-empty matcher"
   "bad_data"
   ```

**Comprehension check**

- **Q2.1** Rewrite `up{job="node"}` in the fully desugared `{...}` form with no bare metric name. What is the exact reserved label that carries the name?
- **Q2.2** The four matcher operators are `=`, `!=`, `=~`, `!~`. Which two are anchored regexes, and what does "fully anchored" mean for `=~"scrape_.+"` — does it match `node_scrape_x`?
- **Q2.3** Why does `{job=~".*"}` get rejected while `{job=~".+"}` is accepted? State the rule about empty‑matching selectors.
- **Q2.4** Label names starting with `__` (like `__name__`) are a reserved class. What happens to `__meta_*` and `__address__` labels by the time a series is stored, and why don't you see them in query results?

---

### Exercise 3 — Target labels: `job`, `instance`, and `external_labels`

`job` and `instance` are **target labels** — Prometheus attaches them from the scrape configuration, not from the exporter. `instance` defaults to the target's `__address__` (`host:port`); `job` is the `job_name`. `external_labels` behave differently: they are stamped only on data *leaving* the server (remote‑write, federation, alerts), not on locally stored series.

1. Confirm the target‑label origin of `job`/`instance` by listing every target and its discovered/final labels:

   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.labels.instance)\t\(.scrapeUrl)"'
   ```

   Expected:

   ```
   node        localhost:9100   http://localhost:9100/metrics
   prometheus  localhost:9090   http://localhost:9090/metrics
   ```

2. Show that `env`/`region` (set in the `node` job's `static_configs.labels`) exist on `node` series but are **absent** on `prometheus` series:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=up' \
     | jq -r '.data.result[] | "\(.metric.job)\tenv=\(.metric.env // "<none>")\tregion=\(.metric.region // "<none>")"'
   ```

   Expected:

   ```
   node        env=lab      region=eu-west-1
   prometheus  env=<none>   region=<none>
   ```

3. Now look for `monitor="pca-lab"` (the `external_labels` value) in locally stored series:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=up{monitor="pca-lab"}' \
     | jq '.data.result | length'
   ```

   Expected:

   ```
   0
   ```

**Comprehension check**

- **Q3.1** A target is defined only as `targets: ['localhost:9100']` with no explicit `instance`. What value does `instance` get, and which magic label is it derived from?
- **Q3.2** Two exporters on the same host expose the metric `process_cpu_seconds_total`. After Prometheus scrapes both, what keeps the two series from colliding into one? Be specific about which labels differ.
- **Q3.3** Step 3 returned `0`. Explain precisely why `external_labels` did not match any locally stored `up` series, and name a context where `monitor="pca-lab"` *would* appear.
- **Q3.4** If an exporter itself exposed a label literally named `job` (e.g. `mymetric{job="frontend"} 5`), what does Prometheus do with it by default at scrape time, and which config knob changes that behaviour?

---

### Exercise 4 — Histograms and summaries decompose into many series

A single histogram metric is not one series. Prometheus (and the exporter) expose it as: one `_bucket` series **per `le` boundary** (cumulative), plus `_sum` and `_count`. A summary instead exposes one series **per `quantile`**, plus `_sum` and `_count`. Prometheus instruments itself with both, so no extra exporter is needed.

1. Inspect a real histogram — Prometheus' own HTTP request latency:

   ```bash
   curl -s http://localhost:9090/metrics \
     | grep '^prometheus_http_request_duration_seconds' \
     | grep 'handler="/api/v1/query"' | head
   ```

   Representative output:

   ```
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.1"} 42
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.2"} 47
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.4"} 48
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="+Inf"} 48
   prometheus_http_request_duration_seconds_sum{handler="/api/v1/query"} 3.17
   prometheus_http_request_duration_seconds_count{handler="/api/v1/query"} 48
   ```

2. Prove the buckets are **cumulative** ("less than or equal to") and that the `+Inf` bucket equals `_count`:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
     'query=prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="+Inf"}
            == on(handler) prometheus_http_request_duration_seconds_count{handler="/api/v1/query"}' \
     | jq '.data.result | length'
   ```

   A non‑zero length means the equality held.

3. Now inspect a **summary** — note the `quantile` label instead of `le`, and that quantiles are computed *client‑side*:

   ```bash
   curl -s http://localhost:9090/metrics \
     | grep '^prometheus_target_interval_length_seconds' | head
   ```

   Representative output:

   ```
   prometheus_target_interval_length_seconds{interval="15s",quantile="0.5"} 15.0004
   prometheus_target_interval_length_seconds{interval="15s",quantile="0.9"} 15.0011
   prometheus_target_interval_length_seconds{interval="15s",quantile="0.99"} 15.0019
   prometheus_target_interval_length_seconds_sum{interval="15s"} 9012.4
   prometheus_target_interval_length_seconds_count{interval="15s"} 601
   ```

4. Compute a real p95 latency from the histogram (this is the payoff of the `le` label):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
     'query=histogram_quantile(0.95, sum by (le) (rate(prometheus_http_request_duration_seconds_bucket[5m])))' \
     | jq -r '.data.result[0].value[1]'
   ```

**Comprehension check**

- **Q4.1** A histogram with 10 explicit buckets is exposed for a single `handler` value. How many time series does that one histogram produce in total, and which series is guaranteed to be the largest? Explain why.
- **Q4.2** What does the label `le="0.2"` mean for a `_bucket` series, and why must the value of `le="0.2"` always be ≥ the value of `le="0.1"`?
- **Q4.3** Both histograms and summaries expose `_sum` and `_count`. Give the operational reason you can *aggregate a histogram across instances* but generally *cannot* aggregate a summary's `quantile` series. Tie your answer to where the quantile is computed.
- **Q4.4** In `histogram_quantile(0.95, sum by (le) (rate(...[5m])))`, why is `by (le)` mandatory, and what would break if you aggregated *away* the `le` label instead?

---

### Exercise 5 — Cardinality: the failure mode of labels

Series count is the product of distinct label‑value combinations. A single ill‑chosen label (a user ID, a full URL, a request ID) multiplies your series count without bound. This is the single most common way to fall over a Prometheus server, and 2.4 expects you to reason about it *quantitatively*.

1. Ask the TSDB directly which metric names and label pairs dominate memory:

   ```bash
   curl -s http://localhost:9090/api/v1/status/tsdb | jq '{
     total_series: .data.headStats.numSeries,
     top_metrics:  (.data.seriesCountByMetricName[:5]),
     top_labels:   (.data.labelValueCountByLabelName[:5])
   }'
   ```

   Representative output:

   ```json
   {
     "total_series": 1284,
     "top_metrics": [
       { "name": "node_cpu_seconds_total", "value": 64 },
       { "name": "prometheus_http_request_duration_seconds_bucket", "value": 210 }
     ],
     "top_labels": [
       { "name": "__name__", "value": 312 },
       { "name": "le",       "value": 26 }
     ]
   }
   ```

2. Compute total active series two ways and reconcile them:

   ```bash
   # From the TSDB head stats:
   curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.headStats.numSeries'

   # From PromQL, using the "matches any non-empty name" idiom:
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count({__name__=~".+"})' \
     | jq -r '.data.result[0].value[1]'
   ```

3. Model a cardinality bomb *on paper before you cause one*. Suppose you add a label `user_id` (10,000 distinct users) to `api_http_requests_total`, which already has `method` (5) × `status` (6) × `handler` (40) across `instance` (3):

   ```bash
   echo "before: $((5*6*40*3))"
   echo "after (+user_id): $((5*6*40*3*10000))"
   ```

   ```
   before: 3600
   after (+user_id): 36000000
   ```

4. Find the current worst offender by name and decide whether its cardinality is *structural* (bounded) or *unbounded*:

   ```bash
   curl -s http://localhost:9090/api/v1/status/tsdb \
     | jq -r '.data.seriesCountByMetricName[] | "\(.value)\t\(.name)"' | sort -rn | head
   ```

**Comprehension check**

- **Q5.1** Give the formula for the number of series produced by one metric name, in terms of its labels. Why is *adding one high‑cardinality label* categorically worse than adding one low‑cardinality label?
- **Q5.2** In step 3, one label turned 3,600 series into 36,000,000. Classify `user_id` as bounded or unbounded cardinality, and state the general rule for what should *never* become a label value.
- **Q5.3** The idiom `count({__name__=~".+"})` counts all series. Why `".+"` and not `".*"`, and why is `count(...)` here safe on a lab but potentially expensive on a large production TSDB?
- **Q5.4** `le` (histogram buckets) and `quantile` (summaries) are technically high‑ish cardinality labels you introduce *on purpose*. Why are they acceptable when `user_id` is not? What bounds them?

---

### Exercise 6 — Rewriting labels at ingestion with relabeling

Labels are not immutable facts from the exporter — you shape them. `relabel_configs` act on the special `__*` labels (target labels, `__address__`, `__meta_*` from service discovery) *before* the scrape; `metric_relabel_configs` act on every sample's labels *after* the scrape. Mastering the difference is core to 2.4.

1. Add a scrape job that **rewrites the instance label** and **drops noisy metrics**. Append this to `prometheus.yml`:

   ```yaml
     - job_name: node-relabeled
       static_configs:
         - targets: ['localhost:9100']
       relabel_configs:
         # Derive a clean host label from __address__ (strip the port)
         - source_labels: [__address__]
           regex: '([^:]+):.*'
           target_label: host
           replacement: '$1'
         # Overwrite instance with a friendly name
         - source_labels: [__address__]
           regex: 'localhost:9100'
           target_label: instance
           replacement: 'edge-node-01'
       metric_relabel_configs:
         # Drop a whole family after scraping — it never hits the TSDB
         - source_labels: [__name__]
           regex: 'go_.*'
           action: drop
   ```

2. Reload configuration without restarting (requires `--web.enable-lifecycle`, on by default in the image via flag — otherwise `docker restart prom`):

   ```bash
   curl -s -X POST http://localhost:9090/-/reload || docker restart prom
   sleep 20
   ```

3. Confirm the relabeled target carries the rewritten `instance` and the new `host` label:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=up{job="node-relabeled"}' \
     | jq '.data.result[0].metric | {instance, host, job}'
   ```

   Expected:

   ```json
   { "instance": "edge-node-01", "host": "localhost", "job": "node-relabeled" }
   ```

4. Confirm the `go_*` family was dropped for this job only:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count(go_goroutines{job="node-relabeled"})' \
     | jq '.data.result | length'
   ```

   Expected: `0` (dropped) — while `count(go_goroutines{job="prometheus"})` still returns `1`.

**Comprehension check**

- **Q6.1** State the timing difference between `relabel_configs` and `metric_relabel_configs`. Which one can act on `__meta_kubernetes_pod_label_*` labels, and why can't the other?
- **Q6.2** In step 1 the `drop` action targets `__name__ =~ "go_.*"`. Does dropping here save scrape bandwidth, storage, both, or neither? Explain what "after the scrape" costs you.
- **Q6.3** You rewrote `instance` to `edge-node-01`. What risk does overwriting `instance` with a non‑unique value create if you later add a second target to this job?
- **Q6.4** Service‑discovery labels like `__meta_ec2_tag_Name` are visible during relabeling but never appear in stored series. How do you *promote* one into a permanent label, and what happens if you don't?

---

## Answers

<details>
<summary>Click to reveal answers to all comprehension checks</summary>

### Exercise 1

**Q1.1** — Metric name: `node_cpu_seconds_total`. Labels: `{cpu="0", mode="idle"}`. Value: `20356.54` (a `float64`). The absent fourth component is the **timestamp** (`int64`, milliseconds since the Unix epoch). The text exposition format normally omits it; **Prometheus supplies it at scrape time**, stamping the sample with the moment of the scrape. (A stored sample = name + labels + value + timestamp.)

**Q1.2** — They are **target labels**, attached by Prometheus during ingestion, not emitted by the exporter. `instance` and `job` come from the scrape config (`instance` defaults to the target's `__address__`, `job` from `job_name`); `env` and `region` come from the `labels:` block under that job's `static_configs`. All are applied at scrape time via the relabeling pipeline, *after* the raw text is fetched.

**Q1.3** — A counter only ever **monotonically increases** (it resets to 0 only on process restart); it never decreases during a process's life. The raw accumulated value is meaningless on its own, so `rate()` (and `irate()`/`increase()`) exists to compute per‑second change while transparently handling counter resets.

**Q1.4** — 4 CPUs × 8 modes = **32 series** for that single metric name. General rule: a metric name produces one series **per distinct combination of label values** — the count is the product (Cartesian) of the distinct values of each label, restricted to combinations that actually occur.

### Exercise 2

**Q2.1** — `{__name__="up", job="node"}`. The reserved label carrying the name is **`__name__`**.

**Q2.2** — The two regex operators are `=~` (matches) and `!~` (does not match). Prometheus regexes are **fully anchored** — implicitly wrapped in `^(?:...)$` — so `=~"scrape_.+"` matches strings that begin with `scrape_`, and it does **not** match `node_scrape_x` (that string doesn't start at `scrape_`).

**Q2.3** — A vector selector must contain at least one matcher that does **not** match the empty string. `.*` matches the empty string (and series lacking the label entirely), so `{job=~".*"}` would select *everything*, including nameless series, and is rejected. `.+` requires at least one character, so `{job=~".+"}` is a valid non‑empty matcher.

**Q2.4** — `__`‑prefixed labels are reserved for internal use. `__address__` and `__meta_*` exist **only during the relabeling phase**; after relabeling completes they are **stripped** before storage. That's why they never appear in query results — they were consumed to derive real labels like `instance`, not persisted.

### Exercise 3

**Q3.1** — `instance` becomes `localhost:9100`, derived from the special **`__address__`** label (the `host:port` Prometheus was told to scrape). Unless you relabel it, `instance` == `__address__`.

**Q3.2** — The **`job`** and/or **`instance`** target labels differ (here both differ, or at minimum `job`). Because every series is uniquely keyed by its *full* label set, `process_cpu_seconds_total{job="a",instance="..."}` and `process_cpu_seconds_total{job="b",instance="..."}` are distinct series and cannot collide.

**Q3.3** — `external_labels` are applied **only to data leaving the server** — remote‑write, federation (`/federate`), and alerts sent to Alertmanager — never to locally stored samples. So a local query for `up{monitor="pca-lab"}` finds nothing. `monitor="pca-lab"` *would* appear on the receiving side of remote‑write/federation, or on the labels of an alert in Alertmanager.

**Q3.4** — By default Prometheus **honours target labels over exposed labels**: the target's `job` wins and the exporter's clashing `job` is renamed to **`exported_job`** (generally `exported_<label>`). Setting `honor_labels: true` in the scrape config reverses this, letting the exporter's label take precedence (used for pushgateway/federation).

### Exercise 4

**Q4.1** — 10 buckets + `_sum` + `_count` = **12 series** for one `handler`. The **`+Inf` bucket is always the largest** (equal to `_count`), because buckets are *cumulative* — each counts all observations ≤ its `le`, and `+Inf` counts every observation.

**Q4.2** — `le="0.2"` means "count of observations whose value was **less than or equal to 0.2**." Because buckets are cumulative, the `le="0.2"` bucket necessarily includes everything counted by `le="0.1"` plus anything in `(0.1, 0.2]`, so its value can never be smaller.

**Q4.3** — A histogram exposes raw cumulative bucket counts, so you can **sum bucket counts across instances** and *then* compute a quantile with `histogram_quantile` — the math is associative. A summary computes its **quantiles client‑side, per instance**, and there is no correct way to average pre‑computed quantiles (the p95 of two hosts is not the average of their p95s). Hence summaries don't aggregate; histograms do. The distinction hinges on *where the quantile is computed*.

**Q4.4** — `histogram_quantile` needs the **per‑bucket distribution**, so the `le` label must survive the aggregation; `by (le)` preserves it while collapsing everything else. If you aggregated `le` away, all bucket boundaries would merge into a single number, the cumulative curve would be destroyed, and the function could not interpolate a quantile — you'd get nonsense or an empty result.

### Exercise 5

**Q5.1** — For one metric name, series = product over its labels of `(distinct values of that label)`, counting only combinations that occur. Adding a low‑cardinality label multiplies by a small constant; adding a *high‑cardinality* label multiplies by a large (or unbounded) factor, so the total explodes multiplicatively, not additively.

**Q5.2** — `user_id` is **unbounded** cardinality (grows with your user base, potentially without limit). Rule: values that are effectively unbounded or unique per event — user IDs, email addresses, full URLs/paths with IDs, request/trace IDs, timestamps, container IDs — must **never** be label values. Put them in logs/traces, not metric labels.

**Q5.3** — `".+"` requires ≥1 character, matching every real metric name (every series has a non‑empty `__name__`); `".*"` would be an all‑empty‑matching selector and is rejected. `count({__name__=~".+"})` must *touch every series* to count it — trivial on a lab TSDB, but on a multi‑million‑series server it's an expensive full scan and should be replaced by `/api/v1/status/tsdb` head stats.

**Q5.4** — `le` and `quantile` are **bounded by design**: the number of buckets/quantiles is fixed at instrumentation time (typically 5–15) and does not grow with traffic or users. `user_id` grows without bound with the population. Bounded, developer‑controlled cardinality is acceptable; open‑ended, data‑driven cardinality is not.

### Exercise 6

**Q6.1** — `relabel_configs` run **before the scrape**, on the target's `__*` labels (including `__address__` and `__meta_*` service‑discovery labels), to decide *whether and how* to scrape a target. `metric_relabel_configs` run **after the scrape**, on each sample's labels, to filter/rewrite ingested series. Only `relabel_configs` can see `__meta_kubernetes_pod_label_*`, because those `__meta_*` labels exist only during target relabeling and are gone before samples arrive.

**Q6.2** — Dropping in `metric_relabel_configs` happens **after the scrape**, so it saves **storage (and TSDB memory/index cost) but not scrape bandwidth or the CPU to parse** — Prometheus still fetched and decoded the `go_*` series, then discarded them before writing. To save the network/parse cost you'd need the exporter to stop exposing them (not possible via relabeling).

**Q6.3** — `instance` must be **unique within a job** (with `job`, it's the target's identity). Overwriting it with a constant like `edge-node-01` means a second target in the same job would produce the *same* `{job, instance}` key, causing series collisions / duplicate‑sample "out of order" errors and making the two targets indistinguishable.

**Q6.4** — Promote it with a relabeling rule that copies the `__meta_*` label into a normal `target_label` (e.g. `source_labels: [__meta_ec2_tag_Name]` → `target_label: node_name`) *during* `relabel_configs`. If you don't copy it before the scrape completes, the `__meta_*` label is **stripped and lost** — it never becomes queryable.

</details>

---

### Sources

- Prometheus — *Data model*: https://prometheus.io/docs/concepts/data_model/
- Prometheus — *Metric types* (counter, gauge, histogram, summary): https://prometheus.io/docs/concepts/metric_types/
- Prometheus — *Jobs and instances* (`up`, `job`, `instance`, scrape‑synthesised metrics): https://prometheus.io/docs/concepts/jobs_instances/
- Prometheus — *Querying basics* (selectors, matchers, empty‑matcher rule): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — *Configuration* (`relabel_configs`, `metric_relabel_configs`, `honor_labels`, `external_labels`): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — *Metric and label naming / cardinality guidance*: https://prometheus.io/docs/practices/naming/ and https://prometheus.io/docs/practices/instrumentation/#do-not-overuse-labels
- Prometheus — *TSDB status API* (`/api/v1/status/tsdb`): https://prometheus.io/docs/prometheus/latest/querying/api/#tsdb-stats
- CNCF — *PCA Curriculum*: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf