# PCA — Topic 1.1: Selecting Data (PromQL)

> **Domain:** PromQL · **Exam weight:** 4 · **Level:** Production SRE / Platform Architect
> *Everything you query in Prometheus — dashboards, alerts, recording rules, SLO burn-rate windows — begins with a selector. Selection is where correctness and cost are decided before a single aggregation function runs.*

---

## 1. Motivation: the architectural problem selection solves

A Prometheus server is a **time-series database with a pull-based scrape pipeline and an embedded query engine**. At steady state a production server holds millions of active series in its head block (in-memory WAL-backed data), plus persisted blocks on disk. A single query like `sum(rate(http_requests_total[5m]))` looks trivial, but before any math happens the engine must answer a much harder question:

> *Given an evaluation timestamp `t`, which of the millions of series match, and which samples of each series are in scope?*

That is **selecting data**. It is the single most performance-sensitive step in PromQL for three reasons:

1. **Cardinality is the cost driver.** The number of series a selector touches — not the number of samples — dominates index lookups, memory allocation, and query latency. A selector that resolves to 2 series and one that resolves to 2,000,000 series look identical in syntax.
2. **Selection defines temporal correctness.** Instant selectors, range selectors, `offset`, and `@` each pin *which samples in time* participate. Alerting logic that is "correct" but selects the wrong time window produces false pages or, worse, silent gaps.
3. **Selection is where staleness is resolved.** A target that vanished 3 minutes ago vs. 7 minutes ago behaves differently under the default 5-minute lookback delta. SRE incident post-mortems frequently trace back to a misunderstanding of this boundary.

The production failure mode this topic prevents:

```
Alert "TargetDown" flaps every scrape cycle
  → root cause: query relies on absent() over a selector whose
    lookback-delta hides the gap for up to 5 minutes
  → the alert fires and resolves inside the staleness window
```

Getting selection right is the difference between an observability stack that is trusted and one that is muted.

---

## 2. The Prometheus data model — what a selector actually resolves

A **time series** is uniquely identified by its full label set. The metric name is *not* special at storage time — it is stored as the reserved label `__name__`. These two are identical:

```promql
http_requests_total{job="api", code="200"}
{__name__="http_requests_total", job="api", code="200"}
```

Each series is an append-only stream of `(timestamp_ms, float64)` samples (or native-histogram samples in Prometheus 3.x). The TSDB maintains an **inverted index** mapping each `label=value` pair to a sorted list of series IDs (a *postings list*). A selector is compiled into a **set intersection over postings lists**:

```
job="api"        → postings: {12, 88, 143, 5567, ...}
code="200"       → postings: {88, 143, 900, ...}
__name__="http_requests_total" → postings: {88, 143, 5567, ...}
                                  ─────────────────────────────
intersection     → {88, 143}     ← series the engine will read
```

This is why the shape of your matchers changes query cost by orders of magnitude: an equality matcher (`=`) hits one postings list; a regex matcher (`=~`) may have to union hundreds of them before intersecting.

Two selector categories exist, and everything in this topic is a variation of one of them:

| Selector kind | Returns | Example | Feeds functions like |
|---|---|---|---|
| **Instant vector selector** | one sample per matching series at time `t` | `node_memory_MemAvailable_bytes` | `sum`, `topk`, comparison ops |
| **Range vector selector** | a *slice* of samples over a duration per series | `node_memory_MemAvailable_bytes[5m]` | `rate`, `increase`, `*_over_time` |

A range vector **cannot be graphed or alerted on directly** — it must be reduced to an instant vector by a function first. `promtool` and the HTTP API will reject a bare range selector as an alert/graph expression.

---

## 3. Instant vector selectors

Syntax: a metric name and/or a `{}` matcher block.

```promql
http_requests_total
http_requests_total{code="500"}
{__name__="http_requests_total", code="500"}   # equivalent
```

**Evaluation semantics** (memorize this — it is heavily tested):

> For each matching series, the engine returns the **most recent sample whose timestamp is within `[t - lookback_delta, t]`**. If no sample exists in that window, the series is dropped from the result. If the most recent in-window sample is a **stale marker**, the series is also dropped.

`lookback_delta` defaults to **5 minutes** and is set by `--query.lookback-delta`. Consequences:

- A metric scraped every 15s will always have a fresh sample; the lookback rarely matters.
- A metric scraped every 4 minutes is fine at default lookback but **disappears from queries** the instant you lower `--query.lookback-delta` below its scrape interval — a classic self-inflicted outage of dashboards.

**The empty-matcher rule.** A selector must contain **at least one matcher that does not match the empty string**. This is rejected:

```promql
{job=~".*"}            # ERROR: vector selector must contain at least one
                       # non-empty matcher
```

Because `.*` matches `""`, the engine refuses to scan the entire index. Use a matcher that excludes empty:

```promql
{job=~".+"}            # OK: ".+" cannot match the empty string
{__name__=~".+"}       # OK: selects every series (expensive, but legal)
```

---

## 4. Label matchers and the RE2 regex engine

Four matcher operators:

| Operator | Meaning | Postings behavior | Cost |
|---|---|---|---|
| `=` | label equals value | single postings list | cheapest |
| `!=` | label not equal | complement — reads all, subtracts | moderate |
| `=~` | label matches regex | union of every matching value's postings | high (fan-out) |
| `!~` | label does not match regex | complement of the union | highest |

**Critical regex facts:**

1. The engine is **RE2** (Google's linear-time regex library). No backreferences, no lookahead. This guarantees no catastrophic backtracking — a deliberate DoS-resistance decision.
2. **Matchers are fully anchored.** `code=~"5.."` behaves as `^5..$`. To match a substring you must write the wildcards explicitly:

```promql
path=~"/api/.*"        # anchored: matches paths STARTING with /api/
path=~".*login.*"      # matches paths CONTAINING login
```

3. **Optimized alternations.** Prometheus rewrites `=~"a|b|c"` into a set of equality lookups internally (since 2.34+), so a bounded alternation is nearly as cheap as `=`. An unbounded `.*`-heavy regex is not.

**Trade-off table — expressing "one of several jobs":**

| Expression | Correctness | Index cost | Readability | Recommendation |
|---|---|---|---|---|
| `{job=~"api\|web\|worker"}` | exact | low (rewritten to eq-set) | high | ✅ preferred |
| `{job=~"a.*"}` (relying on prefix) | brittle — matches `apiv2`, `analytics` | medium | low | ❌ avoid |
| three separate queries `or`-ed | exact | 3× parse cost | low | ❌ avoid |
| `{job!~"db\|cache"}` (negation) | inverts intent, drifts as new jobs appear | high | medium | ⚠️ use sparingly |

**Escaping.** Regex metacharacters in values must be escaped: to match a literal dotted hostname use `instance=~"node1\\.prod\\.example\\.com.*"` (or better, `=` if the value is exact).

---

## 5. Range vector selectors

Append a **duration** in brackets to select a window of samples per series:

```promql
http_requests_total[5m]
rate(http_requests_total[5m])       # range → instant, via rate()
```

Valid duration units, combinable in descending order: `ms`, `s`, `m`, `h`, `d`, `w`, `y` — e.g. `[1h30m]`, `[2w]`. Note `d`=24h and `y`=365d are calendar-naïve.

**Window boundary — a Prometheus 3.0 breaking change you must know:**

| Prometheus version | Interval selected by `v[d]` at time `t` | Boundary |
|---|---|---|
| ≤ 2.x | `[t − d, t]` | closed–closed (both ends inclusive) |
| **≥ 3.0** | `(t − d, t]` | **left-open**, right-closed |

The 3.0 change removed a long-standing off-by-one where a sample landing exactly on `t − d` was double-counted at adjacent evaluation steps. For `rate`/`increase` this shifts extrapolation edge cases; recording rules migrated from 2.x may show a one-sample difference at window edges. **Rule of thumb still holds: make the range at least 4× the scrape interval** so a range vector always contains ≥ 4 samples and `rate()` has slope to work with.

```promql
# scrape_interval = 15s  →  [1m] guarantees ~4 samples
rate(node_network_receive_bytes_total[1m])
```

Too-short ranges silently return empty (`rate` needs ≥ 2 points in-window); too-long ranges smooth over the very spikes you are trying to alert on.

---

## 6. Time modifiers: `offset` and `@`

### 6.1 `offset` — relative time shift

`offset <duration>` shifts the *evaluation timestamp* of that selector into the past:

```promql
http_requests_total offset 5m           # value as it was 5 minutes ago
rate(http_requests_total[5m] offset 1w) # last-week's rate, same instant
```

The offset is placed **after** the metric name and after any `[range]`, but **before** any function wraps it. Week-over-week comparison:

```promql
  sum(rate(http_requests_total[5m]))
/ sum(rate(http_requests_total[5m] offset 1w))
```

**Negative offset** (shift into the *future* — meaningful only inside range queries) requires enabling the feature:

```promql
http_requests_total offset -5m
```
> Behind `--enable-feature=promql-negative-offset` in Prometheus 2.x; **stable by default in Prometheus 3.0**.

### 6.2 `@` — absolute time pin

`@ <unix_timestamp>` pins the selector's evaluation to a fixed wall-clock instant, **independent of the query's own evaluation time**. This is the tool for "compare everything against a known-good baseline":

```promql
http_requests_total @ 1609746000        # value at 2021-01-04T07:40:00Z, always
```

Special forms usable in **range queries** (`/api/v1/query_range`):

```promql
http_requests_total @ start()           # value at the range-query start
http_requests_total @ end()             # value at the range-query end
```

`@ start()` is the canonical way to draw a **flat baseline line** across a whole graph — the value is fixed to the range start and does not move as the graph steps forward.

> `@` was behind `--enable-feature=promql-at-modifier` in 2.x; **stable by default in Prometheus 3.0**.

### 6.3 Combining, and order-independence

`@` and `offset` compose. The offset is applied **relative to the `@` time**, and the two are order-independent — these are identical:

```promql
http_requests_total @ 1609746000 offset 5m
http_requests_total offset 5m @ 1609746000
# both evaluate the selector at 1609746000 − 300 = 1609745700
```

**Trade-off — baseline comparison strategies:**

| Technique | Baseline moves with graph? | Use case | Caveat |
|---|---|---|---|
| `offset 1w` | yes (relative) | week-over-week trend on a moving dashboard | seasonality must be exactly 1w |
| `@ <ts>` | no (absolute) | pin to a specific incident / deploy timestamp | timestamp is hardcoded, not portable |
| `@ start()` | no (per-render) | flat reference line across a range graph | only valid in range queries |
| recording rule snapshot | no (materialized) | expensive baseline reused by many alerts | adds a rule + storage |

---

## 7. Subqueries — a range vector from an instant expression

A subquery lets you run an instant expression *repeatedly over a window*, producing a range vector you can feed to a range function. Syntax:

```
<instant_expression> [ <range> : <resolution> ]
```

The `resolution` is optional and defaults to the global `evaluation_interval`. Canonical use — *the max 5-minute request rate seen over the last 30 minutes*:

```promql
max_over_time( rate(http_requests_total[5m])[30m:1m] )
```

This evaluates `rate(http_requests_total[5m])` at 1-minute steps across a 30-minute window, then takes the max. **Subqueries are expensive** — inner-range × outer-resolution samples per series — and are the #1 cause of `query processing would load too many samples` errors. Production guidance:

| Situation | Prefer |
|---|---|
| One-off exploration in the UI | subquery (fast to write) |
| Reused in alerts / dashboards | **recording rule** — materialize the inner `rate`, then range-select the recorded metric |
| Deep nesting (subquery of subquery) | refactor — almost always a recording-rule smell |

---

## 8. Staleness and the lookback delta

When a target stops exposing a series (target down, series no longer emitted, relabel-dropped), Prometheus injects a **stale marker** (a special NaN) at the next scrape. Effects on selection:

- An instant selector returns the series **until** the stale marker enters the lookback window, then **immediately drops it** — you do *not* wait the full 5 minutes if a stale marker was written.
- If the whole target vanishes without a graceful stale marker (e.g., network partition), the series lingers for **up to `--query.lookback-delta` (5m)** before selection stops returning it.

This is why `up == 0` and `absent(...)` fire on different timelines. Design alerts accordingly:

```promql
# Detects a target-down within one scrape, not up to 5 minutes later:
up{job="api"} == 0

# Detects a whole job disappearing (no series at all) — subject to lookback:
absent(up{job="api"})
```

---

## 9. Manifests — full, syntactically valid, unabridged

### 9.1 Prometheus server with the query-tuning flags that govern selection

```yaml
# prometheus-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
  labels:
    app.kubernetes.io/name: prometheus
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prometheus
    spec:
      serviceAccountName: prometheus
      containers:
        - name: prometheus
          image: prom/prometheus:v3.1.0
          args:
            - "--config.file=/etc/prometheus/prometheus.yml"
            - "--storage.tsdb.path=/prometheus"
            - "--storage.tsdb.retention.time=15d"
            # ── selection-critical flags ──────────────────────────────
            - "--query.lookback-delta=5m"        # staleness window for instant selectors
            - "--query.max-samples=50000000"     # hard ceiling on samples a single query may load
            - "--query.timeout=2m"
            - "--query.max-concurrency=20"
            # In Prometheus 3.x @ and negative-offset are ON by default;
            # no --enable-feature flags are required for them.
          ports:
            - name: web
              containerPort: 9090
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
            - name: tsdb
              mountPath: /prometheus
          readinessProbe:
            httpGet:
              path: /-/ready
              port: web
            initialDelaySeconds: 10
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              memory: "2Gi"
      volumes:
        - name: config
          configMap:
            name: prometheus-config
        - name: tsdb
          emptyDir: {}
```

### 9.2 Scrape config — the labels here are exactly what your selectors will match

```yaml
# prometheus-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s          # ← sets the natural sample cadence
      evaluation_interval: 15s      # ← default subquery resolution
      external_labels:
        cluster: prod-eu-west-1

    scrape_configs:
      - job_name: api               # becomes label job="api"
        kubernetes_sd_configs:
          - role: endpoints
            namespaces:
              names: [default]
        relabel_configs:
          # Keep only endpoints of Services annotated for scraping
          - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
            action: keep
            regex: "true"
          # Expose pod name as a queryable label
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          # Expose the node so you can select by topology
          - source_labels: [__meta_kubernetes_pod_node_name]
            target_label: node
```

### 9.3 Prometheus Operator `ServiceMonitor` — declarative scrape target

```yaml
# servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # matched by the Prometheus CR's serviceMonitorSelector
spec:
  namespaceSelector:
    matchNames: [default]
  selector:
    matchLabels:
      app.kubernetes.io/name: api
  endpoints:
    - port: metrics                  # named port on the Service
      interval: 15s
      path: /metrics
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
```

### 9.4 Recording rule — materialize an expensive selection so alerts select cheaply

```yaml
# recording-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: api-selection-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: api.rules
      interval: 30s
      rules:
        # Pre-compute the per-job 5m error rate once, so 20 alerts don't
        # each re-run the range selection + rate.
        - record: job:http_requests:rate5m
          expr: |
            sum by (job, code) (
              rate(http_requests_total{job="api"}[5m])
            )
        # Baseline pinned via subquery, materialized:
        - record: job:http_requests:rate5m_max30m
          expr: |
            max_over_time( job:http_requests:rate5m[30m:1m] )
```

---

## 10. CLI and real terminal output

### 10.1 Validate rules and selectors before shipping

```console
$ promtool check rules recording-rules.yaml
Checking recording-rules.yaml
  SUCCESS: 2 rules found
```

### 10.2 Instant query via `promtool` (an instant vector selector)

```console
$ promtool query instant http://localhost:9090 \
    'http_requests_total{job="api", code="500"}'
http_requests_total{code="500", instance="10.1.4.9:8080", job="api", pod="api-7c9f-abc"} => 42 @ 1739012400
http_requests_total{code="500", instance="10.1.4.9:8080", job="api", pod="api-7c9f-xyz"} => 17 @ 1739012400
```

The `@ 1739012400` on the right is the **sample timestamp** the lookback resolved to — confirm it is within `lookback-delta` of "now".

### 10.3 Range query (a range/matrix result), with a subquery baseline

```console
$ promtool query range --start=1739012000 --end=1739012400 --step=60 \
    http://localhost:9090 \
    'max_over_time(rate(http_requests_total{job="api"}[5m])[30m:1m])'
{job="api"} =>
  3.87 @[1739012000]
  4.02 @[1739012060]
  4.11 @[1739012120]
  4.11 @[1739012180]
  3.95 @[1739012240]
```

### 10.4 Raw HTTP API — what the engine actually returns for a vector selector

```console
$ curl -sG 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=up{job="api"}' | jq .
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": { "__name__": "up", "instance": "10.1.4.9:8080", "job": "api" },
        "value": [ 1739012400, "1" ]
      }
    ]
  }
}
```

`resultType: vector` ⇒ an instant selector. A range selector or range query returns `resultType: matrix` with a `values` array instead of a single `value`.

### 10.5 The `@` modifier and a negative offset over the API

```console
$ curl -sG 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=http_requests_total @ 1609746000 offset 5m' \
    --data-urlencode 'time=1739012400' | jq '.data.result[0].value'
[
  1739012400,
  "918"
]
```

Note the **result timestamp is 1739012400 (query time)** but the **value 918 is the sample at `1609746000 − 300`** — proof that `@`+`offset` decoupled the value's time from the query's time.

### 10.6 Measure the cost of a selector (cardinality) — TSDB introspection

```console
$ promtool tsdb analyze /prometheus
Block ID: 01HFZK...  Duration: 2h0m0s  Series: 1,284,551  Samples: 612,443,190

Label pairs most involved in churning series:
120334 __name__=apiserver_request_duration_seconds_bucket
 88210 le=<many>
 41002 job=api

Highest cardinality labels:
   le: 43  (histogram buckets)
   pod: 9,214
   instance: 512

Highest cardinality metric names:
   apiserver_request_duration_seconds_bucket: 214,553
   http_requests_total: 61,004
```

`http_requests_total` alone is 61k series — a bare `sum(rate(http_requests_total[5m]))` intersects nothing away and reads all 61k. Narrow it with `{job="api"}` **first**.

### 10.7 Live cardinality of a single selector via the TSDB status API

```console
$ curl -sG 'http://localhost:9090/api/v1/status/tsdb' | \
    jq '.data.seriesCountByMetricName[0:3]'
[
  { "name": "apiserver_request_duration_seconds_bucket", "value": 214553 },
  { "name": "http_requests_total", "value": 61004 },
  { "name": "node_cpu_seconds_total", "value": 18944 }
]
```

---

## 11. Verification & failure-diagnosis guide

| Symptom | Likely cause in selection | Diagnostic command / check | Fix |
|---|---|---|---|
| Query returns empty, metric "exists" | typo in a label value; regex not anchored as you think | `curl .../api/v1/label/job/values`; test regex with `{job=~"api"}` vs `{job=~".*api.*"}` | correct value; add explicit `.*` |
| `parse error: vector selector must contain at least one non-empty matcher` | every matcher can match `""` (e.g. `{job=~".*"}`) | read the expression | change `.*` → `.+` or add an `=` matcher |
| Series present, then intermittently missing | scrape_interval ≥ `--query.lookback-delta` | compare `scrape_interval` to lookback-delta | raise lookback-delta or lower scrape interval |
| `rate()` returns empty for short windows | `[range]` < ~2× scrape_interval → <2 samples in-window | check scrape interval vs range | use `[1m]`+ for 15s scrapes |
| `query processing would load too many samples` | wide selector or heavy subquery exceeds `--query.max-samples` | inspect cardinality via `status/tsdb` | narrow matchers; materialize with a recording rule |
| Alert flaps within ~5 min of target loss | relying on `absent()`/instant selector inside lookback window | correlate with `up == 0` timing | alert on `up == 0` for fast detection |
| Week-over-week comparison is off by hours | `offset 1w` ignores DST / calendar drift | verify `d`/`w` are 24h/7×24h fixed | pin with `@ <ts>` for exact baseline |
| 3.x upgrade changed edge samples of a recording rule | range boundary went `[..]` → `(..]` (left-open) | diff rule output across versions | usually benign; widen range if needed |

**Golden verification workflow before promoting any selector to an alert/rule:**

```console
# 1. Does it parse and is it a valid alert expression (instant vector)?
$ promtool check rules my-rules.yaml

# 2. How many series does it actually touch? (cost gate)
$ curl -sG 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=count(http_requests_total{job="api"})' | \
    jq '.data.result[0].value[1]'
"61"

# 3. Are the sample timestamps fresh (inside lookback)?
$ promtool query instant http://localhost:9090 \
    'timestamp(up{job="api"}) - time()'
{...} => -3   # 3s old → healthy, well within 5m lookback
```

If step 2 returns a number in the thousands for something you expected to be dozens, **stop** — your selector is under-constrained and will be your next latency incident.

---

## 12. Referencias (fuentes oficiales)

- **PCA Curriculum (CNCF):** https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
- **PromQL — Basics (instant/range selectors, matchers, durations):** https://prometheus.io/docs/prometheus/latest/querying/basics/
- **PromQL — Operators & modifiers (`offset`, `@`, subqueries):** https://prometheus.io/docs/prometheus/latest/querying/operators/
- **PromQL — Examples:** https://prometheus.io/docs/prometheus/latest/querying/examples/
- **Staleness:** https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness
- **HTTP API (`/api/v1/query`, `query_range`, `status/tsdb`):** https://prometheus.io/docs/prometheus/latest/querying/api/
- **Data model (labels, `__name__`, samples):** https://prometheus.io/docs/concepts/data_model/
- **Query engine flags (`--query.lookback-delta`, `--query.max-samples`):** https://prometheus.io/docs/prometheus/latest/command-line/prometheus/
- **Feature flags & `@`/negative-offset history:** https://prometheus.io/docs/prometheus/latest/feature_flags/
- **Prometheus 3.0 migration (range boundary change, defaults):** https://prometheus.io/docs/prometheus/latest/migration/
- **RE2 regex syntax:** https://github.com/google/re2/wiki/Syntax
- **Prometheus Operator — ServiceMonitor / PrometheusRule API:** https://prometheus-operator.dev/docs/operator/api/
- **promtool reference:** https://prometheus.io/docs/prometheus/latest/command-line/promtool/