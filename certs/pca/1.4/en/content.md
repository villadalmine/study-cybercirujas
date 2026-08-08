# 1.4 Aggregating over dimensions

> PCA Domain 1 — *Observability Concepts / PromQL*. Exam weight: 4.
> Prerequisite mental model: a Prometheus metric is not a number, it is a **set of time series** indexed by a label tuple. Aggregation is the operation that collapses that label space at query time.

---

## 1. The production problem: too many dimensions to look at

A single instrumented metric name in a real cluster is never one series. Take a modestly-sized API fleet instrumented with a standard `http_requests_total` counter. Its cardinality is the Cartesian product of every label's value set:

```
http_requests_total{job, instance, method, code, handler, ...}
```

With 40 pods (`instance`), 5 HTTP methods, 8 status codes, and 30 handlers, that one metric name resolves to `40 × 5 × 8 × 30 = 48,000` distinct series. A human operator, a dashboard panel, or an alert threshold cannot consume 48,000 lines. What the SRE actually wants is a handful of **service-level signals**: total request rate per service, error ratio per status class, p99 latency per route.

**Aggregation operators** are the mechanism that projects the high-dimensional series set down onto the dimensions you care about, summing/averaging/counting across the dimensions you *don't*. This is the query-time half of dimensional reduction; the storage-time half is recording rules (Section 3), which run the *same* aggregation on a schedule and persist a low-cardinality result.

Three architectural forces make this a first-class concern rather than a cosmetic one:

| Force | Consequence if aggregation is done wrong | Correct lever |
|---|---|---|
| **Query cost** | Aggregating 48k series on every dashboard refresh × 12 panels × 30 viewers melts the query engine | Pre-aggregate with recording rules; query the low-cardinality result |
| **Signal legibility** | Per-pod series flap on deploys; alerts page on a single pod's blip | Aggregate to the service level (`by (job)`) so the SLO signal is stable |
| **Counter correctness** | `rate()` and `sum()` do **not** commute — wrong order silently hides counter resets | Always `sum(rate(x[5m]))`, never `rate(sum(x)[5m])` |

That last row is the single most-tested and most-misapplied fact in this domain. It gets its own treatment in Section 5.

### 1.1 The grammar

Every aggregation operator follows one of two equivalent syntactic forms:

```promql
<aggr-op> [ by | without ( <label-list> ) ] ( [ <parameter>, ] <instant-vector> )
<aggr-op> ( [ <parameter>, ] <instant-vector> ) [ by | without ( <label-list> ) ]
```

Both forms are identical in meaning; the grouping clause may appear before or after the parenthesised expression. Three hard rules:

1. **Aggregation operators consume an *instant vector* only.** `sum(http_requests_total[5m])` is a type error — a range vector `[5m]` must first be reduced to an instant vector by a function (`rate`, `avg_over_time`, …).
2. **`by (...)`** keeps *only* the listed labels in the output and drops the metric name (`__name__`) and everything else.
3. **`without (...)`** keeps *everything except* the listed labels, and *also* always strips `__name__`.

`by` and `without` are the "aggregate over these dimensions" knob. `by (job)` means "give me one result per `job`, collapsing every other dimension." `without (instance, pod)` means "collapse only `instance` and `pod`, keep the rest." They are duals; choose whichever names the shorter list, so new labels appearing later default to the safe behaviour (with `without` a new label is *kept*; with `by` a new label is *dropped*).

---

## 2. The operator catalogue and their trade-offs

There are eleven aggregation operators (plus two experimental). They split into three behavioural classes: **reducers** that emit one value per group and drop non-grouped labels, **selectors** that emit a *subset of the original input series with original labels intact*, and **re-labellers** that synthesise a new label.

| Operator | Param | Class | Output value | Keeps original labels? |
|---|---|---|---|---|
| `sum` | — | reducer | Σ of samples in group | No (only `by`/`without` labels) |
| `avg` | — | reducer | arithmetic mean | No |
| `min` / `max` | — | reducer | extreme sample value | No |
| `count` | — | reducer | **number of series** in group | No |
| `stddev` / `stdvar` | — | reducer | population std-dev / variance | No |
| `group` | — | reducer | always `1` (existence marker) | No |
| `quantile` | φ (0–1) | reducer | φ-quantile *across series* | No |
| `topk` | k | **selector** | the k largest samples | **Yes** |
| `bottomk` | k | **selector** | the k smallest samples | **Yes** |
| `count_values` | "label" | re-labeller | count of series sharing each value | New label = the sampled value |
| `limitk` * | k | selector | arbitrary k series (sampling) | Yes |
| `limit_ratio` * | r (−1..1) | selector | deterministic ratio sample | Yes |

`*` `limitk` / `limit_ratio` require `--enable-feature=promql-experimental-functions` (Prometheus ≥ 2.50).

### 2.1 Reducers vs selectors — the label-set difference that breaks queries

This distinction causes more broken dashboards than any other. A **reducer** *destroys* every label not named in the grouping clause:

```promql
sum by (code) (rate(http_requests_total[5m]))
# output series carry only {code="..."} — instance, handler, pod are gone
```

A **selector** (`topk`/`bottomk`) returns *actual input series unchanged*, merely filtered to the k highest/lowest:

```promql
topk(3, rate(http_requests_total[5m]))
# output series still carry {job,instance,method,code,handler,...} — full identity
```

Because `topk`/`bottomk` keep identity, they are perfect for **ad-hoc triage** ("show me the 5 noisiest pods") but dangerous in **alerting rules and recording rules**: the *set* of returned series can change from one evaluation to the next, so `for:` timers reset and alerts flap. Never put `topk`/`bottomk` in an `alert:` expression that drives paging.

`topk`/`bottomk` also accept a grouping clause, meaning "top-k *per group*":

```promql
topk(3, rate(http_requests_total[5m])) by (job)   # 3 noisiest instances within each job
```

### 2.2 `count` vs `sum` vs `count_values`

Three operators that get confused:

| Question | Operator | Example |
|---|---|---|
| "How many series match?" | `count` | `count by (job) (up == 1)` → healthy targets per job |
| "What is the total of the values?" | `sum` | `sum by (job) (up)` → same number *only because up∈{0,1}* |
| "How many series hold each distinct value?" | `count_values` | `count_values("version", node_uname_info)` → one series per OS version, value = how many nodes run it |

`count_values` is the odd one: its string parameter names a **new output label** that receives the *sample value* of each input series, and the result value is the population count. It is the PromQL equivalent of `GROUP BY value` in SQL.

### 2.3 `avg` is not "average of averages"

`avg` computes the unweighted arithmetic mean *across series at a single instant*. This is correct for gauges of comparable weight (e.g. per-node CPU%) but **wrong** for deriving a fleet-wide ratio from per-instance ratios, because instances have unequal traffic. To get a correctly-weighted mean you must aggregate the numerator and denominator separately and divide:

```promql
# WRONG — mean of per-instance error ratios, ignores traffic weight
avg by (job) (rate(http_requests_total{code=~"5.."}[5m]) / rate(http_requests_total[5m]))

# RIGHT — ratio of aggregated rates (traffic-weighted)
  sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))
/ sum by (job) (rate(http_requests_total[5m]))
```

### 2.4 Aggregating *over dimensions* vs aggregating *over time*

The exam name — "aggregating over dimensions" — is deliberately contrasted with "aggregating over time." They are orthogonal axes and use different tools:

| Axis | What collapses | Tool | Input → output |
|---|---|---|---|
| **Over dimensions** (this topic) | the label/series axis, at one timestamp | aggregation operators (`sum`, `avg`, …) | instant vector → instant vector, fewer series |
| **Over time** | the time axis, within one series | `<fn>_over_time`, `rate`, `increase` | range vector → instant vector, same series count |

They compose in a fixed order: reduce time first (per series), then reduce dimensions:

```promql
sum by (job) (            # 2) collapse the series/label axis
  rate(                   # 1) collapse the time axis, per series
    http_requests_total[5m]
  )
)
```

Reversing the order (`rate(sum(...)[5m])`) is both a type error *and* a correctness error — see Section 5.

---

## 3. Complete infrastructure: query-time reduction persisted as recording rules

The production pattern is: define the aggregation *once* as a recording rule, let Prometheus evaluate it on a schedule, and point every dashboard and alert at the cheap pre-aggregated series. Naming follows the official convention `level:metric:operations`.

### 3.1 `prometheus.yml` — scrape + rule wiring

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: prod-eu-1

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: api
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: job
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: instance
```

### 3.2 `/etc/prometheus/rules/http.rules.yml` — the aggregations

```yaml
groups:
  - name: http.aggregations
    interval: 30s
    rules:
      # Fleet request rate, collapsing instance/handler/method
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))

      # Same, but retaining the status-code dimension for error-ratio math
      - record: job_code:http_requests:rate5m
        expr: sum by (job, code) (rate(http_requests_total[5m]))

      # Error ratio — traffic-weighted, built from the two rules above
      - record: job:http_requests_errors:ratio5m
        expr: |
            sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))
          /
            sum by (job) (rate(http_requests_total[5m]))

      # p99 latency: histogram aggregation MUST keep the `le` bucket dimension
      - record: job:http_request_duration_seconds:p99_5m
        expr: |
          histogram_quantile(
            0.99,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
          )

      # Fleet health: how many instances of each job are up
      - record: job:up:count
        expr: count by (job) (up == 1)
```

The p99 rule is the canonical "aggregating a histogram over dimensions" pattern and a frequent exam item: you **sum the bucket counters `by (job, le)`** — keeping `le` so the cumulative-bucket structure survives — *then* apply `histogram_quantile`. Averaging pre-computed quantiles across instances is statistically meaningless; you must aggregate the raw buckets.

### 3.3 Alerting rules built on the aggregated series

```yaml
groups:
  - name: http.alerts
    rules:
      - alert: HighErrorRatio
        # Reads the cheap pre-aggregated recording rule, not the raw 48k series
        expr: job:http_requests_errors:ratio5m > 0.05
        for: 10m
        labels:
          severity: page
        annotations:
          summary: "5xx ratio {{ $value | humanizePercentage }} on {{ $labels.job }}"

      - alert: JobUnderReplicated
        expr: job:up:count < 3
        for: 5m
        labels:
          severity: ticket
        annotations:
          summary: "Only {{ $value }} instances up for {{ $labels.job }}"
```

### 3.4 Operator-native form: `PrometheusRule` CRD (kube-prometheus-stack)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: http-aggregations
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # must match the Prometheus ruleSelector
spec:
  groups:
    - name: http.aggregations
      interval: 30s
      rules:
        - record: job:http_requests:rate5m
          expr: sum by (job) (rate(http_requests_total[5m]))
        - record: job:http_requests_errors:ratio5m
          expr: |
              sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))
            /
              sum by (job) (rate(http_requests_total[5m]))
```

---

## 4. CLI: evaluating aggregations and reading the wire format

### 4.1 `promtool query instant` — one-shot evaluation

```console
$ promtool query instant http://localhost:9090 \
    'sum by (code) (rate(prometheus_http_requests_total[5m]))'
{code="200"} 8.4666666666 @[1723104000.000]
{code="400"} 0.0333333333 @[1723104000.000]
{code="500"} 0.0000000000 @[1723104000.000]
```

Note the output series carry **only** `{code}` — every other label (`handler`, `instance`) was collapsed by `by (code)`.

Compare a selector, which preserves full identity:

```console
$ promtool query instant http://localhost:9090 \
    'topk(2, rate(prometheus_http_requests_total[5m]))'
{code="200", handler="/api/v1/query", instance="localhost:9090"} 5.20 @[1723104000.000]
{code="200", handler="/metrics",      instance="localhost:9090"} 2.13 @[1723104000.000]
```

### 4.2 Raw HTTP API — the JSON shape

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=count by (job) (up == 1)' | jq .
```
```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      { "metric": { "job": "api" },        "value": [1723104000, "6"] },
      { "metric": { "job": "prometheus" }, "value": [1723104000, "1"] }
    ]
  }
}
```

The empty-ish `metric` object (only `job`, no `__name__`) is the fingerprint of a reducer result: aggregation stripped the metric name and every non-grouped label.

`count_values` in action:

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=count_values("release", node_uname_info)' | jq -c '.data.result[]'
{"metric":{"release":"5.15.0-119-generic"},"value":[1723104000,"18"]}
{"metric":{"release":"6.8.0-40-generic"},"value":[1723104000,"7"]}
```

### 4.3 Static validation before deploy

```console
$ promtool check rules /etc/prometheus/rules/http.rules.yml
Checking /etc/prometheus/rules/http.rules.yml
  SUCCESS: 5 rules found
```

### 4.4 Unit-testing the aggregation logic (`promtool test rules`)

`http.test.yml`:

```yaml
rule_files:
  - http.rules.yml
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      # counter climbing 60/min => 1 req/s for this series
      - series: 'http_requests_total{job="api", instance="a", code="200"}'
        values: '0+60x10'
      # counter climbing 120/min => 2 req/s
      - series: 'http_requests_total{job="api", instance="b", code="200"}'
        values: '0+120x10'
      # counter climbing 6/min => 0.1 req/s
      - series: 'http_requests_total{job="api", instance="a", code="500"}'
        values: '0+6x10'
    promql_expr_test:
      # sum by (job) collapses both instances and both codes: 1 + 2 + 0.1 = 3.1
      - expr: job:http_requests:rate5m
        eval_time: 10m
        exp_samples:
          - labels: '{job="api"}'
            value: 3.1
      # error ratio: 0.1 / 3.1 = 0.032258...
      - expr: job:http_requests_errors:ratio5m
        eval_time: 10m
        exp_samples:
          - labels: '{job="api"}'
            value: 0.03225806451612903
```

```console
$ promtool test rules http.test.yml
Unit Testing:  http.test.yml
  SUCCESS
```

This test is the guardrail that proves your `by` clause collapses the intended dimensions — instance `a`/`b` and both status codes vanish, leaving exactly one `{job="api"}` series.

---

## 5. Verification & failure diagnosis

### 5.1 The `rate` / `sum` ordering trap (the number-one bug)

`rate()` needs to see a *single monotonic counter* so it can detect and correct resets (a pod restart drops the counter to 0). If you `sum` first, resets on different instances happen at different times, and the summed series looks like a jagged non-monotonic line that `rate` misinterprets — undercounting, spikes, or `NaN`.

```promql
#  WRONG: sum flattens per-instance resets → rate sees false drops
rate(sum by (job) (http_requests_total)[5m])   # also a type error in most forms

#  RIGHT: rate each counter, then sum the per-second rates
sum by (job) (rate(http_requests_total[5m]))
```

**Rule:** `rate`/`increase`/`irate` are *innermost*; aggregation operators are *outermost*. Rate the counters, then aggregate the rates.

### 5.2 Empty result after a binary op — mismatched grouping labels

Dividing two aggregations only matches series whose label sets are identical. If the numerator and denominator use different `by` lists, the vector match finds no pairs and returns empty:

```promql
# BUG: numerator grouped by (job,code); denominator by (job) → labels differ → {}
  sum by (job, code) (rate(http_requests_total{code=~"5.."}[5m]))
/ sum by (job)       (rate(http_requests_total[5m]))
```

Diagnose by evaluating each side alone and comparing label sets, or fix the grouping to match (both `by (job)`), or use explicit vector matching (`/ on (job) group_left ...`). First reflex when a ratio panel is blank: **the two sides don't share a label set.**

### 5.3 Confirming a `by` clause collapsed what you intended

Count how many series survived per group; it should equal the number of distinct groups, not the raw fan-in:

```console
$ promtool query instant http://localhost:9090 'count(job:http_requests:rate5m)'
{} 12 @[1723104000.000]     # 12 jobs — good; a value near 48000 means the by-clause didn't collapse
```

### 5.4 Cardinality forensics — nested aggregation

To find which metric name is exploding your TSDB, aggregate the *series count itself*:

```promql
topk(10, count by (__name__) ({__name__=~".+"}))
```

To measure the cardinality contributed by a single label (candidate for a `without` drop):

```promql
count(count by (le) (http_request_duration_seconds_bucket))   # how many histogram buckets
```

`count(count by (X) (...))` — the outer `count` over an inner `count by` — is the idiomatic "how many distinct values does label X have?" probe.

### 5.5 `NaN` swallowing a whole group

Aggregation operators are not `NaN`-skipping. A single `NaN` member (e.g. a `0/0` division upstream) propagates into `sum`/`avg` and poisons the entire group's result. If a `sum by (job)` panel shows gaps where you expect a number, inspect members with `topk`:

```console
$ promtool query instant http://localhost:9090 \
    'topk(20, rate(http_requests_total[5m])) by (job)'
```

and filter the offending upstream expression (`... > 0`, `clamp_min`, or guard the denominator) before it reaches the aggregation.

### 5.6 Histogram quantile that returns nonsense

`histogram_quantile` requires the `le` label. If you aggregate `by (job)` and *forget* `le`, the bucket structure is destroyed and the function returns `NaN` or garbage:

```promql
# BROKEN: le collapsed → histogram_quantile has no buckets to interpolate
histogram_quantile(0.99, sum by (job) (rate(http_request_duration_seconds_bucket[5m])))

# CORRECT: keep le in the by-list
histogram_quantile(0.99, sum by (job, le) (rate(http_request_duration_seconds_bucket[5m])))
```

### 5.7 `topk`/`bottomk` in alerts → flapping

Because selectors return a *changing set* of series, an `alert:` built on `topk(...)` continuously creates and destroys firing series, resetting `for:` and page-storming. Verify by watching the active-series set change between evaluations; **fix** by alerting on a reducer threshold (`sum by (job) (...) > N`) and reserving `topk` for the annotation/notebook where you're triaging *which* member is worst.

### Diagnostic checklist

| Symptom | Likely cause | Confirm with |
|---|---|---|
| Rate graph spikes/dips at deploy times | `sum` before `rate` | Move `rate` innermost |
| Ratio panel is empty | numerator/denominator `by` lists differ | Evaluate each side; compare labels |
| Result has ~raw cardinality | `by`/`without` naming the wrong labels | `count(<expr>)` should equal group count |
| Whole group shows `NaN`/gap | one `NaN` member propagated | `topk(N, ...) by (group)` to find it |
| p99 is `NaN` or absurd | `le` dropped in aggregation | Add `le` to the `by` list |
| Alert flaps on/off | `topk`/`bottomk` in `expr` | Replace with reducer + threshold |

---

## 6. References

- Prometheus — *Querying: Operators → Aggregation operators*: https://prometheus.io/docs/prometheus/latest/querying/operators/#aggregation-operators
- Prometheus — *Querying basics* (instant vs range vectors): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — *Query functions* (`rate`, `histogram_quantile`, `<fn>_over_time`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — *Recording rules*: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — *Recording-rule naming convention* (`level:metric:operations`): https://prometheus.io/docs/practices/rules/
- Prometheus — *Histograms and summaries* (aggregating buckets before `histogram_quantile`): https://prometheus.io/docs/practices/histograms/
- Prometheus — *promtool unit testing rules*: https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus — *HTTP API* (`/api/v1/query` response schema): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus Operator — *PrometheusRule* API reference: https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PrometheusRule
- CNCF — *PCA Curriculum*: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf