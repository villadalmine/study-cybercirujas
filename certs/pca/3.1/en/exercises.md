# Topic 3.1 — Metrics

> **Guided lab exercises.** You will stand up a real Prometheus server, scrape its own instrumentation and a `node_exporter`, and read the raw metric stream by hand. The goal is not to memorize definitions but to *see*, in the wire format, what a counter, a gauge, a histogram and a summary actually are — and why that distinction changes how you query them.

**Curriculum reference:** CNCF Prometheus Certified Associate — Observability Concepts / Metrics, Data Model and Labels, Exposition Format. Source: <https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf>

**Primary docs used throughout:**
- Data model — <https://prometheus.io/docs/concepts/data_model/>
- Metric types — <https://prometheus.io/docs/concepts/metric_types/>
- Exposition formats — <https://prometheus.io/docs/instrumenting/exposition_formats/>
- Metric and label naming — <https://prometheus.io/docs/practices/naming/>
- Histograms and summaries — <https://prometheus.io/docs/practices/histograms/>

**Prerequisites:** Docker + Docker Compose, `curl`, and a browser. No prior Prometheus install.

---

## Exercise 0 — Bring up the lab

You need a metrics *producer* (something exposing a `/metrics` endpoint) and a metrics *consumer* (Prometheus, which is also itself a producer). We use Prometheus's own endpoint as the teaching artifact because it exposes all four metric types at once, plus a `node_exporter` for richer counters and gauges.

1. Create a working directory and a `prometheus.yml`:

   ```yaml
   # prometheus.yml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']

     - job_name: node
       static_configs:
         - targets: ['node-exporter:9100']
   ```

2. Create a `docker-compose.yml`:

   ```yaml
   services:
     prometheus:
       image: prom/prometheus:v2.53.0
       ports:
         - "9090:9090"
       volumes:
         - ./prometheus.yml:/etc/prometheus/prometheus.yml

     node-exporter:
       image: prom/node-exporter:v1.8.1
       ports:
         - "9100:9100"
   ```

3. Launch and wait ~30 s so at least two scrapes have happened:

   ```bash
   docker compose up -d
   sleep 30
   ```

4. Confirm both targets are `UP`:

   ```bash
   curl -s 'http://localhost:9090/api/v1/targets' \
     | grep -o '"health":"[a-z]*"'
   ```

   Expected (order may vary):

   ```
   "health":"up"
   "health":"up"
   ```

   You can also open <http://localhost:9090/targets> in a browser.

**Comprehension check**

- **Q0.1** — The Prometheus config tells `prometheus` to scrape the target `localhost:9090`, yet Prometheus runs inside its own container. Why does `localhost` resolve to the right process here, while the `node` job must use the service name `node-exporter:9100` instead of `localhost:9100`?
- **Q0.2** — Prometheus is described as a *pull*-based system. Based on this setup, who initiates the network connection at scrape time — the Prometheus server, or the `/metrics` endpoint being scraped?

---

## Exercise 1 — Read the exposition format

Every target speaks the same text-based **exposition format**. Learn to read it before touching PromQL.

1. Fetch the raw stream Prometheus exposes about itself:

   ```bash
   curl -s http://localhost:9090/metrics | head -n 20
   ```

   You will see repeating triples of `# HELP`, `# TYPE`, and one or more sample lines, for example:

   ```
   # HELP go_goroutines Number of goroutines that currently exist.
   # TYPE go_goroutines gauge
   go_goroutines 42
   # HELP prometheus_http_requests_total Counter of HTTP requests.
   # TYPE prometheus_http_requests_total counter
   prometheus_http_requests_total{code="200",handler="/metrics"} 7
   prometheus_http_requests_total{code="200",handler="/-/ready"} 2
   ```

2. Inspect the HTTP headers to see how the format version is advertised:

   ```bash
   curl -sI http://localhost:9090/metrics | grep -i content-type
   ```

   Expected:

   ```
   Content-Type: text/plain; version=0.0.4; charset=utf-8
   ```

3. Isolate a single metric family and read its structure carefully:

   ```bash
   curl -s http://localhost:9090/metrics \
     | grep '^prometheus_http_requests_total'
   ```

   Expected (values and label sets vary):

   ```
   prometheus_http_requests_total{code="200",handler="/metrics"} 12
   prometheus_http_requests_total{code="200",handler="/-/healthy"} 3
   prometheus_http_requests_total{code="200",handler="/api/v1/targets"} 1
   ```

**Comprehension check**

- **Q1.1** — Decompose the line `prometheus_http_requests_total{code="200",handler="/metrics"} 12` into its parts. Name each part and state what a `# TYPE` line and a `# HELP` line each contribute.
- **Q1.2** — In step 3 you saw *three lines* that all share the metric name `prometheus_http_requests_total`. Are these one time series or three? What makes them distinct?
- **Q1.3** — The sample lines here have no trailing number after the value. The exposition format allows an optional timestamp there. If a target omits it, what timestamp does Prometheus attach to the sample, and why is omitting it the recommended default?

---

## Exercise 2 — Counters: monotonic, and never read raw

A **counter** is a cumulative metric that only goes up (or resets to zero on process restart). You almost never look at its raw value; you look at its *rate of change*.

1. Sample a counter twice, ~20 s apart, and watch it climb:

   ```bash
   curl -s http://localhost:9090/metrics | grep 'promhttp_metric_handler_requests_total{code="200"'
   sleep 20
   curl -s http://localhost:9090/metrics | grep 'promhttp_metric_handler_requests_total{code="200"'
   ```

   Expected — the second value is larger:

   ```
   promhttp_metric_handler_requests_total{code="200"} 8
   promhttp_metric_handler_requests_total{code="200"} 10
   ```

2. Now query the *rate* instead of the raw value. Open <http://localhost:9090/graph> or use the API:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(node_cpu_seconds_total{mode="idle"}[1m])'
   ```

   Expected (abbreviated) — a small per-second fraction, one result per CPU:

   ```json
   {"status":"success","data":{"resultType":"vector","result":[
     {"metric":{"cpu":"0","mode":"idle"},"value":[1733680000,"0.98"]},
     {"metric":{"cpu":"1","mode":"idle"},"value":[1733680000,"0.97"]}
   ]}}
   ```

3. Contrast: run the same query but on the *raw* counter, and note the number is huge and monotonically growing — meaningless as an instantaneous rate:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=node_cpu_seconds_total{mode="idle",cpu="0"}'
   ```

   Expected — a large accumulating value like `"48213.7"`.

**Comprehension check**

- **Q2.1** — Why is the raw value `48213.7` from step 3 almost never useful on a dashboard, while `rate(...[1m])` from step 2 is?
- **Q2.2** — A counter *resets to 0* when its process restarts. If Prometheus naïvely computed `current - previous` across a restart it would get a large negative number. How does `rate()` / `increase()` handle a counter reset, and what does this imply about computing counter deltas by hand?
- **Q2.3** — By convention this metric is named `..._total`. What does the `_total` suffix signal to a reader, and which metric type does it conventionally mark?

---

## Exercise 3 — Gauges: they go up *and* down

A **gauge** represents a value that can rise or fall — a temperature, a queue depth, a memory footprint, a count of in-flight requests.

1. Read a gauge directly — its instantaneous value *is* meaningful:

   ```bash
   curl -s http://localhost:9090/metrics | grep '^prometheus_tsdb_head_series'
   ```

   Expected:

   ```
   # HELP prometheus_tsdb_head_series Total number of series in the head block.
   # TYPE prometheus_tsdb_head_series gauge
   prometheus_tsdb_head_series 1361
   ```

2. Watch a gauge that oscillates. Sample goroutine count and memory a few times:

   ```bash
   for i in 1 2 3; do
     curl -s http://localhost:9090/metrics \
       | grep -E '^(go_goroutines|process_resident_memory_bytes) '
     sleep 5
   done
   ```

   Expected — values wobble both directions between samples:

   ```
   go_goroutines 44
   process_resident_memory_bytes 8.7138304e+07
   go_goroutines 41
   process_resident_memory_bytes 8.7392256e+07
   go_goroutines 43
   process_resident_memory_bytes 8.7130112e+07
   ```

3. Find a special-case gauge — an **info metric**. Its value is always `1`; the *labels* carry the payload:

   ```bash
   curl -s http://localhost:9090/metrics | grep '^prometheus_build_info'
   ```

   Expected:

   ```
   prometheus_build_info{branch="HEAD",goversion="go1.22.4",revision="...",version="2.53.0"} 1
   ```

**Comprehension check**

- **Q3.1** — For the counter in Exercise 2 you needed `rate()` to get a useful number. For `prometheus_tsdb_head_series` in step 1 you read the raw value directly. State the rule of thumb: when do you wrap a metric in `rate()`/`increase()`, and when do you read it raw?
- **Q3.2** — Applying `rate()` to `go_goroutines` is a modeling error. Why is it wrong to apply counter-oriented functions to a gauge?
- **Q3.3** — `prometheus_build_info` is *typed* as a gauge but its value never changes from `1`. What is the point of such a metric, and how would you use it in a query to attach the `version` label to another series?

---

## Exercise 4 — Histograms: buckets you can aggregate

A **histogram** samples observations (usually latencies or sizes) into a set of **cumulative buckets**, and exposes three companion series per label set: `_bucket`, `_sum`, and `_count`.

1. Read a complete histogram family:

   ```bash
   curl -s http://localhost:9090/metrics \
     | grep 'prometheus_http_request_duration_seconds'
   ```

   Expected (abbreviated — one `handler` shown):

   ```
   # TYPE prometheus_http_request_duration_seconds histogram
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="0.1"}  40
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="0.2"}  42
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="0.4"}  42
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="1"}    42
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="+Inf"} 42
   prometheus_http_request_duration_seconds_sum{handler="/metrics"}   1.234
   prometheus_http_request_duration_seconds_count{handler="/metrics"} 42
   ```

2. Read the buckets carefully. `le` means *less than or equal to*. Confirm they are **cumulative**: each bucket count includes everything in the smaller buckets. Note that the `le="+Inf"` bucket count equals the `_count` value.

3. Compute a quantile *at query time* from the buckets:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=histogram_quantile(0.9, rate(prometheus_http_request_duration_seconds_bucket[5m]))'
   ```

   Expected — an estimated 90th-percentile latency in seconds, e.g. `"0.0921"`.

4. Compute an *average* observation from `_sum` and `_count`:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_request_duration_seconds_sum[5m]) / rate(prometheus_http_request_duration_seconds_count[5m])'
   ```

   Expected — a small average duration in seconds, e.g. `"0.031"`.

**Comprehension check**

- **Q4.1** — The `le="0.1"` bucket shows `40` and `le="0.2"` shows `42`. How many observations fell into the half-open interval `(0.1, 0.2]`? What property of the buckets makes this a simple subtraction?
- **Q4.2** — Why must the histogram bucket boundaries be chosen *before* you know your data's distribution, and what goes wrong with your `histogram_quantile` estimate if all your latencies fall between two adjacent bucket boundaries?
- **Q4.3** — `histogram_quantile(0.9, rate(..._bucket[5m]))` wraps the bucket series in `rate()` first. Given that `_bucket` series are counters, explain why the `rate()` is required rather than optional.
- **Q4.4** — You run 10 replicas of a service, each exposing this histogram. Explain why you can `sum by (le) (rate(..._bucket[5m]))` across all 10 and *then* apply `histogram_quantile` to get a correct fleet-wide percentile.

---

## Exercise 5 — Summaries: client-side quantiles, and why they don't add up

A **summary** also tracks observations, but it computes selected **φ-quantiles on the client** and ships them as pre-computed numbers, alongside `_sum` and `_count`. It has **no buckets**.

1. Read a summary family (Go's GC pause metric is a classic summary):

   ```bash
   curl -s http://localhost:9090/metrics | grep '^go_gc_duration_seconds'
   ```

   Expected:

   ```
   # TYPE go_gc_duration_seconds summary
   go_gc_duration_seconds{quantile="0"}    3.9e-05
   go_gc_duration_seconds{quantile="0.25"} 6.7e-05
   go_gc_duration_seconds{quantile="0.5"}  9.2e-05
   go_gc_duration_seconds{quantile="0.75"} 0.000133
   go_gc_duration_seconds{quantile="1"}    0.000456
   go_gc_duration_seconds_sum   0.012345
   go_gc_duration_seconds_count 87
   ```

2. Notice what is **absent**: there is no `_bucket` and no `le` label. The `quantile="0.5"` line already *is* the median — no `histogram_quantile` function is involved.

3. Try (and reason about) an aggregation that is *invalid*. Suppose two instances each report `quantile="0.99"`. Averaging those two numbers does **not** give the fleet-wide 99th percentile:

   ```bash
   # Conceptually invalid — averaging pre-computed quantiles is mathematically wrong:
   # avg(go_gc_duration_seconds{quantile="0.99"})   # DO NOT trust this across instances
   ```

4. Confirm the one aggregation that *is* valid on a summary — the average, from the two additive series:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(go_gc_duration_seconds_sum[5m]) / rate(go_gc_duration_seconds_count[5m])'
   ```

   Expected — average GC pause in seconds, e.g. `"0.00013"`.

**Comprehension check**

- **Q5.1** — List every observable difference between the histogram output in Exercise 4 and the summary output in Exercise 5. Which series do they *share*?
- **Q5.2** — Where is the quantile computed for a summary versus for a histogram, and at what moment in time (write path vs. query path)?
- **Q5.3** — Why can you *not* aggregate a summary's `quantile="0.99"` across instances, whereas you *can* aggregate a histogram's buckets? Tie your answer to Q4.4.
- **Q5.4** — Give one scenario where a summary is the better choice and one where a histogram is, based on this trade-off (aggregatability and configurable quantiles vs. exactness and cheap client cost).

---

## Exercise 6 — The data model: labels, cardinality, and naming

Metrics are only as good as their label design. Here you feel *cardinality* directly.

1. Count how many distinct time series a single metric name expands into because of its labels:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count(node_cpu_seconds_total)'
   ```

   Expected — one series per `(cpu, mode)` pair, e.g. `"32"` on an 8-core host with 4 CPU modes... actually `8 cores × ~8 modes`, e.g. `"64"`.

2. See the label dimensions that produce that fan-out:

   ```bash
   curl -s http://localhost:9090/metrics | grep '^node_cpu_seconds_total' | head
   ```

   Expected:

   ```
   node_cpu_seconds_total{cpu="0",mode="idle"}   48213.7
   node_cpu_seconds_total{cpu="0",mode="system"}   611.2
   node_cpu_seconds_total{cpu="0",mode="user"}    1044.9
   node_cpu_seconds_total{cpu="1",mode="idle"}   48090.1
   ...
   ```

3. Reason about a **bad** label. Imagine adding a label `request_id="a1b2c3..."` to an HTTP counter. Each unique request creates a brand-new, never-repeating time series. Do **not** run this against real infra — just hold the picture: a metric with an unbounded label is a memory bomb.

4. Check naming conventions against a real metric. `node_cpu_seconds_total` encodes `namespace_subsystem_unit_suffix`. Identify each piece and confirm the unit is a **base unit** (seconds, not milliseconds).

**Comprehension check**

- **Q6.1** — Give the exact definition of a Prometheus *time series* in terms of metric name and labels. Adding one new value to one existing label multiplies series count how?
- **Q6.2** — Why is `request_id` (or `email`, `user_id`, full URL path with IDs) a dangerous label, while `mode` and `cpu` are safe? What is the property that separates them?
- **Q6.3** — Decompose `node_cpu_seconds_total` into namespace, name, unit and suffix. Per the naming best-practices doc, why is the unit `seconds` and not `milliseconds`, and why `_total` rather than `_count`?
- **Q6.4** — The label `__name__` was never written explicitly in any output, yet it exists on every series. What is it, and what does the selector `{__name__="go_goroutines"}` do?

---

## Exercise 7 — Tear down

```bash
docker compose down -v
```

Confirm the containers are gone:

```bash
docker ps --filter "name=prometheus" --filter "name=node-exporter"
```

Expected — an empty list (only the header row).

---

<details>
<summary><strong>Answers</strong> (click to expand)</summary>

### Exercise 0

**A0.1** — Prometheus scrapes the target string it is *given*, resolved from *its own container's* network namespace. For the `prometheus` job, `localhost:9090` is resolved inside the Prometheus container, where the Prometheus process itself listens on `9090` — so it scrapes itself. `node-exporter` runs in a *different* container, so `localhost` there would point back at the Prometheus container, not the exporter. Under Docker Compose, containers reach each other by service name over the shared network, so the exporter is addressed as `node-exporter:9100`.

**A0.2** — The **Prometheus server** initiates every connection. Pull means Prometheus makes an outbound HTTP GET to each target's `/metrics` endpoint on each `scrape_interval`. The target is a passive HTTP server; it never pushes. (Push exists only via the separate Pushgateway for short-lived batch jobs.)

### Exercise 1

**A1.1** — `prometheus_http_requests_total` is the **metric name**; `{code="200",handler="/metrics"}` is the **label set** (key/value pairs, values are always strings); `12` is the **sample value** (a float64). An optional timestamp could follow. The `# TYPE` line declares the metric's type (`counter`, `gauge`, `histogram`, `summary`, or `untyped`) so Prometheus and tooling know how to treat it; the `# HELP` line is a human-readable description surfaced in the UI. Both are metadata comments, one per metric family.

**A1.2** — **Three distinct time series.** A time series is identified by the metric name *plus the full set of labels*. Same name but different `handler` (and/or `code`) values ⇒ different series, each with its own independent value stream over time.

**A1.3** — When the target omits the timestamp, Prometheus stamps the sample with the **scrape time** (the server's clock at the moment of the scrape). Omitting it is recommended because it lets Prometheus own time consistently across all targets, avoids clock-skew and staleness pitfalls, and is what client libraries do by default. Explicit timestamps are reserved for special cases like federation or proxied metrics.

### Exercise 2

**A2.1** — A raw counter value is the total accumulated since process start; it grows without bound and its absolute magnitude depends on uptime, so it says nothing about *current activity*. `rate(...[1m])` gives the per-second average increase over the window — the actual current throughput/utilization, which is what you alert and graph on.

**A2.2** — `rate()` and `increase()` are **counter-reset aware**: when they see the value drop (a reset), they treat it as the counter having gone to 0 and climbed back, rather than a negative delta, so they don't emit a spurious negative spike. Implication: never compute counter deltas by hand with `current - previous` — you'll produce a huge negative number on every restart. Always use the counter functions.

**A2.3** — `_total` signals a **cumulative counter** — monotonically increasing, meant to be consumed with `rate`/`increase`, not read raw. It marks the **counter** type by convention.

### Exercise 3

**A3.1** — Rule of thumb: **counters** (cumulative, `_total`) are wrapped in `rate()`/`increase()` because only their change over time is meaningful. **Gauges** (up-and-down values) are read **raw** — the instantaneous value is itself the answer; you may still apply `avg_over_time`, `delta`, `deriv`, or `max_over_time` to a gauge, but never `rate`/`increase`.

**A3.2** — `rate()`/`increase()` assume monotonic growth and interpret any decrease as a counter reset. A gauge legitimately decreases all the time, so those functions would silently "correct" real decreases into fake resets, producing nonsense. The type mismatch corrupts the math.

**A3.3** — It is an **info metric**: a constant-`1` gauge whose *labels* carry metadata (version, revision, Go version). Its purpose is to expose slowly-changing/static metadata as a joinable series. You attach its labels to another metric with a vector-matching group, e.g.:
`some_metric * on(instance) group_left(version) prometheus_build_info`
— the `group_left(version)` copies the `version` label onto `some_metric`'s results.

### Exercise 4

**A4.1** — `42 − 40 = 2` observations fell in `(0.1, 0.2]`. It's a simple subtraction because buckets are **cumulative**: `le="0.2"` counts *everything ≤ 0.2*, which already includes everything `≤ 0.1`, so the difference isolates the band between them.

**A4.2** — Bucket boundaries are baked into the instrumentation at write time, before you can know the runtime distribution. `histogram_quantile` estimates the quantile by **linear interpolation within the bucket** the quantile lands in. If all observations pile up between two adjacent boundaries, that bucket is very wide relative to your data, and interpolation across it is coarse — the percentile estimate can be badly off. Fix: choose buckets that bracket your expected latency range with enough resolution (or use native/exponential histograms).

**A4.3** — `_bucket` series are **counters** (each is a cumulative count that only rises). `histogram_quantile` needs the *rate of observations per bucket over the window*, i.e. the recent shape of the distribution — not the all-time totals since process start. `rate(..._bucket[5m])` converts each counter into a per-second rate so the quantile reflects *current* traffic; feeding raw counters would compute an all-time quantile dominated by ancient data and would misbehave across restarts.

**A4.4** — Because histogram buckets are **additive across instances**: the number of requests `≤ 0.2s` on the whole fleet is exactly the sum of the per-instance counts `≤ 0.2s`. So `sum by (le) (rate(..._bucket[5m]))` reconstructs a correct fleet-wide cumulative distribution, and `histogram_quantile` on that yields a correct global percentile. (Aggregating pre-computed quantiles, as a summary would force, is *not* valid — see A5.3.)

### Exercise 5

**A5.1** — A summary exposes the base metric name with a `quantile="φ"` label (pre-computed quantile values) plus `_sum` and `_count`. A histogram exposes `_bucket{le="..."}` series plus `_sum` and `_count`, and **no** `quantile` label. Differences: summary has `quantile`/no `le`/no `_bucket`; histogram has `le`/`_bucket`/no `quantile`. **Shared:** both expose `_sum` and `_count`.

**A5.2** — Summary: quantiles are computed **on the client (write path)**, continuously as observations arrive, and shipped as finished numbers. Histogram: only bucket counts are recorded on the client; the quantile is computed **on the server at query time (read path)** by `histogram_quantile`.

**A5.3** — A summary's `quantile="0.99"` is a single scalar already collapsed per instance; you cannot reconstruct the fleet's 99th percentile from ten different 99th percentiles (the 99th of a union is not the average/sum/max of the parts' 99ths). A histogram keeps the raw *bucket counts*, which are additive, so you can merge the distributions first (A4.4) and only then compute the quantile — mathematically valid.

**A5.4** — **Summary** is better when you need exact quantiles for a single instance with no cross-instance aggregation and want the specific φ-quantiles cheaply and precisely (e.g. a per-instance GC pause SLO). **Histogram** is better when you need to aggregate across many instances, compute *arbitrary* quantiles after the fact, or apply the same buckets fleet-wide (e.g. service-level request-latency SLOs) — the near-universal default for RED-style latency.

### Exercise 6

**A6.1** — A time series is uniquely identified by its **metric name together with its complete set of key/value labels** (formally, the label `__name__` plus all other labels). Adding one new value to one label creates one additional series *per existing combination of the other labels* — the total is the **product** (Cartesian) of all label cardinalities, so growth is multiplicative, not additive.

**A6.2** — `request_id`, `email`, full URLs with IDs are **unbounded / high-cardinality**: the set of possible values is effectively infinite and each new value spawns a permanent new series, exhausting memory and disk (cardinality explosion). `mode` and `cpu` are **bounded and low-cardinality** — a small, stable, known set of values. The separating property is whether the label's value space is bounded and stable.

**A6.3** — `node` = namespace/prefix (the exporter/library), `cpu` = the subsystem + `seconds` = base unit + `total` = suffix; full form `node_cpu_seconds_total`. The unit is `seconds` because Prometheus naming practice mandates **base units** (seconds, bytes, ratios 0–1) for consistency across metrics and dashboards — never milliseconds or megabytes. It ends in `_total` (not `_count`) because it is a **cumulative counter**; `_count` is reserved for the observation count of a histogram/summary.

**A6.4** — `__name__` is the **reserved internal label that holds the metric name itself**. Every series carries it implicitly. The selector `{__name__="go_goroutines"}` is exactly equivalent to writing `go_goroutines` — it matches all series of that metric — and because it's a label matcher it also lets you match names by regex, e.g. `{__name__=~"node_cpu_.*"}`.

</details>