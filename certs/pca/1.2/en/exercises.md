# PCA 1.2 — Rates and Derivatives — Guided Exercises

> **Domain:** PromQL · **Exam weight:** 4 · **Certification:** Prometheus Certified Associate (PCA)
>
> These exercises assume Docker and `curl` + `jq` on your workstation. Everything runs against a single Prometheus scraping **itself**, so you need no external targets. Work through the exercises in order — each one builds on the counter/gauge series produced by the previous load.
>
> **Reference sources (official):**
> - Query functions — https://prometheus.io/docs/prometheus/latest/querying/functions/
> - Query basics (instant vs range vectors, staleness) — https://prometheus.io/docs/prometheus/latest/querying/basics/
> - Metric types (counter vs gauge) — https://prometheus.io/docs/concepts/metric_types/
> - Instrumentation best practices — https://prometheus.io/docs/practices/instrumentation/
> - Recording/alerting rules & the aggregation-order rule — https://prometheus.io/docs/prometheus/latest/querying/rules/
> - PCA curriculum — https://github.com/cncf/curriculum

---

## Exercise 0 — Build the lab

**Goal:** stand up a Prometheus that scrapes itself at a fast interval, and generate traffic so the built-in counters move visibly.

1. Create a working directory and a config file. The short `scrape_interval` (5 s) makes rate windows converge quickly during a lab; production defaults are 15 s.

   ```bash
   mkdir -p pca-rates && cd pca-rates
   cat > prometheus.yml <<'EOF'
   global:
     scrape_interval: 5s
     evaluation_interval: 5s
   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']
   EOF
   ```

2. Launch Prometheus (any recent 2.x/3.x image works):

   ```bash
   docker run -d --name pca-prom -p 9090:9090 \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     prom/prometheus:latest
   ```

3. Confirm it is up and scraping itself:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result'
   ```

   Expected (value `"1"` means the target is healthy):

   ```json
   [
     {
       "metric": { "__name__": "up", "instance": "localhost:9090", "job": "prometheus" },
       "value": [ 1733664000.123, "1" ]
     }
   ]
   ```

4. Start a background load generator. Each request to the query API increments the counter `prometheus_http_requests_total{handler="/api/v1/query"}`. Let it run for the whole session:

   ```bash
   ( while true; do
       curl -s 'http://localhost:9090/api/v1/query?query=1' >/dev/null
       sleep 0.2
     done ) &
   echo "load PID: $!"    # remember this to kill it later
   ```

5. Wait ~2 minutes so the counters accumulate at least a dozen samples, then continue.

**Comprehension check**

- **Q0.1** Why did we deliberately hit `/api/v1/query` in a loop instead of just watching the metric sit still?
- **Q0.2** With `scrape_interval: 5s`, how many raw samples does a `[1m]` range vector contain for one series, and what is the minimum number `rate()` needs to return anything?

---

## Exercise 1 — Why a raw counter is (almost) useless

**Goal:** see that counters are monotonically increasing totals, not rates, and that their absolute value carries almost no operational meaning.

1. Look at the raw counter as an **instant vector**:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=prometheus_http_requests_total{handler="/api/v1/query"}' \
     | jq '.data.result[] | {code: .metric.code, value: .value[1]}'
   ```

   Expected (an ever-growing integer — yours will differ):

   ```json
   { "code": "200", "value": "1487" }
   ```

2. Run the same query 10 seconds later. Note the number is **larger**.

3. Restart Prometheus to simulate a process restart, then re-read the counter:

   ```bash
   docker restart pca-prom
   sleep 8
   curl -s 'http://localhost:9090/api/v1/query?query=prometheus_http_requests_total{handler="/api/v1/query"}' \
     | jq '.data.result[] | {code: .metric.code, value: .value[1]}'
   ```

   Expected — the value **dropped back toward zero** (a counter reset):

   ```json
   { "code": "200", "value": "12" }
   ```

4. Re-attach a load generator if the restart killed it (repeat Exercise 0 step 4).

**Comprehension check**

- **Q1.1** The absolute value `1487` tells you almost nothing on its own. Name two facts you *cannot* infer from it.
- **Q1.2** After the restart the value fell. What is this event called, and which family of PromQL functions is specifically designed to survive it without producing a huge negative spike?

---

## Exercise 2 — `rate()`: the per-second average, and how the window shapes it

**Goal:** understand that `rate()` gives the **per-second average rate of increase** over a range window, and that the window length trades responsiveness for smoothness.

1. Compute the request rate over three different windows at the same instant:

   ```bash
   for w in 30s 1m 5m; do
     echo -n "[$w] => "
     curl -s "http://localhost:9090/api/v1/query?query=rate(prometheus_http_requests_total%7Bhandler=%22/api/v1/query%22%7D%5B$w%5D)" \
       | jq -r '.data.result[0].value[1]'
   done
   ```

   Expected (≈5 req/s from our 0.2 s loop; the shorter window reacts faster and is noisier):

   ```
   [30s] => 4.87
   [1m]  => 4.93
   [5m]  => 4.62
   ```

2. Now break the rule that the window must span **at least two scrape intervals**. Query a window shorter than one scrape interval:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[3s])' \
     | jq '.data.result'
   ```

   Expected — **empty**, because a `[3s]` window with a 5 s scrape interval usually contains fewer than two samples:

   ```json
   []
   ```

3. Fix it by widening the window to at least `[15s]` (≥ 2× scrape interval) and confirm a value returns.

**Comprehension check**

- **Q2.1** All three windows in step 1 measured the *same* moment yet returned different numbers. What does the range window actually select, and why does a longer window look smoother?
- **Q2.2** Why did `[3s]` return nothing, and what is the practical rule of thumb for choosing a `rate()` window relative to `scrape_interval`?
- **Q2.3** Prometheus does not know a metric's type at query time. What single assumption does `rate()` make about the data that lets it handle counter resets — and what happens if you feed it a gauge?

---

## Exercise 3 — `irate()` vs `rate()`: instant vs average

**Goal:** contrast `irate()` (instant rate from the **last two** samples) with `rate()` (average over the whole window), and learn when each is appropriate.

1. Compare them side by side over the same `[1m]` window:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=irate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"irate = " + .data.result[0].value[1]'
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"rate  = " + .data.result[0].value[1]'
   ```

   Expected — close under steady load, but `irate` is jumpier:

   ```
   irate = 5.20
   rate  = 4.93
   ```

2. Inject a burst so the two diverge. Fire 300 quick requests, then immediately query both again:

   ```bash
   for i in $(seq 1 300); do curl -s 'http://localhost:9090/api/v1/query?query=1' >/dev/null; done
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=irate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"irate = " + .data.result[0].value[1]'
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"rate  = " + .data.result[0].value[1]'
   ```

   Expected — `irate` spikes on the two most recent samples; `rate` averages the burst across the minute and barely moves:

   ```
   irate = 63.40
   rate  = 9.85
   ```

**Comprehension check**

- **Q3.1** In `irate(...[1m])`, what role does the `[1m]` window play, given that `irate` only uses two samples?
- **Q3.2** You are writing an alerting rule evaluated every 1 minute over a slow counter. Why is `irate` the wrong choice here, and what failure mode ("aliasing") can it cause?
- **Q3.3** Give one legitimate use where `irate` is *preferable* to `rate`.

---

## Exercise 4 — `increase()` and the extrapolation trap

**Goal:** see that `increase()` is `rate()` × window, that both **extrapolate** to the window edges, and why that produces non-integer counts.

1. Compute the total increase over 1 minute and the rate that implies:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=increase(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"increase[1m] = " + .data.result[0].value[1]'
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[1m]) * 60' \
     | jq -r '"rate[1m]*60  = " + .data.result[0].value[1]'
   ```

   Expected — the two lines are (essentially) identical:

   ```
   increase[1m] = 296.4
   rate[1m]*60  = 296.4
   ```

2. Notice `296.4` is **not** an integer, even though a request counter only ever increases by whole numbers. Grab the raw samples to see the true integer delta:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=prometheus_http_requests_total{handler="/api/v1/query"}[1m]' \
     | jq -r '.data.result[0].values | "first=\(.[0][1])  last=\(.[-1][1])  raw_delta=\(( .[-1][1]|tonumber) - (.[0][1]|tonumber))"'
   ```

   Expected — the raw delta between the first and last stored sample is a whole number *smaller* than `296.4`:

   ```
   first=1502  last=1789  raw_delta=287
   ```

**Comprehension check**

- **Q4.1** Why is the reported `increase` (`296.4`) larger than and different from the raw integer delta (`287`)?
- **Q4.2** State the exact relationship between `increase(v[w])` and `rate(v[w])`.
- **Q4.3** A colleague alerts on `increase(errors_total[5m]) < 1` expecting "exactly zero errors." Why is comparing an extrapolated float against an integer threshold fragile?

---

## Exercise 5 — The aggregation-order rule: `sum(rate(...))`, never `rate(sum(...))`

**Goal:** internalize the single most-tested PromQL correctness rule — always take `rate()` **before** aggregating across series, so counter resets are handled per-series.

1. Correct form — rate each child series, then sum:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=sum(rate(prometheus_http_requests_total[1m]))' \
     | jq -r '"sum(rate(...)) = " + .data.result[0].value[1]'
   ```

   Expected — a clean aggregate request rate across all handlers/codes:

   ```
   sum(rate(...)) = 11.72
   ```

2. Incorrect form — sum the raw counters first (this even fails to type-check, because `sum()` returns an instant vector but `rate()` needs a range vector):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(sum(prometheus_http_requests_total)[1m])' \
     | jq -r '.error // .data'
   ```

   Expected — a parse/type error, illustrating that the language pushes you toward the correct order:

   ```
   parse error: ranges only allowed for vector selectors
   ```

3. To make the *semantic* danger concrete, imagine two child series where one resets. Reason about it on paper before the answers: series A goes `…, 100, 101, 2, 3` (reset) and series B goes `…, 50, 51, 52, 53`. If you summed the raw counters first you would get `…, 150, 152, 54, 56` — a big fake drop at the reset. `rate()` applied to that merged series would misread the drop.

**Comprehension check**

- **Q5.1** Restate the rule in one sentence, and explain *why* order matters in terms of how `rate()` detects resets.
- **Q5.2** Even ignoring resets, why is `rate(sum(...))` rejected by the query engine outright? (Hint: instant vector vs range vector.)
- **Q5.3** Write the correct expression for "per-second 5xx request rate, summed across all handlers, per `code`." Keep the `code` label.

---

## Exercise 6 — Gauges: `delta()`, `idelta()`, `deriv()`, `predict_linear()`

**Goal:** apply the gauge-only functions to a real sawtooth gauge (`go_memstats_alloc_bytes`, which climbs then drops on garbage collection) and to a slowly growing gauge (`prometheus_tsdb_head_series`).

1. Look at the heap gauge's shape over 2 minutes:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=go_memstats_alloc_bytes[2m]' \
     | jq -r '.data.result[0].values[] | .[1]' | head
   ```

   Expected — values rise, then fall sharply at a GC (a sawtooth):

   ```
   41200112
   47881040
   53992120
   19004416     <-- GC dropped it
   24771328
   ```

2. `delta()` — first-to-last difference over the window (may be negative):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=delta(go_memstats_alloc_bytes[2m])' \
     | jq -r '.data.result[0].value[1]'
   ```

   Expected (sign depends on where GC fell in the window):

   ```
   -8402112
   ```

3. `idelta()` — difference between only the **last two** samples:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=idelta(go_memstats_alloc_bytes[2m])' \
     | jq -r '.data.result[0].value[1]'
   ```

4. `deriv()` — per-second derivative via least-squares linear regression, on the slowly-growing series count gauge:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=deriv(prometheus_tsdb_head_series[5m])' \
     | jq -r '.data.result[0].value[1]'
   ```

   Expected — series-per-second growth (near zero on an idle server):

   ```
   0.0138
   ```

5. `predict_linear()` — extrapolate the regression forward. Predict the head series count one hour (3600 s) from now:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=predict_linear(prometheus_tsdb_head_series[10m], 3600)' \
     | jq -r '.data.result[0].value[1]'
   ```

   Expected — current count plus `deriv × 3600`:

   ```
   1284.7
   ```

**Comprehension check**

- **Q6.1** What happens if you call `rate()` on `go_memstats_alloc_bytes`, and why is `deriv()` the correct tool for a gauge instead?
- **Q6.2** Contrast `delta()` and `idelta()` on the sawtooth gauge — when would each mislead you about the memory trend?
- **Q6.3** Write a `predict_linear()` alert expression that fires when a filesystem gauge `node_filesystem_avail_bytes` is trending to hit **zero within 4 hours**. Explain each term.
- **Q6.4** Why does `deriv()` use linear regression rather than just `(last − first) / window`, the way `delta()` effectively does?

---

## Exercise 7 — Counter resets and `resets()`

**Goal:** count reset events explicitly and confirm that `rate()`/`increase()` absorb them so downstream math stays correct.

1. Read the reset count over the last 15 minutes (should include the restart from Exercise 1):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=resets(prometheus_http_requests_total{handler="/api/v1/query"}[15m])' \
     | jq -r '.data.result[0].value[1]'
   ```

   Expected (≥ 1 because we restarted the process):

   ```
   1
   ```

2. Force a second reset, wait for a few scrapes, and re-check that `resets()` increments while `rate()` stays sane (non-negative):

   ```bash
   docker restart pca-prom && sleep 20
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=resets(prometheus_http_requests_total{handler="/api/v1/query"}[15m])' \
     | jq -r '"resets = " + .data.result[0].value[1]'
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"rate   = " + (.data.result[0].value[1] // "none-yet")'
   ```

   Expected:

   ```
   resets = 2
   rate   = 3.10
   ```

3. Re-launch the load generator after the restart if needed.

**Comprehension check**

- **Q7.1** How does `rate()` decide that a reset occurred, and what does it add to the computed increase to compensate?
- **Q7.2** `resets()` returns `2` but you know the raw counter dropped only when the process restarted. Could `resets()` ever *over-count* on a healthy counter? Under what condition would a legitimate value decrease be misread as a reset?
- **Q7.3** Is `resets()` meaningful on a gauge? Why or why not?

---

## Exercise 8 — Diagnosing gaps, staleness, and rate pitfalls

**Goal:** connect rate math to failure modes an SRE actually debugs — missing samples, extrapolation at the boundary, and slow counters.

1. Stop scraping mid-flight to create a gap, then observe `rate()` decay to nothing:

   ```bash
   docker stop pca-prom && sleep 20 && docker start pca-prom && sleep 3
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq '.data.result'
   ```

   Expected — right after restart the `[1m]` window has < 2 fresh samples, so the result is **empty** for a moment:

   ```json
   []
   ```

2. Query a **very slow** counter with a **short** window to see how a slow-moving series looks like it "isn't moving." Pick a rarely-hit handler:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/-/healthy"}[1m])' \
     | jq -r '.data.result[0].value[1] // "no data / 0-ish"'
   ```

3. Inspect the boundary-extrapolation behavior. Compare `increase` over a window barely longer than two scrapes vs a long window, on a steady counter, and note that the short window over-reports proportionally more due to edge extrapolation.

**Comprehension check**

- **Q8.1** After a 20 s scrape gap, why did `rate(...[1m])` briefly return nothing rather than a stale value? Tie your answer to Prometheus's **staleness** handling and the two-sample minimum.
- **Q8.2** A slow counter that increments a few times per hour, queried with `rate(...[1m])`, frequently reads `0` or empty. What two knobs (window length and, if needed, function choice) fix this, and what is the cost of each?
- **Q8.3** Explain, in terms of the extrapolation algorithm, why `increase()` over a short window tends to over-report compared with the true integer delta, and how Prometheus clamps this near the series' start-of-life or zero.

---

## Answers

<details>
<summary>Click to reveal all answers</summary>

**Q0.1** A counter only changes when the instrumented event happens. An idle metric produces flat samples, and `rate()`/`increase()` of a flat counter is `0` — nothing to observe. Driving traffic makes the counter climb so the rate functions have a real slope to measure.

**Q0.2** With a 5 s scrape interval, `[1m]` holds roughly `60 / 5 = 12` samples per series (11–13 depending on alignment). `rate()` needs **at least two** samples inside the window to compute a slope; with fewer than two it returns nothing for that series.

---

**Q1.1** From `1487` alone you cannot infer (a) *how fast* requests are arriving now — the value is a lifetime total, not a rate; (b) *when the process started*, so you don't know the time base; (c) whether any resets happened along the way. Absolute counter values are meaningful only after differencing.

**Q1.2** It is a **counter reset** (the process restarted, so the counter went back to zero). The `rate()` family — `rate()`, `irate()`, `increase()`, and `resets()` — is designed to detect the decrease, treat it as a reset, and compensate rather than emit a large negative spike.

---

**Q2.1** The range window `[w]` selects **all raw samples in the trailing `w` seconds** for each series. `rate()` computes the average per-second increase across those samples. A longer window averages over more samples, so transient bursts are diluted → smoother but slower to react; a shorter window tracks recent behavior closely → responsive but noisy.

**Q2.2** `[3s]` is shorter than one 5 s scrape interval, so the window usually contains 0 or 1 samples — below the two-sample minimum — hence empty. Rule of thumb: **the rate window should be at least 2× (ideally ~4×) the `scrape_interval`** so it reliably contains enough samples and tolerates one missed scrape.

**Q2.3** `rate()` assumes the series is **monotonically increasing** (a counter): any observed *decrease* between adjacent samples is interpreted as a reset and compensated. Feed it a gauge that legitimately goes up and down and every downward move is misread as a reset, inflating the result into meaningless positive spikes. Use gauge functions (`deriv`, `delta`) for gauges.

---

**Q3.1** In `irate(...[1m])` the `[1m]` window only bounds *which* samples are eligible; `irate` then uses the **most recent two** samples within it. The window must still be long enough to contain at least two samples, but its length does not change the averaging period the way it does for `rate`.

**Q3.2** `irate` reflects only the last two scrapes. If the rule is evaluated less frequently than data arrives (evaluated every 1 min but scraped every 5 s), each evaluation samples just one narrow 5–10 s slice and ignores everything between evaluations — **aliasing**. On a slow or bursty counter this makes alerts flap or miss sustained problems. Use `rate()` for alerting so the whole window is averaged.

**Q3.3** `irate` shines for **graphing fast-moving, volatile counters** where you want to see high-frequency detail (e.g. a high-QPS endpoint on a dashboard with a short refresh), and you *want* to see instantaneous spikes rather than smooth them away.

---

**Q4.1** `increase()` (and `rate()`) **extrapolate** the observed slope out to the exact edges of the `[1m]` window, because the first/last stored samples rarely land precisely on the window boundaries. The raw delta `287` covers only the span *between stored samples*; extrapolation scales it up to the full 60 s, yielding `296.4`. The fractional part is the extrapolated fraction of a sample interval.

**Q4.2** `increase(v[w]) == rate(v[w]) * w_seconds`. `increase` is exactly `rate` multiplied by the window length in seconds; they share the same reset-handling and extrapolation.

**Q4.3** Because of extrapolation the result is a **float**, not the true integer event count, and its exact value drifts with sample alignment. Comparing `increase(...) < 1` against an integer boundary can flip on rounding noise. For "did any event occur," prefer robust patterns like `increase(errors_total[5m]) > 0` with generous windows, and never assume the number equals a whole count of events.

---

**Q5.1** **Always `rate()` (or `increase()`) each individual counter series first, then aggregate with `sum()`.** Order matters because `rate()` detects and compensates resets **per series**; if you merge series first, one child's reset shows up as a drop in the merged total that no per-series logic can attribute, corrupting the rate.

**Q5.2** `sum(prometheus_http_requests_total)` returns an **instant vector** (one value per group at one instant). `rate()` requires a **range vector** (`[w]`). You cannot apply a range selector to the output of `sum()`, so the engine rejects `rate(sum(...)[1m])` with a parse error — the language deliberately prevents the wrong order.

**Q5.3**
```promql
sum by (code) (rate(prometheus_http_requests_total{code=~"5.."}[5m]))
```
`rate` per series, then `sum by (code)` to keep the `code` label while collapsing everything else; the `code=~"5.."` matcher restricts to 5xx.

---

**Q6.1** `rate()` on `go_memstats_alloc_bytes` misreads every GC drop as a counter reset and inflates the result — garbage. `deriv()` is the gauge-appropriate function: it fits a **least-squares line** to the samples and reports the per-second slope, so a genuine downward trend produces a negative derivative instead of a fake reset.

**Q6.2** `delta()` = last − first over the whole window; on a sawtooth it depends entirely on where the GC drop falls relative to the window edges, so it can report a large negative "trend" that is really just one GC. `idelta()` = last − second-to-last, so it reflects only the single most recent step (allocation or GC) and tells you nothing about the longer trend. Both mislead on sawtooth memory; `deriv()` over a multi-cycle window is the honest trend.

**Q6.3**
```promql
predict_linear(node_filesystem_avail_bytes[1h], 4 * 3600) < 0
```
`node_filesystem_avail_bytes[1h]` gives an hour of gauge history; `predict_linear(..., 14400)` fits a line and extrapolates the value **4 hours (14400 s) into the future**; `< 0` fires when the projected free space would be negative, i.e. the disk is trending to fill within 4 hours. Using a 1 h regression window smooths short-lived dips.

**Q6.4** `deriv()` uses regression so it is **robust to noise**: a single outlier sample (or one GC dip) barely moves a best-fit line, whereas `(last − first)/window` is fully at the mercy of exactly two endpoint samples. For predicting trends (disk fill, memory growth) the regression slope is far more stable, which is also why `predict_linear` is built on the same least-squares fit.

---

**Q7.1** `rate()` walks adjacent samples in the window; whenever a sample is **smaller than its predecessor**, it treats the gap as a reset and adds the **pre-reset value** back into the running increase (so the series is treated as if it kept climbing from zero). This makes the total increase — and therefore the rate — non-negative across resets.

**Q7.2** Yes, `resets()` can over-count if a series ever legitimately decreases. Any downward step is counted as a reset — so a counter that is (incorrectly) allowed to decrease, or a value that dips due to a bad instrumentation bug, inflates the count. True counters must be monotonic; if instrumentation violates that, both `resets()` and `rate()` are fooled.

**Q7.3** No. `resets()` is only meaningful for counters, where a decrease implies a restart. A gauge decreases as normal behavior, so `resets()` on a gauge just counts how often it went down — not a reset, and not a useful signal.

---

**Q8.1** During the 20 s gap no samples were written, and after `staleness` (default 5 min) old samples still exist but a fresh `[1m]` window right after restart contains at most one *new* sample. With fewer than two samples, `rate()` returns nothing for that series rather than fabricating a value or reusing a stale one — Prometheus marks absent series as stale instead of carrying the last value forward into rate math.

**Q8.2** (1) **Widen the window** — e.g. `rate(slow_counter[15m])` — so it spans several increments; cost: slower reaction and coarser time resolution. (2) If you need "did anything happen at all," switch to `increase(slow_counter[…]) > 0` over a long window; cost: extrapolation makes the number a float, so use it as a boolean-ish threshold, not an exact count. `irate` is the wrong fix here — it worsens the problem on slow counters.

**Q8.3** `rate`/`increase` compute the slope from the first and last in-window samples, then **extrapolate that slope to both window edges**. Over a short window the extrapolated fraction is a larger share of the total, so the reported increase overshoots the true integer delta proportionally more. Prometheus limits this: if the first/last sample sits far from the boundary (more than ~110 % of the average sample interval) it only extrapolates halfway to the average interval, and it **clamps** so the result never projects before the series began or below zero — preventing negative or impossibly-large increases near a counter's start-of-life.

</details>

---

### Teardown

```bash
kill %1 2>/dev/null        # stop the load generator(s)
docker rm -f pca-prom      # remove the lab container