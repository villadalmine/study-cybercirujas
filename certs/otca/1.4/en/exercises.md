# 1.4 Analysis and Outcomes — Guided Exercises

> **Domain:** Fundamentals of Observability · **Exam weight:** 4.5%
>
> This topic is about the *last mile* of the pipeline: once traces, metrics and logs have been collected, **what analysis do you perform, and what operational outcome does that analysis drive?** The outcomes an interviewer/exam expects you to connect telemetry to are: **dashboards, alerting, SLIs/SLOs/error budgets, and root-cause analysis (RCA) through signal correlation.** The exercises below take a fully instrumented microservice system, then walk you from raw signals → analysis → concrete outcome.
>
> Reference syllabus: OTCA Curriculum, Domain 1 (`https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf`).

---

## Lab environment (do this once)

We use the official **OpenTelemetry Demo** (the "Astronomy Shop"): ~15 microservices in multiple languages, all emitting traces, metrics and logs through a single Collector, with Prometheus, Jaeger, Grafana and a load generator wired in. It is the canonical, reproducible OTel lab.

Source: `https://opentelemetry.io/docs/demo/`

```bash
# 1. Clone and start (needs Docker + ~6 GB RAM)
git clone https://github.com/open-telemetry/opentelemetry-demo.git
cd opentelemetry-demo
docker compose up -d --no-build

# 2. Confirm the stack is healthy
docker compose ps --format 'table {{.Name}}\t{{.State}}' | head -n 20
```

Expected (abridged) — every row `running`:

```
NAME                       STATE
otel-col                   running
prometheus                 running
jaeger                     running
grafana                    running
frontend-proxy             running
load-generator             running
...
```

Everything is reachable through the front-end proxy on port **8080**:

| UI | URL |
|---|---|
| Web store (generates traffic) | `http://localhost:8080/` |
| Grafana (Prometheus + Jaeger datasources) | `http://localhost:8080/grafana/` |
| Jaeger UI | `http://localhost:8080/jaeger/ui/` |
| Load generator (Locust) | `http://localhost:8080/loadgen/` |

The load generator already drives continuous traffic, so telemetry is flowing. Leave the stack running for all five exercises.

> **Version-drift note (a real production skill):** exact metric and label names depend on SDK/Collector versions. Every exercise below therefore *discovers* the names first with the Prometheus **metrics browser** (Grafana → Explore) before querying them. Never hard-code a metric name you have not confirmed exists in *this* backend.

---

## Exercise 1 — RED analysis of a service (Rate, Errors, Duration)

**Goal:** turn raw request telemetry into the three numbers that describe *any* request-driven service, and understand where those numbers come from in OpenTelemetry.

The demo's Collector runs the **`spanmetrics` connector**, which aggregates spans into RED metrics (a `calls` counter and a `duration` histogram) *without* the services needing to emit those metrics themselves. This is the single most important "analysis" mechanism to understand for the exam.
Reference: `https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector`

**Steps**

1. Open **Grafana → Explore** (`http://localhost:8080/grafana/`, left menu → *Explore*) and select the **Prometheus** datasource.

2. Discover the RED metric names generated from spans. In the query box, click the **metric dropdown** and type `calls`, then `duration`. You should find a counter and a histogram, e.g. `calls_total` and `duration_milliseconds_bucket` (names may carry a namespace prefix in your version — use whatever the browser shows).

3. Inspect the dimensions the connector attached. Run:
   ```promql
   count by (service_name, status_code, span_kind) (calls_total)
   ```
   Note the `status_code` values: `STATUS_CODE_OK`, `STATUS_CODE_ERROR`, `STATUS_CODE_UNSET`.

4. **Rate** — requests/second entering the checkout service:
   ```promql
   sum(rate(calls_total{service_name="checkout", span_kind="SPAN_KIND_SERVER"}[5m]))
   ```

5. **Errors** — the error ratio (fraction of requests that failed), the way SREs actually express "errors":
   ```promql
   sum(rate(calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[5m]))
     /
   sum(rate(calls_total{service_name="checkout"}[5m]))
   ```

6. **Duration** — the p95 latency, read from the histogram:
   ```promql
   histogram_quantile(
     0.95,
     sum by (le) (rate(duration_milliseconds_bucket{service_name="checkout"}[5m]))
   )
   ```

7. Now open the **load generator** (`http://localhost:8080/loadgen/`), raise the user count, and re-run steps 4–6 after ~2 minutes. Watch rate climb and p95 duration move.

**Comprehension check 1**

- **1a.** Neither the checkout service nor its language SDK explicitly records a `calls_total` metric. Where does it come from, and what is the architectural advantage of deriving it there rather than instrumenting each service?
- **1b.** In step 6, why must `by (le)` appear *inside* the `sum(...)` before `histogram_quantile`, and what wrong answer do you get if you compute the quantile per-series and then average?
- **1c.** The error ratio in step 5 is a *ratio of rates*, not `rate(errors) / instant(total)`. Why is dividing two `rate()`s over the *same* window correct, and what breaks if the numerator and denominator use different time windows?
- **1d.** RED (Rate, Errors, Duration) is one of three classic methods. Name the other two and the situation each is designed for.

---

## Exercise 2 — From SLI to SLO to error budget

**Goal:** convert the RED "errors" signal into a **Service Level Indicator (SLI)**, set a **Service Level Objective (SLO)**, and compute the **error budget** — the outcome that decides whether you ship features or freeze and fix reliability.

Reference: Google SRE Workbook, *Implementing SLOs* — `https://sre.google/workbook/implementing-slos/`

**Steps**

1. Define an **availability SLI** for checkout = *good requests / valid requests*. In Grafana Explore, over a 30‑day-representative window:
   ```promql
   1 -
   (
     sum(rate(calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[30m]))
       /
     sum(rate(calls_total{service_name="checkout"}[30m]))
   )
   ```
   (The lab has only minutes of history; treat this 30‑minute window as a stand-in for the real 30‑day compliance window.)

2. Set the **SLO**: availability ≥ **99.9%** over 30 days. Write down the target: `SLO = 0.999`.

3. Compute the **error budget** by hand:
   - Budget as a fraction of requests: `1 − SLO = 0.001` (0.1%).
   - Budget as time over 30 days: `30 d × 24 h × 60 min × 0.001 = ` ______ minutes.

4. Compute **budget remaining** as a query (fraction of the month's allowance still unspent). Using the observed error ratio `q` from step 1:
   ```promql
   1 - (
     ( sum(rate(calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[30m]))
         / sum(rate(calls_total{service_name="checkout"}[30m])) )
     / 0.001
   )
   ```
   A result of `0` means the budget is fully spent; negative means you are *over* budget.

5. Push the system past its SLO on purpose: in the load generator, spike the user count high enough that downstream services start returning errors, wait ~2 min, and re-run step 4. Watch remaining budget drop.

**Comprehension check 2**

- **2a.** Fill in step 3: how many minutes of unavailability per 30 days does a 99.9% SLO permit? What about 99.95% and 99%?
- **2b.** An SLI, an SLO, and an SLA are three different things. Define each and state which one has *financial or contractual* consequences.
- **2c.** Your dashboard shows the SLO is currently met but the error budget for the month is 95% consumed with two weeks left. What is the *outcome* — the decision this analysis should drive — and why is "we're still meeting the SLO" the wrong lens?
- **2d.** Why is a *ratio* SLI (good events / valid events) generally preferred over a threshold on raw error *count*?

---

## Exercise 3 — Metric → trace correlation with exemplars

**Goal:** close the gap between "a latency chart spiked" and "here is the *exact request* that was slow." **Exemplars** are the OpenTelemetry data-model feature that attaches a sampled `trace_id`/`span_id` onto a histogram bucket, letting you jump from an aggregate straight to one representative trace.

References:
- Exemplars in the metrics data model — `https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exemplars`
- Prometheus exemplar storage — `https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage`

**Steps**

1. Confirm the Collector is emitting exemplars and Prometheus is storing them. Locate the demo's Collector override file and the Prometheus flags:
   ```bash
   find . -name 'otelcol-config-extras.yml'
   docker compose exec prometheus sh -c 'ps -o args= 1' | tr ' ' '\n' | grep -i exemplar
   ```
   You should see Prometheus started with `--enable-feature=exemplar-storage`. If the `spanmetrics` connector in your version does not emit exemplars, enable it in `otelcol-config-extras.yml`:
   ```yaml
   connectors:
     spanmetrics:
       exemplars:
         enabled: true
   ```
   then `docker compose restart otel-col`.

2. In **Grafana → datasource settings → Prometheus**, ensure **Exemplars** is toggled on for the histogram metric (Grafana links exemplars to the **Jaeger** datasource via the `trace_id` label).

3. In **Explore**, graph the checkout p95 again:
   ```promql
   histogram_quantile(0.95, sum by (le) (rate(duration_milliseconds_bucket{service_name="checkout"}[5m])))
   ```
   Exemplars appear as **diamond markers** scattered on the graph.

4. Hover a marker on a latency *peak*. The tooltip shows the sampled `trace_id`. Click **"Query with Jaeger"** (or copy the `trace_id`).

5. In Jaeger, open that trace. Read the span waterfall to find *which downstream span* consumed the latency (e.g. `checkout → cart → valkey`, or a slow `productcatalog` call).

**Comprehension check 3**

- **3a.** A histogram bucket is an aggregate over thousands of requests. What single piece of information does an exemplar add that a bucket count alone can never give you, and why is that the whole point of exemplars for RCA?
- **3b.** Exemplars are *sampled*, not exhaustive. Why is one representative trace per bucket usually sufficient for latency RCA, and when would sampling actively mislead you?
- **3c.** Trace-based sampling (e.g. tail sampling) can drop the trace an exemplar points to. What is the consequence of "exemplar references a trace that was sampled away," and how do you avoid the dangling reference?

---

## Exercise 4 — Trace ↔ log correlation for root-cause analysis

**Goal:** perform an end-to-end RCA that uses **all three signals together**: a metric tells you *something is wrong*, a trace tells you *where*, and logs tell you *why*. The mechanism is the shared **trace context** (`trace_id`/`span_id`) that OpenTelemetry stamps onto every log record emitted inside an active span.

Reference: OpenTelemetry logs & correlation — `https://opentelemetry.io/docs/concepts/signals/logs/`

**Steps**

1. Start from an errored request. Query the error *rate* per service to find the noisiest one:
   ```promql
   topk(3,
     sum by (service_name) (rate(calls_total{status_code="STATUS_CODE_ERROR"}[5m]))
   )
   ```

2. In **Jaeger**, search that service, filter **Tags: `error=true`**, and open a failed trace. Note the `Trace ID` and the specific span with the red error marker.

3. Read that span's `events` (Jaeger shows them under *Logs* on the span). An exception recorded via the OTel API appears as a span event named `exception` with `exception.type`, `exception.message`, and `exception.stacktrace` attributes.

4. Pivot to backend **logs** for the same request. In **Grafana → Explore**, switch to the logs datasource and filter by the trace id:
   ```logql
   {service_name="<the-service>"} | trace_id="<paste-trace-id>"
   ```
   (If your demo build routes logs to the Collector's `debug`/stdout instead of a log store, tail them directly:)
   ```bash
   docker compose logs otel-col | grep '<paste-trace-id>'
   ```

5. Read the correlated log lines. Confirm they carry the *same* `trace_id` and the `span_id` of the failing span, and that the message explains the failure (e.g. a downstream connection refused, a feature-flag-induced fault, a serialization error).

6. State the root cause in one sentence, citing the *signal that proved each step*: metric → which service, trace → which span, log/event → why.

**Comprehension check 4**

- **4a.** What exact field(s), and injected by which component, make it possible to run the LogQL filter in step 4? If a log line lacks them, at which layer was the trace context dropped?
- **4b.** Order the three signals by the RCA question each answers, and explain why starting RCA from *logs* (grepping) instead of from a *metric/SLO* is the classic anti-pattern.
- **4c.** In step 3 the error surfaced as a **span event** (`exception.*`), not as a log record. What is the practical difference between recording an exception as a span event versus emitting it as a correlated log, and why might you do both?

---

## Exercise 5 — Turning analysis into an alerting outcome (burn-rate alerts)

**Goal:** produce the operational *outcome* that matters most: an alert that pages a human at the right time. A naïve "error rate > 1%" alert is either too noisy or too slow. The SRE-standard outcome is a **multi-window, multi-burn-rate** alert tied to the SLO's error budget.

Reference: Google SRE Workbook, *Alerting on SLOs* — `https://sre.google/workbook/alerting-on-slos/`

**Steps**

1. Understand **burn rate** = how fast you are spending the error budget relative to "sustainable." Sustainable error ratio = `1 − SLO = 0.001`. If your observed error ratio over a window is `0.0144`, burn rate = `0.0144 / 0.001 = 14.4×`.

2. Verify the "2% in 1 hour" intuition by hand: a 14.4× burn sustained for 1 hour of a 30‑day (720 h) budget consumes `14.4 × (1/720) = ` ______ of the whole month's budget. This is why 14.4 is the canonical *fast-burn* page threshold.

3. Write the **fast-burn** alert expression (fires only when *both* a long 1h window and a short 5m window exceed the threshold — the short window makes it stop firing quickly once the incident resolves):
   ```promql
   (
     sum(rate(calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[1h]))
       / sum(rate(calls_total{service_name="checkout"}[1h]))    > (14.4 * 0.001)
   )
   and
   (
     sum(rate(calls_total{service_name="checkout", status_code="STATUS_CODE_ERROR"}[5m]))
       / sum(rate(calls_total{service_name="checkout"}[5m]))    > (14.4 * 0.001)
   )
   ```

4. Test it against reality. Paste the expression into Grafana Explore while the load generator is at *normal* load — it should return **no series** (no alert). Then spike the load generator to force errors, wait a few minutes, and re-run — it should return `1` (alert would fire).

5. Sketch the full alert table you would deploy (you don't have to wire all three into Alertmanager; just record the parameters):

   | Severity | Long window | Short window | Burn rate | Budget consumed |
   |---|---|---|---|---|
   | Page | 1h | 5m | 14.4 | 2% |
   | Page | 6h | 30m | 6 | 5% |
   | Ticket | 3d | 6h | 1 | 10% |

**Comprehension check 5**

- **5a.** Fill in step 2. Why does pairing a long window (detection) with a short window (reset) beat a single-window alert?
- **5b.** A fast-burn (14.4×) and a slow-burn (1×) alert detect different failure shapes. Describe an outage each one catches that the other misses, and why the fast-burn pages while the slow-burn only tickets.
- **5c.** Why alert on **error-budget burn rate** at all, instead of directly on p95 latency or raw 5xx count? Tie your answer back to the SLO from Exercise 2.
- **5d.** This whole chain — metric → SLI → SLO → error budget → burn-rate alert — is one continuous "analysis and outcomes" pipeline. Name the analysis artifact produced at each of the five exercises and the single outcome the chain ultimately delivers.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**1a.** It is generated by the **`spanmetrics` connector** running inside the Collector: it consumes the trace/span stream and aggregates spans into a `calls` counter and a `duration` histogram, keyed by dimensions like `service.name`, `span.kind`, `status.code`. Architectural advantage: RED metrics are produced **uniformly and centrally**, independent of each service's language, SDK maturity, or whether its authors remembered to add metric instrumentation. You instrument *tracing* once and get *metrics* for free, with consistent naming across a polyglot fleet — and you can change the dimensions in one place (the Collector) rather than redeploying every service.

**1b.** `histogram_quantile` needs the full set of `le` (bucket boundary) series *summed across all other label dimensions first*, so `sum by (le)(rate(...))` reconstructs one aggregate histogram, and the quantile is computed from that. If you instead compute a per-series quantile and then average them, you are **averaging percentiles**, which is mathematically meaningless — the average of p95s is not the p95 of the population, and it typically *understates* tail latency (a small very-slow subset gets diluted).

**1c.** `rate()` over a window already yields a per-second average over that window; dividing two rates computed over the **same** window gives the fraction of requests in that window that were errors — a proper time-consistent ratio. If numerator and denominator use *different* windows they cover different populations of requests, so the "ratio" no longer corresponds to any real set of requests: during a traffic ramp the mismatched windows can even produce a ratio above 1 or below 0.

**1d.** **USE** (Utilization, Saturation, Errors) — for **resources** (CPU, memory, disk, NICs, queues); it answers "is this resource a bottleneck?" **Four Golden Signals** (Latency, Traffic, Errors, Saturation) — Google's superset for **user-facing systems**, adding *saturation* (how full the service is) on top of RED. Rule of thumb: RED/Golden Signals for **services/requests**, USE for **resources**.

### Exercise 2

**2a.** 99.9% → `43200 × 0.001 = ` **43.2 minutes** / 30 days. 99.95% → 21.6 minutes. 99% → 432 minutes (7.2 hours). Each added "nine" cuts the budget by 10×.

**2b.**
- **SLI** — the *measurement*: a quantified indicator of service health (e.g. successful-request ratio = 99.94%).
- **SLO** — the *internal target* the SLI must meet (e.g. ≥ 99.9% over 30 days). It is the line that drives engineering decisions.
- **SLA** — the *external contract* with customers, usually *looser* than the SLO, carrying **financial/contractual consequences** (credits, penalties) when breached. Only the SLA has legal/financial teeth; the SLO is deliberately stricter so you react before the SLA is ever at risk.

**2c.** The outcome is an **error-budget policy decision: slow or freeze feature releases and redirect effort to reliability**, because burning 95% of the budget with half the month left means you are on track to *exhaust* it and breach the SLO before month-end. "We're still meeting the SLO right now" is the wrong lens because the SLO is a *rate-of-consumption* question over the whole window, not an instantaneous status — the budget is the leading indicator, current compliance is a lagging one.

**2d.** A ratio SLI (good/valid) is **normalized to traffic**, so the objective means the same thing at 10 rps and 10,000 rps and directly maps to an error budget. A raw error-*count* threshold breaks whenever traffic changes: the same count is catastrophic at low volume and negligible at high volume, so a fixed count threshold is simultaneously too sensitive off-peak and too lax on-peak.

### Exercise 3

**3a.** An exemplar adds a concrete **`trace_id` (and `span_id`) of one real request that landed in that bucket** — i.e. a pointer from the *statistical aggregate* to an *individual, inspectable example*. A bucket count tells you "N requests were slow"; the exemplar lets you open the *actual slow request's* trace and see exactly where the time went. That jump from aggregate to specimen is the entire reason exemplars exist.

**3b.** For *latency* RCA you usually want to know *what a slow request looks like*, and slow requests in the same bucket tend to share the same bottleneck, so one specimen is representative. Sampling misleads when the bucket contains **heterogeneous causes** — e.g. p99 latency driven by two unrelated problems (a slow DB *and* a GC pause); a single exemplar shows only one, and you may "fix" the wrong one while the other keeps burning budget.

**3c.** You get a **dangling reference**: the exemplar's `trace_id` resolves to nothing in the trace store, so the click-through dead-ends. Avoid it by aligning sampling so that any trace *referenced by an exemplar is retained* — e.g. exemplar-aware/tail sampling that keeps error and high-latency traces, or a `spanmetrics`/exemplar configuration that only emits exemplars for spans the sampler will keep. The failure mode is subtle because the metric side looks perfectly healthy.

### Exercise 4

**4a.** The **`trace_id`** (and `span_id`) fields on the log record. They are populated by the logging bridge/appender when it reads the **active span from context** at log time (OTel logging instrumentation / the SDK's log-context injection). If a line lacks them, the trace context was dropped where the log was *emitted* — typically logging outside the active span's scope, a thread/async boundary that didn't propagate context, or a logging framework not wired to the OTel context bridge.

**4b.** Order: **Metric/SLO → *is* there a problem and is it worth waking someone for; Trace → *where* in the request path; Log/event → *why* it failed.** Starting from logs (grepping) is an anti-pattern because logs are unstructured, high-cardinality, and give no sense of *scope or user impact* — you can spend an hour reading logs for a problem that never breached an SLO, or miss a widespread issue because you grepped the wrong service. Metrics scope the blast radius first; you only drill to logs once a trace has told you *which* logs to read.

**4c.** A **span event** (`exception.*`) is attached *inside the trace*, so it is automatically scoped to the exact span/operation and travels with the trace's sampling decision — great for "this operation threw here." A **correlated log** is a first-class, independently queryable record that survives even if the trace is sampled away and can carry richer/free-form context and be aggregated across requests. You often do **both**: the span event makes the trace self-explanatory in the waterfall; the log guarantees the failure is searchable and countable even without the trace.

### Exercise 5

**5a.** `14.4 × (1/720) = 0.02` = **2% of the monthly budget in one hour** — the canonical fast-burn threshold. Pairing windows beats a single window because the **long (1h) window gives statistical confidence** (few false pages from a brief blip) while the **short (5m) window makes the alert *reset quickly*** once the incident is over — a lone long window would keep the alert firing for up to an hour after recovery, delaying the "resolved" signal.

**5b.** The **fast-burn (14.4×)** catches a *sharp, severe* outage — e.g. a bad deploy sends 5–10% of requests to 5xx; it exhausts the budget in ~2 days, so it **pages** immediately. The **slow-burn (1×)** catches a *low-grade chronic* leak — e.g. a steady 0.1–0.15% error rate that never trips the fast-burn but silently drains the whole month's budget; it only **tickets** because there's no urgency to a slow drip, but ignored, it still breaches the SLO. Each is invisible to the other: the fast alert's short windows never trigger on the slow drip, and the slow alert reacts too late for the sharp spike.

**5c.** Because the SLO/error budget is what actually maps to **user pain and the release policy**, whereas raw latency/5xx thresholds are proxies that drift out of meaning as traffic and infrastructure change. Alerting on burn rate ties the page directly to "are we about to break the promise from Exercise 2," giving alerts that are *symptom-based, traffic-normalized, and self-tuning to the SLO* — you change the SLO in one place and every alert threshold follows, instead of re-tuning arbitrary numbers per service.

**5d.** Artifacts: **Ex 1 →** RED metrics (rate/errors/duration) from spans; **Ex 2 →** an SLI, an SLO, and a computed error budget; **Ex 3 →** exemplar-linked metric-to-trace evidence; **Ex 4 →** a full trace↔log root-cause chain; **Ex 5 →** multi-window burn-rate alert rules. The single delivered **outcome**: a running service whose reliability is *measured against an explicit objective and defended by automated, budget-aware alerting that pages a human exactly when — and only when — user-facing reliability is genuinely at risk.*

</details>