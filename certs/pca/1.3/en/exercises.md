# PCA — Topic 1.3: Aggregating over time
## Guided exercises (production-grade PromQL)

> **Scope.** This topic covers the `*_over_time()` family: the PromQL functions that collapse a **range vector** (many samples of one series across a time window) into a single value **per series**. The exam's recurring trap is confusing this *temporal* aggregation with the *dimensional* aggregation operators (`sum`, `avg`, `max`, …) that collapse across series at a single instant. Every exercise below drills that distinction on a real Prometheus.

**Reference sources**
- `_over_time` catalogue: https://prometheus.io/docs/prometheus/latest/querying/functions/#aggregation_over_time
- Range-vector selectors: https://prometheus.io/docs/prometheus/latest/querying/basics/#range-vector-selectors
- Subqueries: https://prometheus.io/docs/prometheus/latest/querying/subqueries/
- Aggregation *operators* (for contrast): https://prometheus.io/docs/prometheus/latest/querying/operators/#aggregation-operators
- PCA curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf

---

## Lab setup

You need a running Prometheus with a few minutes of scraped history. Self-scraping is enough — Prometheus exposes rich counters and gauges about itself.

1. Create `prometheus.yml`:

   ```yaml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ["localhost:9090"]
   ```

2. Start Prometheus (pin a version so outputs are reproducible):

   ```bash
   docker run -d --name prom -p 9090:9090 \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     prom/prometheus:v2.53.0
   ```

3. Generate some HTTP traffic so counters have movement, then **wait at least 6 minutes** so every `[5m]` window is fully populated:

   ```bash
   for i in $(seq 1 300); do
     curl -s 'http://localhost:9090/api/v1/query?query=up' >/dev/null
   done
   sleep 360
   ```

4. Two ways to run queries — pick either throughout:
   - **Expression browser**: http://localhost:9090/graph
   - **HTTP API + jq** (used in the outputs below):

     ```bash
     q() { curl -s 'http://localhost:9090/api/v1/query' \
             --data-urlencode "query=$1" | jq -r '.data.result'; }
     ```

---

## Exercise 1 — Range vector in, instant vector out

The whole family shares one signature: it **requires** a range vector `[d]` and **returns** an instant vector.

1. Run a raw range-vector selector and inspect its shape:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=up[5m]' | jq -r '.data.result[0].values | length'
   ```

   Expected: a count near **20** (300 s ÷ 15 s). It may be 20 or 21 depending on window-boundary alignment.

2. Now wrap it in `count_over_time`:

   ```bash
   q 'count_over_time(up[5m])'
   ```

   ```json
   [
     {
       "metric": { "__name__": "up", "instance": "localhost:9090", "job": "prometheus" },
       "value": [ 1733680000, "20" ]
     }
   ]
   ```

3. Deliberately break it — feed an **instant** vector to an `_over_time` function:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=count_over_time(up)'
   ```

   You get an HTTP 400 and an error like
   `expected type range vector in call to function "count_over_time", got instant vector`.

> ❓ **Comprehension check 1**
> 1. `up[5m]` is a range vector. Why can you *not* graph it directly in the expression browser's Graph tab, yet `count_over_time(up[5m])` graphs fine?
> 2. The `count_over_time(up[5m])` result was `20`, not `1`. What exactly did it count — and why is that number a function of your `scrape_interval`?
> 3. You have three `up` series (three targets). How many output series does `count_over_time(up[5m])` return, and what does each value mean?

---

## Exercise 2 — Smoothing a noisy gauge: `avg/min/max_over_time`

Gauges (memory, goroutines, queue depth) jitter between scrapes. The `_over_time` family gives you a per-series statistical summary of the window without touching other series.

1. Look at the raw gauge, then its 5-minute average, minimum and maximum:

   ```bash
   q 'go_goroutines'
   q 'avg_over_time(go_goroutines[5m])'
   q 'min_over_time(go_goroutines[5m])'
   q 'max_over_time(go_goroutines[5m])'
   ```

   Typical values:

   ```text
   go_goroutines                     -> 47
   avg_over_time(go_goroutines[5m])  -> 45.3
   min_over_time(go_goroutines[5m])  -> 41
   max_over_time(go_goroutines[5m])  -> 52
   ```

2. Compute the peak-to-trough spread of the window in one expression:

   ```bash
   q 'max_over_time(go_goroutines[5m]) - min_over_time(go_goroutines[5m])'
   ```

3. Compare a resident-memory gauge instant value vs its smoothed average — useful when a dashboard flickers:

   ```bash
   q 'process_resident_memory_bytes'
   q 'avg_over_time(process_resident_memory_bytes[5m])'
   ```

> ❓ **Comprehension check 2**
> 1. `max_over_time(go_goroutines[5m])` returned `52`, but the current value is `47`. Is the metric broken? Explain what `52` represents.
> 2. In step 2 the subtraction returned **one** value per series with no `on()`/`ignoring()` needed. Why does the vector match "just work" here, when subtracting two arbitrary metrics usually requires matching modifiers?
> 3. Your alerting engineer wants to page on a *sustained* memory ceiling, not a single spiky scrape. Which of `max_over_time` / `avg_over_time` / `min_over_time` reduces false pages from one-scrape spikes, and what does each choice trade away?

---

## Exercise 3 — Sample presence and scrape health: `count_over_time`, `present_over_time`, `absent_over_time`

These three answer "did data arrive?" rather than "what was its value?" — the backbone of dead-man's-switch alerts.

1. `present_over_time` returns `1` for every series with **at least one** sample in the window:

   ```bash
   q 'present_over_time(up[5m])'
   ```

   ```json
   [ { "metric": { "__name__": "up", "instance": "localhost:9090", "job": "prometheus" },
       "value": [ 1733680000, "1" ] } ]
   ```

2. Compare scrape volume across a short vs long window to see partial coverage of a target that just started:

   ```bash
   q 'count_over_time(scrape_samples_scraped[1m])'
   q 'count_over_time(scrape_samples_scraped[10m])'
   ```

3. `absent_over_time` is the inverse alerting primitive. Ask about a series that **exists**, then one that does **not**:

   ```bash
   q 'absent_over_time(up[5m])'                          # -> [] (empty)
   q 'absent_over_time(up{job="does-not-exist"}[5m])'    # -> value "1"
   ```

   ```json
   // second query
   [ { "metric": { "job": "does-not-exist" }, "value": [ 1733680000, "1" ] } ]
   ```

> ❓ **Comprehension check 3**
> 1. `present_over_time(up[5m])` and `absent_over_time(up[5m])` are near-opposites. State precisely what each returns when the series **is** present, and when it **is not**. Why can't you just write `up == 0` to detect a missing target?
> 2. For a Dead Man's Switch alert ("page me if this metric stops arriving for 10 minutes"), which function goes in the alert expression, and why is `absent()` (no `_over_time`) a worse choice for a flappy, occasionally-scraped target?
> 3. In step 3, notice the labels of the `absent_over_time` result came from your **query**, not from stored data. Where did `{job="does-not-exist"}` come from, and what's the risk if your selector uses a regex matcher like `job=~".+"`?

---

## Exercise 4 — Statistical shape of a window: `quantile_over_time`, `stddev_over_time`, `stdvar_over_time`, `sum_over_time`

1. Estimate the 95th percentile of scrape duration for each target over 30 minutes:

   ```bash
   q 'quantile_over_time(0.95, scrape_duration_seconds[30m])'
   ```

   ```text
   -> 0.0043   # 95% of scrapes finished within ~4.3 ms
   ```

2. Measure volatility of the goroutine count:

   ```bash
   q 'stddev_over_time(go_goroutines[30m])'   # standard deviation
   q 'stdvar_over_time(go_goroutines[30m])'   # variance (= stddev^2)
   ```

3. Probe the guard rails of `quantile_over_time` — φ must be within `[0, 1]`:

   ```bash
   q 'quantile_over_time(1.5, scrape_duration_seconds[30m])'   # -> +Inf
   q 'quantile_over_time(-0.2, scrape_duration_seconds[30m])'  # -> -Inf
   ```

4. Now the sharp edge — `sum_over_time` on a **counter** is a classic bug. Contrast it with the correct pattern:

   ```bash
   q 'sum_over_time(prometheus_http_requests_total[5m])'   # meaningless number
   q 'increase(prometheus_http_requests_total[5m])'        # the real "requests in 5m"
   ```

> ❓ **Comprehension check 4**
> 1. `quantile_over_time(0.95, scrape_duration_seconds[30m])` gave a per-target p95. How does this differ, mechanically and in meaning, from `histogram_quantile(0.95, ...)` over a native/classic histogram? When is the `_over_time` form *not* a valid latency percentile?
> 2. Why is `sum_over_time(prometheus_http_requests_total[5m])` semantically wrong? Walk through what it actually adds up, and why `increase(...)` is what you meant.
> 3. `stdvar_over_time` returned a number ~ the square of `stddev_over_time`. Which one would you feed into an anomaly rule of the form "current value is more than 3σ from the window mean", and write that rule as a PromQL expression sketch.

---

## Exercise 5 — Aggregating *derived* data with subqueries: `max_over_time(rate(...))`

You often want "the peak request **rate** over the last 30 minutes." But `rate()` returns an instant vector, and you can't append `[30m]` to a function call. The **subquery** `[range:resolution]` bridges the gap.

1. Try the naive (broken) form first:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=max_over_time(rate(prometheus_http_requests_total[1m])[30m])'
   ```

   → parse error: `[30m]` cannot follow a function; a range selector only attaches to a bare selector.

2. Fix it with subquery syntax — inner `rate` evaluated every `1m` across a `30m` window, then `max_over_time` collapses it:

   ```bash
   q 'max_over_time( rate(prometheus_http_requests_total[1m])[30m:1m] )'
   ```

   ```text
   -> 2.87   # peak per-second request rate seen in any 1m step of the last 30m
   ```

3. Omit the resolution to inherit the global `evaluation_interval`, and compare with the average of the same derived series:

   ```bash
   q 'max_over_time( rate(prometheus_http_requests_total[1m])[30m:] )'
   q 'avg_over_time( rate(prometheus_http_requests_total[1m])[30m:1m] )'
   ```

4. `last_over_time` carries the most recent sample forward — handy to align a slow gauge onto a step grid, or to survive brief gaps:

   ```bash
   q 'last_over_time(process_resident_memory_bytes[5m])'
   ```

> ❓ **Comprehension check 5**
> 1. In `rate(...)[30m:1m]`, name the three time parameters in play (`1m`, `30m`, `1m`) and say precisely what each one controls.
> 2. Subqueries are convenient but expensive. Why does `max_over_time(rate(...)[30m:15s])` cost far more to evaluate than `[30m:5m]`, and what production alternative (hint: rules) removes that cost at query time?
> 3. What is the difference between `last_over_time(x[5m])` and simply querying `x`? Give one scenario where they return **different** values for the same series.

---

## Exercise 6 — The core exam distinction: over **time** vs over **dimensions**

This is the pattern examiners test most. `avg_over_time` averages **one series across time**; the `avg` operator averages **many series at one instant**. They are orthogonal and frequently combined.

1. There are three `scrape_duration_seconds` targets (or one, in this minimal lab — the shape of the answer is what matters). Look at both directions:

   ```bash
   # Temporal: one output series PER target, each smoothed over 5m
   q 'avg_over_time(scrape_duration_seconds[5m])'

   # Dimensional: ONE output value, collapsing all targets at "now"
   q 'avg(scrape_duration_seconds)'
   ```

2. Combine them correctly — smooth each series over time, *then* average across series:

   ```bash
   q 'avg( avg_over_time(scrape_duration_seconds[5m]) )'
   ```

3. Observe how `by` interacts only with the **operator**, never with `_over_time`:

   ```bash
   q 'max( max_over_time(scrape_duration_seconds[5m]) ) by (job)'
   ```

4. Look at label sets to make it concrete:

   ```bash
   q 'avg_over_time(scrape_duration_seconds[5m])'   # keeps instance+job labels
   q 'avg(scrape_duration_seconds)'                  # drops all labels
   ```

> ❓ **Comprehension check 6**
> 1. In one sentence each, define the axis that `avg_over_time(x[5m])` collapses and the axis that `avg(x)` collapses.
> 2. `avg_over_time(x[5m])` **preserves** every label of `x`, while `avg(x)` **drops** them (unless you add `by`). Explain why that asymmetry is a direct consequence of what each one aggregates.
> 3. A colleague writes `avg_over_time(x)` and `avg(x[5m])`. Both are errors. State the error in each, and give the corrected intent-preserving expression for both.
> 4. For "the average, across all targets, of each target's peak scrape duration in the last hour", write the full expression and justify the nesting order (why not `max_over_time(avg(...)[1h:])`?).

---

## Exercise 7 — Putting it together: a real alert expression

1. Build a rule that fires when a job's **smoothed** error rate stays above a threshold — combining a subquery, `_over_time`, and a dimensional aggregation:

   ```promql
   # "avg per-second 5xx rate over the last 15m, summed per job, exceeds 1"
   sum by (job) (
     avg_over_time(
       rate(prometheus_http_requests_total{code=~"5.."}[5m])[15m:1m]
     )
   ) > 1
   ```

2. Add a companion dead-man's-switch so the alert itself can't go blind:

   ```promql
   absent_over_time(prometheus_http_requests_total[10m])
   ```

3. Reason about evaluation cost and correctness before shipping (see checks).

> ❓ **Comprehension check 7**
> 1. Peel the step-1 expression from the inside out and name what each layer does: `rate(...[5m])`, `[15m:1m]`, `avg_over_time(...)`, `sum by (job)(...)`.
> 2. Why is the `sum by (job)` on the **outside** and not folded into a `sum_over_time`? What would `sum_over_time(rate(...)[15m:1m])` compute instead, and why is it wrong here?
> 3. If `prometheus_http_requests_total{code=~"5.."}` has produced **zero** samples (no 5xx ever), what does the step-1 expression return, and would the alert fire? How does the step-2 rule cover the blind spot this creates?

---

<details>
<summary><strong>Answer key — Exercises 1–7</strong></summary>

### Exercise 1
1. The Graph tab plots **instant vectors** over the query range — one number per series per step. A range vector (`up[5m]`) is a *set of raw sample series* with many timestamped values at a single evaluation instant; it has no single value to plot. `count_over_time(up[5m])` reduces each range vector to one instant value, which *is* plottable. (The Table/Console tab will display the raw range-vector samples, but not graph them.)
2. It counted the **number of raw samples** of `up` that fell inside the trailing 5-minute window. With `scrape_interval: 15s`, 5 min ÷ 15 s = **20** scrapes → 20 samples. Change the interval and the count changes proportionally — `count_over_time` measures *scrape density*, not the value of the metric.
3. **Three** output series — one per input series. `_over_time` functions aggregate **each series independently along time**; they never merge series. Each value is that particular target's sample count in the window.

### Exercise 2
1. Not broken. `max_over_time(go_goroutines[5m])` returns the **highest value any scrape observed within the trailing 5-minute window**. The count peaked at 52 at some earlier scrape and has since settled to 47; the window still remembers the 52.
2. Both operands (`max_over_time(...)` and `min_over_time(...)`) are derived from the **same** source series and therefore carry **identical label sets** (`_over_time` preserves labels). PromQL's default one-to-one vector matching pairs series with equal labels, so the match is exact without `on()`/`ignoring()`. The subtraction produces one result per original series.
3. `avg_over_time` best suppresses single-scrape spikes because one outlier is diluted by ~20 samples — but it also **hides** real short bursts (you could miss a genuine 30-second memory blowup). `max_over_time` never hides a spike but pages on transients. `min_over_time` shows the sustained *floor* and is essentially useless for a ceiling alert. Typical production choice: alert on `avg_over_time` (or `quantile_over_time(0.9, …)`) held `for:` a few minutes to require persistence.

### Exercise 3
1. `present_over_time(up[5m])` → `1` when the series has ≥1 sample in the window, and returns **no series at all** (empty) when it's absent. `absent_over_time(up[5m])` → returns **nothing** when the series is present, and a single series with value `1` (labels taken from the selector's equality matchers) when it's absent. `up == 0` cannot detect a *missing* target: if the scrape target disappears entirely, the `up` series stops being produced, so `up == 0` has nothing to evaluate and yields empty — you'd never fire. `up == 0` only catches a target that is **scraped but failing**; `absent_over_time` catches a target that **isn't being scraped/stored at all**.
2. Use **`absent_over_time(metric[10m])`**. Plain `absent(metric)` looks only at the **single most recent** evaluation instant, so for a flappy target that reports every few minutes it flips between "present" and "absent" on nearly every rule evaluation → alert flapping. `absent_over_time` tolerates the gaps: it stays quiet as long as *any* sample landed in the 10-minute window, and fires only when the target has truly gone silent for the whole window.
3. The result labels come from the **equality matchers in your selector** (`job="does-not-exist"`), because there's no stored series to borrow labels from — Prometheus synthesizes the output from the query text. With a **regex** matcher like `job=~".+"`, there are no equality matchers to copy, so a firing `absent_over_time` result would be **label-less** (just value `1`), which makes the resulting alert ambiguous and hard to route. Always give `absent`/`absent_over_time` selectors with concrete equality labels so the alert carries useful identity.

### Exercise 4
1. `quantile_over_time(0.95, x[30m])` computes the 95th percentile **of the raw scrape values of series `x` over 30 minutes** — a percentile *across time* of an already-observed gauge/scalar. `histogram_quantile(0.95, …)` estimates a percentile **across a population of events at one instant** by interpolating within histogram buckets. The `_over_time` form is **not** a valid *latency* percentile of requests: it percentiles the *scrape samples themselves* (e.g. p95 of the 120 scrape_duration readings), not p95 of the underlying request latency distribution. Use `_over_time` for "how did this gauge behave over time"; use `histogram_quantile` for "what's the p95 of the events."
2. A counter only ever increases; `sum_over_time` literally adds the 20 monotonically-growing raw values (e.g. 1000 + 1001 + … + 1019) — a number with no physical meaning that scales with scrape density and counter magnitude. What you wanted is **how much the counter grew in the window**, which is `increase(...[5m])` (or `rate(...[5m]) * 300`). `_over_time` on counters is almost always a bug; take `rate`/`increase` first.
3. Feed **`stddev_over_time`** (same unit as the metric, so it's comparable to a raw deviation). Sketch: `abs(x - avg_over_time(x[30m])) > 3 * stddev_over_time(x[30m])`. `stdvar_over_time` is in *squared* units and is used when you compose variances mathematically, not for a "distance in σ" threshold.

### Exercise 5
1. Inner `[1m]` = the **rate window**: over how many trailing minutes each `rate()` point is computed. `[30m` = the **subquery range**: the total span of derived `rate` points that `max_over_time` will scan. `:1m]` = the **subquery resolution/step**: how often the inner `rate` is evaluated inside that span (30 evaluated points here). `max_over_time` then returns the largest of those 30 points.
2. Cost scales with the **number of inner evaluations** = range ÷ resolution. `[30m:15s]` = 120 inner `rate` computations; `[30m:5m]` = 6. Each inner `rate` is itself a range scan, so a fine resolution multiplies work dramatically and can hammer the TSDB. Production fix: precompute `rate(...)` in a **recording rule** at a fixed interval, then run `max_over_time(job:http_rate:rate1m[30m])` on the *stored* series — no subquery, cheap and cacheable.
3. `x` returns the current value at the evaluation instant, subject to **staleness** — if the last sample is older than ~5 min (or marked stale) it returns *nothing*. `last_over_time(x[5m])` returns the **most recent sample within the 5-minute window regardless of staleness handling**, carrying it forward. They differ when a target has stopped reporting recently but sampled, say, 4 minutes ago: `x` may be empty/stale, while `last_over_time(x[5m])` still returns that 4-minute-old value.

### Exercise 6
1. `avg_over_time(x[5m])` collapses the **time** axis (many samples of each series → one per series). `avg(x)` collapses the **series/dimension** axis (many series at one instant → one value).
2. `_over_time` aggregates *within* a series, so the series' identity — its labels — is untouched and preserved. The `avg` **operator** aggregates *across* series; to produce one combined result it must discard the labels that distinguished the inputs (keeping only those named in `by`). The label behaviour follows directly from which axis is being merged.
3. `avg_over_time(x)` — missing the required **range vector**; it needs a window: `avg_over_time(x[5m])`. `avg(x[5m])` — the **operator** was handed a **range vector**, which it can't take; either drop the window for an instant average `avg(x)`, or, if a per-series time-average across series was intended, `avg(avg_over_time(x[5m]))`.
4. `avg( max_over_time(scrape_duration_seconds[1h]) )`. Inner `max_over_time` gives **each target's** peak over the hour (one value per target, labels intact); outer `avg` averages those peaks across targets. The rejected form `max_over_time(avg(...)[1h:])` first averages *across targets at each step* (destroying per-target identity) and then takes the max of that fleet-average timeline — it answers "the peak fleet-average", not "the average of per-target peaks." Order encodes intent.

### Exercise 7
1. `rate(prometheus_http_requests_total{code=~"5.."}[5m])` → per-series, per-second 5xx rate smoothed over 5 min. `[15m:1m]` → subquery: evaluate that rate every 1 min across the last 15 min, yielding a derived range vector. `avg_over_time(...)` → per series, average those 15 rate points into one value (a 15-minute smoothed rate). `sum by (job)(...)` → collapse the remaining series **across dimensions**, summing per `job`.
2. `sum by (job)` is a **dimensional** collapse that must happen *after* each series is reduced to one instant value — it merges *different series*. `sum_over_time(rate(...)[15m:1m])` is a **temporal** collapse that would *add together the 15 successive rate samples of each single series* — inflating one series' rate by ~15× (and still per-series, not per-job). That's neither an average nor a cross-job total; it's dimensionally and numerically wrong.
3. With zero 5xx samples the inner `rate` produces **no series**, so `avg_over_time` and `sum by (job)` also produce **empty** — the `> 1` comparison has nothing to test and the alert **cannot fire**. That's the blind spot: "no data" reads identically to "healthy." Step 2's `absent_over_time(prometheus_http_requests_total[10m])` fires precisely when the underlying metric stops arriving, so a broken exporter/scrape is caught even though the error-rate rule has gone silent.

</details>