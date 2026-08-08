# PCA 1.5 — Binary Operators

> Domain: PromQL · Exam weight: 4
> Profile: SRE / Platform Architect — production depth

---

## 1. Motivation: the architectural problem binary operators solve

A time series database that could only *select* and *aggregate* would let you answer "how many requests per second is this handler serving?" but never the questions that actually drive an SLO:

- What **fraction** of requests are errors? (a division of two independent vectors)
- Is memory usage **above** a threshold *relative to the limit*, not an absolute byte count? (a ratio + comparison)
- Which instances are **up but not receiving traffic**? (a set difference between two metrics with different `__name__`)
- What is the **headroom** between provisioned capacity and current demand? (a subtraction across two series families that share only *some* labels)

None of these are aggregations. They are **pairwise operations between two time series families**, and the entire difficulty — the part that fails in production and shows up on the exam — is not the arithmetic. It is **matching**: given a left vector with N series and a right vector with M series, which left series pairs with which right series, and what happens to the labels of the result.

Prometheus does not do a Cartesian product. It performs a **relational join on the label set**, and if that join is ambiguous it refuses to run the query. Binary operators are, in effect, PromQL's `JOIN` clause, and `on` / `ignoring` / `group_left` / `group_right` are its join keys and cardinality declarations. An SRE who does not internalize this writes ratio panels that silently return empty, or alerting rules that throw `many-to-many matching not allowed` at 3 a.m. during an incident.

There are three families of binary operator, and they behave differently with respect to matching and label output:

| Family | Operators | Result on `vector op vector` |
|---|---|---|
| **Arithmetic** | `+  -  *  /  %  ^  atan2` | Value computed pairwise; **metric name dropped**; result keeps the matched label set |
| **Comparison** | `==  !=  >  <  >=  <=` | Filters (drops non-matching series) by default; with `bool` returns `0`/`1` and keeps series |
| **Logical / set** | `and  or  unless` | Set operations on the *series* themselves; only defined for `vector op vector` |

---

## 2. Operand types and the three matching regimes

Every binary operation is one of three shapes. The shape determines whether matching happens at all.

| Left | Right | Matching? | Result | Notes |
|---|---|---|---|---|
| scalar | scalar | none | scalar | Pure math: `4 * 1024` → `4096`. Comparisons yield `0`/`1`. |
| vector | scalar | none | vector | Op applied to every element. Metric name **kept** (arithmetic). |
| vector | vector | **yes** | vector | Requires a label-based join. Metric name **dropped** (arithmetic). |

### 2.1 Why the metric name disappears

For `vector op vector` and `vector op scalar` arithmetic, Prometheus drops `__name__` from the result, because `http_requests_total / 60` is no longer `http_requests_total` — it is a rate-like derived quantity with no canonical name. This is deliberate and has a consequence: **the result of an arithmetic op is an anonymous vector**. If you then try to combine it again, you match on the *remaining* labels only. This is the single most common source of "why is my join empty" confusion.

### 2.2 Vector matching: one-to-one

By default, two vector operands match **one-to-one**: for each entry on the left, Prometheus looks for exactly one entry on the right with an **identical label set**, and produces one result. Entries with no partner on the other side are dropped from the result.

You reshape the join key with:

- **`ignoring(<labels>)`** — match on all labels *except* the listed ones.
- **`on(<labels>)`** — match on *only* the listed labels.

```promql
# Error ratio per (job, instance): numerator and denominator share
# job+instance but differ in `code`, so we must ignore `code`.
sum by (job, instance) (rate(http_requests_total{code=~"5.."}[5m]))
  /
sum by (job, instance) (rate(http_requests_total[5m]))
```

Here the two `sum by (job, instance)` results already carry only `job` and `instance`, so the label sets are identical and the one-to-one match is exact — no `on`/`ignoring` needed. This is the canonical pattern: **aggregate both sides to the same label set first, then divide.** It sidesteps almost every matching problem.

### 2.3 Vector matching: many-to-one and one-to-many

When the two sides have **different cardinality** — many series on one side share a single series on the other — you must declare it explicitly, or Prometheus aborts. `group_left` / `group_right` name the **"many" side** and optionally **copy extra labels from the "one" side** into the result.

```promql
# Requests per pod, joined against the pod's owning deployment info metric.
# Left has one series per (pod); right (kube_pod_info) is the "one" that
# carries `created_by_name`. We copy that label onto every left series.
rate(http_requests_total[5m])
  * on (pod, namespace) group_left (created_by_name)
kube_pod_info
```

- `group_left(labels)`  → **left side is many**, right side is one; `labels` are pulled from the **right**.
- `group_right(labels)` → **right side is many**, left side is one; `labels` are pulled from the **left**.

The labels inside `group_left(...)` are *additive*: they extend the result's label set with values from the "one" side. This is how you decorate a high-cardinality metric with metadata (owner, team, tier) from an info-style metric.

| Situation | Construct | "many" side | Extra labels come from |
|---|---|---|---|
| Both sides identical label set | *(none)* | — | — |
| Match on a subset | `on(...)` / `ignoring(...)` | — | — |
| Left has higher cardinality | `group_left(...)` | left | right (the "one") |
| Right has higher cardinality | `group_right(...)` | right | left (the "one") |

**Many-to-many is never allowed.** If, after applying `on`/`ignoring`, a single left series matches multiple right series *and* vice versa, Prometheus fails the query. The fix is always to make one side unique on the join key (usually by aggregating it).

### 2.4 Logical / set operators

These operate on the *presence* of series, not their values, and are only defined for `vector op vector`. Matching is one-to-one on the full label set (adjustable with `on`/`ignoring`).

| Operator | Semantics | Values / labels of result |
|---|---|---|
| `and` (intersection) | Left series that have a matching series on the right | **Left** values and labels |
| `or` (union) | All left series, plus right series with no left match | Respective values/labels |
| `unless` (complement) | Left series that have **no** matching series on the right | **Left** values and labels |

```promql
# Instances that are up but currently serving zero traffic — a "dark" endpoint.
(up == 1) unless (rate(http_requests_total[5m]) > 0)
```

`and`/`unless` never change values; they filter which series survive. This makes them the right tool for **conditional alerting** ("fire this only when *also* that").

---

## 3. Comparison operators: filter vs. `bool`

Comparison operators have two modes, and the difference is central to both alerting and dashboards.

### 3.1 Default (filtering) mode

`vector > scalar` **removes** every series whose value fails the comparison and keeps the surviving series **with their original value**. This is what makes an alert expression fire only on breaching series:

```promql
# Only instances whose 5xx ratio exceeds 5% survive — each with its real ratio.
sum by (instance) (rate(http_requests_total{code=~"5.."}[5m]))
  /
sum by (instance) (rate(http_requests_total[5m]))
  > 0.05
```

### 3.2 `bool` modifier

Prefixing the operator with `bool` changes the result to `0` (false) or `1` (true) **for every input series**, keeping them all. Use it when you need a boolean signal series rather than a filter — e.g. counting how many instances breach, or graphing a step function.

```promql
# 1 when the instance is over budget, 0 otherwise — for every instance.
(rate(http_requests_total{code=~"5.."}[5m]) / rate(http_requests_total[5m]))
  > bool 0.05

# How many instances are currently breaching?
count(
  (rate(http_requests_total{code=~"5.."}[5m]) / rate(http_requests_total[5m]))
    > bool 0.05
)
```

For **scalar `op` scalar** comparisons, `bool` is **mandatory** — a bare `2 > 1` is a parse error, because a scalar comparison must resolve to a value, and Prometheus forces you to say so with `bool`.

| Need | Use | Result |
|---|---|---|
| Alert only on breaching series | bare comparison | filtered vector, real values |
| Boolean signal for all series | `bool` comparison | every series → `0` / `1` |
| Compare two scalars | `bool` **required** | `0` / `1` |
| Count breaches | `count(... > bool ...)` | scalar count |

---

## 4. Operator precedence and associativity

Binary operators bind in a fixed order. Getting this wrong silently changes the meaning of an expression — `a / b * 100` is `(a / b) * 100` (correct for a percentage), but `a + b / c` is `a + (b / c)`.

**Precedence, highest to lowest:**

| Level | Operators | Associativity |
|---|---|---|
| 1 | `^` | **right** |
| 2 | `*  /  %  atan2` | left |
| 3 | `+  -` | left |
| 4 | `==  !=  <=  <  >=  >` | left |
| 5 | `and  unless` | left |
| 6 | `or` | left |

Right-associativity of `^` means `2 ^ 3 ^ 2` = `2 ^ (3 ^ 2)` = `2^9` = `512`, **not** `64`. When in doubt, parenthesize — production PromQL should never rely on a reader recalling this table.

```promql
# WRONG: precedence makes this  cache_hits + (cache_misses/anything) ...
# Always parenthesize ratios:
100 * (
  rate(cache_hits_total[5m])
  /
  (rate(cache_hits_total[5m]) + rate(cache_misses_total[5m]))
)
```

---

## 5. Production manifests

### 5.1 Prometheus scrape + rules configuration

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: prod-eu-west-1

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: api
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: api
        action: keep
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
```

### 5.2 Recording rules — pre-compute the joins

Ratio and join expressions are expensive at query time and re-evaluated on every dashboard refresh. Bake them into recording rules so the binary operation runs **once per evaluation interval**, and Grafana reads a single cheap series.

```yaml
# /etc/prometheus/rules/slo.yml
groups:
  - name: slo-ratios
    interval: 30s
    rules:
      # ---- 5xx error ratio per service (vector / vector, one-to-one) ----
      - record: job:http_error_ratio:ratio5m
        expr: |
          sum by (job, namespace) (rate(http_requests_total{code=~"5.."}[5m]))
            /
          sum by (job, namespace) (rate(http_requests_total[5m]))

      # ---- Decorate with team ownership (many-to-one, group_left) ----
      - record: job:http_error_ratio:ratio5m:owned
        expr: |
          job:http_error_ratio:ratio5m
            * on (namespace) group_left (team)
          namespace_ownership_info

      # ---- Memory headroom as a fraction of the limit ----
      - record: pod:memory_utilization:ratio
        expr: |
          container_memory_working_set_bytes{container!=""}
            /
          on (namespace, pod, container)
          kube_pod_container_resource_limits{resource="memory"}
```

### 5.3 Alerting rules — comparison + set operators

```yaml
# /etc/prometheus/rules/alerts.yml
groups:
  - name: slo-alerts
    rules:
      # Comparison in filtering mode: only breaching services survive.
      - alert: HighErrorRatio
        expr: job:http_error_ratio:ratio5m:owned > 0.05
        for: 10m
        labels:
          severity: page
        annotations:
          summary: "{{ $labels.job }} error ratio {{ $value | humanizePercentage }} (team {{ $labels.team }})"

      # `unless`: pod is over its memory limit ratio AND not being throttled
      # away by an already-firing OOM alert (set complement).
      - alert: MemoryPressure
        expr: |
          (pod:memory_utilization:ratio > 0.90)
            unless
          (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1)
        for: 5m
        labels:
          severity: warning

      # Set intersection: instance is up AND its scrape target is stale.
      - alert: StaleButUp
        expr: |
          (up == 1)
            and
          (time() - process_start_time_seconds > 0)  # placeholder guard
            and
          (rate(http_requests_total[5m]) == 0)
        for: 15m
        labels:
          severity: warning
```

---

## 6. CLI: real commands and expected output

### 6.1 Validate the rules before shipping

```console
$ promtool check rules /etc/prometheus/rules/slo.yml /etc/prometheus/rules/alerts.yml
Checking /etc/prometheus/rules/slo.yml
  SUCCESS: 3 rules found
Checking /etc/prometheus/rules/alerts.yml
  SUCCESS: 3 rules found
```

### 6.2 Evaluate an instant query with `promtool`

```console
$ promtool query instant http://localhost:9090 \
    'sum by (job)(rate(http_requests_total{code=~"5.."}[5m])) / sum by (job)(rate(http_requests_total[5m]))'
{job="api"} => 0.032258064516129 @[1754640000]
{job="checkout"} => 0.114285714285714 @[1754640000]
{job="static"} => 0 @[1754640000]
```

Note the result carries **no `__name__`** — arithmetic dropped it — and only the `job` label survived, because both sides were aggregated `by (job)`.

### 6.3 The `bool` modifier, seen at the API

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=(rate(http_requests_total{code=~"5.."}[5m]) / rate(http_requests_total[5m])) > bool 0.05' \
  | jq '.data.result[] | {instance: .metric.instance, breach: .value[1]}'
{
  "instance": "10.1.4.7:8080",
  "breach": "0"
}
{
  "instance": "10.1.4.9:8080",
  "breach": "1"
}
```

Every input series is retained; the value is the boolean. Drop `bool` and only `10.1.4.9:8080` would appear, carrying its real ratio.

### 6.4 Reproduce a matching failure deliberately

```console
$ promtool query instant http://localhost:9090 \
    'container_memory_working_set_bytes / kube_pod_container_resource_limits'
Error executing query: found duplicate series for the match group
{namespace="prod", pod="api-7c9", container="api"} on the right hand-side of
the operation: [...]; many-to-many matching not allowed: matching labels must
be unique on one side
```

The right side has extra labels (`resource`, `unit`) that make several series collide on the same join key. The fix is §2.3: constrain and pin the join.

```console
$ promtool query instant http://localhost:9090 \
    'container_memory_working_set_bytes{container!=""}
       / on (namespace,pod,container)
     kube_pod_container_resource_limits{resource="memory"}'
{namespace="prod", pod="api-7c9", container="api"} => 0.734 @[1754640000]
```

---

## 7. Verification & failure diagnosis

| Symptom | Root cause | Diagnosis | Fix |
|---|---|---|---|
| Query returns **empty vector** | Label sets differ, so one-to-one match finds no partners | Run each side alone; diff the label sets with `count by(__name__)(...)` or inspect in the expression browser | Aggregate both sides to the same labels, or add `on()`/`ignoring()` |
| `many-to-many matching not allowed` | Extra labels make the join key non-unique on both sides | Look at which labels differ between sides | Add `on(<join-keys>)`, and/or filter one side to be unique |
| `multiple matches for labels ... group_left/right` | Declared "one" side actually has multiple series per key | The "one" side isn't unique | Aggregate the "one" side (`max/min/sum by(...)`) or tighten its selector |
| Ratio **> 1** or negative | Numerator and denominator not from the same population, or counter reset inside a non-`rate` subtraction | Compare numerator/denominator series individually | Use `rate()` on both; ensure numerator ⊆ denominator |
| Percentage panel shows `0` everywhere | `bool` accidentally left in, or precedence turned the ratio into `a + b/c` | Read the expression tree; check for stray `bool` | Remove `bool`; parenthesize |
| Metric name unexpectedly gone downstream | Arithmetic op dropped `__name__`; a later `on(__name__)` join now fails | Query the intermediate result | Match on real labels, not `__name__`; use recording rules to name it |
| Scalar comparison rejected at parse | Bare `x > y` where both are scalars | `promtool check` / parse error | Add `bool`: `x > bool y` |

**Diagnostic workflow for any failing join:**

1. **Split it.** Run the left and right operands as separate queries.
2. **Compare label sets.** `sum without()(<left>)` vs `<right>` in the browser, or `count by (<join-key>) (<side>)` — any count `> 1` on the "one" side is your bug.
3. **Pin the key.** Add `on(<explicit join keys>)`; never rely on implicit full-label matching in production.
4. **Declare cardinality.** If one side is legitimately many, add `group_left`/`group_right` naming the many side.
5. **Name the result.** Promote the working expression to a recording rule so downstream queries never re-derive the join.

```console
# Step 2 in practice — is the "one" side actually unique on the key?
$ promtool query instant http://localhost:9090 \
    'count by (namespace, pod, container) (kube_pod_container_resource_limits{resource="memory"})'
{namespace="prod", pod="api-7c9", container="api"} => 1 @[1754640000]
{namespace="prod", pod="api-7c9", container="istio-proxy"} => 1 @[1754640000]
# Every count is 1 → the key is unique → the join is safe.
```

---

## 8. References

- **CNCF Prometheus Certified Associate — Curriculum:** https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
- **PromQL — Operators (binary operators, vector matching, precedence):** https://prometheus.io/docs/prometheus/latest/querying/operators/
- **PromQL — Basics (expression language data types, selectors):** https://prometheus.io/docs/prometheus/latest/querying/basics/
- **PromQL — Query examples (ratios, joins):** https://prometheus.io/docs/prometheus/latest/querying/examples/
- **Recording rules:** https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- **Alerting rules:** https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- **HTTP API — `/api/v1/query` (instant queries):** https://prometheus.io/docs/prometheus/latest/querying/api/
- **`promtool` (rule checking and query CLI):** https://github.com/prometheus/prometheus/blob/main/docs/command-line/promtool.md