# Guided Exercises — Topic 1.4: Aggregating over Dimensions

> **Domain:** PromQL · **Exam weight:** 4 · **Certification:** Prometheus Certified Associate (PCA)
>
> These exercises are **reproducible**: you build a small Prometheus + Pushgateway lab, load a *deterministic* multi-dimensional dataset, and every expected output below is hand-computed from that data. Work through the steps in order, answer the checkpoint questions **before** expanding the answers section at the end.
>
> **Reference sources (official):**
> - Aggregation operators — https://prometheus.io/docs/prometheus/latest/querying/operators/#aggregation-operators
> - Querying basics (instant vs range vectors) — https://prometheus.io/docs/prometheus/latest/querying/basics/
> - Query functions (`rate`, `*_over_time`) — https://prometheus.io/docs/prometheus/latest/querying/functions/
> - Recording-rule / aggregation best practices — https://prometheus.io/docs/practices/rules/
> - Pushgateway — https://github.com/prometheus/pushgateway
> - PCA Curriculum — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf

---

## What "aggregating over dimensions" actually means

A Prometheus **instant vector** is a set of time series, each identified by a unique combination of labels, evaluated at a single instant. Those labels *are* the dimensions. An **aggregation operator** collapses one or more of those dimensions, folding many series into fewer (or one) by combining their sample values.

Keep two orthogonal axes clear from the start — the exam tests the confusion between them:

| | Collapses the **series (label) dimension** | Collapses the **time dimension** |
|---|---|---|
| Operates at | one instant, across many series | one series, across a time range |
| Tooling | aggregation **operators**: `sum`, `avg`, `topk`, `quantile`, … with `by`/`without` | aggregation **functions**: `sum_over_time`, `avg_over_time`, `max_over_time`, … |
| Input | instant vector | range vector |

Topic 1.4 is the **left column**. Exercise 8 makes the contrast explicit so you never reach for the wrong one.

---

## Exercise 0 — Build the lab

**Steps**

1. Create a working directory and the Prometheus config. Note `honor_labels: true` on the Pushgateway job — it makes Prometheus keep the labels we push (`job="demo_api"`) instead of overwriting them.

   ```bash
   mkdir promql-agg && cd promql-agg
   ```

   `prometheus.yml`:
   ```yaml
   global:
     scrape_interval: 5s
     evaluation_interval: 5s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']

     - job_name: pushgateway
       honor_labels: true          # keep pushed job/instance labels verbatim
       static_configs:
         - targets: ['pushgateway:9091']
   ```

2. Bring up Prometheus and Pushgateway with Compose.

   `docker-compose.yml`:
   ```yaml
   services:
     prometheus:
       image: prom/prometheus:v2.53.0
       command:
         - --config.file=/etc/prometheus/prometheus.yml
       volumes:
         - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
       ports:
         - "9090:9090"

     pushgateway:
       image: prom/pushgateway:v1.9.0
       ports:
         - "9091:9091"
   ```

   ```bash
   docker compose up -d
   ```

3. Push the deterministic dataset. This is a *static* set of counter/gauge samples — perfect for instant-vector aggregation because the values never move.

   ```bash
   cat <<'EOF' | curl --data-binary @- http://localhost:9091/metrics/job/demo_api
   # TYPE demo_http_requests_total counter
   demo_http_requests_total{region="us-east",app="checkout",method="GET",code="200"} 100
   demo_http_requests_total{region="us-east",app="checkout",method="GET",code="500"} 5
   demo_http_requests_total{region="us-east",app="checkout",method="POST",code="200"} 40
   demo_http_requests_total{region="us-east",app="cart",method="GET",code="200"} 200
   demo_http_requests_total{region="us-east",app="cart",method="GET",code="500"} 20
   demo_http_requests_total{region="eu-west",app="checkout",method="GET",code="200"} 80
   demo_http_requests_total{region="eu-west",app="checkout",method="GET",code="500"} 10
   demo_http_requests_total{region="eu-west",app="cart",method="GET",code="200"} 150
   demo_http_requests_total{region="eu-west",app="cart",method="POST",code="200"} 60
   demo_http_requests_total{region="eu-west",app="cart",method="POST",code="500"} 15
   # TYPE demo_pods_ready gauge
   demo_pods_ready{node="n1"} 3
   demo_pods_ready{node="n2"} 3
   demo_pods_ready{node="n3"} 5
   demo_pods_ready{node="n4"} 3
   demo_pods_ready{node="n5"} 5
   EOF
   ```

4. Wait ~10 s for a scrape, then confirm the data landed. From here on you can run queries **either** in the expression browser at http://localhost:9090/graph (use the **Table** tab) **or** via the HTTP API:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count(demo_http_requests_total)' \
     | jq '.data.result[0].value[1]'
   ```

   Expected output:
   ```
   "10"
   ```

**Checkpoint**

- **Q1.** `demo_http_requests_total` has ten series. Which *labels* are the dimensions available to aggregate over? (Include the ones Pushgateway added.)
- **Q2.** Why does the Table view — not the Graph view — matter for the aggregations you're about to run on this static dataset?

---

## Exercise 1 — Your first collapse, and the disappearing metric name

**Steps**

1. Sum every series into a single scalar-per-vector:

   ```
   sum(demo_http_requests_total)
   ```
   Expected (Table view):
   ```
   {}   680
   ```

2. Look hard at the result's label set: `{}`. Now compare against a query that does **not** aggregate:

   ```
   demo_http_requests_total{app="cart",region="us-east"}
   ```
   Expected:
   ```
   demo_http_requests_total{app="cart",code="200",method="GET",region="us-east",job="demo_api"}   200
   demo_http_requests_total{app="cart",code="500",method="GET",region="us-east",job="demo_api"}    20
   ```

3. Confirm the total independently: `100+5+40+200+20+80+10+150+60+15 = 680`.

**Checkpoint**

- **Q3.** The aggregated result lost the `__name__` label (the metric name `demo_http_requests_total`) *and* every other label. State the general rule about what aggregation operators do to labels **when no `by`/`without` clause is given**.
- **Q4.** True or false: `sum(demo_http_requests_total)` and `sum(demo_pods_ready)` could ever collide into the same output series if run in the same expression. Explain in terms of label sets.

---

## Exercise 2 — Grouping with `by`

`by (<labels>)` says *keep only these labels*; everything else is folded away.

**Steps**

1. Requests per region:
   ```
   sum by (region) (demo_http_requests_total)
   ```
   Expected:
   ```
   {region="us-east"}   365
   {region="eu-west"}   315
   ```

2. Requests per app:
   ```
   sum by (app) (demo_http_requests_total)
   ```
   Expected:
   ```
   {app="checkout"}   235
   {app="cart"}       445
   ```

3. Two-dimensional grouping — region × response class:
   ```
   sum by (region, code) (demo_http_requests_total)
   ```
   Expected:
   ```
   {region="us-east",code="200"}   340
   {region="us-east",code="500"}    25
   {region="eu-west",code="200"}   290
   {region="eu-west",code="500"}    25
   ```

4. Via the API, to see the raw shape:
   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=sum by (region) (demo_http_requests_total)' \
     | jq -c '.data.result[] | {metric, value: .value[1]}'
   ```
   Expected:
   ```
   {"metric":{"region":"us-east"},"value":"365"}
   {"metric":{"region":"eu-west"},"value":"315"}
   ```

**Checkpoint**

- **Q5.** Every one of the sub-totals in steps 1–3 adds back up to 680. Why is that guaranteed for `sum`, and would it still hold for `avg` or `max`?
- **Q6.** In step 3, series with the same `(region, code)` pair were combined even though they differ in `app` and `method`. Describe the grouping rule in one sentence: which series end up in the same group?

---

## Exercise 3 — `without`: the complement (and why it survives new labels)

`without (<labels>)` says *drop exactly these labels, keep all the rest* (the metric name `__name__` is still removed). It is the inverse of `by`.

**Steps**

1. Collapse only `method` and `code`, keeping the rest of the identity intact:
   ```
   sum without (method, code) (demo_http_requests_total)
   ```
   Expected:
   ```
   {region="us-east",app="checkout",job="demo_api"}   145
   {region="us-east",app="cart",job="demo_api"}       220
   {region="eu-west",app="checkout",job="demo_api"}    90
   {region="eu-west",app="cart",job="demo_api"}       225
   ```

2. Write the `by` query that produces the **same numbers** but a **different label set**:
   ```
   sum by (region, app) (demo_http_requests_total)
   ```
   Expected:
   ```
   {region="us-east",app="checkout"}   145
   {region="us-east",app="cart"}       220
   {region="eu-west",app="checkout"}    90
   {region="eu-west",app="cart"}       225
   ```

3. Note the difference: the `without` result still carries `job="demo_api"`; the `by` result dropped it.

**Checkpoint**

- **Q7.** A teammate later adds a new label `canary="true"` to some series and re-pushes. The dashboard uses `sum by (region, app) (...)`. Does the new `canary` label appear in the output? What would happen instead if the query used `sum without (method, code) (...)`? Which of the two is more robust to *new* dimensions appearing, and which is more robust to *unwanted* dimensions leaking in?
- **Q8.** Rewrite `sum by (region) (demo_http_requests_total)` as a `without` clause that yields the identical label set `{region="…"}`. (Hint: you must name every label that is *not* `region`, and it will keep `job` unless you list it.)

---

## Exercise 4 — Choosing the operator: `sum` / `avg` / `min` / `max` / `count` / `group`

The grouping is orthogonal to the *reducer*. Same `by (region)`, six different questions.

**Steps**

1. Run each and read the semantics off the numbers:
   ```
   sum   by (region) (demo_http_requests_total)
   avg   by (region) (demo_http_requests_total)
   min   by (region) (demo_http_requests_total)
   max   by (region) (demo_http_requests_total)
   count by (region) (demo_http_requests_total)
   group by (region) (demo_http_requests_total)
   ```
   Expected:
   ```
   sum     {region="us-east"} 365     {region="eu-west"} 315
   avg     {region="us-east"} 73      {region="eu-west"} 63
   min     {region="us-east"} 5       {region="eu-west"} 10
   max     {region="us-east"} 200     {region="eu-west"} 150
   count   {region="us-east"} 5       {region="eu-west"} 5
   group   {region="us-east"} 1       {region="eu-west"} 1
   ```

2. Count *distinct* apps across the whole dataset using `group` as a deduplicator:
   ```
   count(group by (app) (demo_http_requests_total))
   ```
   Expected:
   ```
   {}   2
   ```

**Checkpoint**

- **Q9.** `avg by (region)` returned 73 and 63. Confirm 73 by hand from the us-east series, and state exactly what `avg` divides by.
- **Q10.** `count` returned 5 per region, but the *values* of those series range from 5 to 200. What does `count` count — samples, series, or the sum of values?
- **Q11.** `group` returned 1 for every group regardless of the underlying values. Give one production query where that "always 1" behavior is exactly what you want.

---

## Exercise 5 — Parameterized aggregators: `topk` / `bottomk` (and their range-query trap)

`topk` and `bottomk` take a numeric **parameter** `k` before the vector. Unlike `sum`/`avg`, they **do not collapse** series into a computed value — they *select* the k input series and return them **with their original labels and metric name intact**.

**Steps**

1. Three busiest series overall:
   ```
   topk(3, demo_http_requests_total)
   ```
   Expected (note the full labels *and* the metric name survive):
   ```
   demo_http_requests_total{region="us-east",app="cart",code="200",method="GET"}       200
   demo_http_requests_total{region="eu-west",app="cart",code="200",method="GET"}       150
   demo_http_requests_total{region="us-east",app="checkout",code="200",method="GET"}   100
   ```

2. Quietest single series:
   ```
   bottomk(1, demo_http_requests_total)
   ```
   Expected:
   ```
   demo_http_requests_total{region="us-east",app="checkout",code="500",method="GET"}   5
   ```

3. Combine `topk` with a grouping clause to get **top-1 per region**:
   ```
   topk(1, demo_http_requests_total) by (region)
   ```
   Expected:
   ```
   demo_http_requests_total{region="us-east",app="cart",code="200",method="GET"}   200
   demo_http_requests_total{region="eu-west",app="cart",code="200",method="GET"}   150
   ```

4. `topk` over a pre-aggregation — "top 2 (region, app) pairs by traffic":
   ```
   topk(2, sum by (region, app) (demo_http_requests_total))
   ```
   Expected:
   ```
   {region="eu-west",app="cart"}    225
   {region="us-east",app="cart"}    220
   ```

**Checkpoint**

- **Q12.** In step 1, `topk` kept `__name__` and every label, while `sum` in Exercise 1 threw them away. Why is that the *correct* behavior for `topk` specifically?
- **Q13.** You graph `topk(3, rate(demo_http_requests_total[5m]))` over the last 6 hours and get a jagged mess where series appear and vanish. Explain, in terms of *per-instant evaluation*, why `topk` is dangerous in a **range** query and fine in an **instant** query. What is the usual production fix (think alerting/table panels vs. time-series panels)?

---

## Exercise 6 — `count_values`: turning sample values into a distribution

`count_values("<newlabel>", <vector>)` groups series **by their sample value**, and reports how many series share each value — writing that value into a brand-new label.

**Steps**

1. How many nodes have each ready-pod count?
   ```
   count_values("ready_pods", demo_pods_ready)
   ```
   Expected:
   ```
   {ready_pods="3"}   3
   {ready_pods="5"}   2
   ```

2. Contrast with `count`, which ignores the values entirely:
   ```
   count(demo_pods_ready)
   ```
   Expected:
   ```
   {}   5
   ```

**Checkpoint**

- **Q14.** In step 1, the original `node` label vanished and a new `ready_pods` label appeared. What determines the *number of output series* from `count_values`?
- **Q15.** Name a real-world use: you have `kube_pod_info` or a `build_info`-style metric. Sketch a `count_values(...)` query that answers "how many targets are running each application version?" — and state the one requirement the metric's **sample value** must satisfy for `count_values` to be the right tool.

---

## Exercise 7 — `quantile` / `stddev` / `stdvar` over the series dimension

These reduce a group of series to a statistic of their **current sample values** — *across series*, at one instant. (Do not confuse `quantile()` the aggregation with `histogram_quantile()`, which reconstructs a quantile from bucket series — a different Topic.)

**Steps**

1. Median request count across all ten series:
   ```
   quantile(0.5, demo_http_requests_total)
   ```
   Expected:
   ```
   {}   50
   ```

2. 90th percentile across all series:
   ```
   quantile(0.9, demo_http_requests_total)
   ```
   Expected:
   ```
   {}   155
   ```

3. Spread of traffic within each region:
   ```
   stddev by (region) (demo_http_requests_total)
   stdvar by (region) (demo_http_requests_total)
   ```
   Expected (rounded):
   ```
   stddev  {region="us-east"} 71.25    {region="eu-west"} 50.95
   stdvar  {region="us-east"} 5076     {region="eu-west"} 2596
   ```

**Checkpoint**

- **Q16.** Prometheus computes `quantile(0.5, …)` by sorting the group's values and linearly interpolating at rank `φ·(n−1)`. With the ten sorted values `5,10,15,20,40,60,80,100,150,200`, show the arithmetic that yields **50** for φ=0.5.
- **Q17.** `stdvar by (region)` for us-east is 5076 = `stddev²` (71.25² ≈ 5076). Is Prometheus dividing the squared deviations by `n` or by `n−1`? State which (population vs. sample) and why that matters when you compare against a value someone computed in a spreadsheet.

---

## Exercise 8 — Series dimension vs. time dimension (the classic mix-up)

Aggregation *operators* need an **instant vector**. If you hand one a **range vector**, you get a parse error — and the fix is a time-dimension *function*, not an operator.

**Steps**

1. Deliberately trigger the error:
   ```
   sum(demo_http_requests_total[5m])
   ```
   Expected:
   ```
   Error executing query: expected type instant vector in aggregation expression, got range vector
   ```

2. Collapse the **time** dimension of one series with an `_over_time` function (max value seen per series over 5 minutes):
   ```
   max_over_time(demo_http_requests_total[5m])
   ```
   Expected: ten series returned, each keeping its full label set, value = its max sample in the window (here equal to the constant pushed value, e.g. `200`, `150`, …).

3. Collapse **both** dimensions — max over time, then summed across series — by nesting the operator *outside* the function:
   ```
   sum(max_over_time(demo_http_requests_total[5m]))
   ```
   Expected:
   ```
   {}   680
   ```

**Checkpoint**

- **Q18.** Precisely why did step 1 fail while step 3 succeeded? Reference the input type each `sum` received.
- **Q19.** A colleague wants "the average CPU of each instance over the last hour." They wrote `avg by (instance) (node_cpu_seconds_total[1h])`. Diagnose the two problems (type mismatch *and* the missing `rate`) and write a corrected expression.

---

## Exercise 9 — Aggregate the rate; never rate the aggregate

The single most-tested aggregation pitfall with **counters**: order matters. You must compute `rate()` **per series first**, then aggregate — because `rate` needs to detect counter resets *within each individual series*, and independent resets get lost the moment you sum raw counters.

**Steps**

1. Generate real, *increasing* counter traffic against Prometheus's own metrics (each query bumps `prometheus_http_requests_total`):
   ```bash
   for i in $(seq 1 60); do
     curl -s 'http://localhost:9090/api/v1/query?query=up' >/dev/null
     sleep 1
   done
   ```

2. **Correct** — rate each handler series, then sum:
   ```
   sum(rate(prometheus_http_requests_total[1m]))
   ```
   Expected: a small positive per-second rate (e.g. `~3.2`), stable and meaningful.

3. **Wrong** — sum the raw counters, then try to rate the aggregate with a subquery:
   ```
   rate(sum(prometheus_http_requests_total)[1m:15s])
   ```
   Expected: a number that *looks* plausible on a healthy system but silently misbehaves the instant any underlying series resets (restart / churned target), because the aggregate can no longer see the individual resets.

4. See the per-series rates before they are summed:
   ```
   topk(5, rate(prometheus_http_requests_total[1m]))
   ```
   Expected: the five busiest handlers (e.g. `/api/v1/query`) with their individual per-second rates.

**Checkpoint**

- **Q20.** State the rule as a memorizable order: for counters, which of `rate()` / `sum()` must be the **inner** function and which the **outer**? Give the reason in terms of counter-reset detection.
- **Q21.** Does the same "inner rate" rule apply to `demo_pods_ready` (a gauge)? Why or why not?

---

## Exercise 10 — Diagnostic: "half my labels disappeared"

A realistic on-call scenario combining everything above.

**Steps**

1. An engineer's panel query is:
   ```
   sum(rate(demo_http_requests_total[5m])) by (region)
   ```
   They complain the panel is flat at zero. First, confirm the *rate* is genuinely zero here:
   ```
   sum by (region) (rate(demo_http_requests_total[5m]))
   ```
   Expected:
   ```
   {region="us-east"}   0
   {region="eu-west"}   0
   ```

2. Now confirm the *counts* are non-zero:
   ```
   sum by (region) (demo_http_requests_total)
   ```
   Expected: `365` / `315` as in Exercise 2.

3. Explain the flat panel and record the fix (the pushed values are constant → `rate` is 0). Then reproduce a genuine label-loss bug:
   ```
   sum by (app) (demo_http_requests_total)   # keeps only app
   ```
   and note that `region`, `method`, `code`, `job` are all gone — expected, but a frequent surprise.

**Checkpoint**

- **Q22.** The two queries in step 1 (`sum(...) by (region)` vs `sum by (region) (...)`) — are they equivalent, or is one of them wrong? Explain where the `by` clause is allowed to sit.
- **Q23.** Give the two-step diagnostic recipe you'd use whenever an aggregated panel is "empty/flat": what do you check first about the **type/order** of the aggregation, and second about **which labels** the `by`/`without` clause retains?

---

## Teardown

```bash
docker compose down -v
```

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** The dimensions are the labels on each series: `region`, `app`, `method`, `code`, plus `job="demo_api"` (added by Pushgateway) and an empty `instance=""`. The metric name is held in the reserved `__name__` label, which is also technically a dimension but is dropped by every aggregation operator except `topk`/`bottomk`/`limitk`/`limit_ratio`.

**Q2.** The dataset is static, so a time-series *Graph* would just show flat horizontal lines and hide the label sets. Aggregation produces **new label sets** whose values you need to read exactly — the **Table** view shows one row per output series with its full labels and the instantaneous value, which is what these exercises verify.

**Q3.** With no `by`/`without` clause, an aggregation operator collapses **all** series in the vector into a **single** output series and strips **every** label, including `__name__`. The result carries an empty label set `{}`.

**Q4.** They cannot collide when run as two separate expressions (different results), but *conceptually* both produce the identical empty label set `{}`. If you tried to combine them in one expression via a binary operator with default matching, the empty-labelled results would match and the metric identities (already gone) could not distinguish them — a concrete reason aggregation drops `__name__`: to make results deliberately name-agnostic, and a reason to keep at least one distinguishing label with `by` when you plan to combine results.

**Q5.** `sum` distributes over partitioning: every series lands in exactly one group, so the group sub-totals always re-add to the grand total (365+315 = 235+445 = … = 680). This does **not** hold for `avg` (average of group averages ≠ overall average unless groups are equal-sized) or `max` (the max of group-maxes equals the global max, but the group maxes don't "add up" to anything meaningful).

**Q6.** Two series are placed in the same group **iff** they have identical values for all labels named in the `by` clause (or, for `without`, identical values for all labels *except* those named). In step 3, everything with the same `(region, code)` pair merges, regardless of `app` or `method`.

**Q7.** With `sum by (region, app)`, the new `canary` label is **collapsed away** — it does not appear, and canary + non-canary series merge into one number. With `sum without (method, code)`, the query keeps *all* labels except the two named, so `canary` **does** appear and canary/non-canary are kept separate. `by` is more robust to *unwanted new dimensions leaking in* (you enumerate exactly what you want); `without` is more robust in the sense that it *automatically preserves genuinely new identity labels* (you enumerate only what to discard). Choose `by` for stable dashboard cardinality; choose `without` when you want to strip a known noisy label and keep everything else.

**Q8.** `sum without (app, method, code, job, instance) (demo_http_requests_total)`. You must name every non-`region` label, **including** `job` and `instance`, or the result keeps them and no longer matches `{region="…"}`. This is exactly why `by (region)` is the idiomatic choice — it's shorter and immune to unlisted labels.

**Q9.** us-east values are `100, 5, 40, 200, 20`; sum = 365; `avg` divides by the **number of series in the group** (5): 365 / 5 = 73. `avg` divides by series count, never by a time count.

**Q10.** `count` counts **series** (vector elements) in each group — here 5 per region — not samples over time and not the sum of the values.

**Q11.** Deduplication / existence and cardinality counting. Example: `count(group by (instance) (up))` → number of distinct instances currently scraped, regardless of whether each is up (1) or down (0); or `count(group by (app) (demo_http_requests_total))` for "how many distinct apps exist." `group` normalizes every group to 1 so the outer `count` isn't skewed by underlying values.

**Q12.** `topk`/`bottomk` **select** actual input series rather than computing a new aggregate value; the whole point is to answer "*which* series," so the identity (metric name + all labels) must be preserved to be useful. `sum` computes a new number that no longer belongs to any single input series, so it discards the identity.

**Q13.** `topk` is evaluated **independently at every timestamp**. In a range/graph query, the *membership* of the top-k set can change from step to step, so different series enter and leave, producing a jagged, flapping graph — and no single line is a continuous "top" series. In an instant query (a table panel or an alert rule), you evaluate at one moment, which is exactly what "top 3 right now" means. Production fix: use `topk` in **table panels / alerts**, and for time-series graphs either graph *all* series and rely on the legend, or pre-aggregate to a bounded, stable series set — don't graph `topk` over a range.

**Q14.** The number of **distinct sample values** present across the input series determines the output series count. Values `3` and `5` appear ⇒ two output series. Each output's new label (`ready_pods`) holds the value, and the group's count is how many input series had it.

**Q15.** `count_values("version", app_build_info)` where the metric's **sample value encodes the version** (e.g. a numeric build id). Result: one series per distinct version, valued by how many targets run it. The hard requirement: the thing you're counting must live in the **sample value**, not in a label — if the version is a label, you'd use `count by (version) (...)` instead. (Many real `*_info` metrics put the version in a *label* and are always valued `1`; for those, `count by (version)` is correct, not `count_values`.)

**Q16.** n = 10, φ = 0.5. rank = φ·(n−1) = 0.5·9 = 4.5. Lower index = ⌊4.5⌋ = 4 → value `40`; upper index = 5 → value `60`; weight = 4.5 − 4 = 0.5. Result = 40·(1−0.5) + 60·0.5 = 20 + 30 = **50**. (For φ=0.9: rank = 8.1, values `150` and `200`, weight 0.1 → 150·0.9 + 200·0.1 = 135 + 20 = **155**.)

**Q17.** Prometheus divides by **n** (population variance/standard deviation), not n−1. us-east: deviations from mean 73 are `27, −68, −33, 127, −53`; squares sum to 25 380; ÷ 5 = **5076** = `stdvar`; √5076 ≈ **71.25** = `stddev`. A spreadsheet's `STDEV`/`VAR` (sample, ÷ n−1) will read *higher* on the same data; use `STDEVP`/`VARP` to match Prometheus.

**Q18.** `sum` requires an **instant vector**. In step 1 the `[5m]` selector produced a **range vector**, so `sum` errored on the type. In step 3, `max_over_time(...[5m])` consumed the range vector and *returned an instant vector* (one value per series), which `sum` then legally aggregated. The operator never sees a range vector.

**Q19.** Two bugs: (1) `[1h]` makes a range vector, illegal input to `avg`; (2) `node_cpu_seconds_total` is a counter, so you need `rate` first, and averaging seconds-counters is meaningless anyway. Corrected: `avg by (instance) (rate(node_cpu_seconds_total[5m]))` — `rate` turns the counter into a per-second instant vector, then `avg by (instance)` aggregates across the CPU/mode series of each instance. (Use `[5m]` or a window covering several scrapes; `1h` is unusual for `rate`.)

**Q20.** `rate()` is the **inner** function, aggregation (`sum`) is the **outer**: `sum(rate(counter[5m]))`. `rate` must run per individual series so it can detect that series' counter resets (restarts); if you `sum()` the raw counters first, independent resets in different series cancel/hide, and the outer `rate` computes garbage (spurious dips or negatives). Rule of thumb: **rate first, aggregate second.**

**Q21.** No. `demo_pods_ready` is a **gauge** — it can go up or down freely and has no notion of a counter reset — so `rate()` is inappropriate for it entirely. You aggregate gauges directly (`sum`, `avg`, `max` …). The inner-rate rule exists specifically because **counters** monotonically increase and reset to zero, which only `rate`/`increase`/`irate` know how to handle.

**Q22.** They are **equivalent**. PromQL accepts the modifier in either position: `<aggr>(<expr>) by (<labels>)` and `<aggr> by (<labels>) (<expr>)` mean the same thing. The flat panel is not a syntax problem — it's that the pushed counter values are *constant*, so `rate(...[5m])` is genuinely `0`. Fix for a demo: push increasing values over time (or use a live counter like Exercise 9), not change the `by` placement.

**Q23.** (1) **Type/order:** confirm you aggregated an *instant* vector and, for counters, that `rate()` is inside the aggregation (`sum(rate(...))`, not `rate(sum(...))` and not `sum(counter[range])`). A flat-zero panel is very often a constant/`rate`-order problem. (2) **Labels:** check that the `by`/`without` clause actually retains a label your legend/join expects — an empty `{}` result or "missing series" usually means the grouping collapsed the label you were keying on, or a join on the other side has a label your aggregated side dropped (`__name__` and all non-`by` labels are gone).

</details>