# PCA — Domain 1.2: Rates and Derivatives

> **Scope.** This topic is the analytical core of PromQL. A Prometheus counter that only ever goes up carries no operational meaning as an absolute number — `http_requests_total 8481920` tells you nothing. What an SRE actually pages on, dashboards, and burns into SLOs is *how fast that number is moving*. This chapter covers the functions that turn monotonic counters and fluctuating gauges into rates of change: `rate`, `irate`, `increase`, `delta`, `idelta`, `deriv`, `predict_linear`, plus the reset/change accounting functions `resets` and `changes`. It covers the extrapolation and counter-reset mechanics that make their results non-obvious, and the two failure modes (`sum`-before-`rate`, and `irate` in alerts) that account for most broken dashboards in the field.

---

## 1. Motivation and the production architectural problem

Prometheus has exactly two numeric metric types that matter here:

- **Counter** — monotonically non-decreasing, resets to 0 only on process restart (`http_requests_total`, `node_cpu_seconds_total`, `node_network_receive_bytes_total`). The absolute value is an accumulator since process start and is operationally meaningless.
- **Gauge** — a value that goes up and down (`node_filesystem_avail_bytes`, `node_memory_MemAvailable_bytes`, `go_goroutines`, temperature, queue depth).

The architectural problem is threefold:

1. **The signal lives in the slope, not the level.** Traffic, throughput, error rate, CPU utilization, I/O — every RED (Rate, Errors, Duration) and USE (Utilization, Saturation, Errors) signal is a *derivative*. You must compute it query-side because storing pre-derived rates loses information and breaks re-aggregation.

2. **Counters reset, and the math must survive it.** A pod restart, an OOM kill, a rolling deploy — the counter snaps back to 0 mid-window. A naive `last - first` subtraction over the window would produce a large **negative** rate. The rate family must detect and correct resets transparently, or every deploy would fire false "throughput collapsed" alerts.

3. **Samples are discrete, sparse, and misaligned.** With a 15s scrape interval, your query window boundaries almost never land on a sample. A window `[1m]` might contain 3 or 5 samples depending on jitter. The functions must **extrapolate** to the window edges to give a stable, boundary-independent answer — which is why `increase()` of an integer counter frequently returns a *fractional* number, a result that surprises every engineer exactly once.

The job of Domain 1.2 is to make these three problems disappear behind a small, composable function set — and to know precisely what each function assumes so you don't apply a counter function to a gauge (or vice versa) and silently ship garbage to a dashboard.

---

## 2. The function family: technical comparison

### 2.1 Counter functions (require monotonic input, handle resets)

| Function | Computes | Uses | Reset-aware | Extrapolates | Alerting-safe | Typical range |
|---|---|---|---|---|---|---|
| `rate(c[w])` | per-second **average** rate of increase over `w` | **all** samples in `w` | ✅ | ✅ | ✅ (smooth) | ≥ 4× scrape interval |
| `irate(c[w])` | per-second **instant** rate | **last 2** samples in `w` | ✅ | ❌ | ❌ (too spiky) | just enough to hold 2 samples |
| `increase(c[w])` | **total** increase over `w` (= `rate × w` seconds) | all samples in `w` | ✅ | ✅ | ✅ | ≥ 4× scrape interval |

`rate` and `increase` are the same computation scaled differently: `increase(c[w]) == rate(c[w]) * w_seconds`. Use `rate` for graphs/alerts (unit `/s`, scale-invariant); use `increase` when a human wants "how many in the last hour."

### 2.2 Gauge functions (do **not** handle resets — a drop is a real drop)

| Function | Computes | Method | Use case |
|---|---|---|---|
| `delta(g[w])` | difference between extrapolated first/last value | endpoint difference, extrapolated | temperature drift, gauge change over a window |
| `idelta(g[w])` | difference between the **last two** samples | last-2 difference | detecting the most recent gauge step |
| `deriv(g[w])` | per-second derivative via **simple linear regression** over all samples | least-squares slope | smoothed rate-of-change of a noisy gauge |
| `predict_linear(g[w], t)` | linear-regression extrapolation of the value `t` seconds into the future | least-squares projection | disk-fill / capacity forecasting |

### 2.3 Accounting functions

| Function | Computes | Applies to |
|---|---|---|
| `resets(c[w])` | number of counter resets within `w` | counters (restart/crash counting) |
| `changes(g[w])` | number of times the value changed within `w` | gauges (flapping detection, e.g. leader elections) |

### 2.4 Smoothing (experimental in Prometheus 3.x)

`holt_winters(v, sf, tf)` was **renamed to `double_exponential_smoothing`** in Prometheus 3.0 and moved behind `--enable-feature=promql-experimental-functions`. It produces a smoothed value using double exponential smoothing (level + trend). Rarely on the exam beyond "it exists and is experimental," but know the rename.

### 2.5 The decision table: which function, when

| You have… | You want… | Use |
|---|---|---|
| Counter | smooth rate for a dashboard or alert | `rate` |
| Counter | responsive rate for a high-res console graph | `irate` |
| Counter | absolute count over a period ("errors in last 1h") | `increase` |
| Gauge | how much it moved over a window | `delta` |
| Gauge | de-noised trend / slope | `deriv` |
| Gauge | when will it cross a threshold | `predict_linear` |
| Counter | how many restarts happened | `resets` |
| Gauge | how often it flapped | `changes` |

---

### 2.6 Mechanic #1 — Extrapolation (why `increase` returns fractions)

`rate`, `irate`(no — `irate` does not extrapolate), `increase` and `delta` **extrapolate to the window boundaries**. Prometheus never sees a sample exactly at the window edge, so it projects the observed slope outward. The algorithm (`extrapolatedRate` in `promql/functions.go`):

1. Let `sampledInterval` = time between first and last sample in the window; `avgInterval = sampledInterval / (numSamples − 1)`.
2. `durationToStart` = gap from window start to first sample; `durationToEnd` = gap from last sample to window end.
3. If a gap ≥ `1.1 × avgInterval` (the `extrapolationThreshold`), the boundary is assumed to be *beyond* real data, so extrapolation is capped at `avgInterval / 2` on that side.
4. **Counter clamp:** if extrapolating backward would imply the counter was negative, `durationToStart` is clamped so the projected line reaches zero, not below.
5. Final value is scaled by `(sampledInterval + durationToStart + durationToEnd) / sampledInterval`.

**Worked example.** Counter `http_requests_total`, scrape 15s, evaluated at `t=60`, window `[1m]` (the left-open range `(0, 60]`):

```
t=15 → 130    t=30 → 160    t=45 → 190    t=60 → 220
```

- Raw sample delta = 220 − 130 = **90** over `sampledInterval = 45s`.
- `avgInterval = 45/3 = 15s`; `durationToStart = 15s` (< 16.5s threshold, kept); `durationToEnd = 0`.
- Scale factor = `(45 + 15 + 0) / 45 = 1.333…`
- `increase[1m] = 90 × 1.333 = 120`; `rate[1m] = 120 / 60 = 2 req/s`.

The extrapolated `increase` of **120** matches the *true* increase from the (excluded) sample at `t=0` (100) to `t=60` (220). Extrapolation is not an error — it recovers the boundary-aligned truth. **But** when scrapes jitter and boundaries don't line up cleanly, the same math yields values like `increase(...) = 118.6`, which is why you must never assert `increase(counter[1h]) == <integer>`.

---

### 2.7 Mechanic #2 — Counter-reset handling

`rate`/`irate`/`increase` walk the samples and, whenever `sample[i] < sample[i-1]`, treat it as a reset and add the pre-reset value as a correction:

```
values:  100, 130,  20,  50   (reset between 130 and 20)
delta = (130-100) + (50-20) + 130(carried across reset) → 30 + 30 + 130 corrective
```

The corrected total increase is `(130−100) + (130) + (50−20) = 30 + 130 + 30`… the implementation carries the last value before the drop into the accumulator so the result reflects real work done across the restart. Net effect: **a deploy or crash does not produce a negative rate.** `resets(counter[w])` reports how many such drops occurred — pair it with `rate` when you want to know "throughput *and* how many restarts caused it."

---

### 2.8 Mechanic #3 — The 4× rule and window sizing

`rate` needs **≥ 2 samples** in the window to produce any output. With one missed scrape you can drop to 1 sample and get an *empty result* — a silent gap in your graph and, worse, a silently-not-firing alert.

**Rule of thumb: window ≥ 4 × scrape_interval.** At 15s scrape → `[1m]` minimum. This tolerates one missed scrape and still leaves ≥ 2 samples.

| Window relative to scrape | Behavior | Failure mode |
|---|---|---|
| `< 2×` | often 1 sample → **no data** | gaps, alerts that never fire |
| `= 4×` (recommended min) | 2–4 samples, responsive | good default |
| very large (`[1h]`) | heavy smoothing, high query cost | spikes vanish, slow to react, expensive |

`irate` sidesteps the window-size question (it only reads the last 2 points), but is far too jumpy for alerting — an `irate` graph is a hedgehog. **Alert on `rate`, eyeball on `irate`.**

---

### 2.9 Mechanic #4 — Aggregate rates, never rate aggregates

The single most important compositional rule in PromQL:

```promql
# ✅ CORRECT — rate first (per-series, reset-aware), then aggregate
sum(rate(http_requests_total[5m])) by (service)

# ❌ WRONG — aggregate first, then rate
rate(sum(http_requests_total)[5m:])   # (and this even needs a subquery)
```

`sum()` collapses many per-target series into one. When any single target restarts, the summed line **dips**, and `rate()` applied *after* the sum sees a decrease it can only interpret as a reset — over-correcting and producing a wrong spike. Applied *before* the sum, `rate()` sees each raw per-target counter and handles each reset correctly; summing rates is then just addition. **Push `rate`/`irate`/`increase` as deep as possible, aggregate on the outside.**

| Order | Reset handling | Correctness | Verdict |
|---|---|---|---|
| `sum(rate(x[5m]))` | per-series, correct | ✅ | always this |
| `rate(sum(x)[5m:])` | on the aggregate, wrong on any restart | ❌ | never |

The same rule governs latency and quantiles:

```promql
# average latency: rate the _sum and _count separately, then divide
rate(http_request_duration_seconds_sum[5m])
  /
rate(http_request_duration_seconds_count[5m])

# p99 from a classic histogram: rate the buckets first, then histogram_quantile
histogram_quantile(0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)
```

---

## 3. Complete manifests and infrastructure

### 3.1 Scrape configuration (`prometheus.yml`)

```yaml
global:
  scrape_interval: 15s          # sets your minimum rate window (4× = 1m)
  scrape_timeout: 10s
  evaluation_interval: 15s      # how often recording/alerting rules run
  external_labels:
    cluster: prod-eu-west-1
    replica: A

rule_files:
  - /etc/prometheus/rules/recording.rules.yml
  - /etc/prometheus/rules/alerting.rules.yml

scrape_configs:
  - job_name: node
    kubernetes_sd_configs:
      - role: endpoints
    relabel_configs:
      - source_labels: [__meta_kubernetes_endpoints_name]
        regex: node-exporter
        action: keep

  - job_name: api
    metrics_path: /metrics
    static_configs:
      - targets: ['api-0.api:8080', 'api-1.api:8080', 'api-2.api:8080']
```

### 3.2 Recording rules — precompute expensive rates

Rate queries over wide windows or high-cardinality selectors are expensive to run interactively and re-run per dashboard refresh. Precompute them once per `evaluation_interval`.

```yaml
# recording.rules.yml
groups:
  - name: request_rates
    interval: 15s
    rules:
      # per-service request rate (rate first, then aggregate)
      - record: service:http_requests:rate5m
        expr: sum by (service) (rate(http_requests_total[5m]))

      # per-service error rate
      - record: service:http_requests_errors:rate5m
        expr: sum by (service) (rate(http_requests_total{code=~"5.."}[5m]))

      # error ratio (SLI) — division of two recording rules
      - record: service:http_requests_error_ratio:rate5m
        expr: |
          service:http_requests_errors:rate5m
            /
          service:http_requests:rate5m

      # CPU utilization per instance (counter → rate)
      - record: instance:node_cpu_utilization:rate5m
        expr: |
          1 - avg by (instance) (
            rate(node_cpu_seconds_total{mode="idle"}[5m])
          )
```

### 3.3 Alerting rules — rate-based, plus `predict_linear` forecasting

```yaml
# alerting.rules.yml
groups:
  - name: slo_and_capacity
    rules:
      # High 5xx ratio — rate-based, smoothed, for=10m debounces
      - alert: HighErrorRate
        expr: service:http_requests_error_ratio:rate5m > 0.05
        for: 10m
        labels:
          severity: page
        annotations:
          summary: "{{ $labels.service }} error ratio {{ $value | humanizePercentage }}"

      # Multi-window multi-burn-rate SLO alert (fast + slow burn)
      - alert: ErrorBudgetBurnFast
        expr: |
          (
            sum by (service) (rate(http_requests_total{code=~"5.."}[5m]))
              /
            sum by (service) (rate(http_requests_total[5m]))
          ) > (14.4 * 0.001)          # 14.4× burn of a 99.9% SLO
          and
          (
            sum by (service) (rate(http_requests_total{code=~"5.."}[1h]))
              /
            sum by (service) (rate(http_requests_total[1h]))
          ) > (14.4 * 0.001)
        for: 2m
        labels: { severity: page }
        annotations:
          summary: "{{ $labels.service }} is burning error budget 14.4× (page)"

      # Disk will fill in the next 4h — classic predict_linear on a GAUGE
      - alert: DiskWillFillIn4h
        expr: |
          predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 4 * 3600) < 0
          and
          node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes < 0.30
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }}:{{ $labels.mountpoint }} projected to fill within 4h"

      # Crash-looping process — resets() counts counter restarts
      - alert: ProcessRestartStorm
        expr: resets(process_start_time_seconds{job="api"}[15m]) > 3
        for: 0m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }} restarted >3 times in 15m"
```

> **Note on `predict_linear`.** It runs on a **gauge** (`node_filesystem_avail_bytes`), uses least-squares regression over the `[6h]` window, and projects `4 × 3600` seconds ahead. `< 0` means "the fit line crosses empty within 4h." The added `< 0.30` guard prevents firing on a nearly-empty-but-huge disk whose noise regression trends slightly downward.

### 3.4 prometheus-operator `PrometheusRule` CRD (same rules, Kubernetes-native)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: slo-and-capacity
  namespace: monitoring
  labels:
    role: alert-rules
    prometheus: k8s          # must match Prometheus CR ruleSelector
spec:
  groups:
    - name: slo_and_capacity
      rules:
        - alert: DiskWillFillIn4h
          expr: predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 4 * 3600) < 0
          for: 15m
          labels: { severity: warning }
          annotations:
            summary: "{{ $labels.instance }}:{{ $labels.mountpoint }} projected to fill within 4h"
```

---

## 4. CLI commands and real terminal output

### 4.1 Instant query via `promtool` and the HTTP API

```console
$ promtool query instant http://localhost:9090 'sum(rate(http_requests_total[5m]))'
{} => 2 @[1754640000]
```

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=sum by (service) (rate(http_requests_total[5m]))' | jq .
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": { "service": "checkout" },
        "value": [ 1754640000, "42.7333333" ]
      },
      {
        "metric": { "service": "catalog" },
        "value": [ 1754640000, "318.4" ]
      }
    ]
  }
}
```

### 4.2 Range query (what a Grafana panel actually sends)

```console
$ curl -s 'http://localhost:9090/api/v1/query_range' \
    --data-urlencode 'query=rate(node_network_receive_bytes_total{device="eth0"}[5m])' \
    --data-urlencode 'start=1754639700' \
    --data-urlencode 'end=1754640000' \
    --data-urlencode 'step=15s' | jq '.data.result[0].values[:3]'
[
  [ 1754639700, "1048576.0" ],
  [ 1754639715, "1050112.0" ],
  [ 1754639730, "1179648.0" ]
]
```

### 4.3 Demonstrating `increase` returning a non-integer

```console
$ promtool query instant http://localhost:9090 'increase(http_requests_total{service="checkout"}[1h])'
{service="checkout"} => 153847.6 @[1754640000]
```

> `153847.6` — fractional, because of boundary extrapolation (§2.6). Correct behavior, not a bug.

### 4.4 `irate` vs `rate` side by side (spikiness)

```console
$ promtool query instant http://localhost:9090 'irate(http_requests_total{service="checkout"}[5m])'
{service="checkout"} => 61.3333 @[1754640000]     # last-2-samples, jumpy

$ promtool query instant http://localhost:9090 'rate(http_requests_total{service="checkout"}[5m])'
{service="checkout"} => 42.7333 @[1754640000]     # averaged over 5m, smooth
```

### 4.5 Static rule validation

```console
$ promtool check rules /etc/prometheus/rules/*.yml
Checking /etc/prometheus/rules/alerting.rules.yml
  SUCCESS: 5 rules found
Checking /etc/prometheus/rules/recording.rules.yml
  SUCCESS: 4 rules found
```

### 4.6 Unit-testing rate logic with `promtool test rules`

This is the production-grade verification path — you assert what `rate`/`increase`/`predict_linear` *should* return given a synthetic series, and it fails CI if the math or the rule drifts.

```yaml
# rate_tests.yml
rule_files:
  - recording.rules.yml
  - alerting.rules.yml

evaluation_interval: 15s

tests:
  # A steady 10-req/scrape counter over 10 scrapes → rate ≈ 0.667/s
  - interval: 15s
    input_series:
      - series: 'http_requests_total{service="checkout", instance="a"}'
        values: '0+10x40'          # 0,10,20,…  (start 0, +10, 40 steps)
    promql_expr_test:
      - expr: rate(http_requests_total{service="checkout"}[1m])
        eval_time: 10m
        exp_samples:
          - labels: 'http_requests_total{service="checkout", instance="a"}'
            value: 0.6666666666666666

  # A counter reset must NOT produce a negative rate
  - interval: 15s
    input_series:
      - series: 'http_requests_total{service="checkout", instance="b"}'
        values: '0+10x20 0+10x20'  # rises, resets to 0, rises again
    promql_expr_test:
      - expr: rate(http_requests_total{service="checkout", instance="b"}[1m])
        eval_time: 6m
        exp_samples:
          - labels: 'http_requests_total{service="checkout", instance="b"}'
            value: 0.6666666666666666   # positive across the reset

  # predict_linear on a falling gauge fires DiskWillFillIn4h
  - interval: 1m
    input_series:
      - series: 'node_filesystem_avail_bytes{instance="n1", mountpoint="/", fstype="ext4"}'
        values: '100000000-500000x360'   # draining steadily over 6h
      - series: 'node_filesystem_size_bytes{instance="n1", mountpoint="/", fstype="ext4"}'
        values: '400000000x360'
    alert_rule_test:
      - eval_time: 6h
        alertname: DiskWillFillIn4h
        exp_alerts:
          - exp_labels: { severity: warning, instance: n1, mountpoint: /, fstype: ext4 }
```

```console
$ promtool test rules rate_tests.yml
Unit Testing:  rate_tests.yml
  SUCCESS
```

---

## 5. Verification and failure diagnosis

### 5.1 Symptom → cause → fix table

| Symptom | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| `rate()` returns **empty / gaps** | window too small; < 2 samples | `count_over_time(metric[1m])` — is it ≥ 2? | widen window to ≥ 4× scrape |
| Rate **spikes on every deploy** | `sum` before `rate` (reset seen on aggregate) | check for `rate(sum(...)...)` | `sum(rate(...))`, rate the raw series |
| Alert **flaps wildly** | `irate` in an alert rule | inspect `expr` | switch to `rate` |
| `increase()` returns a **fraction** | boundary extrapolation | expected (§2.6) | not a bug; don't compare to integer |
| **Negative** rate | counter function applied to a **gauge** | is the metric a gauge? | use `delta`/`deriv`, not `rate` |
| `predict_linear` **never fires** / fires wrongly | applied to a counter, or window too short for the trend | verify gauge; check `[w]` covers a real trend | use a gauge and a window ≫ prediction horizon's noise |
| Rate **lags real traffic** | window too large, over-smoothed | compare `[5m]` vs `[1m]` | shorten window (respect 4× floor) |
| Query **times out / OOMs** | wide window × high cardinality, run interactively | check series count | precompute with a recording rule (§3.2) |

### 5.2 Diagnostic queries

```promql
# How many samples are actually in your window? (rate needs ≥ 2)
count_over_time(http_requests_total{service="checkout"}[1m])

# Did this counter reset during the window? (explains a rate spike)
resets(http_requests_total{service="checkout"}[15m])

# Is the target even up / being scraped?
up{job="api"}

# Is the series stale (scrape stopped)? absent() catches disappearance
absent(http_requests_total{service="checkout"})

# Confirm gauge vs counter mistake: a "counter" that ever decreases isn't one
rate(node_filesystem_avail_bytes[5m])   # returns garbage — it's a gauge!
```

### 5.3 Terminal-side reasoning about staleness

Prometheus injects a **staleness marker** when a series stops being scraped; after that, `rate()` returns no value rather than a stale carry-forward. If a rate graph flatlines to "no data" right when a pod dies, that is staleness working correctly — pair the rate alert with an `up == 0` or `absent()` alert so "no data" is never silently interpreted as "zero traffic."

### 5.4 The verification ladder for this topic

1. **Static:** `promtool check rules` — YAML and expression syntax.
2. **Behavioral:** `promtool test rules` — assert exact rate/increase/predict_linear outputs on synthetic series (§4.6). This is the only place the *math* is proven, not assumed.
3. **Live:** the diagnostic queries in §5.2 against the running server.
4. **Composition:** grep your rules for `rate(sum(` and `irate(` inside `alert:` blocks — both are code smells that static checks pass but semantics fail.

---

## 6. References

- Prometheus — Query functions (`rate`, `irate`, `increase`, `delta`, `idelta`, `deriv`, `predict_linear`, `resets`, `changes`, `double_exponential_smoothing`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — Querying basics (range/instant vectors, range selectors): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — Querying operators (aggregation, binary operators): https://prometheus.io/docs/prometheus/latest/querying/operators/
- Prometheus — Metric types (counter vs gauge vs histogram): https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Recording rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — Alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus — Unit testing rules (`promtool test rules`): https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus — Best practices, histograms & quantiles: https://prometheus.io/docs/practices/histograms/
- Prometheus — HTTP API (`/api/v1/query`, `/api/v1/query_range`): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — Staleness: https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness
- Google SRE Workbook — Alerting on SLOs (multi-window multi-burn-rate): https://sre.google/workbook/alerting-on-slos/
- prometheus-operator — `PrometheusRule` API: https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PrometheusRule
- CNCF — Prometheus Certified Associate (PCA) curriculum: https://github.com/cncf/curriculum