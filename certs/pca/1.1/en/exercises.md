# PCA — Domain: PromQL
## Topic 1.1 — Selecting Data

> **Exam weight:** 4 · **Domain:** PromQL
> Everything you graph, alert on, or aggregate in Prometheus begins with a *selector*: the expression that decides **which time series** and **which samples of them** enter the query. Get the selector wrong and every downstream `rate()`, `sum()`, or alert threshold is wrong too. This topic covers the two selector kinds — **instant vector selectors** and **range vector selectors** — plus the label matchers, the `offset` modifier, and the `@` modifier that steer them.
>
> Reference sources:
> - PromQL basics — <https://prometheus.io/docs/prometheus/latest/querying/basics/>
> - PromQL operators / modifiers — <https://prometheus.io/docs/prometheus/latest/querying/operators/>
> - PCA curriculum — <https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf>

---

## Exercise 0 — Bootstrap a lab that produces data to select

You need a running Prometheus with a few targets so the selectors return non-empty results. Prometheus scraping *itself* is enough for this topic.

1. Create a minimal config `prometheus.yml`:

   ```yaml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ["localhost:9090"]
   ```

2. Launch Prometheus (pin a version so outputs are reproducible):

   ```bash
   docker run --rm -d --name prom \
     -p 9090:9090 \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     prom/prometheus:v2.53.0
   ```

3. Confirm it is up and has scraped itself at least twice (wait ~30 s):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result'
   ```

   Expected (one target, healthy):

   ```json
   [
     {
       "metric": {
         "__name__": "up",
         "instance": "localhost:9090",
         "job": "prometheus"
       },
       "value": [ 1717000000.123, "1" ]
     }
   ]
   ```

4. Open the expression browser at <http://localhost:9090/graph> — you will run most queries there and cross-check a few via the HTTP API.

> **Q0.1** In the JSON above, what do the two elements of `"value": [ 1717000000.123, "1" ]` represent?
> **Q0.2** Why did the instructions say to wait ~30 s before expecting `up == 1`?

---

## Exercise 1 — Instant vector selectors: selecting a whole metric

An **instant vector selector** written as just a metric name returns, for **every** series carrying that name, the **single most recent sample** at or before the evaluation time (subject to the staleness lookback, default 5 minutes).

1. In the expression browser, run:

   ```promql
   prometheus_http_requests_total
   ```

2. Switch to the **Table** tab. You will see one row per series (per `code`/`handler` combination), each ending in one number — the current counter value:

   ```
   prometheus_http_requests_total{code="200", handler="/api/v1/query",    instance="localhost:9090", job="prometheus"}   17
   prometheus_http_requests_total{code="200", handler="/-/healthy",       instance="localhost:9090", job="prometheus"}    4
   prometheus_http_requests_total{code="200", handler="/metrics",         instance="localhost:9090", job="prometheus"}   22
   prometheus_http_requests_total{code="302", handler="/",                instance="localhost:9090", job="prometheus"}    1
   ...
   ```

3. Count how many series matched, without reading them one by one:

   ```promql
   count(prometheus_http_requests_total)
   ```

   ```
   {}   9
   ```

4. Now ask for a metric name that does not exist:

   ```promql
   prometheus_http_requests_totl
   ```

   The result is **empty** (no error) — a typo in a metric name silently returns nothing.

> **Q1.1** A bare instant vector selector returns how many samples *per matching series*, and from what point in time?
> **Q1.2** You run `prometheus_http_requests_total` and get zero rows, but you are certain the metric existed 20 minutes ago and the target has since gone away. Give the two mechanisms that together explain the empty result.
> **Q1.3** Why is `count(prometheus_http_requests_total)` a safer "does this metric exist and how big is its cardinality" probe than eyeballing the table?

---

## Exercise 2 — Filtering with equality label matchers

A selector narrows the series set with `{...}` label matchers. The two equality matchers are `=` (equal) and `!=` (not equal).

1. Keep only the `/api/v1/query` handler:

   ```promql
   prometheus_http_requests_total{handler="/api/v1/query"}
   ```

   ```
   prometheus_http_requests_total{code="200", handler="/api/v1/query", instance="localhost:9090", job="prometheus"}   17
   prometheus_http_requests_total{code="400", handler="/api/v1/query", instance="localhost:9090", job="prometheus"}    2
   ```

2. Stack matchers — they combine with logical **AND**. Keep that handler **and** only successful responses:

   ```promql
   prometheus_http_requests_total{handler="/api/v1/query", code="200"}
   ```

   ```
   prometheus_http_requests_total{code="200", handler="/api/v1/query", instance="localhost:9090", job="prometheus"}   17
   ```

3. Invert one matcher — every handler **except** `/metrics`:

   ```promql
   prometheus_http_requests_total{handler!="/metrics"}
   ```

4. A subtle but important behaviour — `!=` also matches series where the label is **absent** (an absent label is treated as the empty string, and `"" != "/metrics"`). Confirm the population of `/metrics` was excluded:

   ```promql
   count(prometheus_http_requests_total) - count(prometheus_http_requests_total{handler!="/metrics"})
   ```

   ```
   {}   1
   ```

> **Q2.1** How do multiple matchers inside one `{}` combine — AND or OR?
> **Q2.2** A metric `api_latency` has some series with a `region` label and some without it at all. Does `api_latency{region!="eu"}` return the series that have *no* `region` label? Why?
> **Q2.3** Rewrite "the `/metrics` handler, but only non-2xx responses" as a single selector. (Assume 2xx codes are exactly `"200"` here.)

---

## Exercise 3 — Regex matchers and full anchoring

`=~` (regex-match) and `!~` (regex-not-match) use RE2 syntax. **Critical rule:** regex matchers are **fully anchored** — the pattern must match the *entire* label value, as if wrapped in `^(?:...)$`.

1. Try the intuitive-but-wrong "starts with /api" query:

   ```promql
   prometheus_http_requests_total{handler=~"/api"}
   ```

   Result: **empty.** No handler value is *exactly* `/api`; they are `/api/v1/query`, `/api/v1/label/...`, etc. The anchoring makes `=~"/api"` behave like `="/api"`.

2. Fix it by matching the whole value:

   ```promql
   prometheus_http_requests_total{handler=~"/api/.*"}
   ```

   ```
   prometheus_http_requests_total{code="200", handler="/api/v1/query",  instance="localhost:9090", job="prometheus"}   17
   prometheus_http_requests_total{code="400", handler="/api/v1/query",  instance="localhost:9090", job="prometheus"}    2
   prometheus_http_requests_total{code="200", handler="/api/v1/labels", instance="localhost:9090", job="prometheus"}    3
   ...
   ```

3. Use alternation to select two exact status classes at once:

   ```promql
   prometheus_http_requests_total{code=~"400|500"}
   ```

4. Now hit the **empty-matcher rule**. A selector must contain at least one matcher that does *not* match the empty string. Run:

   ```promql
   prometheus_http_requests_total{code=~".*"}
   ```

   Prometheus rejects it:

   ```
   Error executing query: vector selector must contain at least one non-empty matcher
   ```

   Wait — that error only appears when the metric name is *also* removed. With the name present, `{code=~".*"}` is fine because the name itself is a non-empty matcher. Prove the rule by dropping the name too:

   ```promql
   {code=~".*"}
   ```

   ```
   Error executing query: vector selector must contain at least one non-empty matcher
   ```

5. The legal fix is a matcher that cannot match empty — e.g. `.+`:

   ```promql
   {code=~".+"}
   ```

   This now returns **every series in the TSDB that has a non-empty `code` label**, across all metric names.

> **Q3.1** Why does `handler=~"/api"` return nothing even though many handlers begin with `/api`? Write the equivalent form the engine effectively compiles it to.
> **Q3.2** `{job=~".*"}` is rejected but `{job=~".+"}` is accepted. State the rule and explain the difference between `.*` and `.+` here.
> **Q3.3** Convert `code=~"400|500"` reasoning: does it match a code of `"4000"`? Why or why not?

---

## Exercise 4 — The `__name__` meta-label

The metric name is itself a label: `__name__`. Anything you can do with a name, you can do with a matcher on `__name__` — which is the *only* way to regex-match across metric names.

1. Prove the equivalence — these two return identical series:

   ```promql
   prometheus_http_requests_total
   ```
   ```promql
   {__name__="prometheus_http_requests_total"}
   ```

2. Select a *family* of metrics by name pattern — every TSDB-head metric Prometheus exports:

   ```promql
   {__name__=~"prometheus_tsdb_head_.+"}
   ```

   ```
   prometheus_tsdb_head_series{...}          1834
   prometheus_tsdb_head_chunks{...}          1834
   prometheus_tsdb_head_samples_appended_total{...}   90421
   prometheus_tsdb_head_max_time{...}        1717000000123
   ...
   ```

3. Count how many distinct metric names live in the head right now:

   ```promql
   count(count by (__name__) ({__name__=~".+"}))
   ```

   ```
   {}   612
   ```

> **Q4.1** What is the fully-desugared `{...}` form of the selector `up{job="prometheus"}`?
> **Q4.2** Why can you *not* write `prometheus_tsdb.*` as a metric name to match a family, and what is the correct construct?
> **Q4.3** In step 3, why is `{__name__=~".+"}` legal as a standalone selector when `{__name__=~".*"}` would be rejected?

---

## Exercise 5 — Range vector selectors and duration syntax

Appending a **duration in square brackets** turns an instant vector selector into a **range vector selector**: instead of one sample per series, it returns *all* samples within the trailing window `[d]`.

1. Ask for the last 1 minute of raw samples of one series:

   ```promql
   prometheus_http_requests_total{handler="/metrics", code="200"}[1m]
   ```

   In the Table view you get a stack of `value @ timestamp` pairs (roughly one per 15 s scrape):

   ```
   prometheus_http_requests_total{code="200", handler="/metrics", instance="localhost:9090", job="prometheus"}
     22 @1717000000.123
     23 @1717000015.123
     24 @1717000030.123
     25 @1717000045.123
   ```

2. Try to **graph** that expression (Graph tab). It fails:

   ```
   Error executing query: invalid expression type "range vector" for range query, must be Scalar or instant Vector
   ```

   A range vector is not directly renderable — it must be reduced to an instant vector by a function. Do that:

   ```promql
   rate(prometheus_http_requests_total{handler="/metrics", code="200"}[1m])
   ```

   This now graphs (per-second rate over the 1-minute window).

3. Exercise the **duration units**. Valid units are `ms, s, m, h, d, w, y`; compound durations must be ordered **largest → smallest**, each unit at most once:

   ```promql
   rate(prometheus_http_requests_total[1h30m])   # valid: 1h then 30m
   ```

4. Break the rules deliberately and read the parser's complaints:

   ```promql
   prometheus_http_requests_total[5]
   ```
   ```
   Error executing query: bad number or duration syntax: "5"
   ```

   ```promql
   rate(prometheus_http_requests_total[30m1h])
   ```
   ```
   Error executing query: not a valid duration string: "30m1h"
   ```

> **Q5.1** What is the fundamental difference in the *shape* of data returned by `X` versus `X[5m]`?
> **Q5.2** Why does the expression `prometheus_http_requests_total[1m]` refuse to graph, and what class of function fixes it?
> **Q5.3** Are `[90m]` and `[1h30m]` equivalent? Is `[1h30m]` legal but `[30m1h]` not — why?
> **Q5.4** Roughly how many samples would `some_metric[1m]` contain when the scrape interval is 15 s, and why is it an *approximate* count?

---

## Exercise 6 — The `offset` modifier: looking back in time

`offset <duration>` shifts the evaluation of a selector into the past, **relative to the query evaluation time**. It is the building block for "compared to last week" style queries.

1. Current value vs. the value 5 minutes ago:

   ```promql
   prometheus_tsdb_head_series
   ```
   ```promql
   prometheus_tsdb_head_series offset 5m
   ```

   The second returns the sample that was current 5 minutes before now.

2. Compute growth over the last hour using two offset selectors:

   ```promql
   prometheus_tsdb_head_series - prometheus_tsdb_head_series offset 1h
   ```

   ```
   {instance="localhost:9090", job="prometheus"}   128
   ```

3. `offset` attaches to the **selector**, not to a surrounding function/aggregation. This is correct — the offset lives *inside* `rate(...)` on the selector:

   ```promql
   sum(rate(prometheus_http_requests_total[5m] offset 1h))
   ```

4. This is a **parse error** — you cannot offset an aggregation result:

   ```promql
   sum(prometheus_http_requests_total) offset 1h
   ```
   ```
   Error executing query: offset modifier must be preceded by an instant vector selector or range vector selector or a subquery
   ```

5. **Negative offset** (peeking into the future, useful with recording-rule/backfill scenarios) and the precise ordering with range vectors — the offset always comes *after* the `[range]`:

   ```promql
   rate(prometheus_http_requests_total[5m] offset -30s)
   ```

   In current Prometheus this is accepted by default; in older 2.2x releases it required `--enable-feature=promql-negative-offset`.

> **Q6.1** `offset 5m` shifts evaluation relative to *what* reference point?
> **Q6.2** Why does `sum(prometheus_http_requests_total) offset 1h` fail while `sum(prometheus_http_requests_total offset 1h)` succeeds? What do the two mean differently?
> **Q6.3** For a range vector, write the correct token order combining a 5-minute range and a 1-week offset.

---

## Exercise 7 — The `@` modifier: pinning to an absolute timestamp

Where `offset` is *relative* to eval time, the `@` modifier **fixes** the evaluation to an absolute Unix timestamp (seconds), independent of when or over what range the query runs.

1. Evaluate a series exactly at one instant. Grab a timestamp first:

   ```bash
   date -d '10 minutes ago' +%s     # e.g. 1716999400
   ```

   ```promql
   prometheus_tsdb_head_series @ 1716999400
   ```

   No matter where you drag a range-query graph, this term always returns the value at `1716999400`.

2. Combine `@` with a range and even with `offset` (evaluation order: apply `@`, then `offset` shifts from that fixed point):

   ```promql
   rate(prometheus_http_requests_total[5m] @ 1716999400)
   ```

3. Use the special `start()` / `end()` helpers, which resolve to the range query's own start/end boundaries — handy in recording rules to anchor to a window edge:

   ```promql
   prometheus_tsdb_head_series @ end()
   ```

4. A common real use — "what fraction of today's growth had already happened by a fixed checkpoint" — mixing a live value and a pinned one:

   ```promql
   prometheus_tsdb_head_samples_appended_total
     / (prometheus_tsdb_head_samples_appended_total @ 1716999400)
   ```

   In older 2.2x releases the `@` modifier required `--enable-feature=promql-at-modifier`; it is enabled by default in current Prometheus.

> **Q7.1** State the essential difference between `offset 10m` and `@ <timestamp>`.
> **Q7.2** In a **range** (graphed) query, which of these produces a *flat* line and which produces a moving one: `metric @ 1716999400` vs. `metric offset 10m`? Why?
> **Q7.3** What do `@ start()` and `@ end()` resolve to, and in what query type are they most useful?

---

## Exercise 8 — Selecting data through the HTTP API (what the UI is really doing)

The expression browser is a thin client over `/api/v1/query` (instant) and `/api/v1/query_range` (range). Knowing the API is examinable and essential for scripting.

1. Instant query — URL-encode the selector:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=prometheus_tsdb_head_series' | jq '.data'
   ```

   ```json
   {
     "resultType": "vector",
     "result": [
       {
         "metric": { "__name__": "prometheus_tsdb_head_series", "instance": "localhost:9090", "job": "prometheus" },
         "value": [ 1717000000.123, "1834" ]
       }
     ]
   }
   ```

2. Instant query **at a past time** with the `time` parameter (server-side equivalent of `@`):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=prometheus_tsdb_head_series' \
     --data-urlencode 'time=1716999400' | jq '.data.result[0].value'
   ```

3. Send a **range vector selector** to the *instant* endpoint and inspect the result type:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=prometheus_tsdb_head_series[1m]' | jq '.data.resultType'
   ```

   ```
   "matrix"
   ```

> **Q8.1** Which `resultType` string does a bare instant vector selector return, and which does a range vector selector return?
> **Q8.2** What is the API-parameter equivalent of putting `@ 1716999400` on a selector in an instant query?
> **Q8.3** Why must the selector be passed with `--data-urlencode` rather than concatenated raw into the URL?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 0**
- **Q0.1** `[ 1717000000.123, "1" ]` is `[<evaluation timestamp in Unix seconds, float>, <sample value as a string>]`. Prometheus returns sample values as JSON strings to preserve full float precision and special values (`NaN`, `+Inf`).
- **Q0.2** With a 15 s `scrape_interval`, the first scrape happens shortly after startup and a series needs at least one successful scrape to exist. Waiting ~30 s guarantees at least one (usually two) scrapes have landed, so `up` is present and `== 1`.

**Exercise 1**
- **Q1.1** Exactly **one** sample per matching series — the most recent sample at or before the evaluation instant, provided it falls within the staleness lookback window (`--query.lookback-delta`, default 5 m).
- **Q1.2** (1) The **staleness lookback**: with the target gone, the last real sample is older than 5 minutes, so it is outside the lookback window. (2) **Staleness markers**: when a target disappears, Prometheus injects a stale marker so the series stops returning a value almost immediately rather than lingering for the full 5 minutes. Together the series returns no data.
- **Q1.3** `count()` collapses the set to a single scalar-like number, so you learn "exists / how many series" in one glance without scrolling — and it will not accidentally hide high-cardinality explosions the way a truncated table might.

**Exercise 2**
- **Q2.1** **AND.** All matchers in one `{}` must be satisfied simultaneously.
- **Q2.2** Yes. A missing label is treated as the empty string `""`, and `"" != "eu"` is true, so series lacking `region` entirely are returned by `!=`. (This is the classic trap: `!=`/`!~` include label-absent series.)
- **Q2.3** `prometheus_http_requests_total{handler="/metrics", code!="200"}`.

**Exercise 3**
- **Q3.1** Regex matchers are **fully anchored**, so `handler=~"/api"` compiles to effectively `^(?:/api)$` — it matches only the exact string `/api`, which no handler equals. Equivalent form: `handler=~"^(?:/api)$"` (i.e. it behaves like `handler="/api"`).
- **Q3.2** Rule: *a vector selector must contain at least one matcher that does not match the empty string.* `.*` matches the empty string (zero or more), so `{job=~".*"}` alone is illegal; `.+` requires at least one character, so it cannot match empty and `{job=~".+"}` is legal.
- **Q3.3** `code=~"400|500"` is anchored, so it means `^(?:400|500)$` — the value must be exactly `400` or exactly `500`. `"4000"` does **not** match, because the anchoring forbids extra trailing characters.

**Exercise 4**
- **Q4.1** `{__name__="up", job="prometheus"}`.
- **Q4.2** The metric name is not a wildcard token; it is a label (`__name__`). To pattern-match names you must use a regex matcher on that label: `{__name__=~"prometheus_tsdb.*"}` (anchored, so include `.*`).
- **Q4.3** `.+` cannot match the empty string, satisfying the "at least one non-empty matcher" rule; `.*` can match empty and would leave the selector with no non-empty matcher, so it is rejected.

**Exercise 5**
- **Q5.1** `X` is an **instant vector** — one sample per series. `X[5m]` is a **range vector** — a whole slice of samples (every raw sample in the trailing 5 minutes) per series.
- **Q5.2** A range vector has no single value per series, so it cannot be plotted as a line; the range/graph endpoint requires a Scalar or instant Vector. A function that consumes a range vector and returns an instant vector — `rate`, `increase`, `avg_over_time`, `max_over_time`, etc. — fixes it.
- **Q5.3** Yes, `[90m]` and `[1h30m]` are equal (both 5400 s). `[1h30m]` is legal because units go largest→smallest; `[30m1h]` is illegal because it lists a smaller unit before a larger one.
- **Q5.4** About 4 samples (60 s ÷ 15 s). It is approximate because scrape timings jitter, a scrape may fail, and the window boundary rarely lines up exactly with scrape instants — so you can see 3, 4, or 5.

**Exercise 6**
- **Q6.1** Relative to the **query evaluation time** (the instant the query is evaluated for — which, in a range query, moves across each step).
- **Q6.2** `offset` may only follow a selector/range vector/subquery, not an aggregation result — hence the parse error on `sum(...) offset 1h`. `sum(prometheus_http_requests_total offset 1h)` first shifts each series 1 h into the past, *then* sums those past values; the illegal form tried to shift the already-computed sum, which the grammar disallows.
- **Q6.3** `rate(prometheus_http_requests_total[5m] offset 1w)` — the `[range]` comes first, then `offset`.

**Exercise 7**
- **Q7.1** `offset` is **relative** (shift N units back from the current eval time, so it moves as eval time moves). `@` is **absolute** (pin to a fixed Unix timestamp, identical no matter when/over what range the query runs).
- **Q7.2** `metric @ 1716999400` is **flat** — every step of the range query returns the same pinned value. `metric offset 10m` is **moving** — each step evaluates 10 minutes before that step's own time, so the line tracks the metric shifted left by 10 minutes.
- **Q7.3** `@ start()` resolves to the range query's start timestamp and `@ end()` to its end timestamp. They are most useful in **range queries** (and recording rules) to anchor a term to a window boundary.

**Exercise 8**
- **Q8.1** Instant vector selector → `"vector"`. Range vector selector → `"matrix"`.
- **Q8.2** The `time=<unix_ts>` query parameter on `/api/v1/query` — it sets the evaluation instant for the whole query, which for a single selector is equivalent to `@ <unix_ts>`.
- **Q8.3** PromQL contains characters that are unsafe or meaningful in a URL — `{`, `}`, `=`, `"`, `~`, `+`, spaces, `[`, `]`. `--data-urlencode` percent-encodes them so the server receives the intended expression instead of a truncated or misparsed one (and sends it in the body, avoiding URL-length limits).

</details>