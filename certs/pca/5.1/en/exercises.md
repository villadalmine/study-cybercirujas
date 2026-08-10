# Topic 5.1 — Client Libraries · Guided Exercises

> **Certification:** Prometheus Certified Associate (PCA) — Domain *Instrumentation and Exemplars*
> **Format:** Each exercise is a sequence of numbered steps you execute on your own machine, followed by comprehension checkpoints. All answers are collapsed at the end.
>
> **Reference sources (official):**
> - Client libraries overview — https://prometheus.io/docs/instrumenting/clientlibs/
> - Writing client libraries (the contract every library implements) — https://prometheus.io/docs/instrumenting/writing_clientlibs/
> - Metric types — https://prometheus.io/docs/concepts/metric_types/
> - Metric and label naming — https://prometheus.io/docs/practices/naming/
> - Instrumentation best practices — https://prometheus.io/docs/practices/instrumentation/
> - Exposition formats — https://prometheus.io/docs/instrumenting/exposition_formats/
> - `client_python` — https://github.com/prometheus/client_python · https://prometheus.github.io/client_python/
> - `client_golang` — https://github.com/prometheus/client_golang

---

## Prerequisites

You will need Python ≥ 3.8 and, for Exercise 6, a Go toolchain (≥ 1.21). Everything else is `curl` and a shell.

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install 'prometheus_client==0.20.0'
```

A **client library** is the code you embed *inside your application* to define metrics, keep their values in a registry, and render them on demand in the Prometheus exposition format. It is the "push" side of instrumentation only in the sense that *your code* pushes numbers into in-process objects; Prometheus still **pulls** the exposition over HTTP. Keep that model in mind — several checkpoints hinge on it.

---

## Exercise 1 — Expose the default registry over HTTP

**Goal:** Stand up the smallest possible instrumented process and inspect what a client library gives you *for free*.

1. Create `app1.py`:

   ```python
   import time
   from prometheus_client import start_http_server

   if __name__ == "__main__":
       # Starts a WSGI server in a daemon thread, backed by the default registry.
       start_http_server(8000)
       print("serving metrics on :8000")
       while True:
           time.sleep(1)
   ```

2. Run it: `python3 app1.py`

3. In another terminal, scrape it:

   ```bash
   curl -s localhost:8000/metrics | head -n 25
   ```

4. Now scrape a *different* path and compare:

   ```bash
   curl -s localhost:8000/ | head -n 3
   curl -s localhost:8000/anything | head -n 3
   ```

5. Inspect the `Content-Type` the library advertises:

   ```bash
   curl -s -D - -o /dev/null localhost:8000/metrics
   ```

You should see, among the output, series such as `process_resident_memory_bytes`, `process_cpu_seconds_total`, `process_start_time_seconds`, and `python_info`, plus a header like:

```
Content-Type: text/plain; version=0.0.4; charset=utf-8
```

**Checkpoints 1**
- **1a.** You never defined a single metric, yet `/metrics` is full of series. Where did `process_*` and `python_*` come from?
- **1b.** `/`, `/anything` and `/metrics` all returned identical output. What does that tell you about how `start_http_server` routes requests, and why is this *not* how a real production endpoint should behave?
- **1c.** What is the exact meaning of `version=0.0.4` in the `Content-Type`? Is that a version of your app, of Prometheus, or of something else?

---

## Exercise 2 — Direct instrumentation: Counter and Gauge

**Goal:** Define the two simplest metric types by hand and observe how the client library serializes them.

1. Create `app2.py`:

   ```python
   import time
   from prometheus_client import start_http_server, Counter, Gauge

   # NOTE: no `_total` suffix here — the client appends it.
   REQUESTS = Counter(
       "myapp_requests",
       "Total requests processed.",
       ["method"],
   )
   INPROGRESS = Gauge(
       "myapp_inprogress_requests",
       "Requests currently being processed.",
   )

   def handle(method: str) -> None:
       INPROGRESS.inc()
       REQUESTS.labels(method=method).inc()
       time.sleep(0.2)
       INPROGRESS.dec()

   if __name__ == "__main__":
       start_http_server(8000)
       while True:
           handle("GET")
           handle("POST")
   ```

2. Run it, then scrape only your own series:

   ```bash
   curl -s localhost:8000/metrics | grep '^myapp_'
   ```

3. Observe the output shape. You should see something like:

   ```
   # HELP myapp_requests_total Total requests processed.
   # TYPE myapp_requests_total counter
   myapp_requests_total{method="GET"} 42.0
   myapp_requests_total{method="POST"} 42.0
   # HELP myapp_requests_created Total requests processed.
   # TYPE myapp_requests_created gauge
   myapp_requests_created{method="GET"} 1.7e+09
   ...
   # HELP myapp_inprogress_requests Requests currently being processed.
   # TYPE myapp_inprogress_requests gauge
   myapp_inprogress_requests 0.0
   ```

4. Scrape twice, a second apart, and confirm `myapp_requests_total` only ever grows while `myapp_inprogress_requests` oscillates between `0` and `2`.

5. Try to break the counter — add a temporary line `REQUESTS.labels(method="GET").dec()` and run. Note the result.

**Checkpoints 2**
- **2a.** You named the counter `myapp_requests`, but the exposed series is `myapp_requests_total`. Which side added `_total`, and what would you have gotten had you named it `myapp_requests_total` yourself?
- **2b.** What are the `myapp_requests_created` series, why is their `# TYPE` a `gauge` and not a `counter`, and what do their values represent?
- **2c.** Step 5 fails. Which method does a `Counter` object *not* expose, and what property of counters is the library enforcing at the API level?
- **2d.** A `Gauge` offers `.inc()`, `.dec()`, `.set()`, `.set_to_current_time()`, and context managers `.track_inprogress()` / `.time()`. Rewrite `handle()` so `INPROGRESS` is managed by a context manager instead of manual `inc/dec`. Why is that safer?

---

## Exercise 3 — Histogram: buckets, `_sum`, `_count`

**Goal:** Understand the *composite* nature of a Histogram — one logical metric that a client library expands into many series.

1. Create `app3.py`:

   ```python
   import random
   import time
   from prometheus_client import start_http_server, Histogram

   LATENCY = Histogram(
       "myapp_request_duration_seconds",
       "Request duration in seconds.",
       buckets=(0.1, 0.25, 0.5, 1.0, 2.5),  # explicit, application-tuned buckets
   )

   @LATENCY.time()  # decorator times the wrapped call and observes the result
   def do_work() -> None:
       time.sleep(random.expovariate(2))

   if __name__ == "__main__":
       start_http_server(8000)
       while True:
           do_work()
   ```

2. Run it, let it collect for ~10 s, then scrape:

   ```bash
   curl -s localhost:8000/metrics | grep '^myapp_request_duration_seconds'
   ```

   Expected shape:

   ```
   myapp_request_duration_seconds_bucket{le="0.1"} 118.0
   myapp_request_duration_seconds_bucket{le="0.25"} 210.0
   myapp_request_duration_seconds_bucket{le="0.5"} 260.0
   myapp_request_duration_seconds_bucket{le="1.0"} 279.0
   myapp_request_duration_seconds_bucket{le="2.5"} 283.0
   myapp_request_duration_seconds_bucket{le="+Inf"} 284.0
   myapp_request_duration_seconds_count 284.0
   myapp_request_duration_seconds_sum 96.3...
   ```

3. Verify the bucket values are **non-decreasing** as `le` grows. Pick the largest finite `le` and compare it with the `+Inf` bucket and with `_count`.

4. Remove the explicit `buckets=` argument, restart, and count how many `_bucket` series appear now.

**Checkpoints 3**
- **3a.** A Histogram is *one* metric to you. How many time series did the client library generate from it, and by which formula (given *N* explicit buckets)?
- **3b.** The buckets are **cumulative**. What does `myapp_request_duration_seconds_bucket{le="0.5"} 260` actually count? Why must the `le="+Inf"` bucket always equal `_count`?
- **3c.** In Step 4, without an explicit `buckets=`, you got a specific default set. What are Prometheus' default histogram buckets, and why are they a poor default for, say, RPC latencies measured in milliseconds?
- **3d.** You cannot read a p95 latency straight off these series — there is no `quantile` label. Which PromQL function reconstructs quantiles from a histogram, and why is the computation only an *estimate*?

---

## Exercise 4 — Summary, and why it differs across client libraries

**Goal:** See the fourth core metric type and confront a deliberate divergence between client libraries.

1. Create `app4.py`:

   ```python
   import random
   import time
   from prometheus_client import start_http_server, Summary

   S = Summary("myapp_processing_seconds", "Time spent processing.")

   if __name__ == "__main__":
       start_http_server(8000)
       while True:
           with S.time():
               time.sleep(random.random() / 5)
   ```

2. Run and scrape:

   ```bash
   curl -s localhost:8000/metrics | grep '^myapp_processing_seconds'
   ```

3. Note which series exist — and, crucially, which do **not**.

4. Read the Summary section of https://prometheus.io/docs/concepts/metric_types/#summary and the note on the Python client at https://github.com/prometheus/client_python#summary.

**Checkpoints 4**
- **4a.** Your Summary produced `_sum` and `_count` but **no** `{quantile="..."}` series. Is that a bug in your code, or a documented property of *this* client library?
- **4b.** The Go client's Summary *can* expose configured quantiles (e.g. `quantile="0.99"`). Name the single most important operational reason to prefer a **Histogram** over a quantile-bearing **Summary** when the number is measured across many instances you intend to aggregate.
- **4c.** Both Histogram and Summary expose `_sum` and `_count`. Using only those two series, write the PromQL for the *average* event size over the last 5 minutes.

---

## Exercise 5 — Custom registries and isolating what you export

**Goal:** Stop relying on the implicit default registry. Control exactly which collectors are exposed — the pattern behind unit tests, multi-tenant exporters, and the Pushgateway.

1. Create `app5.py`:

   ```python
   from prometheus_client import CollectorRegistry, Counter, generate_latest

   # A private registry — completely disconnected from the default one.
   reg = CollectorRegistry()

   JOBS = Counter(
       "batch_jobs_processed",
       "Batch jobs processed.",
       registry=reg,          # explicit target registry
   )
   JOBS.inc(7)

   # Render this registry to the wire format, no HTTP server involved.
   print(generate_latest(reg).decode())
   ```

2. Run it: `python3 app5.py`. Confirm the output contains `batch_jobs_processed_total 7.0` **and nothing else** — no `process_*`, no `python_*`.

3. Now compare against `generate_latest()` with no argument (the default registry) in a Python REPL:

   ```python
   from prometheus_client import generate_latest
   print(generate_latest().decode()[:200])
   ```

4. Read how `start_http_server(port, registry=...)` accepts a registry, and how `generate_latest` is the same function the HTTP handler calls internally.

**Checkpoints 5**
- **5a.** The private registry produced only `batch_jobs_processed_total`, but the default registry was full of `process_*`/`python_*`. Explain the mechanism: *how* did those default collectors get into the default registry, and why did `reg` not receive them?
- **5b.** Give two concrete situations where you *must* use a custom `CollectorRegistry` instead of the default one.
- **5c.** `generate_latest(reg)` returns `bytes`, not `str`. Why does a client library serialize to bytes, and what does that imply about the charset declared in the `Content-Type`?

---

## Exercise 6 — The same contract in another language (Go)

**Goal:** Confirm that "client library" names a *specification*, not a Python thing. The four metric types, the registry, and the exposition format are identical; only the idioms change.

1. In a fresh directory:

   ```bash
   go mod init pca/ex6
   go get github.com/prometheus/client_golang/prometheus/promauto
   go get github.com/prometheus/client_golang/prometheus/promhttp
   ```

2. Create `main.go`:

   ```go
   package main

   import (
       "math/rand"
       "net/http"
       "time"

       "github.com/prometheus/client_golang/prometheus"
       "github.com/prometheus/client_golang/prometheus/promauto"
       "github.com/prometheus/client_golang/prometheus/promhttp"
   )

   var requests = promauto.NewCounterVec(
       prometheus.CounterOpts{
           Name: "myapp_requests_total", // Go: you DO write the _total suffix
           Help: "Total requests processed.",
       },
       []string{"method"},
   )

   func main() {
       go func() {
           for {
               requests.WithLabelValues("GET").Inc()
               time.Sleep(time.Duration(rand.Intn(200)) * time.Millisecond)
           }
       }()
       http.Handle("/metrics", promhttp.Handler())
       http.ListenAndServe(":2112", nil)
   }
   ```

3. Run `go run main.go`, then `curl -s localhost:2112/metrics | grep '^myapp_'`.

4. Compare this endpoint's behavior against Exercise 1: request `curl -s localhost:2112/` (root) versus `/metrics`.

**Checkpoints 6**
- **6a.** In Go you wrote `Name: "myapp_requests_total"` explicitly, but in Python (Exercise 2) writing `_total` yourself was wrong. Reconcile these two facts without calling either library buggy.
- **6b.** Unlike `start_http_server`, the Go example serves metrics *only* on `/metrics` (root returns 404). Which component is responsible for that routing, and why is `promhttp.Handler()` the correct production choice?
- **6c.** `promauto` differs from `prometheus.NewCounterVec` in exactly one behavior. What does `promauto` do automatically, and what silent failure does it prevent?

---

## Exercise 7 — Exposition format & content negotiation (text vs OpenMetrics)

**Goal:** Make the client library emit both wire formats and read the difference. This is the seam between "client library" and "what Prometheus ingests."

1. Return to the running `app2.py` from Exercise 2 (Counter + Gauge).

2. Fetch the default text format explicitly and note the header:

   ```bash
   curl -s -H 'Accept: text/plain' -D - localhost:8000/metrics | head -n 4
   ```

3. Now ask for OpenMetrics via content negotiation:

   ```bash
   curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' \
        -D - localhost:8000/metrics | tail -n 12
   ```

4. Compare the two outputs. Look specifically at: the `Content-Type` header, the `_created` series, and the final line of the payload.

**Checkpoints 7**
- **7a.** What single token at the very end of an OpenMetrics payload is *required* and absent from the legacy `0.0.4` text format?
- **7b.** The client library chose the output format based on your request. Which HTTP mechanism drove that choice, and which header did the *server* set in response?
- **7c.** In the legacy format every `# HELP`/`# TYPE` precedes its samples, values are floats, and the body is `text/plain; version=0.0.4`. Name **one** capability OpenMetrics adds that the legacy format cannot represent — and tie it to this exam domain's name.

---

## Answers

<details>
<summary>Click to reveal all checkpoint answers</summary>

### Exercise 1
- **1a.** The Python client library auto-registers three default collectors into the **default registry** (`REGISTRY`) at import time: `ProcessCollector` (the `process_*` series, read from `/proc` on Linux), `PlatformCollector` (`python_info`), and `GCCollector` (`python_gc_*`). You inherited them simply by using `start_http_server`, which serves that default registry. On non-Linux platforms the `process_*` set is largely empty because it depends on `/proc`.
- **1b.** `start_http_server` uses a minimal WSGI app that returns the metrics exposition for **every** path — it does no routing. That is fine for a demo but wrong for a real service: production apps serve metrics on a dedicated path (conventionally `/metrics`) alongside other routes, and you'd normally mount the metrics handler in your existing web framework rather than run a second, path-blind server.
- **1c.** `version=0.0.4` is the version of the **Prometheus text exposition format** — the on-the-wire serialization contract. It has nothing to do with your application's version or the Prometheus server's version. Its counterpart is `application/openmetrics-text; version=1.0.0` (Exercise 7).

### Exercise 2
- **2a.** The **client library** appended `_total`. The Python client treats a `Counter`'s name as the base and adds the conventional `_total` suffix (plus a `_created` series). Had you named it `myapp_requests_total`, you would have exposed the malformed `myapp_requests_total_total`. (Go is the opposite — see 6a.)
- **2b.** `myapp_requests_created` carries, per label set, the **Unix timestamp when that counter series was first created/initialized**. It is a `gauge` because it is an absolute point in time that does not monotonically increase like the counter it accompanies; it lets consumers detect counter resets/process restarts. These `_created` series come from the OpenMetrics data model.
- **2c.** A `Counter` deliberately exposes **no `.dec()`** (and no `.set()`). The library enforces **monotonicity** at the API level: counters may only increase (or reset to zero on restart). If a value can go down, it should be a `Gauge`.
- **2d.** Use the built-in context manager:
  ```python
  def handle(method: str) -> None:
      with INPROGRESS.track_inprogress():
          REQUESTS.labels(method=method).inc()
          time.sleep(0.2)
  ```
  It is safer because the decrement runs in a `finally` — an exception inside the block cannot leak a permanently incremented "in-progress" gauge, which is a classic source of stuck, ever-climbing gauges.

### Exercise 3
- **3a.** From *N* explicit buckets the library generated **N + 3** series: one `_bucket` per explicit `le`, plus the implicit `le="+Inf"` bucket, plus `_sum` and `_count`. Here N = 5 → 8 series.
- **3b.** `le="0.5"} 260` counts every observation **≤ 0.5 s** — buckets are cumulative ("less-than-or-equal"), not per-interval. `le="+Inf"` counts *all* observations regardless of value, which is by definition the total number of observations, so it must equal `_count`.
- **3c.** The defaults are `.005, .01, .025, .05, .075, .1, .25, .5, .75, 1.0, 2.5, 5.0, 7.5, 10.0, +Inf` — tuned for **seconds** of web-request latency. For millisecond-scale RPCs almost every observation falls into the first bucket, so the histogram loses all resolution where you need it; you must choose buckets that bracket *your* expected distribution.
- **3d.** `histogram_quantile(0.95, rate(myapp_request_duration_seconds_bucket[5m]))`. It is an **estimate** because the raw observations are gone — only bucket counts survive, so the function interpolates *linearly within the bucket* the quantile falls into. Accuracy is bounded by bucket width, and any value above the largest finite bucket is clamped.

### Exercise 4
- **4a.** Documented behavior, **not** a bug. The **Python** client's `Summary` exposes only `_sum` and `_count` — it does **not** support client-side quantiles at all.
- **4b.** Summary quantiles are computed **per instance and are not aggregatable** — you cannot average or add `quantile="0.99"` across pods to get a fleet-wide p99. Histograms expose additive `_bucket` counts, so you aggregate the buckets first (`sum by (le) (rate(...))`) and *then* apply `histogram_quantile`, yielding a correct cross-instance quantile. That aggregatability is the decisive operational advantage.
- **4c.** `rate(myapp_processing_seconds_sum[5m]) / rate(myapp_processing_seconds_count[5m])`. (Using `rate` on both handles counter resets correctly; a bare `_sum / _count` gives the lifetime average instead.)

### Exercise 5
- **5a.** The default collectors are registered against the **default registry** object the moment `prometheus_client` is imported (module-level `REGISTRY` receives `ProcessCollector`, `PlatformCollector`, `GCCollector`). Your `CollectorRegistry()` is an independent object; nothing auto-registers into it, and you attached only `JOBS` via `registry=reg`. Registries are just collections of collectors — isolation is the point.
- **5b.** For example: (1) **unit tests**, where you want a clean registry per test with no leakage of `process_*` noise or "already registered" collisions; (2) **batch jobs pushed to the Pushgateway**, where you build a throwaway registry, add just that job's metrics, and `push_to_gateway(...)`; also multi-tenant exporters that expose a different metric set per scrape target.
- **5c.** The exposition format is **UTF‑8 encoded bytes** on the wire, so the library serializes to `bytes` to match exactly what goes into the HTTP body — no implicit re-encoding. That is why the `Content-Type` explicitly declares `charset=utf-8`.

### Exercise 6
- **6a.** The `_total` suffix is a **naming convention of the exposition format**, so the exposed series must end in `_total` either way. The libraries differ only in *who writes it*: the **Python** client adds it for you (so you pass the base name), while **Go's** `client_golang` takes the metric name verbatim (so you type `_total` yourself). Both produce identical output; neither is wrong — you just have to know each library's contract.
- **6b.** The **HTTP mux/router** (`http.ServeMux` via `http.Handle("/metrics", ...)`) does the routing; only `/metrics` is registered, so `/` 404s. `promhttp.Handler()` is correct for production because it negotiates the exposition format, handles concurrent scrapes safely, and can be composed with instrumentation middleware and gzip — unlike a hand-rolled writer.
- **6c.** `promauto.NewCounterVec` **registers the collector with the default registry automatically** as part of construction. Plain `prometheus.NewCounterVec` returns an *unregistered* collector; if you forget the explicit `prometheus.MustRegister(...)`, the metric silently never appears in `/metrics`. `promauto` prevents that "defined but never exported" mistake.

### Exercise 7
- **7a.** OpenMetrics requires the payload to end with the literal terminator line `# EOF`. The legacy `0.0.4` text format has no such marker.
- **7b.** HTTP **content negotiation**: your `Accept` request header signalled the desired format, and the client library set the response **`Content-Type`** accordingly (`text/plain; version=0.0.4` vs `application/openmetrics-text; version=1.0.0`). Prometheus does exactly this when it scrapes.
- **7c.** OpenMetrics can carry **exemplars** — trace-id/context references attached to a `_bucket` or counter sample (appended after a `#`), which the legacy format cannot represent. This is precisely the "Exemplars" half of this exam domain, *Instrumentation and Exemplars*: exemplars are the bridge from a metric series to the individual trace that produced an observation. (OpenMetrics also natively models `_created` timestamps and the `Info`/`StateSet` types.)

</details>