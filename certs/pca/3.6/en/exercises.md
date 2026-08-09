# Guided Exercises — 3.6 Basics of SLOs, SLAs, and SLIs

> **Certification:** Prometheus Certified Associate (PCA) — Domain 3, *Data & Visualization / Observability practices*
> **Prerequisites:** A working Prometheus (`v2.4x+`) with an instrumented target exposing `http_requests_total` (counter, labels `job`, `code`) and `http_request_duration_seconds_*` (histogram). If you have no live target, the sample numbers embedded in each step let you complete every calculation by hand and verify the PromQL logic against them.
>
> Throughout, keep the vocabulary straight: an **SLI** is a *measurement*, an **SLO** is a *target* for that measurement, and an **SLA** is a *contract* (with consequences) built on top of one or more SLOs. Prometheus is where SLIs live as PromQL, where SLOs become recording rules, and where error-budget burn becomes alerts.

---

## Exercise 1 — Separating SLI, SLO, and SLA

**Goal:** Fix the three definitions in place before touching any query, because most exam traps hinge on confusing them.

1. Read this statement from a fictional service's public docs and internal runbook:

   > *"We measure the fraction of successful HTTP requests. Our internal target is that at least 99.9% of requests succeed over any rolling 30-day window. Our paid-tier contract promises customers 99.5% monthly availability; below that, they receive a 10% service credit."*

2. Underline (on paper) exactly one clause that is the **SLI**, one that is the **SLO**, and one that is the **SLA**.

3. Note the two *different* percentages (99.9% and 99.5%) and write down, in one sentence, why a well-run service deliberately sets its SLO **stricter** than its SLA.

4. Classify each of the following as SLI, SLO, SLA, or "none of these":
   - a. `sum(rate(http_requests_total{code!~"5.."}[5m])) / sum(rate(http_requests_total[5m]))`
   - b. "99.95% of writes complete in under 200 ms, measured monthly."
   - c. "If monthly uptime drops below 99.9%, the customer may terminate the contract without penalty."
   - d. "The CPU is running at 73%."

> **Check your understanding — 1**
> 1. Which of the three (SLI/SLO/SLA) is the only one that carries **business or legal consequences** when breached?
> 2. Why is a raw resource metric like `node_cpu_seconds_total` usually a *poor* SLI, even though it is a perfectly good metric?
> 3. If a team has an SLA of 99.5% but no internal SLO, what operational capability are they missing?

---

## Exercise 2 — Building an availability SLI in PromQL

**Goal:** Turn "fraction of successful requests" into a real, dimensionless SLI query, and understand why every term uses `rate()`.

1. Assume your target exposes a counter `http_requests_total{job="api", code}`. Over the last 5 minutes the per-second rates are:

   | `code` | `rate(...[5m])` (req/s) |
   |--------|--------------------------|
   | `200`  | 480 |
   | `301`  | 12  |
   | `404`  | 6   |
   | `500`  | 3   |
   | `503`  | 1   |

2. Write the SLI as the ratio of **good events** (everything that is *not* a server error) to **total valid events**:

   ```promql
   sum(rate(http_requests_total{job="api", code!~"5.."}[5m]))
   /
   sum(rate(http_requests_total{job="api"}[5m]))
   ```

3. Compute the numerator, denominator, and ratio by hand from the table in step 1.

4. Now flip it into the more useful **error-ratio SLI** (this is the form you will feed to alerts later):

   ```promql
   sum(rate(http_requests_total{job="api", code=~"5.."}[5m]))
   /
   sum(rate(http_requests_total{job="api"}[5m]))
   ```

5. Run both. Confirm that `availability_ratio + error_ratio == 1` for this data set, and explain in one line why that identity holds **only because** you counted `4xx` as "good."

> **Check your understanding — 2**
> 1. Why must every term be wrapped in `rate()` rather than using the raw counter values directly?
> 2. A colleague writes the denominator as `sum(rate(http_requests_total{job="api", code=~"2.."}[5m]))`. What subtle bug does this introduce into the SLI?
> 3. Should `404 Not Found` count as a *failure* in your availability SLI? Give the reasoning that decides it (hint: whose fault is a 404?).
> 4. What does it mean, physically, that this SLI is *dimensionless* — and why is that a desirable property for an SLI?

---

## Exercise 3 — A latency SLI from a histogram

**Goal:** Express "requests served fast enough" as a *good-events / total-events* ratio directly from histogram buckets — **not** with a percentile — and understand why that distinction matters for SLOs.

1. Your service exposes `http_request_duration_seconds_bucket{job="api", le}`. The SLO threshold is **300 ms**. Over the last 5 minutes:

   - `sum(rate(http_request_duration_seconds_bucket{job="api", le="0.3"}[5m]))` = **491**
   - `sum(rate(http_request_duration_seconds_count{job="api"}[5m]))`           = **502**

2. Write the latency SLI — the fraction of requests that landed in a bucket at or below the threshold:

   ```promql
   sum(rate(http_request_duration_seconds_bucket{job="api", le="0.3"}[5m]))
   /
   sum(rate(http_request_duration_seconds_count{job="api"}[5m]))
   ```

3. Compute the ratio from step 1's numbers.

4. Contrast this with the percentile approach:

   ```promql
   histogram_quantile(0.99,
     sum by (le) (rate(http_request_duration_seconds_bucket{job="api"}[5m])))
   ```

   Run (or reason about) it. Note that this returns a **duration in seconds**, not a ratio.

5. Explain why the *bucket-ratio* form (step 2) is the correct shape for an SLI, while the *quantile* form (step 4) is better suited to a dashboard panel than to an SLO comparison.

> **Check your understanding — 3**
> 1. The `le="0.3"` bucket must exist in your histogram configuration for step 2 to work. What happens to the SLI if the nearest defined bucket boundaries are `le="0.25"` and `le="0.5"`, and you query `le="0.3"`?
> 2. Why is comparing a `histogram_quantile()` output against an SLO threshold statistically weaker than the bucket-ratio approach? (Think about interpolation inside the bucket.)
> 3. Your SLO says "99% of requests under 300 ms." Which query — step 2 or step 4 — do you compare against `0.99`, and which against `0.3`?

---

## Exercise 4 — From SLO to error budget

**Goal:** Convert an SLO percentage into a concrete error budget expressed in *both* a ratio and *wall-clock minutes*, and see how much unreliability the budget actually buys.

1. Take the SLO: **99.9% availability over a rolling 30-day window.**

2. Compute the **error budget as a ratio**: `error_budget = 1 − SLO`.

3. Convert 30 days into minutes, then compute the **allowed downtime** = `error_budget_ratio × window_minutes`.

4. Repeat the whole calculation for three neighbouring SLO targets and complete this table:

   | SLO | Error budget (ratio) | Allowed bad time / 30 days |
   |------|----------------------|-----------------------------|
   | 99%    | ? | ? |
   | 99.9%  | ? | ? |
   | 99.95% | ? | ? |
   | 99.99% | ? | ? |

5. In Prometheus terms, express the *fraction of budget already consumed* over the window as a query, given a precomputed 30-day error-ratio SLI called `job:slo_errors_per_request:ratio_rate30d`:

   ```promql
   job:slo_errors_per_request:ratio_rate30d{job="api"} / 0.001
   ```

   A value of `1.0` means the budget is exactly exhausted; `0.5` means half-spent; `> 1.0` means the SLO is already violated for the window.

> **Check your understanding — 4**
> 1. Going from 99.9% to 99.99% multiplies the allowed downtime by what factor, and roughly how many minutes/month does each buy?
> 2. Why is an error budget described as giving a team *permission to fail* rather than a target to minimise?
> 3. If a service has burned **0 %** of its error budget three weeks into the window, what does the SRE philosophy suggest that team is doing *wrong*?
> 4. Two teams both hold a 99.9% SLO, but one measures over a *rolling* 30-day window and the other over the *calendar* month. Which one can "reset" a bad day just by waiting for the 1st, and why does that change alerting behaviour?

---

## Exercise 5 — Precomputing the SLI with recording rules

**Goal:** Move the SLI math out of ad-hoc dashboards and into named, versioned recording rules, so alerts and panels all read the *same* number.

1. Create a rule file `slo-api.rules.yml` with two error-ratio SLIs at different windows (short and long — you will need both in Exercise 6):

   ```yaml
   groups:
     - name: slo-api-error-ratio
       rules:
         - record: job:slo_errors_per_request:ratio_rate5m
           expr: |
             sum(rate(http_requests_total{job="api", code=~"5.."}[5m]))
             /
             sum(rate(http_requests_total{job="api"}[5m]))
         - record: job:slo_errors_per_request:ratio_rate1h
           expr: |
             sum(rate(http_requests_total{job="api", code=~"5.."}[1h]))
             /
             sum(rate(http_requests_total{job="api"}[1h]))
   ```

2. Reference it from `prometheus.yml`:

   ```yaml
   rule_files:
     - "slo-api.rules.yml"
   ```

3. Validate the rule file **before** reloading — never reload blind:

   ```console
   $ promtool check rules slo-api.rules.yml
   Checking slo-api.rules.yml
   SUCCESS: 2 rules found
   ```

4. Reload Prometheus and confirm the new series exist:

   ```console
   $ curl -s -X POST http://localhost:9090/-/reload
   $ curl -s 'http://localhost:9090/api/v1/query?query=job:slo_errors_per_request:ratio_rate5m'
   ```

5. Inspect the naming convention `job:slo_errors_per_request:ratio_rate5m`. Break it into its three colon-separated parts and state what each part communicates.

> **Check your understanding — 5**
> 1. What does the recording-rule naming convention `level:metric:operations` encode, and which part tells you the aggregation *level* of the series?
> 2. Give two concrete reasons to precompute an SLI as a recording rule instead of pasting the raw expression into every alert and dashboard.
> 3. `promtool check rules` passed, yet after reload the new series returns *no data*. Name two non-syntax causes (the rule is valid, but the value is empty).
> 4. Why is enabling `--web.enable-lifecycle` (needed for the `/-/reload` endpoint) a decision you should make deliberately rather than by default?

---

## Exercise 6 — Error-budget burn rate and multi-window alerting

**Goal:** Build the alert that pages *only* when the budget is being spent dangerously fast, using the multi-window, multi-burn-rate technique from the Google SRE Workbook.

1. Define **burn rate**: it is how many times faster than "sustainable" you are consuming the error budget. A burn rate of **1** exhausts the entire 30-day budget exactly at the end of the window; a burn rate of **2** exhausts it in 15 days; **14.4** exhausts it in ~50 hours.

2. Derive the burn-rate threshold for a page. The SRE Workbook's first tier says: *page if 2% of the 30-day budget would be consumed in 1 hour.* Compute it:

   ```
   burn_rate = (budget_fraction) / (alert_window / SLO_window)
             = 0.02 / (1h / 720h)
   ```

3. Confirm the standard multi-burn-rate table by filling in the missing burn rates (SLO window = 30 d = 720 h):

   | Severity | Long window | Short window | Budget consumed | Burn rate |
   |----------|-------------|--------------|-----------------|-----------|
   | Page     | 1h  | 5m  | 2%  | ? |
   | Page     | 6h  | 30m | 5%  | ? |
   | Ticket   | 3d  | 6h  | 10% | ? |

4. Write the **page** alert. It fires only when **both** the long *and* the short window exceed the threshold `burn_rate × error_budget_ratio` (with error budget = `1 − 0.999 = 0.001`). The short window is the fast "still-happening?" guard that makes the alert reset quickly once the incident ends:

   ```yaml
   groups:
     - name: slo-api-burnrate
       rules:
         - alert: ApiHighErrorBudgetBurn
           expr: |
             (
               job:slo_errors_per_request:ratio_rate1h{job="api"} > (14.4 * 0.001)
               and
               job:slo_errors_per_request:ratio_rate5m{job="api"} > (14.4 * 0.001)
             )
           for: 2m
           labels:
             severity: page
           annotations:
             summary: "API burning 30-day error budget 14.4x too fast"
             description: "1h and 5m error ratios both exceed the 2%-in-1h burn threshold."
   ```

5. Reason about the two-window design: given a brief 3-minute total outage, explain why the **long window alone** would keep the alert firing for an hour afterwards, and how adding the **short-window `and` clause** fixes that.

6. Validate and (optionally) load:

   ```console
   $ promtool check rules slo-api.rules.yml
   Checking slo-api.rules.yml
   SUCCESS: 3 rules found
   ```

> **Check your understanding — 6**
> 1. Why does the multi-burn-rate scheme use *both* a long and a short window joined by `and`, instead of a single long window? Name the specific failure mode each window prevents.
> 2. A single 1-hour window at burn rate 14.4 would take ~55 minutes to notice a total outage. What property of the *short* window shortens both detection *and* reset time?
> 3. The ticket-tier alert has burn rate **1**. Why is that intentionally *not* a page — what is it telling you about the pace of budget consumption?
> 4. If you lower the SLO from 99.9% to 99.5%, does the numeric threshold `14.4 × error_budget` go up or down, and does the alert become more or less sensitive to a fixed real error rate?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
**Step 2 (classification of the clauses):**
- **SLI** — *"the fraction of successful HTTP requests"* — the measurement itself.
- **SLO** — *"at least 99.9% of requests succeed over any rolling 30-day window"* — the internal target for that measurement.
- **SLA** — *"contract promises customers 99.5% monthly availability; below that, they receive a 10% service credit"* — the external contract *with a consequence* (the credit).

**Step 3:** The SLO is set stricter than the SLA so the team gets an **early-warning buffer**: they can breach their own internal target and still have room to react before they breach the customer contract that costs money. The gap between 99.9% and 99.5% is deliberate operational headroom.

**Step 4:**
- a. **SLI** — a PromQL ratio; it is a measurement.
- b. **SLO** — a target with a threshold and a window, no contractual consequence stated.
- c. **SLA** — an external contract clause with a consequence (right to terminate).
- d. **None of these** — a bare resource utilisation reading; it is just a metric, with no target or contract.

**Check 1:**
1. The **SLA** — it is the only one carrying business/legal consequences (credits, penalties, termination rights).
2. `node_cpu_seconds_total` measures a *cause*, not the *user-visible experience*. Good SLIs measure what the user feels (success, latency, freshness); CPU can be at 90% with users perfectly happy, or at 20% while the service is down. A resource metric doesn't map monotonically to user happiness.
3. They can measure whether they *met* the contract after the fact, but they have **no early-warning margin and no error budget** to drive day-to-day decisions — no way to know they're heading for a breach *before* it happens.

### Exercise 2
**Step 3:**
- Numerator (`code!~"5.."`): 480 + 12 + 6 = **498 req/s**.
- Denominator (all): 480 + 12 + 6 + 3 + 1 = **502 req/s**.
- Availability SLI = 498 / 502 = **0.99203… ≈ 99.20%**.

**Step 4:** Error ratio = (3 + 1) / 502 = 4 / 502 = **0.00797… ≈ 0.80%**.

**Step 5:** 0.99203 + 0.00797 = **1.0**. The identity holds *because* the "good" set is defined as the exact complement of the "bad" set (`code!~"5.."` vs `code=~"5.."`) over the *same* denominator; every request is counted as exactly one of good or bad, and `4xx` was placed on the "good" side, so the two ratios partition the whole.

**Check 2:**
1. Counters only ever increase and reset to 0 on restart. Raw values are meaningless as a rate and would corrupt on restart; `rate()` computes the per-second increase over the window and is restart-aware, giving a stable throughput you can divide.
2. Using `code=~"2.."` in the denominator makes the denominator *smaller than the true total* (it drops 3xx, 4xx, 5xx). The SLI then measures "2xx among 2xx," which can exceed reality or hide failures — the denominator must be **all valid events**, not just the successful ones.
3. It depends on ownership. A `404` is usually the **client** asking for something that doesn't exist — not a failure of *your* service — so it typically counts as "good" (a correctly served response). You'd only count it as bad if a bug in your service is returning 404 for resources that should exist.
4. Dimensionless means it's a pure ratio in `[0,1]` with the units cancelling (req/s ÷ req/s). That's desirable because it's directly comparable to an SLO percentage, is independent of traffic volume (a 3 AM low-traffic period and a noon peak are measured on the same scale), and composes cleanly into error-budget math.

### Exercise 3
**Step 3:** Latency SLI = 491 / 502 = **0.97809… ≈ 97.81%** of requests served at or under 300 ms.

**Step 5:** The bucket-ratio form yields a *fraction of good events* — exactly the SLI shape you compare to an SLO like `0.99`. `histogram_quantile()` yields a *latency value in seconds* (e.g. "p99 = 0.42 s"), which answers "how slow is the tail?" — great for a dashboard, but it is a duration, not a ratio, so it isn't the natural thing to compare against a "99% of requests" objective.

**Check 3:**
1. `le` matches an *exact existing boundary*. If only `0.25` and `0.5` exist, `le="0.3"` matches **no series** and the query returns empty — the SLI silently breaks. You must define a bucket boundary *at* your SLO threshold (here, add `le="0.3"`).
2. `histogram_quantile()` **interpolates linearly inside the bucket** the quantile falls in, assuming a uniform distribution there. That estimate can be off by the full bucket width, especially with wide buckets or skewed data. The bucket-ratio form uses only the *exact* cumulative count at a real boundary — no interpolation, no distributional assumption.
3. Compare the **step-2** query against `0.99` (fraction of good requests ≥ 99%). You'd compare the **step-4** query against `0.3` (is p99 latency ≤ 300 ms?) — a valid but distinct, interpolation-based formulation.

### Exercise 4
**Steps 2–4:**

| SLO | Error budget (ratio) | Allowed bad time / 30 days (43 200 min) |
|------|----------------------|------------------------------------------|
| 99%    | 0.01    | 432 min ≈ **7.2 h** |
| 99.9%  | 0.001   | 43.2 min |
| 99.95% | 0.0005  | 21.6 min |
| 99.99% | 0.0001  | 4.32 min |

(30 days = 30 × 24 × 60 = 43 200 min; allowed downtime = `error_budget_ratio × 43 200`.)

**Check 4:**
1. Each extra "nine" cuts allowed downtime by **10×** (99.9% → 99.99% goes from 43.2 min to 4.32 min per 30 days, a factor of 10). Rough monthly budgets: 99% ≈ 7.2 h, 99.9% ≈ 43 min, 99.99% ≈ 4.3 min.
2. Because 100% reliability is neither achievable nor worth its cost, the budget is the *acceptable amount of unreliability*. Spending it — on faster releases, risky experiments, planned maintenance — is legitimate. It's a permission slip, not a debt to drive to zero.
3. They're being **too conservative** — hoarding the budget means they're likely shipping too slowly or over-investing in reliability the users don't need. Unspent budget is a signal to take more risk (ship faster, run experiments), not a badge of honour.
4. The **calendar-month** team resets on the 1st: a bad day early in the month can be "aged out" simply by the calendar flipping. The **rolling** team's window always looks back exactly 30 days, so a bad day keeps counting against them for a full 30 days. This changes alerting: rolling windows give smoother, more honest budget tracking; calendar windows create a sawtooth where risk tolerance is high right after reset and tightens toward month-end.

### Exercise 5
**Step 5:** `job:slo_errors_per_request:ratio_rate5m` splits as `level:metric:operations`:
- `job` — the **aggregation level** (this series is aggregated to the `job` level; the per-instance labels have been summed away).
- `slo_errors_per_request` — the **metric/meaning** (SLO error ratio, errors per request).
- `ratio_rate5m` — the **operations applied** (a ratio of `rate()`s over a 5-minute window).

**Check 5:**
1. It encodes `level:metric:operations`. The **first segment** (`job`) is the aggregation level — it tells you which labels survive and which were aggregated away, so you never accidentally sum an already-summed series.
2. (a) **Single source of truth** — alerts, dashboards, and reports all read the identical value, so they can't disagree. (b) **Cost/performance** — an expensive long-window ratio (e.g. `[30d]`) is computed once per evaluation interval instead of on every dashboard refresh and every alert evaluation.
3. Any two of: the underlying metric `http_requests_total{job="api"}` doesn't exist or the `job` label value doesn't match (typo/label mismatch); the target isn't scraped yet / no data in the range; a division-by-zero where the denominator rate is 0 (no traffic) yields no result; or not enough time has elapsed for the rule to evaluate its first sample.
4. `--web.enable-lifecycle` exposes `/-/reload` (and `/-/quit`) over HTTP. Anyone who can reach that endpoint can reload or shut down Prometheus, so it's a small attack surface you should enable only behind proper network controls/authz — a deliberate security decision, not a default.

### Exercise 6
**Step 2:** `0.02 / (1 / 720) = 0.02 × 720 = **14.4**`.

**Step 3:**

| Severity | Long window | Short window | Budget consumed | Burn rate |
|----------|-------------|--------------|-----------------|-----------|
| Page     | 1h  | 5m  | 2%  | **14.4** (`0.02 / (1/720)`) |
| Page     | 6h  | 30m | 5%  | **6** (`0.05 / (6/720)`) |
| Ticket   | 3d  | 6h  | 10% | **1** (`0.10 / (72/720)`) |

**Step 5:** With only the **1-hour long window**, a 3-minute total outage pushes the 1h error ratio above threshold, and because `rate(...[1h])` averages over 60 minutes, that ratio stays elevated for roughly the *full hour* after the outage ends — so the page keeps firing long after the incident is over. Adding `and job:...:ratio_rate5m > threshold` requires the **5-minute** window to *also* be hot; once the outage stops, the 5m ratio collapses within ~5 minutes and the `and` becomes false, resetting the alert quickly. The short window confirms "this is still happening right now."

**Check 6:**
1. The **long window** provides the burn-rate *significance* — it ensures you're spending budget at a genuinely dangerous rate over a meaningful span, filtering out tiny blips (avoids false pages). The **short window** provides *recency/reset* — it confirms the problem is ongoing and lets the alert clear fast once it ends (avoids lingering false-positive pages after recovery). Joined by `and`, you get both low false-positive *and* low reset latency.
2. The short window has a much smaller averaging span, so its ratio *rises and falls quickly*. That makes detection of a sudden severe outage fast (it crosses threshold in minutes) and makes the alert reset promptly after recovery — a long window alone is sluggish on both edges.
3. Burn rate 1 means the budget is being consumed at exactly the pace that would exhaust it right at the end of the 30-day window — a *slow, sustained* drain, not an emergency. It doesn't need someone woken up; it needs a **ticket** so an engineer investigates during business hours before the trend becomes a breach.
4. Error budget = `1 − SLO`, so lowering SLO to 99.5% *raises* the budget to `0.005`, and the threshold `14.4 × 0.005 = 0.072` goes **up** (vs `0.0144` at 99.9%). A higher threshold means the alert is **less sensitive** to a fixed real error rate — the looser SLO tolerates more errors before paging.

</details>

---

### Sources

- CNCF — *Prometheus Certified Associate (PCA) Curriculum*, Domain 3: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
- Google — *Site Reliability Engineering*, Ch. 3 "Embracing Risk" and Ch. 4 "Service Level Objectives": https://sre.google/sre-book/service-level-objectives/
- Google — *The Site Reliability Workbook*, Ch. 2 "Implementing SLOs" (multi-window, multi-burn-rate alerting): https://sre.google/workbook/alerting-on-slos/
- Prometheus — Recording rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — Querying functions (`rate`, `histogram_quantile`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — Metric and label naming best practices: https://prometheus.io/docs/practices/naming/