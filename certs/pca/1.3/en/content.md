# Aggregating over time — PromQL range-vector aggregation for production SRE

> PCA · Domain: PromQL · Topic 1.3 · Exam weight: 4
> Prerequisite topics: Selecting Data (range vs instant vectors), Rates and Derivatives (`rate`, `increase`).

---

## 1. Motivation and the production architectural problem

Prometheus stores every scrape as a raw sample: a `(timestamp, float64)` pair per series, taken at the scrape interval (commonly 15s or 30s). This raw resolution is correct for storage but *wrong for almost every consumer*:

- **Dashboards undersample.** A 7-day panel rendered ~1000px wide makes Grafana request a query `step` of ~10 minutes. If you plot the raw gauge, Prometheus returns the **single instant sample** nearest each 10-minute step. With a 15s scrape that is **1 of every ~40 samples**; a 2-minute memory spike that occurred *between* two steps is invisible. This is classic **aliasing / undersampling**.
- **Alerts flap.** Firing on a single noisy scrape (`node_load1 > 8`) triggers on one unlucky sample and recovers on the next. You need a statement about a *window of time*, not an instant.
- **SLO / availability math is temporal.** "What fraction of the last 30 days was this target up?" is not answerable from an instant vector — it is an integral over time.
- **Long-range queries are expensive.** Loading 30 days of raw samples for 100k series at query time melts the query engine. You want to pre-aggregate into a coarser series.

**Aggregation over time** is the PromQL answer. The `*_over_time()` family takes a **range vector** (one series sampled across a time window) and collapses the **time dimension** into a single value per series, returning an **instant vector**. It is the temporal dual of *aggregation over dimensions* (topic 1.4: `sum`, `avg`, `topk`, … which collapse the **label dimension** across many series at one instant).

```
                 label dimension  ───────────────────►
                 (aggregate over dimensions: sum/avg/topk...)
   time  │  s1: ● ● ● ● ● ● ● ● ●
   dim   │  s2: ● ● ● ● ● ● ● ● ●
   │     │  s3: ● ● ● ● ● ● ● ● ●
   ▼     │       └──────[5m]──────┘
  (aggregate over time:            avg_over_time(metric[5m])
   *_over_time)                    → one value per series
```

The mental model to lock in for the exam: **`*_over_time` never mixes series together.** It processes each series independently and keeps its full label set. To combine series you *also* need an aggregation operator — the two are composed:

```promql
avg by (job) (avg_over_time(node_load1[5m]))
#   ^^^^^^^^^^^ over dimensions (spatial)
#              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ over time (temporal), per-series first
```

### The critical semantic boundary: raw values vs. rates

`*_over_time` operates on **raw sample values** with **no counter-reset handling and no extrapolation**. This is the single most common production mistake:

- `avg_over_time(node_load1[5m])` — **correct**. `node_load1` is a gauge; averaging raw values is meaningful.
- `sum_over_time(http_requests_total[5m])` — **meaningless**. `http_requests_total` is a monotonic counter; summing its raw cumulative values produces a number with no physical interpretation, and it silently ignores counter resets. To aggregate a counter over time you first convert to a rate (`rate(...)`) and then, if needed, aggregate the rate with a **subquery** (§2.4).

---

## 2. Technical comparison and trade-offs

### 2.1 The `*_over_time` family

All operate on a range vector and return an instant vector with **one sample per input series**, preserving every label.

| Function | Returns per series | Native histogram support | Typical production use |
|---|---|---|---|
| `avg_over_time(v[d])` | arithmetic mean of samples in window | yes | smoothing gauges; average utilisation |
| `min_over_time(v[d])` | minimum sample | no (histograms ignored) | worst-case floor; "was it ever below X" |
| `max_over_time(v[d])` | maximum sample | no (histograms ignored) | **peak/spike detection**, capacity headroom |
| `sum_over_time(v[d])` | sum of samples | yes | integrating a per-scrape *gauge* delta; **never** a counter |
| `count_over_time(v[d])` | number of samples in window | yes (counts) | scrape-density / data-presence checks |
| `quantile_over_time(φ, v[d])` | φ-quantile (0≤φ≤1, linear interpolation) | no | per-series percentile of a gauge over time |
| `stddev_over_time(v[d])` | population standard deviation | no | volatility / noise measurement |
| `stdvar_over_time(v[d])` | population standard variance | no | inputs to anomaly heuristics |
| `last_over_time(v[d])` | most recent sample in window | yes | carry-forward the latest value; **keeps `__name__`** |
| `present_over_time(v[d])` | `1` if ≥1 sample exists | yes | "did this series report at all in the window" |
| `mad_over_time(v[d])` | median absolute deviation | no | robust anomaly detection — **experimental**, needs `--enable-feature=promql-experimental-functions` |

Related but **not** part of the over-time family (they read a range vector to compute change, and they **drop `__name__`**): `rate`, `irate`, `increase`, `delta`, `idelta`, `deriv`, `predict_linear`, `resets`, `changes`, `double_exponential_smoothing` (formerly `holt_winters`, experimental in Prometheus 3.x). And `absent_over_time(v[d])` is a special case: it returns a 1-element `1` vector **only when the range vector is empty**, used to alert on missing data.

**Label behaviour to memorise:** every `*_over_time` function **drops the `__name__` label** — *except* `last_over_time`, which returns an actual stored sample unchanged and therefore keeps the metric name.

### 2.2 `avg_over_time` vs `rate` — both smooth, but they are not interchangeable

| | `avg_over_time(gauge[5m])` | `rate(counter[5m])` |
|---|---|---|
| Input metric type | gauge | counter |
| What it computes | mean of raw values | per-second average increase |
| Counter-reset aware | n/a | yes (handles resets) |
| Extrapolation at window edges | no | yes (extrapolates to window boundaries) |
| Output unit | same as input | input-unit **per second** |
| Wrong use | on a counter → nonsense | on a gauge → nonsense (treats dips as resets) |

### 2.3 Choosing the aggregation for alerting: window function vs `for:`

Three ways to require a condition to persist — each has a distinct failure profile:

| Expression | Fires when… | Behaviour on a single dip | Behaviour on a scrape gap |
|---|---|---|---|
| `metric > X` **`for: 5m`** | *every* evaluation in 5m exceeds X | one dip **resets** the timer | a missing eval can reset/extend timing |
| `min_over_time(metric[5m]) > X` | the *minimum* over 5m still exceeds X | tolerant only if the dip stays above X | one gap does **not** reset (window still evaluated) |
| `avg_over_time(metric[5m]) > X` | the *mean* over 5m exceeds X | tolerant of brief dips | robust to gaps |
| `max_over_time(metric[5m]) > X` | *any* sample in 5m exceeded X | fires on a single spike | robust to gaps |

Production rule of thumb: use `for:` when you want "continuously true"; use `max_over_time` when you must catch a transient spike that `for:` would miss because the spike lasted less than one evaluation cycle; use `avg_over_time`/`min_over_time` to damp flapping.

### 2.4 Aggregating a *derived* series over time: subqueries

You cannot write `max_over_time(rate(http_requests_total[5m]))` — `rate(...)` is an instant vector, and `*_over_time` needs a range vector. The **subquery** turns an instant expression back into a range vector:

```promql
max_over_time(  rate(http_requests_total[5m])  [30m:1m]  )
#               └─────── inner instant query ───┘  └──┬─┘
#                                                  range:resolution
```

Read as: "evaluate `rate(...[5m])` every 1 minute over the last 30 minutes, then take the maximum." This is how you find the *peak 5-minute request rate over the last half hour* — a common capacity signal.

**Trade-off:** subqueries are expensive. Each output point re-runs the inner query at the sub-resolution; `[30m:1m]` = 30 inner evaluations *per outer step per series*. Prefer a **recording rule** to materialise `rate(...)` and then aggregate the recorded series, if the pattern is used repeatedly (§3).

### 2.5 On-the-fly vs recording-rule downsampling

| | Ad-hoc `*_over_time` at query time | Recording rule (pre-aggregated) |
|---|---|---|
| Query cost | high — loads full range vector each time | low — reads pre-computed series |
| Freshness | always current | lags by `interval` |
| Cardinality impact | none (transient) | adds new series to TSDB |
| Best for | exploration, ad-hoc dashboards | dashboards/alerts hit repeatedly, long ranges |

---

## 3. Complete infrastructure manifests

### 3.1 Prometheus configuration wiring the rule files

`prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 30s        # how often recording/alerting rules run
  external_labels:
    cluster: prod-eu-1
    region: eu-west

rule_files:
  - /etc/prometheus/rules/aggregation_recording.yml
  - /etc/prometheus/rules/aggregation_alerts.yml

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['node1:9100', 'node2:9100', 'node3:9100']
```

### 3.2 Recording rules — temporal downsampling and pre-aggregation

`aggregation_recording.yml`:

```yaml
groups:
  - name: node-load.over-time
    interval: 1m                    # this group evaluates once per minute
    rules:
      # Smoothed 5-minute average load, per instance (dashboard-friendly).
      - record: instance:node_load1:avg_over_time_5m
        expr: avg_over_time(node_load1[5m])

      # Peak load in the last hour — capacity headroom signal.
      - record: instance:node_load1:max_over_time_1h
        expr: max_over_time(node_load1[1h])

      # Volatility of load — feeds anomaly heuristics.
      - record: instance:node_load1:stddev_over_time_1h
        expr: stddev_over_time(node_load1[1h])

  - name: memory.over-time
    interval: 1m
    rules:
      # Worst-case available memory over 10m — undersampling-proof.
      - record: instance:node_memory_MemAvailable_bytes:min_over_time_10m
        expr: min_over_time(node_memory_MemAvailable_bytes[10m])

  - name: request-rate.over-time
    interval: 1m
    rules:
      # Step 1: materialise the per-second rate (counter -> gauge-like).
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))

      # Step 2: aggregate the recorded rate over time WITHOUT a subquery.
      #         Because job:http_requests:rate5m is now a stored series,
      #         a plain range selector works and is cheap.
      - record: job:http_requests:rate5m:max_over_time_30m
        expr: max_over_time(job:http_requests:rate5m[30m])

  - name: availability.slo
    interval: 1m
    rules:
      # Fraction of time the target reported up, over 30 days.
      # avg of a 0/1 gauge over time == uptime ratio.
      - record: instance:up:availability_ratio_30d
        expr: avg_over_time(up[30d])
```

### 3.3 Alerting rules using over-time aggregation

`aggregation_alerts.yml`:

```yaml
groups:
  - name: over-time.alerts
    rules:
      # Sustained high load: mean over 10m, damped against single-scrape noise.
      - alert: NodeLoadHighSustained
        expr: avg_over_time(node_load1[10m]) > 8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Sustained high load on {{ $labels.instance }}"
          description: "10m avg load1 is {{ $value | printf \"%.2f\" }} (>8) on {{ $labels.instance }}."

      # Transient spike detection: any single sample above threshold in 5m.
      - alert: NodeLoadSpike
        expr: max_over_time(node_load1[5m]) > 20
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Load spike on {{ $labels.instance }}"
          description: "Peak load1 in the last 5m reached {{ $value | printf \"%.2f\" }}."

      # Data-presence alert: the series stopped reporting for 10m.
      - alert: NodeMetricAbsent
        expr: absent_over_time(node_load1{instance="node1:9100"}[10m])
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "node_load1 absent from node1 for 10m"
          description: "No samples for node_load1{instance=node1:9100} in the last 10m."

      # Availability SLO breach over the rolling 30d window.
      - alert: TargetAvailabilityBelowSLO
        expr: instance:up:availability_ratio_30d < 0.995
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} below 99.5% availability (30d)"
          description: "30d availability is {{ $value | humanizePercentage }}."
```

### 3.4 Prometheus Operator CRD equivalent (`PrometheusRule`)

For Kubernetes deployments the same rules ship as a CRD that the Operator reconciles into a rules ConfigMap:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: over-time-aggregations
  namespace: monitoring
  labels:
    app.kubernetes.io/part-of: kube-prometheus-stack
    prometheus: k8s          # must match the Prometheus CR ruleSelector
    role: alert-rules
spec:
  groups:
    - name: node-load.over-time
      interval: 1m
      rules:
        - record: instance:node_load1:avg_over_time_5m
          expr: avg_over_time(node_load1[5m])
        - record: instance:node_load1:max_over_time_1h
          expr: max_over_time(node_load1[1h])
    - name: over-time.alerts
      rules:
        - alert: NodeLoadHighSustained
          expr: avg_over_time(node_load1[10m]) > 8
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Sustained high load on {{ $labels.instance }}"
```

---

## 4. CLI commands and real terminal output

### 4.1 Validate rule syntax before shipping

```console
$ promtool check rules /etc/prometheus/rules/aggregation_recording.yml
Checking /etc/prometheus/rules/aggregation_recording.yml
  SUCCESS: 7 rules found
```

### 4.2 Instant query — smoothed gauge (metric name dropped)

```console
$ promtool query instant http://localhost:9090 'avg_over_time(node_load1[5m])'
{instance="node1:9100", job="node"} => 0.42 @[1754640000]
{instance="node2:9100", job="node"} => 1.07 @[1754640000]
{instance="node3:9100", job="node"} => 0.18 @[1754640000]
```

Contrast with `last_over_time`, which **keeps** the metric name:

```console
$ promtool query instant http://localhost:9090 'last_over_time(node_load1[5m])'
node_load1{instance="node1:9100", job="node"} => 0.39 @[1754640000]
node_load1{instance="node2:9100", job="node"} => 1.11 @[1754640000]
```

### 4.3 Range query — showing peak vs raw over a window

```console
$ promtool query range --start=1754639700 --end=1754640000 --step=60 \
      http://localhost:9090 'max_over_time(node_load1{instance="node1:9100"}[5m])'
{instance="node1:9100", job="node"} =>
0.55 @[1754639700]
0.61 @[1754639760]
2.34 @[1754639820]
0.48 @[1754639880]
0.47 @[1754639940]
0.51 @[1754640000]
```

The `2.34` at `1754639820` is a spike that a raw-value plot at this 60s step would have missed entirely — `max_over_time` surfaces it.

### 4.4 Verify scrape density with `count_over_time`

With a 15s scrape interval, a 1-hour window should contain ~240 samples:

```console
$ promtool query instant http://localhost:9090 'count_over_time(up{job="node"}[1h])'
{instance="node1:9100", job="node"} => 240 @[1754640000]
{instance="node2:9100", job="node"} => 240 @[1754640000]
{instance="node3:9100", job="node"} => 173 @[1754640000]   # <-- 28% samples missing
```

`node3` shows 173/240 → intermittent scrape failures. `count_over_time` is your data-completeness probe.

### 4.5 Availability ratio over 30 days

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
       --data-urlencode 'query=avg_over_time(up{instance="node1:9100"}[30d])' | jq .
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": { "instance": "node1:9100", "job": "node" },
        "value": [ 1754640000, "0.9987" ]
      }
    ]
  }
}
```

`0.9987` → 99.87% availability over 30 days.

### 4.6 Subquery: peak 5-minute rate over the last 30 minutes

```console
$ promtool query instant http://localhost:9090 \
      'max_over_time(sum by (job) (rate(http_requests_total[5m]))[30m:1m])'
{job="api"} => 1423.6 @[1754640000]
{job="web"} =>  318.9 @[1754640000]
```

### 4.7 Unit-testing over-time rules with `promtool test rules`

`aggregation_test.yml` — note the deliberate boundary case at `t=0`:

```yaml
rule_files:
  - aggregation_recording.yml

evaluation_interval: 1m

tests:
  - interval: 1m
    input_series:
      # Samples at t = 0m,1m,2m,3m,4m,5m with values 1,2,3,4,5,6
      - series: 'node_load1{instance="node1:9100", job="node"}'
        values: '1 2 3 4 5 6'

    promql_expr_test:
      # A range selector is LEFT-OPEN, RIGHT-CLOSED: (T-5m, T].
      # At eval_time 5m the window (0m, 5m] EXCLUDES the t=0 sample (value 1)
      # and includes t=1..5m (values 2,3,4,5,6). Mean = 20/5 = 4.
      - expr: avg_over_time(node_load1[5m])
        eval_time: 5m
        exp_samples:
          - labels: '{instance="node1:9100", job="node"}'
            value: 4

      - expr: max_over_time(node_load1[5m])
        eval_time: 5m
        exp_samples:
          - labels: '{instance="node1:9100", job="node"}'
            value: 6

      - expr: min_over_time(node_load1[5m])
        eval_time: 5m
        exp_samples:
          - labels: '{instance="node1:9100", job="node"}'
            value: 2

      - expr: count_over_time(node_load1[5m])
        eval_time: 5m
        exp_samples:
          - labels: '{instance="node1:9100", job="node"}'
            value: 5

      # last_over_time keeps the __name__ label.
      - expr: last_over_time(node_load1[5m])
        eval_time: 5m
        exp_samples:
          - labels: 'node_load1{instance="node1:9100", job="node"}'
            value: 6
```

```console
$ promtool test rules aggregation_test.yml
Unit Testing:  aggregation_test.yml
  SUCCESS
```

---

## 5. Verification and failure diagnosis

### 5.1 The range-window / scrape-interval floor — "empty result"

The most frequent failure: **the range window is shorter than (or comparable to) the scrape interval**, so the left-open interval `(T-d, T]` catches too few samples — or none.

- `metric[10s]` with a 15s scrape can select **zero** samples at some evaluation times → the series *silently disappears* from the result.
- **Rule:** make the range at least `4 × scrape_interval` so it reliably contains ≥3–4 samples. For a 15s scrape, `[1m]` is the practical minimum.

Diagnose with `count_over_time`:

```console
$ promtool query instant http://localhost:9090 'count_over_time(node_load1[20s])'
# (empty result — window too small)

$ promtool query instant http://localhost:9090 'count_over_time(node_load1[1m])'
{instance="node1:9100", job="node"} => 4 @[1754640000]
```

### 5.2 Staleness cuts your window short

If a target goes down (or a series stops being exposed), Prometheus writes a **staleness marker** and the series is considered *absent* after `--query.lookback-delta` (default **5m**). Inside an `*_over_time` window that crosses the stale boundary, samples after the last real scrape are **not** counted — your `avg_over_time(...[1h])` may actually average far fewer than an hour's worth of data. Always pair long windows with `count_over_time` to confirm the sample count is what you expect.

### 5.3 Counter misuse — the silent wrong answer

`sum_over_time`/`avg_over_time` on a counter passes every free check (URL resolves, YAML parses, rule loads) and produces a number — a *wrong* one. Verification: assert the metric type.

```console
$ curl -s http://node1:9100/metrics | grep -A1 '^# TYPE http_requests_total'
# TYPE http_requests_total counter        # <-- counter: do NOT *_over_time the raw value
```

If it's a counter, the correct pattern is `rate()` first, then aggregate the rate (recording rule or subquery).

### 5.4 Memory / cost blow-ups on wide windows × high cardinality

`avg_over_time(some_metric[30d])` over 100k series at 15s = ~172,800 samples/series × 100k ≈ **17 billion samples** materialised per evaluation. Symptoms: slow queries, `query timed out`, evaluation-time spikes on the Prometheus process.

Diagnose:

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
       --data-urlencode 'query=avg_over_time(node_cpu_seconds_total[30d])' \
       -w '\n%{time_total}s\n' -o /dev/null
30.004s        # hit the default 30s query timeout

# Confirm cardinality of the selector:
$ promtool query instant http://localhost:9090 'count(node_cpu_seconds_total)'
{} => 96 @[1754640000]
```

Remedy: pre-aggregate with a recording rule at a coarse `interval`, then query the recorded (low-cardinality, low-frequency) series over the long window.

### 5.5 Verifying a recording rule actually populated

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
       --data-urlencode 'query=instance:node_load1:avg_over_time_5m' | jq '.data.result | length'
3
```

Zero here means the rule group has not evaluated yet (wait one `interval`), the expression is empty (see §5.1), or the group failed to load — check the runtime view:

```console
$ curl -s http://localhost:9090/api/v1/rules | \
      jq '.data.groups[].rules[] | select(.health!="ok") | {name, health, lastError}'
```

### 5.6 Confirming the interval convention when a boundary sample "vanishes"

If a unit test or a hand-computed mean is off by exactly one edge sample, it is the **left-open `(T-d, T]`** convention (§4.7). A `[5m]` window at `T` does **not** include the sample stamped at `T-5m`. Re-derive expected values with that boundary in mind before assuming a bug.

---

## 6. References

- Prometheus — Query functions (`avg_over_time`, `min_over_time`, `max_over_time`, `sum_over_time`, `count_over_time`, `quantile_over_time`, `stddev_over_time`, `stdvar_over_time`, `last_over_time`, `present_over_time`, `mad_over_time`, `absent_over_time`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — Querying basics (instant vs range vectors, range selectors, `offset`, `@` modifier): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — Subquery syntax: https://prometheus.io/docs/prometheus/latest/querying/basics/#subquery
- Prometheus — Aggregation operators (aggregation over dimensions, for contrast): https://prometheus.io/docs/prometheus/latest/querying/operators/#aggregation-operators
- Prometheus — Recording rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — Alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus — Staleness and `--query.lookback-delta`: https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness
- Prometheus — HTTP API (`/api/v1/query`, `/api/v1/query_range`, `/api/v1/rules`): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — `promtool` unit testing for rules: https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus — Feature flags (`--enable-feature=promql-experimental-functions`): https://prometheus.io/docs/prometheus/latest/feature_flags/
- Prometheus Operator — `PrometheusRule` API reference: https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PrometheusRule
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf