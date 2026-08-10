# Topic 5.4 — Structuring and Naming Metrics — Guided Exercises

> **Domain:** Instrumentation and Exposition · **Exam weight:** 4
> **Goal:** Build muscle memory for the Prometheus naming conventions (`namespace_subsystem_name_unit_suffix`), base units, the `_total`/`_info`/`_created` suffixes, label design, cardinality control, and the reserved colon (`:`) for recording rules — by instrumenting a real service, inspecting its exposition, and linting it with `promtool`.

**Reference sources**
- Metric & label naming — https://prometheus.io/docs/practices/naming/
- Instrumentation best practices (labels, cardinality) — https://prometheus.io/docs/practices/instrumentation/
- Data model (name/label regex, reserved names) — https://prometheus.io/docs/concepts/data_model/
- Metric types (counter/gauge/histogram/summary) — https://prometheus.io/docs/concepts/metric_types/
- Recording-rule naming (`level:metric:operations`) — https://prometheus.io/docs/practices/rules/
- Python client — https://github.com/prometheus/client_python
- OpenMetrics spec — https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md

**Prerequisites**
- Docker (or local binaries) for `prometheus` and `node_exporter`
- `promtool` (ships in the Prometheus release tarball)
- Python 3.12 with `prometheus_client` (`pip install prometheus_client`)
- `curl` and `jq`

---

## Exercise 1 — Dissecting a real metric name (the anatomy)

You will read metrics from a production-grade exporter and decompose each name into its parts: **namespace**, **name**, **unit**, and **suffix**.

1. Run `node_exporter` and expose its `/metrics` endpoint:

   ```bash
   docker run -d --name ne -p 9100:9100 quay.io/prometheus/node-exporter:latest
   ```

2. Pull three representative metric families and look only at their `# TYPE` lines:

   ```bash
   curl -s localhost:9100/metrics \
     | grep -E '^# TYPE (node_cpu_seconds_total|node_memory_MemAvailable_bytes|node_network_receive_bytes_total) '
   ```

   Expected output:

   ```
   # TYPE node_cpu_seconds_total counter
   # TYPE node_memory_MemAvailable_bytes gauge
   # TYPE node_network_receive_bytes_total counter
   ```

3. Now inspect one series of each so you can see units and labels:

   ```bash
   curl -s localhost:9100/metrics | grep -E '^node_cpu_seconds_total\{cpu="0"' | head -3
   ```

   Expected output (values will differ):

   ```
   node_cpu_seconds_total{cpu="0",mode="idle"} 84213.55
   node_cpu_seconds_total{cpu="0",mode="system"} 612.19
   node_cpu_seconds_total{cpu="0",mode="user"} 1893.42
   ```

4. Decompose `node_network_receive_bytes_total` on paper into: `namespace` / `name` / `unit` / `suffix`.

**Comprehension check**

- **1a.** In `node_network_receive_bytes_total`, identify the namespace, the descriptive name, the unit, and the type suffix.
- **1b.** Why is the unit `bytes` and not `kilobytes` or `mebibytes`? State the general rule this follows.
- **1c.** `node_cpu_seconds_total` is a counter measuring CPU time. Why is `seconds` (a *base unit of time*) the right choice here, and why does it carry `_total`?
- **1d.** `node_memory_MemAvailable_bytes` is a gauge and has **no** `_total` suffix. What rule dictates that?

---

## Exercise 2 — Instrumenting an application with correct naming

You will author instrumentation in Python and observe how the client library enforces conventions (the auto-appended `_total`, `_info`, `_created`, `_bucket/_sum/_count`).

1. Create `app.py`:

   ```python
   #!/usr/bin/env python3
   """Minimal instrumented service demonstrating metric-naming conventions."""
   import random
   import time

   from prometheus_client import Counter, Gauge, Histogram, Info, start_http_server

   # namespace = "myapp"; base name = "http_requests".
   # NOTE: do NOT write "_total" here — the Python client appends it in the exposition.
   REQUESTS = Counter(
       "myapp_http_requests",
       "Total number of HTTP requests handled.",
       ["method", "path", "status"],
   )
   IN_FLIGHT = Gauge(
       "myapp_http_requests_in_flight",
       "Number of HTTP requests currently in flight.",
   )
   LATENCY = Histogram(
       "myapp_http_request_duration_seconds",   # base unit is seconds, never milliseconds
       "HTTP request latency in seconds.",
       ["method", "path"],
       buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
   )
   BUILD = Info("myapp_build", "Build metadata for the running binary.")
   BUILD.info({"version": "1.4.2", "revision": "ab12cd3", "language": "python"})

   PATHS = ["/", "/login", "/api/orders"]

   def handle_one_request() -> None:
       method, path = "GET", random.choice(PATHS)
       status = random.choices(["200", "404", "500"], weights=[92, 6, 2])[0]
       with IN_FLIGHT.track_inprogress():
           with LATENCY.labels(method=method, path=path).time():
               time.sleep(random.expovariate(20))   # ~50 ms mean latency
       REQUESTS.labels(method=method, path=path, status=status).inc()

   if __name__ == "__main__":
       start_http_server(8000)
       print("Serving metrics on :8000/metrics")
       while True:
           handle_one_request()
   ```

2. Run it and let it accumulate a few seconds of traffic:

   ```bash
   python3 app.py &
   sleep 5
   ```

3. Look at how the **counter** was exposed:

   ```bash
   curl -s localhost:8000/metrics | grep -E '^# (HELP|TYPE) myapp_http_requests_total|^myapp_http_requests_total' | head -5
   ```

   Expected output (values differ):

   ```
   # HELP myapp_http_requests_total Total number of HTTP requests handled.
   # TYPE myapp_http_requests_total counter
   myapp_http_requests_total{method="GET",path="/",status="200"} 143.0
   myapp_http_requests_total{method="GET",path="/login",status="200"} 61.0
   myapp_http_requests_total{method="GET",path="/api/orders",status="500"} 3.0
   ```

4. Look at the **histogram** and **info** metrics:

   ```bash
   curl -s localhost:8000/metrics \
     | grep -E '^myapp_http_request_duration_seconds_(bucket|sum|count)|^myapp_build_info' | head -8
   ```

   Expected output (values differ):

   ```
   myapp_http_request_duration_seconds_bucket{le="0.005",method="GET",path="/"} 12.0
   myapp_http_request_duration_seconds_bucket{le="0.05",method="GET",path="/"} 118.0
   myapp_http_request_duration_seconds_bucket{le="+Inf",method="GET",path="/"} 143.0
   myapp_http_request_duration_seconds_sum{method="GET",path="/"} 6.94
   myapp_http_request_duration_seconds_count{method="GET",path="/"} 143.0
   myapp_build_info{language="python",revision="ab12cd3",version="1.4.2"} 1.0
   ```

5. Note the extra `_created` series the client emits:

   ```bash
   curl -s localhost:8000/metrics | grep -E '^myapp_http_requests_created' | head -1
   ```

   Expected output:

   ```
   myapp_http_requests_created{method="GET",path="/",status="200"} 1.7523e+09
   ```

**Comprehension check**

- **2a.** In the source you wrote `Counter("myapp_http_requests", ...)` with no `_total`, yet the exposition shows `myapp_http_requests_total`. What happened, and what would the exposed name have been if you had written `"myapp_http_requests_total"` in the source?
- **2b.** The histogram expanded into three families: `_bucket`, `_sum`, `_count`. What does the `le` label on `_bucket` mean, and why is `le` a reserved label name you must not reuse?
- **2c.** `myapp_build_info` always has the value `1.0` and carries `version`, `revision`, `language` as labels. What is the purpose of this "info" pattern, and why is the constant `1` the whole point?
- **2d.** Why is the latency histogram named `..._duration_seconds` rather than `..._duration_ms` or `..._latency`? Name the two conventions at play.
- **2e.** What is the `_created` series, and which exposition standard defines it?

---

## Exercise 3 — Labels: dimensions, consistency, and cardinality

You will measure how label choices drive series count, and reproduce the classic high-cardinality anti-pattern.

1. With `app.py` still running and Prometheus scraping it (or querying the exporter directly), count the current series of the request counter:

   ```bash
   curl -s localhost:8000/metrics | grep -c '^myapp_http_requests_total{'
   ```

   Expected output (≤ methods×paths×statuses = 1×3×3 = 9):

   ```
   7
   ```

2. Compute the *theoretical* upper bound for this metric from its label dimensions: `method` (1 value) × `path` (3 values) × `status` (3 values).

3. Now introduce the anti-pattern. Edit `app.py` to add a unique-per-user label. Change the counter definition and the `.inc()` call:

   ```python
   REQUESTS = Counter(
       "myapp_http_requests",
       "Total number of HTTP requests handled.",
       ["method", "path", "status", "user_id"],   # ← unbounded dimension
   )
   # ...
   REQUESTS.labels(
       method=method, path=path, status=status,
       user_id=str(random.randint(1, 10000)),      # up to 10,000 distinct values
   ).inc()
   ```

4. Restart the app, let it run, and count again:

   ```bash
   kill %1 2>/dev/null; python3 app.py & sleep 8
   curl -s localhost:8000/metrics | grep -c '^myapp_http_requests_total{'
   ```

   Expected output (grows without bound as more users are seen):

   ```
   2871
   ```

5. If Prometheus is scraping this target, ask its TSDB which metric names dominate cardinality:

   ```bash
   curl -s localhost:9090/api/v1/status/tsdb \
     | jq '.data.seriesCountByMetricName[] | select(.name|startswith("myapp"))'
   ```

   Expected output:

   ```json
   { "name": "myapp_http_requests_total", "value": 2871 }
   ```

6. Revert the `user_id` label before continuing.

**Comprehension check**

- **3a.** The theoretical bound in step 2 was 9, but you observed 7. Why can the actual series count be lower than the product of label cardinalities?
- **3b.** Cardinality is roughly the *product* of the distinct values of each label. Explain why adding `user_id` turned a 9-series metric into thousands, and what the two operational costs of that are.
- **3c.** A teammate proposes a `path` label whose value is the full raw request URL (including query strings like `?id=847213`). Why is this dangerous, and how should the path be handled instead?
- **3d.** Two different metrics in the same app use a label for the HTTP verb — one calls it `method`, the other `verb`. Why does the naming convention insist a given concept use the **same label name** everywhere?
- **3e.** Label names beginning with `__` (double underscore) are rejected for user use. What are they reserved for?

---

## Exercise 4 — Linting names with `promtool check metrics`

You will feed a deliberately broken exposition to `promtool` and interpret each lint message.

1. Create `bad.prom` — it parses as valid exposition but violates four naming rules:

   ```bash
   cat > bad.prom <<'EOF'
   # HELP myapp_processed Number of processed items.
   # TYPE myapp_processed counter
   myapp_processed 100
   # HELP myapp_queue_length_total Current queue length.
   # TYPE myapp_queue_length_total gauge
   myapp_queue_length_total 7
   # HELP myapp_request_latency_milliseconds Last request latency.
   # TYPE myapp_request_latency_milliseconds gauge
   myapp_request_latency_milliseconds 12
   # HELP myapp_disk_usage_bytes Disk space used.
   # TYPE myapp_disk_usage_bytes gauge
   myapp_disk_usage_bytes{deviceName="sda"} 2048
   EOF
   ```

2. Lint it:

   ```bash
   cat bad.prom | promtool check metrics
   ```

   Expected output:

   ```
   myapp_processed counter metrics should have "_total" suffix
   myapp_queue_length_total non-counter metrics should not have "_total" suffix
   myapp_request_latency_milliseconds use base unit "seconds" instead of "milliseconds"
   myapp_disk_usage_bytes label names should be written in 'snake_case' not 'camelCase'
   ```

3. Write the corrected `good.prom` that resolves all four findings, then re-lint until it is silent:

   ```bash
   cat > good.prom <<'EOF'
   # HELP myapp_processed_total Number of processed items.
   # TYPE myapp_processed_total counter
   myapp_processed_total 100
   # HELP myapp_queue_length Current queue length.
   # TYPE myapp_queue_length gauge
   myapp_queue_length 7
   # HELP myapp_request_latency_seconds Last request latency in seconds.
   # TYPE myapp_request_latency_seconds gauge
   myapp_request_latency_seconds 0.012
   # HELP myapp_disk_usage_bytes Disk space used.
   # TYPE myapp_disk_usage_bytes gauge
   myapp_disk_usage_bytes{device_name="sda"} 2048
   EOF
   cat good.prom | promtool check metrics && echo "clean"
   ```

   Expected output:

   ```
   clean
   ```

**Comprehension check**

- **4a.** Map each of the four `bad.prom` lint messages to the exact edit you made in `good.prom`.
- **4b.** For `myapp_request_latency_milliseconds`, converting to seconds changed the value from `12` to `0.012`. Why must the *value* change and not just the name?
- **4c.** `promtool check metrics` flagged style problems but the file still *parsed*. What is the difference between an exposition that is **invalid** (fails to parse) and one that is merely **non-conventional** (lints)? Which class of problem would break a scrape?
- **4d.** The valid character set for a metric name is `[a-zA-Z_:][a-zA-Z0-9_:]*`. The colon `:` is legal in that regex, yet the naming guide says never to use it in instrumented metrics. Why?

---

## Exercise 5 — Metadata and the reserved colon for recording rules

You will read the type/unit metadata Prometheus stores per metric, then create a correctly-named recording rule that *uses* the reserved colon.

1. Query the metadata catalog Prometheus builds from scraped `# TYPE`/`# HELP` lines:

   ```bash
   curl -s 'localhost:9090/api/v1/metadata?metric=myapp_http_requests_total' | jq .
   ```

   Expected output:

   ```json
   {
     "status": "success",
     "data": {
       "myapp_http_requests_total": [
         {
           "type": "counter",
           "help": "Total number of HTTP requests handled.",
           "unit": ""
         }
       ]
     }
   }
   ```

2. Create a recording rule that pre-aggregates the per-job request rate. Note the name format `level:metric:operations`:

   ```bash
   cat > rules.yml <<'EOF'
   groups:
     - name: myapp.rules
       rules:
         - record: job:myapp_http_requests:rate5m
           expr: sum by (job) (rate(myapp_http_requests_total[5m]))
   EOF
   ```

3. Validate the rule file:

   ```bash
   promtool check rules rules.yml
   ```

   Expected output:

   ```
   Checking rules.yml
     SUCCESS: 1 rules found
   ```

4. Confirm that `promtool check metrics` would reject that same colon-bearing name if it appeared as a *directly instrumented* metric:

   ```bash
   printf '# TYPE job:myapp_http_requests:rate5m gauge\njob:myapp_http_requests:rate5m 1\n' \
     | promtool check metrics
   ```

   Expected output:

   ```
   job:myapp_http_requests:rate5m metric names should not contain ':'
   ```

**Comprehension check**

- **5a.** In the recording-rule name `job:myapp_http_requests:rate5m`, decode each of the three colon-separated segments per the `level:metric:operations` convention.
- **5b.** Step 3 accepted the colon while step 4 rejected it. State the single rule that reconciles those two results.
- **5c.** The `/api/v1/metadata` `unit` field was empty for our counter even though the name ends in a unit-like word elsewhere in the codebase. Where does that `unit` value actually come from, and why is it blank here?
- **5d.** Why is it good practice to give the recording rule its own aggregated name rather than reusing `myapp_http_requests_total` with a different set of labels?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**

- **1a.** `namespace = node` · `name = network_receive` · `unit = bytes` · `suffix = _total`. So it is "cumulative received bytes on a network interface," a counter.
- **1b.** Prometheus convention: **always use unqualified base units** and let the query/dashboard layer scale for display (bytes, seconds, ratios in 0–1). Encoding `kilobytes`/`mebibytes` in the name forces every consumer to know and undo the scaling factor, and mixing scales across metrics breaks arithmetic. Ref: https://prometheus.io/docs/practices/naming/.
- **1c.** CPU time is *accumulated* time, and the base unit of time is the **second** (never milliseconds/nanoseconds in the name). Because it only ever increases (monotonic cumulative), it is a counter, and counters carry the `_total` suffix so `rate()`/`increase()` and tooling can recognize them.
- **1d.** Counters end in `_total`; **non-counters (gauges, etc.) must not**. `MemAvailable` is an instantaneous level that goes up and down — a gauge — so it takes no `_total`.

**Exercise 2**

- **2a.** The Python client **automatically appends `_total`** to counter names in the exposition; you supply the base name. Had you written `"myapp_http_requests_total"` in the source, the client would have appended again and exposed the doubled, wrong name `myapp_http_requests_total_total`. (Contrast: the Go client does *not* auto-append — there you must write `_total` yourself. Know which library you are using.)
- **2b.** `le` = "less than or equal to": each `_bucket` series counts observations whose value is ≤ that upper bound (cumulative buckets; the `+Inf` bucket equals `_count`). `le` is **reserved for histogram bucket boundaries**, so you must never define your own label called `le` (just as `quantile` is reserved for summaries).
- **2c.** The **info / machine-state pattern**: a gauge pinned to `1` whose *labels* carry constant, low-churn metadata (version, revision, build). You join it to real metrics with `* on(...) group_left(version) myapp_build_info` to attach the version dimension without baking high-churn strings into every operational metric. The constant `1` means the series only ever contributes its labels, never a value.
- **2d.** (1) **Base units** — latency is time, so the base unit `seconds`, not `ms`. (2) **Descriptive, unit-suffixed naming** — `..._duration_seconds` states what is measured and its unit; a bare `..._latency` omits the unit and is ambiguous.
- **2e.** `_created` carries the Unix timestamp at which that series was first created, emitted by default under the **OpenMetrics** exposition format so consumers can detect counter resets. Ref: OpenMetrics spec.

**Exercise 3**

- **3a.** Cardinality is only *realized* when a label combination is actually observed. Some combinations may never occur in the sample window (e.g., no `500` on `/login` yet), and some are logically impossible, so the live count sits at or below the theoretical product.
- **3b.** Total series ≈ product of per-label value counts, so `9 × (up to 10,000 user_ids) →` tens of thousands. Costs: (1) **memory/TSDB** — each active series consumes head-block memory and index space; (2) **query cost** — aggregations must touch every series, so dashboards and rules slow down. This is the primary way Prometheus instances fall over.
- **3c.** A raw URL with query strings is effectively **unbounded, unique-per-request** cardinality — the same failure mode as `user_id`. Use the **route template** instead (`/api/orders/{id}`, `/user/{name}`), so all requests to one handler share one label value.
- **3d.** Labels are the aggregation and join keys. If the same concept is `method` in one metric and `verb` in another, you cannot `group_left`/`group_right` join them or aggregate consistently across metrics — **label names must be stable and identical for the same meaning**.
- **3e.** `__`-prefixed labels are **reserved for Prometheus internal use** — e.g., `__name__` (the metric name itself), and the `__meta_*` / `__address__` labels present during relabeling before a target is scraped. User instrumentation must not create them.

**Exercise 4**

- **4a.**
  - `counter metrics should have "_total" suffix` → renamed `myapp_processed` → `myapp_processed_total`.
  - `non-counter metrics should not have "_total" suffix` → the gauge `myapp_queue_length_total` → `myapp_queue_length`.
  - `use base unit "seconds" instead of "milliseconds"` → `myapp_request_latency_milliseconds` → `myapp_request_latency_seconds`.
  - `label names should be written in 'snake_case' not 'camelCase'` → label `deviceName` → `device_name`.
- **4b.** The name is a *contract about the unit*. Renaming to `_seconds` while leaving `12` would claim 12 **seconds** of latency; the real quantity was 12 ms, so the value must be divided by 1000 to `0.012` to keep name and value consistent.
- **4c.** **Invalid** = violates the exposition grammar (bad syntax, duplicate series, malformed labels) → the scrape **fails** and the target is marked down. **Non-conventional** = parses fine but breaks naming best practices → `promlint` warns, the scrape still succeeds. Only the invalid class breaks a scrape.
- **4d.** The colon is **reserved by convention for recording-rule output names** (`level:metric:operations`). Keeping it out of directly-instrumented metrics preserves that signal: a `:` in a name tells you at a glance the series is a derived recording rule, not raw instrumentation.

**Exercise 5**

- **5a.** `job` = the aggregation **level** (aggregated to one value per job); `myapp_http_requests` = the **source metric** it derives from; `rate5m` = the **operation(s)** applied (a 5-minute rate, then summed). Reads as "the per-job 5-minute request rate."
- **5b.** **Colons are permitted only in recording-rule (and query) names, never in directly instrumented/exposed metric names.** `check rules` treats the name as rule output (allowed); `check metrics` treats it as instrumentation (forbidden).
- **5c.** The `unit` field is populated from the (optional) `# UNIT` metadata line of the **OpenMetrics** exposition, not inferred from the name. Our exporter emits no `# UNIT`, so it is the empty string even though the unit lives in the name suffix.
- **5d.** Recording rules should publish a **new, distinct name** (with the colon convention) so the pre-aggregated series is unmistakably derived and cannot collide or be confused with the raw counter. Re-emitting the original name with reduced labels would create two different series claiming the same name/semantics — ambiguous to query and to reason about.

</details>