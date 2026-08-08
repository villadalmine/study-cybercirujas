# PCA Topic 1.6 — Histograms: Guided Exercises

> **Format.** Each exercise is a numbered, runnable procedure. After each block there are **comprehension checks** (Q1, Q2, …). All answers live in the single collapsible section at the very end. Everything here is reproducible on a laptop with Docker (or a local `prometheus`/`promtool` binary) and Python 3.
>
> **What a histogram *is*, in one line.** A Prometheus histogram samples observations (usually request durations or sizes) and counts them into **cumulative** buckets, exposing three derived series — `<name>_bucket{le="..."}`, `<name>_sum`, `<name>_count` — from which the server computes quantiles *at query time*. Contrast with a summary, which computes quantiles *client-side* and cannot be re-aggregated. ([metric_types](https://prometheus.io/docs/concepts/metric_types/#histogram), [practices/histograms](https://prometheus.io/docs/practices/histograms/))

**Prerequisites for the whole set**

```bash
# Option A: containers (recommended, self-contained)
docker --version          # any recent Docker
# Option B: local binaries
prometheus --version      # 2.40+ for native histograms; 3.x preferred
promtool --version
python3 --version         # 3.8+
pip install prometheus_client
```

---

## Exercise 1 — Anatomy of a histogram on the wire

**Goal:** read a real, classic histogram straight from an exposition endpoint and identify every component before touching PromQL.

1. Start Prometheus so it scrapes *itself* (its own HTTP handler is instrumented with a histogram):

   ```bash
   docker run --rm -d --name prom -p 9090:9090 prom/prometheus:v3.1.0
   ```

2. Generate a little self-traffic so the histogram is non-empty, then scrape the raw exposition:

   ```bash
   for i in $(seq 1 30); do curl -s localhost:9090/api/v1/query?query=up >/dev/null; done
   curl -s localhost:9090/metrics | grep 'prometheus_http_request_duration_seconds' | grep 'query'
   ```

3. Read the output. You will see something structurally like this (values differ):

   ```text
   # HELP prometheus_http_request_duration_seconds Histogram of latencies for HTTP requests.
   # TYPE prometheus_http_request_duration_seconds histogram
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.1"} 30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.2"} 30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="0.4"} 30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="1"}   30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="3"}   30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="8"}   30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="20"}  30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="60"}  30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="120"} 30
   prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query",le="+Inf"} 30
   prometheus_http_request_duration_seconds_sum{handler="/api/v1/query"}   0.041231
   prometheus_http_request_duration_seconds_count{handler="/api/v1/query"} 30
   ```

4. Confirm the two invariants by eye:
   - the `le` values only ever increase, and the last one is `+Inf`;
   - the count in the `+Inf` bucket equals the value of `..._count`.

**Comprehension checks**

- **Q1.** The `le="1"` bucket reads `30`. Does that mean "30 requests took *exactly* between 0.4s and 1s"? What does it actually count?
- **Q2.** Why is the `+Inf` bucket mandatory, and what single value must it always equal?
- **Q3.** If you divided `..._sum` by `..._count` (here `0.041231 / 30`), what would you get, and why is that value *not* a substitute for the p90?
- **Q4.** A colleague's exporter emits `le="0.10000000000000001"` instead of `le="0.1"`. Why is this a real operational hazard for aggregation across targets?

---

## Exercise 2 — Instrument your own histogram and choose the buckets

**Goal:** feel the single most consequential design decision — the bucket boundaries — and see how the client library derives the three series.

1. Save this as `app.py`. It exposes a histogram with **hand-picked** buckets and simulates an exponentially distributed latency (mean ≈ 0.25s):

   ```python
   import random, time
   from prometheus_client import start_http_server, Histogram

   LATENCY = Histogram(
       "app_request_latency_seconds",
       "End-to-end request latency in seconds",
       # Boundaries clustered around the region we care about (an SLO near 0.3s),
       # not a uniform 0..5 ramp. This is the whole game.
       buckets=(0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 2.5, 5.0),
   )

   @LATENCY.time()            # times the wrapped call and observes it
   def handle_request():
       time.sleep(random.expovariate(1 / 0.25))

   if __name__ == "__main__":
       start_http_server(8000)
       while True:
           handle_request()
   ```

2. Run it, then scrape its endpoint:

   ```bash
   python3 app.py &
   sleep 5
   curl -s localhost:8000/metrics | grep app_request_latency_seconds
   ```

3. Inspect the exposition. Note that the client library added `le="+Inf"` for you and that the buckets are monotonically non-decreasing:

   ```text
   # TYPE app_request_latency_seconds histogram
   app_request_latency_seconds_bucket{le="0.05"} 118.0
   app_request_latency_seconds_bucket{le="0.1"}  221.0
   app_request_latency_seconds_bucket{le="0.2"}  392.0
   app_request_latency_seconds_bucket{le="0.3"}  505.0
   app_request_latency_seconds_bucket{le="0.5"}  643.0
   app_request_latency_seconds_bucket{le="0.75"} 731.0
   app_request_latency_seconds_bucket{le="1.0"}  779.0
   app_request_latency_seconds_bucket{le="2.5"}  818.0
   app_request_latency_seconds_bucket{le="5.0"}  824.0
   app_request_latency_seconds_bucket{le="+Inf"} 825.0
   app_request_latency_seconds_sum   214.77
   app_request_latency_seconds_count 825.0
   ```

4. Point a Prometheus at it. Create `prometheus.yml`:

   ```yaml
   global:
     scrape_interval: 5s
     evaluation_interval: 5s
   scrape_configs:
     - job_name: demo-app
       static_configs:
         - targets: ["host.docker.internal:8000"]   # or localhost:8000 for a local binary
   ```

   ```bash
   docker run --rm -d --name prom2 -p 9091:9090 \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     --add-host=host.docker.internal:host-gateway \
     prom/prometheus:v3.1.0
   ```

5. Let it scrape for ~2 minutes so the `rate()` windows in Exercise 3 have data.

**Comprehension checks**

- **Q5.** You picked 9 finite buckets tightly around 0.3s. What are the two costs you would pay if instead you used 50 buckets from 0.001 to 100? Name the specific Prometheus resource that scales with bucket count and by what factor per series/target.
- **Q6.** The highest finite bucket is `le="5.0"`. From the numbers above, roughly how many observations exceeded 5.0s, and where do you read that off?
- **Q7.** `@LATENCY.time()` — at what moment is the observation recorded, start or end of the call, and what would happen to the histogram if the wrapped function raised an exception? (Reason about it; the decorator uses a context manager.)

---

## Exercise 3 — Quantiles: the `histogram_quantile` + `rate` pattern

**Goal:** compute p50/p90/p99 correctly, and internalize *why* the two mandatory wrappers (`rate`, `sum by (le)`) are there.

1. Run an instant p90 query with `promtool`:

   ```bash
   promtool query instant http://localhost:9091 \
     'histogram_quantile(0.9, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))'
   ```

   Expected shape (value near the 0.75–1.0 region for this distribution):

   ```text
   {} => 0.71 @[1754655600.000]
   ```

2. Now run the p50, p90, p99 together in the expression browser (`http://localhost:9091/graph`) or as three `promtool` calls:

   ```promql
   histogram_quantile(0.50, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))
   histogram_quantile(0.90, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))
   histogram_quantile(0.99, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))
   ```

   Typical results:

   ```text
   p50 => 0.196
   p90 => 0.706
   p99 => 4.83     # <-- notice how imprecise this one is; Exercise 4 explains it
   ```

3. Deliberately **break** the query two ways and observe the failure modes:

   ```promql
   # (a) Forget rate(): feed raw ever-growing counters straight in.
   histogram_quantile(0.9, sum by (le) (app_request_latency_seconds_bucket))

   # (b) Drop the le label during aggregation.
   histogram_quantile(0.9, sum(rate(app_request_latency_seconds_bucket[1m])))
   ```

   Query (b) returns `NaN`. Query (a) returns a plausible-looking-but-meaningless number that never reacts to recent latency changes.

**Comprehension checks**

- **Q8.** `histogram_quantile` needs the *rate of increase* of each bucket, not the raw bucket value. Explain, in terms of what a `_bucket` series is, why applying `rate()` first is not optional. What real event would silently corrupt the raw-counter version?
- **Q9.** Why does dropping `le` (query b) yield `NaN` rather than a wrong number? What is `histogram_quantile` structurally unable to do without that label?
- **Q10.** Team A charts `avg(histogram_quantile(0.99, ...))` across 20 pods. Team B charts `histogram_quantile(0.99, sum by (le) (rate(..._bucket[5m])))`. Only one is statistically valid. Which, and what is the name of the error the other one commits?
- **Q11.** The p99 came back as `4.83`, suspiciously close to your top finite bucket of `5.0`. Predict what `histogram_quantile(0.999, ...)` returns and why it *cannot* exceed a specific number.

---

## Exercise 4 — Aggregation, interpolation error, and an Apdex SLO

**Goal:** aggregate a histogram across a dimension, quantify the error baked into bucket interpolation, and build a real SLO signal directly from buckets.

1. **Interpolation error, made visible.** Your buckets jump `1.0 → 2.5 → 5.0 → +Inf`. Any quantile landing in `(1.0, 2.5]` is *linearly interpolated* across a 1.5s-wide bucket, assuming a uniform spread that your exponential tail does not have. Confirm the mechanic by asking for a quantile you know sits in the top finite bucket:

   ```promql
   histogram_quantile(0.995, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))
   ```

   It will return a value pinned near `5.0` regardless of how bad the true tail is, because there is no resolution above `5.0` — only `+Inf`.

2. **Fix by design (do not run yet — reason about it):** to measure the tail honestly you would add finite buckets *above* the region of interest (e.g. `7.5, 10, 20`). The correct place to spend bucket budget is wherever your SLO thresholds and alert boundaries live.

3. **Build an Apdex score** — a satisfaction ratio with target `T = 0.3s` (so "tolerating" ≤ `4T = 1.2s`). Because your buckets are cumulative, the counts you need are *exactly* bucket boundaries — but note you don't have `le="1.2"`. Add it in `app.py`’s `buckets=(...)` (insert `1.2`) and restart, **or** use the nearest available boundaries `0.3` and `1.0` for this drill. The Apdex query:

   ```promql
   (
       sum(rate(app_request_latency_seconds_bucket{le="0.3"}[5m]))
     + sum(rate(app_request_latency_seconds_bucket{le="1.2"}[5m]))
   ) / 2 / sum(rate(app_request_latency_seconds_bucket{le="+Inf"}[5m]))
   ```

   Result is a number in `[0,1]`, e.g. `=> 0.68`.

4. **Error-budget style ratio** — fraction of requests slower than the 0.3s SLO:

   ```promql
   1 - (
       sum(rate(app_request_latency_seconds_bucket{le="0.3"}[5m]))
     /
       sum(rate(app_request_latency_seconds_bucket{le="+Inf"}[5m]))
   )
   ```

**Comprehension checks**

- **Q12.** Derive the Apdex formula in step 3 from its definition — `(satisfied + tolerating/2) / total`, where *satisfied* ≤ `T` and *tolerating* is in `(T, 4T]`. Show why, with cumulative buckets, it collapses to `(bucket_T + bucket_4T) / (2 · bucket_+Inf)`.
- **Q13.** Why is the "fraction slower than 0.3s" query in step 4 **exact** (up to scrape granularity), while the p99 in Exercise 3 is only an *estimate*? What structural difference between the two questions removes the interpolation?
- **Q14.** You want a tighter p99 without ballooning bucket count everywhere. Where do you add the two or three buckets you can afford, and what principle decides the placement?
- **Q15.** `histogram_quantile` interpolates assuming a *uniform* distribution inside each bucket. For an exponential/long-tail latency, does this tend to over- or under-estimate a quantile that falls deep inside a wide bucket? Give the intuition.

---

## Exercise 5 — Native histograms (the modern alternative)

**Goal:** contrast classic (bucketed, one series per boundary) with **native histograms** — a single series carrying sparse, exponential, auto-resolving buckets — and see how the query surface changes.

1. Native histograms are still behind a feature flag. Restart Prometheus with it enabled:

   ```bash
   docker run --rm -d --name prom3 -p 9092:9090 \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     --add-host=host.docker.internal:host-gateway \
     prom/prometheus:v3.1.0 \
     --config.file=/etc/prometheus/prometheus.yml \
     --enable-feature=native-histograms
   ```

   With the flag on, Prometheus negotiates the **protobuf** exposition format at scrape time so it can ingest native histograms. ([feature_flags](https://prometheus.io/docs/prometheus/latest/feature_flags/#native-histograms), [native histograms spec](https://prometheus.io/docs/specs/native_histograms/))

2. A native histogram must be *emitted* by the client. In Go (`client_golang`), the same metric becomes native by setting a bucket **factor** instead of a fixed boundary list:

   ```go
   latency := prometheus.NewHistogram(prometheus.HistogramOpts{
       Name: "app_request_latency_seconds",
       Help: "End-to-end request latency in seconds",
       // Native histogram: exponential buckets that auto-adjust resolution.
       NativeHistogramBucketFactor:     1.1,        // ~10% width per bucket
       NativeHistogramMaxBucketNumber:  100,        // cap cardinality per series
       NativeHistogramMinResetDuration: time.Hour,  // schema-reset guard
       // No `Buckets: []float64{...}` at all.
   })
   ```

3. Query it. **The most important contrast:** there is no `_bucket` suffix and no `le` label to preserve — the native histogram is a single sample, so `rate()` alone reconstitutes it and `histogram_quantile` takes it directly:

   ```promql
   # Classic (Exercises 3-4):
   histogram_quantile(0.9, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))

   # Native — no _bucket, no `by (le)`:
   histogram_quantile(0.9, rate(app_request_latency_seconds[1m]))
   ```

4. Use the native-only accessor functions that read a histogram sample as a whole:

   ```promql
   histogram_count(rate(app_request_latency_seconds[1m]))          # observations/sec
   histogram_sum(rate(app_request_latency_seconds[1m]))            # summed value/sec
   histogram_avg(rate(app_request_latency_seconds[1m]))            # sum/count
   histogram_fraction(0, 0.3, rate(app_request_latency_seconds[1m]))  # fraction ≤ 0.3s, no bucket-boundary needed
   ```

   `histogram_fraction(0, 0.3, ...)` gives your SLO ratio from Exercise 4 step 4 — but for *any* threshold, not only where you happened to place a bucket. ([querying functions](https://prometheus.io/docs/prometheus/latest/querying/functions/#histograms))

**Comprehension checks**

- **Q16.** A classic histogram with 10 buckets produces how many time series *per label combination*? A native histogram produces how many? State both numbers and why the native count is the same regardless of resolution.
- **Q17.** Why does the native-histogram quantile query drop both the `_bucket` suffix *and* the `sum by (le)` wrapper that were mandatory for classic histograms?
- **Q18.** `histogram_fraction(0, 0.3, ...)` answers Exercise 4’s SLO ratio for an *arbitrary* 0.3s cut-off. Why can a classic histogram only answer that exactly when `0.3` happens to be a bucket boundary, while a native histogram is not so constrained (and what is the residual source of its small error)?
- **Q19.** Your dashboards still `sum by (le)` on this metric after switching it to native. What happens, and how would you notice? (Consider `always_scrape_classic_histograms` in the scrape config.)

---

## Exercise 6 — Diagnostics: reading `NaN`, empty, and pinned results

**Goal:** turn the failure modes into a checklist you can run under exam pressure.

1. Reproduce **"quantile returns `NaN`"** three distinct ways and record the cause of each:

   ```promql
   # (a) No traffic in the window → every bucket rate is 0.
   histogram_quantile(0.9, sum by (le) (rate(app_request_latency_seconds_bucket[10s])))
   #     (run right after a fresh Prometheus start, before enough samples)

   # (b) le dropped by aggregation (from Exercise 3b).
   histogram_quantile(0.9, sum(rate(app_request_latency_seconds_bucket[1m])))

   # (c) Fewer than two buckets survive a filter.
   histogram_quantile(0.9, sum by (le) (rate(app_request_latency_seconds_bucket{le="+Inf"}[1m])))
   ```

2. Reproduce **"quantile pinned to the top bucket"** and connect it to Exercise 4:

   ```promql
   histogram_quantile(0.9999, sum by (le) (rate(app_request_latency_seconds_bucket[1m])))
   ```

3. Confirm the **rate-window rule of thumb** — the range must span at least ~4 scrape intervals. With `scrape_interval: 5s`, compare `[1m]` (12 samples, stable) against `[8s]` (≈1–2 samples, jittery/empty):

   ```promql
   histogram_quantile(0.9, sum by (le) (rate(app_request_latency_seconds_bucket[8s])))
   ```

4. Check **bucket cardinality** before it bites you — list distinct `le` values a metric carries:

   ```promql
   count by (le) (app_request_latency_seconds_bucket)
   ```

**Comprehension checks**

- **Q20.** For each of the three `NaN` producers in step 1, name the root cause in one clause.
- **Q21.** Why does asking for `0.9999` reliably return your highest *finite* `le` (here `5.0`) rather than something larger? What does the `+Inf` bucket *not* give you?
- **Q22.** A too-short `rate()` window over a histogram bucket can produce `NaN` or flapping quantiles. State the "≥ 4× scrape interval" rule and why fewer than two samples in the window is fatal to `rate()`.
- **Q23.** You suspect a metric is blowing up your TSDB. `count by (le) (some_bucket)` shows 40 `le` values across 200 targets. How many bucket *series* is that, and which of counter/gauge/histogram would you reach for if you could tolerate server-side re-quantiling but not this cardinality?

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

**Q1.** The `le="1"` bucket is **cumulative**: it counts every observation **≤ 1s**, i.e. all requests that took *up to* 1 second — not just those between 0.4s and 1s. To get the count of the `(0.4, 1]` slice you subtract: `bucket{le="1"} − bucket{le="0.4"}`. Cumulative counting is exactly what lets the server interpolate quantiles later.

**Q2.** The `+Inf` bucket catches every observation regardless of size, so it is the total. It is mandatory because `histogram_quantile` needs the grand total to locate the rank `φ · total`. It must always equal `..._count`. If an exporter omitted it, quantiles above the last finite bucket would be uncomputable.

**Q3.** `sum / count` is the **arithmetic mean** latency (≈ 0.0014s here — actually `0.041231/30`). It is not the p90 because the mean is dominated by the bulk and hides the tail: a service can have a great mean and a terrible p99. Percentiles answer "how bad is it for the unlucky N%"; the mean cannot.

**Q4.** `le` is a **string label**, and `0.10000000000000001` and `0.1` are *different label values*. When you `sum by (le)` across targets, the two spellings do not merge — you get two half-populated buckets, the cumulative monotonicity breaks, and `histogram_quantile` produces wrong or `NaN` results. Client libraries normalize float formatting to avoid this; a hand-rolled exporter can reintroduce it.

**Q5.** Cost 1 — **time-series cardinality**: a classic histogram creates *one series per `le`* (plus `_sum` and `_count`). 50 buckets ≈ 52 series **per label combination per target**; multiplied across targets and other labels this dominates TSDB memory, disk, and query cost. Cost 2 — **scrape/ingest volume and slower `sum by (le)`** over more series. The resource that scales linearly with bucket count is active time series (and therefore head-block memory), roughly `(buckets + 2)` per series identity.

**Q6.** `count − bucket{le="5.0"} = 825 − 824 = 1` observation exceeded 5.0s. You read it as `+Inf` minus the highest finite bucket: `bucket{le="+Inf"} − bucket{le="5.0"}`.

**Q7.** The observation is recorded at the **end** of the call, when the timer/context-manager exits (it measures elapsed wall time). Because `@Histogram.time()` uses a context manager, the observation is still recorded **even if the function raises** — the `__exit__` runs during exception unwinding. So exceptions are timed and counted like any other request (they are *not* silently dropped).

**Q8.** A `_bucket` series is a **monotonically increasing counter** (total observations ≤ le since process start). Its raw value carries all of history and resets to 0 on process restart. `histogram_quantile` needs the *current shape* of the distribution — the recent per-second increase of each bucket — so you must `rate()` (or `increase()`) first. The real event that corrupts the raw-counter version is a **process restart / counter reset**: `rate()` handles the reset; a raw counter would show a nonsensical drop and a frozen, ever-growing baseline that never reflects recent latency.

**Q9.** `histogram_quantile` reconstructs the cumulative distribution *from the `le` boundaries*. Drop `le` and you have collapsed all buckets into one number — there is no ladder of thresholds to interpolate across, so the function has nothing to walk and returns `NaN`. It is structurally unable to locate a rank without the bucket boundaries.

**Q10.** **Team B** is valid. Team A commits the classic error of **averaging quantiles** (averaging percentiles across series is mathematically meaningless — the average of per-pod p99s is not the fleet p99). The correct approach is to aggregate the **buckets** with `sum by (le)` *first*, then take the quantile once over the merged distribution.

**Q11.** `histogram_quantile(0.999, ...)` also returns a value ≤ **5.0** (your highest *finite* `le`). It cannot exceed 5.0 because above it there is only `+Inf`, which has no numeric upper bound to interpolate toward — Prometheus returns the highest finite boundary. Any quantile whose rank lands in the `+Inf` bucket is reported at that boundary, which is why the tail looks artificially capped.

**Q12.** Definition: `Apdex = (satisfied + tolerating/2) / total`, with `satisfied = count(≤T)` and `tolerating = count(≤4T) − count(≤T)`. Substitute:
`= [count(≤T) + (count(≤4T) − count(≤T))/2] / total`
`= [count(≤T)/2 + count(≤4T)/2] / total`
`= (count(≤T) + count(≤4T)) / (2 · total)`.
With cumulative buckets `count(≤T) = bucket{le="T"}`, `count(≤4T) = bucket{le="4T"}`, `total = bucket{le="+Inf"}`, giving `(bucket_T + bucket_4T) / (2 · bucket_+Inf)`.

**Q13.** The step-4 query asks a question whose boundary (`0.3`) **is an actual bucket edge**, so the count of requests ≤ 0.3 is stored *exactly* in that cumulative bucket — no interpolation. A quantile (p99) asks "what latency has 99% below it?" — the answer almost never lands on a bucket edge, so Prometheus must **interpolate inside a bucket**, and that estimate is only as good as the bucket width there.

**Q14.** Add the extra buckets **around the specific latency where p99 falls and around your SLO/alert thresholds** — the regions you actually query. Principle: bucket resolution should be highest where decisions are made; wide buckets are fine in ranges you never quantile. Don't spread buckets uniformly; concentrate them at thresholds.

**Q15.** Interpolation assumes observations are spread **uniformly** across the bucket. A long-tail/exponential distribution has *more mass near the lower edge* of a wide bucket, so a quantile deep inside the bucket tends to be **over-estimated** (the linear model places the rank higher than the true, front-loaded distribution would). The remedy is narrower buckets in that region (or native histograms).

**Q16.** Classic with 10 buckets → the 10 `_bucket` series **plus `_sum` and `_count` = 12 series** per label combination (the `+Inf` bucket is one of the ten if you count it among them; the point is ~N+2). A native histogram → **1 series** per label combination, because all buckets, sum, and count travel inside a single sample. The native count stays 1 regardless of resolution because higher resolution adds *sparse spans inside the sample*, not new series.

**Q17.** Because a native histogram is a **single sample that already contains all its buckets**. There is no separate `_bucket` child series to name, and no `le` label to preserve during aggregation — `rate()` reconstitutes the whole histogram, and `sum(rate(...))` (plain, or `sum by (job)`, etc.) merges histograms element-wise. `histogram_quantile` then reads the merged sample directly.

**Q18.** A classic histogram only *knows* the counts at its predefined boundaries; a cut-off that isn't a boundary must be interpolated, and if it's between boundaries the answer is an estimate — exact only when the threshold equals a bucket edge. A native histogram has fine, exponential resolution everywhere, so `histogram_fraction(0, 0.3, ...)` finds a boundary very close to 0.3 for almost any threshold. The residual error is just the native histogram's own bucket width at that value (governed by the factor, e.g. ~10% for 1.1) plus interpolation within it — much smaller and threshold-independent.

**Q19.** After switching to native, there is **no `..._bucket` series and no `le` label**, so `sum by (le) (rate(..._bucket[...]))` matches nothing and returns **empty** — dashboards go blank rather than erroring. You notice by empty panels. To keep old classic-based dashboards working during migration, set **`always_scrape_classic_histograms: true`** in the scrape config so Prometheus ingests *both* the classic buckets and the native histogram for that metric.

**Q20.** (a) **No observations in the window** → all bucket rates are 0, total is 0, rank undefined → `NaN`. (b) **`le` label dropped** by `sum(...)` → no boundaries to interpolate → `NaN`. (c) **Fewer than two buckets** survive the filter (`{le="+Inf"}` alone) → `histogram_quantile` needs ≥ 2 boundaries → `NaN`.

**Q21.** Rank `0.9999 · total` falls inside the `+Inf` bucket, which has no numeric upper edge to interpolate toward, so Prometheus reports the **highest finite `le` (5.0)**. The `+Inf` bucket gives you a *count of oversized requests* but **not their magnitude** — it cannot tell you how far past 5.0 the tail actually stretches.

**Q22.** Rule of thumb: the `rate()` **range must be ≥ ~4× the scrape interval** so the window reliably contains several samples. `rate()` needs at least **two samples** in the window to compute a slope; with a `[8s]` window over a 5s scrape you may capture only one sample (or zero), so `rate()` yields no value and the quantile is `NaN` or flaps as the window slides across sample boundaries.

**Q23.** 40 `le` values × 200 targets = **8,000 bucket series** (before `_sum`/`_count`, so ~8,400 total). If you can tolerate server-side re-quantiling but not this cardinality, switch the metric to a **native histogram** (1 series per label set instead of 42) — you keep query-time quantiles and re-aggregation while collapsing the series count. (A summary would cut cardinality too but *loses* server-side re-quantiling and cross-target aggregation, so it's the wrong trade here.)

</details>

---

### Sources

- Prometheus — *Metric types: Histogram*: https://prometheus.io/docs/concepts/metric_types/#histogram
- Prometheus — *Best practices: Histograms and summaries*: https://prometheus.io/docs/practices/histograms/
- Prometheus — *Querying functions: `histogram_quantile`, `histogram_fraction`, `histogram_count/sum/avg`*: https://prometheus.io/docs/prometheus/latest/querying/functions/#histograms
- Prometheus — *Native histograms (feature flag)*: https://prometheus.io/docs/prometheus/latest/feature_flags/#native-histograms
- Prometheus — *Native histograms specification*: https://prometheus.io/docs/specs/native_histograms/
- CNCF PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf