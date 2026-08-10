# Topic 5.2 — Instrumentation

> **Guided lab.** *Instrumentation* is the act of adding metric-emitting code **inside your own application** using a Prometheus **client library**, so that the process exposes an HTTP `/metrics` endpoint in the text exposition format. This is distinct from *exporters* (Topic 5.1), which translate metrics from **third‑party** systems you cannot modify. If you own the source code, you instrument; if you don't, you deploy an exporter.
>
> You will build a real service step by step, watch the raw exposition format change as you go, and reason about metric types, labels, cardinality, histograms, batch jobs and production failure modes.

### Prerequisites

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install prometheus_client flask
# Optional, for the scraping and Pushgateway exercises:
#   docker (to run prom/prometheus and prom/pushgateway)
```

Keep two terminals open: one running your Python program, one running `curl`.

---

## Exercise 1 — Expose your first metric

1. Create `app1.py`:

   ```python
   from prometheus_client import start_http_server, Counter
   import time

   # NOTE: no "_total" in the name — the Python client appends it for you.
   REQUESTS = Counter('myapp_requests', 'Total requests processed')

   if __name__ == '__main__':
       start_http_server(8000)          # serves /metrics on :8000
       while True:
           REQUESTS.inc()               # +1 each second
           time.sleep(1)
   ```

2. Run it: `python3 app1.py`

3. In the second terminal, scrape the endpoint after ~5 seconds:

   ```bash
   curl -s localhost:8000/metrics
   ```

4. Read the output. Alongside your metric you will see **default collectors** that `start_http_server` registers automatically on the default registry:

   ```text
   # HELP python_gc_objects_collected_total Objects collected during gc
   # TYPE python_gc_objects_collected_total counter
   python_gc_objects_collected_total{generation="0"} 362.0
   ...
   # HELP process_cpu_seconds_total Total user and system CPU time spent in seconds.
   # TYPE process_cpu_seconds_total counter
   process_cpu_seconds_total 0.04
   # HELP process_resident_memory_bytes Resident memory size in bytes.
   # TYPE process_resident_memory_bytes gauge
   process_resident_memory_bytes 1.4327808e+07
   ...
   # HELP myapp_requests_total Total requests processed
   # TYPE myapp_requests_total counter
   myapp_requests_total 5.0
   # HELP myapp_requests_created Total requests processed
   # TYPE myapp_requests_created gauge
   myapp_requests_created 1.7534096e+09
   ```

5. Note three things: (a) every metric is preceded by a `# HELP` and a `# TYPE` line; (b) your counter is exposed as `myapp_requests_total`, not `myapp_requests`; (c) a second series `myapp_requests_created` appeared that you never declared.

**Q1.1** — You named the counter `myapp_requests`, yet the scraped series is `myapp_requests_total`. What happened, and what would be *wrong* about naming it `myapp_requests_total` in your code?

**Q1.2** — What is the `myapp_requests_created` series, what is its type, and how could you suppress it?

**Q1.3** — Where did `process_cpu_seconds_total` and `process_resident_memory_bytes` come from, given that your code never declared them?

---

## Exercise 2 — The four metric types

You will now expose one of each core type and inspect how each renders. Create `app2.py`:

1. Add a **Counter** and a **Gauge**:

   ```python
   from prometheus_client import start_http_server, Counter, Gauge, Histogram, Summary
   import time, random

   PROCESSED = Counter('myapp_items_processed', 'Items processed')
   INFLIGHT  = Gauge('myapp_inflight_requests', 'In-flight requests')
   ```

2. Add a **Histogram** with explicit buckets (seconds — a base unit) and a **Summary**:

   ```python
   LATENCY = Histogram(
       'myapp_request_duration_seconds', 'Request duration in seconds',
       buckets=(0.1, 0.5, 1, 2.5, 5, 10),
   )
   PROCTIME = Summary('myapp_processing_seconds', 'Time spent processing')
   ```

3. Drive the metrics in a loop:

   ```python
   if __name__ == '__main__':
       start_http_server(8000)
       while True:
           INFLIGHT.inc()
           d = random.uniform(0.05, 3.0)
           LATENCY.observe(d)
           PROCTIME.observe(d)
           PROCESSED.inc()
           time.sleep(d)
           INFLIGHT.dec()
   ```

4. Run it and scrape once: `curl -s localhost:8000/metrics | grep myapp_`. Study each rendering.

5. The **Histogram** expands into cumulative buckets plus a `_sum` and `_count`:

   ```text
   # TYPE myapp_request_duration_seconds histogram
   myapp_request_duration_seconds_bucket{le="0.1"} 1.0
   myapp_request_duration_seconds_bucket{le="0.5"} 4.0
   myapp_request_duration_seconds_bucket{le="1.0"} 6.0
   myapp_request_duration_seconds_bucket{le="2.5"} 9.0
   myapp_request_duration_seconds_bucket{le="5.0"} 11.0
   myapp_request_duration_seconds_bucket{le="10.0"} 11.0
   myapp_request_duration_seconds_bucket{le="+Inf"} 11.0
   myapp_request_duration_seconds_sum 18.734
   myapp_request_duration_seconds_count 11.0
   ```

6. The **Summary** in the Python client renders **only** `_sum` and `_count` — no quantiles:

   ```text
   # TYPE myapp_processing_seconds summary
   myapp_processing_seconds_count 11.0
   myapp_processing_seconds_sum 18.734
   ```

**Q2.1** — A `Counter` and a `Gauge` can both hold the number `4`. What is the semantic contract that separates them, and which one may be reset to a lower value or decremented?

**Q2.2** — In step 5, `..._bucket{le="0.5"}` is `4.0` and `..._bucket{le="1.0"}` is `6.0`. How many observations fell **into the interval** `(0.5, 1.0]`, and why can't you read that directly from a single bucket line?

**Q2.3** — The Python Summary printed no `quantile` lines, but the Prometheus docs describe summaries as carrying client-side φ‑quantiles. Reconcile this — is the documentation wrong, or the client?

---

## Exercise 3 — Instrument an HTTP service (RED signals)

Now instrument a real HTTP handler with the three golden request signals — **R**ate, **E**rrors, **D**uration — using labels. Create `service.py`:

1. Declare the metrics **once**, at import time (never inside the handler):

   ```python
   from flask import Flask, Response, request, abort
   from prometheus_client import (
       Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST,
   )
   import time, random

   app = Flask(__name__)

   REQUESTS = Counter(
       'http_requests', 'Total HTTP requests',
       ['method', 'endpoint', 'status'],
   )
   LATENCY = Histogram(
       'http_request_duration_seconds', 'HTTP request latency',
       ['method', 'endpoint'],
   )
   INPROGRESS = Gauge(
       'http_requests_in_progress', 'In-flight HTTP requests',
       ['method', 'endpoint'],
   )
   ```

2. Write a handler that is **exception-safe**, using the context managers so the gauge and timer are always released even if the body raises:

   ```python
   @app.route('/work')
   def work():
       ep, m = '/work', request.method
       with INPROGRESS.labels(m, ep).track_inprogress():
           with LATENCY.labels(m, ep).time():
               time.sleep(random.uniform(0.05, 0.4))   # simulate work
               if random.random() < 0.1:               # 10% failures
                   REQUESTS.labels(m, ep, '500').inc()
                   abort(500)
       REQUESTS.labels(m, ep, '200').inc()
       return 'done\n'
   ```

3. Expose the metrics endpoint from the same process:

   ```python
   @app.route('/metrics')
   def metrics():
       return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

   if __name__ == '__main__':
       app.run(host='0.0.0.0', port=5000)
   ```

4. Run it (`python3 service.py`), generate load, then scrape:

   ```bash
   for i in $(seq 1 40); do curl -s localhost:5000/work >/dev/null; done
   curl -s localhost:5000/metrics | grep -E 'http_requests_total|_in_progress'
   ```

   Expected shape:

   ```text
   http_requests_total{endpoint="/work",method="GET",status="200"} 36.0
   http_requests_total{endpoint="/work",method="GET",status="500"} 4.0
   http_requests_in_progress{endpoint="/work",method="GET"} 0.0
   ```

5. **(Optional)** Scrape it with a real Prometheus. Create `prometheus.yml`:

   ```yaml
   global:
     scrape_interval: 5s
   scrape_configs:
     - job_name: 'myapp'
       static_configs:
         - targets: ['host.docker.internal:5000']   # Linux: use your host IP
   ```

   ```bash
   docker run --rm -p 9090:9090 \
     -v "$(pwd)/prometheus.yml:/etc/prometheus/prometheus.yml" \
     prom/prometheus
   ```

   Then in the Prometheus UI (`localhost:9090`) run:

   ```promql
   sum by (status) (rate(http_requests_total[1m]))
   ```

**Q3.1** — Why must `Counter(...)`, `Histogram(...)` and `Gauge(...)` be declared at module scope and not created inside `work()` on each request?

**Q3.2** — The handler uses `track_inprogress()` and `.time()` as context managers rather than manual `.inc()/.dec()` and `time.perf_counter()`. What production failure does this specifically prevent?

**Q3.3** — You increment a `Counter` for successful requests, but *rate* is a per-second value. Why do you expose a monotonic counter and compute the rate at query time with `rate(...)`, instead of maintaining a "requests per second" gauge in the application?

---

## Exercise 4 — Labels, cardinality, and the naming rules

Labels are powerful and dangerous. This exercise makes the danger concrete.

1. Add a deliberately **bad** counter to a scratch script and drive it with unique values:

   ```python
   from prometheus_client import start_http_server, Counter
   import uuid, time

   BAD = Counter('bad_requests', 'Do not do this', ['user_id', 'request_id'])

   start_http_server(8000)
   for _ in range(1000):
       BAD.labels(user_id=str(uuid.uuid4()), request_id=str(uuid.uuid4())).inc()
   ```

2. Scrape and count how many time series a *single metric* produced:

   ```bash
   curl -s localhost:8000/metrics | grep -c '^bad_requests_total'
   ```

   You will see close to `1000` — one time series per unique label combination. Each is stored, indexed, and scraped forever.

3. Contrast with a **bounded** label set. Good label values come from a small, known set (`method`, `status_code`, `region`), never from unbounded input (`user_id`, `email`, `full URL with IDs`, `error message text`).

4. Apply the naming rules to your metrics. A well-formed metric name:
   - is `snake_case` with an application/library **prefix** (`http_`, `myapp_`);
   - carries a **single base unit** as a suffix — `_seconds` (not `_milliseconds`), `_bytes` (not `_kilobytes`);
   - ends counters in `_total`;
   - **never** encodes a dimension that belongs in a label (write `http_requests_total{method="GET"}`, not `http_get_requests_total`).

**Q4.1** — Total cardinality is the product of the number of distinct values of each label across all combinations that actually occur. If a metric has labels `method` (4 values), `status` (6 values) and `endpoint` (10 values), what is the theoretical upper bound on its time series?

**Q4.2** — Why is putting `request_id` in a label catastrophic for Prometheus specifically, and what is the correct place to attach a per-request identifier for later correlation?

**Q4.3** — Rewrite the name `myapp_response_time_ms` to follow the conventions, and explain each change.

---

## Exercise 5 — Histograms vs Summaries and `histogram_quantile`

The single most tested instrumentation decision: histogram or summary?

1. Reuse the `http_request_duration_seconds` histogram from Exercise 3. Confirm it exposes `_bucket{le=...}`, `_sum` and `_count`.

2. Estimate the 95th‑percentile latency *at query time* from the buckets:

   ```promql
   histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
   ```

3. Understand why this works: because buckets are additive across series and across time, Prometheus can `sum` them by `le` **on the server** and then interpolate the quantile. The result is a fleet-wide p95, aggregated over every instance.

4. Now consider a client-computed **Summary** with quantiles (as the Go/Java clients can emit):

   ```text
   http_request_duration_seconds{quantile="0.5"}  0.19
   http_request_duration_seconds{quantile="0.9"}  0.32
   http_request_duration_seconds{quantile="0.99"} 0.39
   ```

   Try to "average the p99 across three instances." You cannot — averaging pre-computed quantiles is mathematically invalid. This is the summary's fatal limitation for aggregation.

5. Compute the *average* latency, which works with **either** type, since both expose `_sum` and `_count`:

   ```promql
   rate(http_request_duration_seconds_sum[5m])
     /
   rate(http_request_duration_seconds_count[5m])
   ```

**Q5.1** — State the core trade-off in one sentence: what does a histogram give you that a summary cannot, and what does a summary give you that a histogram cannot?

**Q5.2** — Your histogram's largest explicit bucket is `le="10.0"` and all observations land in `+Inf` above it (the `10.0` and `+Inf` buckets are equal). What does `histogram_quantile(0.99, ...)` return in that regime, and what is the fix?

**Q5.3** — Why is `histogram_quantile` applied to a `rate()` of the `_bucket` series rather than to the raw `_bucket` counters directly?

---

## Exercise 6 — Batch jobs and the Pushgateway

Prometheus **pulls**. A batch job that runs for 20 seconds and exits is never scraped in time. The Pushgateway is the sanctioned exception: the job **pushes** its final metrics to a gateway, and Prometheus scrapes the gateway.

1. Start a Pushgateway:

   ```bash
   docker run --rm -d -p 9091:9091 prom/pushgateway
   ```

2. Write a batch job `batch.py` that pushes on success:

   ```python
   from prometheus_client import CollectorRegistry, Gauge, push_to_gateway
   import time

   registry = CollectorRegistry()          # isolated registry, NOT the default one
   last_success = Gauge(
       'batch_job_last_success_timestamp_seconds',
       'Unix time of the last successful run',
       registry=registry,
   )
   duration = Gauge(
       'batch_job_duration_seconds', 'Duration of the last run',
       registry=registry,
   )

   start = time.time()
   time.sleep(2)                            # ... the actual work ...
   duration.set(time.time() - start)
   last_success.set_to_current_time()

   push_to_gateway('localhost:9091', job='nightly_backup', registry=registry)
   ```

3. Run it (`python3 batch.py`), then read what the gateway now serves:

   ```bash
   curl -s localhost:9091/metrics | grep batch_job
   ```

   ```text
   batch_job_duration_seconds{instance="",job="nightly_backup"} 2.0007
   batch_job_last_success_timestamp_seconds{instance="",job="nightly_backup"} 1.7534101e+09
   ```

4. Point Prometheus at the gateway with `honor_labels: true` so the pushed `job`/`instance` labels win:

   ```yaml
   scrape_configs:
     - job_name: 'pushgateway'
       honor_labels: true
       static_configs:
         - targets: ['localhost:9091']
   ```

**Q6.1** — Why is a batch job the case where pushing is appropriate, when the Prometheus model is otherwise strictly pull-based?

**Q6.2** — The gateway keeps the last pushed value **indefinitely**, even after the job succeeds and its host is gone. Why does this make a *staleness* alert like `time() - batch_job_last_success_timestamp_seconds > 86400` valuable, and why would a plain "target down" alert fail here?

**Q6.3** — Why does the job build its own `CollectorRegistry()` instead of using the default registry that `start_http_server` uses?

---

## Exercise 7 — Production gotchas (advanced)

### 7a. Multi-process servers reset your counters

1. Run `service.py` from Exercise 3 under Gunicorn with **4 workers**:

   ```bash
   gunicorn -w 4 -b 0.0.0.0:5000 service:app
   ```

2. Generate load, then scrape `/metrics` **repeatedly**:

   ```bash
   for i in $(seq 1 40); do curl -s localhost:5000/work >/dev/null; done
   curl -s localhost:5000/metrics | grep http_requests_total
   curl -s localhost:5000/metrics | grep http_requests_total   # run again
   ```

   You will see the counter **jump around** between scrapes — sometimes small, sometimes different — because each of the 4 workers has its **own registry in its own process**, and the load balancer routes each scrape to a random worker.

3. Fix it with the client's **multiprocess mode**. Set a shared directory and a `child_exit` hook:

   ```python
   # in a gunicorn config file, gunicorn.conf.py
   import os
   os.environ.setdefault('PROMETHEUS_MULTIPROC_DIR', '/tmp/prom_mp')

   def child_exit(server, worker):
       from prometheus_client import multiprocess
       multiprocess.mark_process_dead(worker.pid)
   ```

   ```python
   # in the /metrics handler, aggregate across all worker files:
   from prometheus_client import CollectorRegistry, multiprocess, generate_latest

   @app.route('/metrics')
   def metrics():
       registry = CollectorRegistry()
       multiprocess.MultiProcessCollector(registry)
       return Response(generate_latest(registry), mimetype=CONTENT_TYPE_LATEST)
   ```

   ```bash
   mkdir -p /tmp/prom_mp && rm -f /tmp/prom_mp/*   # must be empty at startup
   gunicorn -c gunicorn.conf.py -w 4 -b 0.0.0.0:5000 service:app
   ```

### 7b. Exemplars (OpenMetrics)

1. Attach a trace ID to an observation so a latency spike links to a specific trace:

   ```python
   LATENCY.labels(m, ep).observe(0.42, exemplar={'trace_id': 'a1b2c3d4'})
   ```

2. Exemplars are emitted **only** in the OpenMetrics format, so the scraper must ask for it:

   ```bash
   curl -s -H 'Accept: application/openmetrics-text' localhost:5000/metrics \
     | grep -A1 duration_seconds_bucket
   ```

   ```text
   http_request_duration_seconds_bucket{endpoint="/work",method="GET",le="0.5"} 12 # {trace_id="a1b2c3d4"} 0.42 1.7534103e+09
   ```

3. Prometheus stores them only when started with `--enable-feature=exemplar-storage`.

**Q7.1** — In multi-process mode, `Counter` and `Histogram` aggregate correctly across workers, but a plain `Gauge` needs a `multiprocess_mode` (e.g. `'livesum'`, `'max'`, `'liveall'`). Why is a gauge fundamentally ambiguous to aggregate across processes when a counter is not?

**Q7.2** — In 7a step 2, before the fix, the scraped counter went **down** between two scrapes. Why is that especially destructive for `rate()` and `increase()`, and what does `rate()` assume about a counter that this violates?

**Q7.3** — What is an exemplar, and what problem at the boundary between metrics and tracing does it solve that neither a label nor a log line can?

---

## References

- Metric types — https://prometheus.io/docs/concepts/metric_types/
- Instrumenting your code / client libraries — https://prometheus.io/docs/instrumenting/clientlibs/
- Writing client libraries (semantics) — https://prometheus.io/docs/instrumenting/writing_clientlibs/
- Instrumentation best practices — https://prometheus.io/docs/practices/instrumentation/
- Metric and label naming — https://prometheus.io/docs/practices/naming/
- Histograms and summaries — https://prometheus.io/docs/practices/histograms/
- Exposition formats — https://prometheus.io/docs/instrumenting/exposition_formats/
- Pushing metrics / Pushgateway — https://prometheus.io/docs/instrumenting/pushing/ and https://github.com/prometheus/pushgateway
- Python client (usage, multiprocess, exemplars) — https://prometheus.github.io/client_python/ and https://github.com/prometheus/client_python
- OpenMetrics specification — https://github.com/OpenObservability/OpenMetrics

---

<details>
<summary><strong>Solutions</strong></summary>

**Q1.1** — The Python client automatically appends the `_total` suffix to counter time series (following the OpenMetrics convention that counters end in `_total`). You therefore name the metric `myapp_requests` and it is *exposed* as `myapp_requests_total`. Writing the suffix yourself is the mistake: you fight the library's convention and risk an ugly `..._total_total` or a validation warning depending on version. Let the client add it.

**Q1.2** — `myapp_requests_created` is a **Gauge** holding the Unix timestamp (in seconds) at which the counter was first created/reset. It comes from the OpenMetrics `_created` convention and is emitted for counters, histograms and summaries so consumers can detect resets. You can turn it off with `prometheus_client.disable_created_metrics()` in code, or by setting the environment variable `PROMETHEUS_DISABLE_CREATED_SERIES=true`.

**Q1.3** — From the **default registry's default collectors**. `start_http_server` uses the global `REGISTRY`, which has a `ProcessCollector` (`process_cpu_seconds_total`, `process_resident_memory_bytes`, open FDs, start time), a `PlatformCollector` (`python_info`) and a `GCCollector` (`python_gc_*`) registered automatically. You get process-level telemetry for free.

**Q2.1** — A **Counter** is monotonically non-decreasing between resets: it only ever goes up (`.inc()`), and a decrease signals a process restart. It answers "how many total, ever." A **Gauge** is a snapshot that can go up *and* down (`.inc()`, `.dec()`, `.set()`); it answers "what is the current value right now." Only the Gauge may legitimately decrease.

**Q2.2** — Buckets are **cumulative** (`le` = "less than or equal to"). `le="1.0"` counts *all* observations ≤ 1.0, and `le="0.5"` counts all ≤ 0.5. The count in the interval `(0.5, 1.0]` is the difference: `6.0 − 4.0 = 2`. You can't read it from one line because each `_bucket` line is a running total up to its threshold, not the population of a single band.

**Q2.3** — Both are correct; they describe *different client libraries*. The **Python** client's `Summary` intentionally does not implement streaming φ‑quantiles, so it exposes only `_sum` and `_count`. The Go and Java clients *can* compute client-side quantiles and emit `{quantile="..."}` series. Quantile support in a summary is client-dependent, and this is a strong reason to prefer histograms in Python.

**Q3.1** — Metric objects register themselves with the registry on construction. Re-creating them per request would raise a "duplicated timeseries / already registered" error (or, if worked around, throw away the accumulated state every call, so the counter would never climb). Declare each metric **once** at module scope; then call `.labels(...).inc()/.observe()` per request. The metric object is long-lived; only the label lookups are per-request.

**Q3.2** — Exception safety. If the handler body raises after a manual `INPROGRESS.inc()` (or after starting a manual timer), the matching `.dec()` / stop never runs, so the in-flight gauge **leaks upward forever** and the latency of failed requests is never recorded. `track_inprogress()` and `.time()` are context managers whose `__exit__` runs even on exception, guaranteeing the gauge is decremented and the duration observed.

**Q3.3** — A counter is the correct primitive because it survives scrapes losslessly: Prometheus can compute *any* time window's rate from two samples, tolerate missed scrapes, and detect resets. A "requests per second" gauge computed in the app bakes in one averaging window, loses information between scrapes, and can't be re-aggregated. The rule is **expose raw monotonic counts; derive rates at query time** with `rate()`/`irate()`.

**Q4.1** — `4 × 6 × 10 = 240` time series in the worst case (every combination occurs). Cardinality is multiplicative across labels — the reason a single careless label can explode a metric.

**Q4.2** — Prometheus creates and indexes **one time series per unique label-set**, and stores it essentially forever (subject to retention). An unbounded label like `request_id` produces a new series on every request, exploding memory, the index, and query cost — a classic way to OOM a Prometheus server. Per-request identifiers belong in **traces and logs** (or as an **exemplar** attached to a metric sample), not as a metric label.

**Q4.3** — `myapp_http_request_duration_seconds`. Changes: keep the `myapp_`/`http_` **prefix**; convert the unit from milliseconds to the **base unit seconds** (`_ms` → `_seconds`), because Prometheus convention is base units; use `duration` consistently; and ensure it's a histogram of `_seconds`. If it were a counter it would end in `_total`; a duration histogram ends in the unit.

**Q5.1** — A **histogram** stores bucketed counts that are additive, so quantiles can be computed and **aggregated across instances at query time** (`histogram_quantile` over a `sum by (le)`), at the cost of pre-chosen buckets and approximation. A **summary** gives an **exact** client-side quantile with no bucket configuration, but those quantiles **cannot be aggregated** across instances or re-windowed. Histogram = aggregatable/approximate; summary = exact/non-aggregatable.

**Q5.2** — Once the requested quantile falls into the top bucket bounded by `+Inf` (here everything above `10.0`), `histogram_quantile` cannot interpolate — the upper edge is infinite — so it returns the **lower bound of that bucket** (`+Inf`'s lower edge = the last finite bound, `10.0`) or `+Inf`, i.e. a useless/clamped value. The fix is to **add higher buckets** so real observations land in finite ranges (choose bucket boundaries around your actual latency distribution/SLO).

**Q5.3** — `_bucket` series are **counters** (ever-growing). Feeding raw counters to `histogram_quantile` would mix all history since process start and be sensitive to counter resets. Applying `rate(..._bucket[5m])` first converts each bucket to a per-second rate over a window, normalizing for resets and giving the quantile of the **recent** distribution — which is what you want to alert and dashboard on.

**Q6.1** — Batch/cron jobs are **short-lived and exit**, so a pull-based scraper on a 15–60 s interval will usually miss them entirely — there is no long-running endpoint to pull. Pushing the job's final results to the Pushgateway gives Prometheus a stable, always-scrapeable surface. (It is *only* for service-level batch jobs, not a general workaround for the pull model.)

**Q6.2** — The gateway retains the last push forever, so the series `batch_job_last_success_timestamp_seconds` is always present even long after the job/host disappears. A "target down" alert therefore never fires (the gateway target stays up). The meaningful alert is on **staleness of the value itself** — `time() - batch_job_last_success_timestamp_seconds > 86400` says "no successful run in a day," which is exactly the failure a batch job has.

**Q6.3** — `push_to_gateway` should send **only this job's metrics**, not the default registry's process/GC/platform collectors. Using a fresh `CollectorRegistry()` isolates the payload so you push a clean, deliberate set of series and don't pollute the gateway with per-invocation process metrics that would also carry confusing semantics.

**Q7.1** — A counter across processes is unambiguous: the fleet value is the **sum** of each worker's monotonic count. A gauge is a *current snapshot*, so "the value across 4 workers" has no single correct meaning — do you want the sum of in-flight requests (`livesum`), the max, all values kept as separate series (`liveall`), the latest? The client forces you to declare `multiprocess_mode` because the aggregation is a semantic choice, not a fact.

**Q7.2** — `rate()` and `increase()` assume the counter is **monotonic**: any decrease is interpreted as a counter *reset*, and the function compensates by adding the pre-reset value. When scrapes bounce between workers with different partial counts, the series jitters up and down, so `rate()` sees phantom resets and **massively over-counts** (each apparent drop is treated as a restart and added back), producing wildly inflated rates. Multiprocess aggregation gives a single monotonic view that restores the assumption.

**Q7.3** — An exemplar is a specific example observation (e.g. one request's latency) attached to a metric sample, carrying labels like `trace_id` plus the value and timestamp — emitted only in OpenMetrics format. It bridges **aggregate metrics** and **individual traces**: from a p99 latency spike on a dashboard you can jump directly to *an actual trace that was in that bucket*. A metric label can't do this (it would explode cardinality), and a log line isn't linked from the metric point — the exemplar is the pointer from "the graph went up" to "here is one request that caused it."

</details>