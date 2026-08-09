# 2.5 Exposition Format

> **Domain:** Prometheus Fundamentals · **Exam weight class:** 4 (high)
> **Prerequisite topics:** 2.3 Data Model & Labels, 2.4 Configuration & Scraping

---

## 1. The production problem the exposition format solves

Prometheus is a **pull-based** system. The server periodically issues an HTTP `GET` against a target's `/metrics` endpoint and parses whatever comes back. That single design decision creates an architectural requirement that is easy to underestimate: **there must be a wire contract that any process, in any language, on any runtime, can implement without linking a heavyweight library and without the server knowing anything about the target in advance.**

The exposition format *is* that contract. It is the seam between the two halves of a Prometheus deployment:

```
  ┌───────────────┐   HTTP GET /metrics    ┌──────────────────────┐
  │  Instrumented │  ◄───────────────────  │   Prometheus server  │
  │    target     │   text/plain body      │   (scrape + parse +  │
  │  (exporter)   │  ─────────────────►    │    ingest into TSDB) │
  └───────────────┘                        └──────────────────────┘
       exposes                                    consumes
```

Design forces that shaped it, and which you must be able to defend in an SRE design review:

| Force | Consequence in the format |
|---|---|
| **Polyglot fleet** — the target may be a Go service, a shell script, a Java app, a Postgres exporter | Format is line-oriented UTF-8 text; a `printf` loop is a valid exporter. No schema registry, no codegen required. |
| **Debuggability at 3 a.m.** | A human can `curl` the endpoint and read it. This is a hard requirement, not a nicety — it is the primary triage tool when a scrape misbehaves. |
| **Stateless scrape** | Each scrape is a *complete snapshot* of current state. There is no delta protocol, no session, no ordering guarantee across scrapes. The exporter holds the state; the wire carries a full dump every interval. |
| **Cheap to produce** | Counters are cumulative (monotonic) so the exporter never has to compute rates — that is deferred to PromQL at query time. The exporter's only job is to print current values. |
| **Self-describing** | `# HELP` / `# TYPE` metadata travels inline so the server (and `promtool`) can lint and reason about semantics without out-of-band configuration. |

The critical mental model for the exam and for production: **the exposition format is a snapshot of an instantaneous state, not an event stream.** If your target restarts between two scrapes, the counter resets to zero and the *format has no way to tell you that happened* — detecting the reset is the job of PromQL's `rate()`/`increase()` at query time, aided by the `_created` timestamp in OpenMetrics.

---

## 2. Anatomy of a line

Every non-comment line follows one grammar:

```
metric_name [ "{" label_name="label_value" ( "," label_name="label_value" )* "}" ] SP value [ SP timestamp ] LF
```

Concrete, annotated:

```
http_requests_total{method="POST",handler="/api/v1/write",code="200"} 1027 1699999999000
└────────┬────────┘└──────────────────┬──────────────────────────┘ └─┬─┘ └──────┬──────┘
   metric name              label set (the "instance vector" key)   value   optional timestamp
                                                                            (ms since epoch)
```

### 2.1 Lexical rules you are expected to know cold

| Element | Rule |
|---|---|
| **Metric name** | Regex `[a-zA-Z_:][a-zA-Z0-9_:]*`. Colons `:` are **reserved for recording rules** — never use them in directly instrumented metrics. |
| **Label name** | Regex `[a-zA-Z_][a-zA-Z0-9_]*`. Names with a `__` prefix are **reserved** for Prometheus internals (`__name__`, `__address__`, …) and are dropped after relabeling. |
| **Label value** | Arbitrary UTF-8. Must be escaped (see below). An **empty label value is semantically identical to the label being absent** — `x{a=""}` and `x` are the same series. |
| **Value** | A Go `float64` parsed by `strconv.ParseFloat`. Accepts `1.5e9`, `+Inf`, `-Inf`, `Nan`. Integers are just floats with no fractional part. |
| **Timestamp** | Optional `int64`, **milliseconds** since the Unix epoch (classic text format). **Omit it in almost all cases** — let the server stamp ingestion time. Explicit timestamps are only for federation/proxy exporters and are subject to the staleness and out-of-order rules of the TSDB. |

### 2.2 Escaping — the two different rule sets (a frequent source of bugs)

The escaping rules differ between `HELP` text and label values:

| Context | Characters that MUST be escaped |
|---|---|
| `# HELP` description | backslash `\` → `\\`, newline → `\n` |
| Label value | backslash `\` → `\\`, double-quote `"` → `\"`, newline → `\n` |

Note that in a **label value the newline is `\n`** but the `#` and `=` characters are *not* special and need no escaping. Getting this wrong (e.g. a JSON blob in a label value with un-escaped quotes) is a classic cause of `text format parsing error`.

### 2.3 Metadata comments

Two comment lines carry semantics; everything else beginning with `#` is a free comment and ignored.

```
# HELP <metric_name> <single-line human description>
# TYPE <metric_name> <counter|gauge|histogram|summary|untyped>
```

Rules the parser enforces:
- **At most one `HELP` and one `TYPE` per metric name**, and they must appear **before** the samples for that metric.
- A second `HELP`/`TYPE` line for the same name is a **hard parse error**.
- `untyped` (classic) / `unknown` (OpenMetrics) means "no semantic guarantee" — the server ingests it but PromQL functions that assume monotonicity (`rate`) are meaningless on it.

---

## 3. The metric types on the wire

Only **four** types exist in the classic text format. The distinction lives entirely in how a *composite* type is decomposed into flat time series — the wire has no nested structures.

### 3.1 Counter and Gauge (atomic)

```
# HELP process_cpu_seconds_total Total user and system CPU time spent in seconds.
# TYPE process_cpu_seconds_total counter
process_cpu_seconds_total 34412.7

# HELP node_memory_MemAvailable_bytes Memory available in bytes.
# TYPE node_memory_MemAvailable_bytes gauge
node_memory_MemAvailable_bytes 8.128757760e+09
```

### 3.2 Histogram (composite → `_bucket` + `_sum` + `_count`)

A single logical histogram explodes into **N+2 time series**. Buckets are **cumulative** ("less than or equal to `le`") and the `+Inf` bucket is mandatory and **must equal `_count`**.

```
# HELP http_request_duration_seconds Request latency in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.05"}  24054
http_request_duration_seconds_bucket{le="0.1"}   33444
http_request_duration_seconds_bucket{le="0.25"}  100392
http_request_duration_seconds_bucket{le="0.5"}   129389
http_request_duration_seconds_bucket{le="1"}     133988
http_request_duration_seconds_bucket{le="+Inf"}  144320
http_request_duration_seconds_sum   53423.0
http_request_duration_seconds_count 144320
```

Invariants a correct exporter guarantees, and that `promtool` will check:
- Bucket counts are **monotonically non-decreasing** as `le` increases.
- The `le="+Inf"` bucket count `== _count`.
- `_sum` may *decrease* only if you record negative observations (rare, e.g. temperature) — with negative observations `rate()` on `_sum` becomes unsafe.

### 3.3 Summary (composite → quantiles + `_sum` + `_count`)

Quantiles (φ) are computed **client-side, per-instance**, and therefore **cannot be aggregated across instances** — the fundamental reason histograms are preferred in production.

```
# HELP rpc_duration_seconds RPC latency, client-side quantiles.
# TYPE rpc_duration_seconds summary
rpc_duration_seconds{quantile="0.5"}   0.0123
rpc_duration_seconds{quantile="0.9"}   0.0489
rpc_duration_seconds{quantile="0.99"}  0.1732
rpc_duration_seconds_sum   1.7560e+04
rpc_duration_seconds_count 2.6932e+06
```

### 3.4 Histogram vs Summary — the production trade-off

| Dimension | Histogram | Summary |
|---|---|---|
| Quantile computed | **At query time**, server-side, via `histogram_quantile()` | **At exposition time**, client-side, fixed φ set |
| Aggregatable across instances | **Yes** — sum the `_bucket` series, then compute quantile | **No** — averaging quantiles is statistically meaningless |
| Accuracy | Bounded by bucket boundaries (you must choose good `le` cuts) | Exact for the configured φ (within the exporter's sliding window) |
| Exporter cost | Cheap (increment a bucket counter) | Higher (streaming quantile estimator, memory + CPU) |
| Cardinality on the wire | `buckets + 2` series per label combination | `quantiles + 2` series per label combination |
| Change the target quantile later? | Yes, re-query historical data | No — only future data, quantiles are frozen at exposition |
| **Production default** | ✅ **Preferred** for latency/size SLOs | Use only when you need an exact single-instance quantile and will never aggregate |

**Rule of thumb for a design review:** if the metric feeds an SLO computed across a fleet, it must be a histogram. Summaries are a last resort.

### 3.5 Native (sparse) histograms — where the text format ends

Classic histograms force you to hand-pick `le` boundaries up front, trading cardinality against resolution. **Native histograms** (Prometheus 2.40+, still gated behind `--enable-feature=native-histograms`) replace fixed buckets with exponentially-spaced schema buckets that are allocated dynamically.

Critical exam-relevant fact: **native histograms are exposed only over the Protobuf format, not the text format.** They are the single most important reason Protobuf exposition returned to relevance after being deprecated. In text/OpenMetrics you will always see the classic `_bucket`/`_sum`/`_count` decomposition.

---

## 4. Format variants and content negotiation

There are three exposition encodings in the Prometheus universe. The server and target negotiate via standard HTTP `Accept`/`Content-Type`.

| Encoding | `Content-Type` value | Status | Notes |
|---|---|---|---|
| **Classic text** | `text/plain; version=0.0.4; charset=utf-8` | Universal default | What `curl` shows. Line-oriented, no terminator. |
| **OpenMetrics** | `application/openmetrics-text; version=1.0.0; charset=utf-8` | CNCF standard (evolved *from* this format) | Requires trailing `# EOF`; adds exemplars, `_created`, `UNIT`, `info`/`stateset`. Timestamps in **seconds** (float). |
| **Protobuf** | `application/vnd.google.protobuf; proto=io.prometheus.client.MetricFamily; encoding=delimited` | De-deprecated for native histograms | Binary, length-delimited `MetricFamily` messages. Required for native histograms. |

### 4.1 The Accept header a real Prometheus scraper sends

```
Accept: application/openmetrics-text;version=1.0.0;q=0.5,text/plain;version=0.0.4;q=0.4,*/*;q=0.1
```

With native histograms enabled, the scraper prepends the Protobuf type at higher `q`:

```
Accept: application/vnd.google.protobuf;proto=io.prometheus.client.MetricFamily;encoding=delimited;q=0.75,application/openmetrics-text;version=1.0.0;q=0.5,text/plain;version=0.0.4;q=0.4
```

The target inspects `Accept` and replies with the best format it can produce, setting `Content-Type` accordingly. `client_golang`'s `promhttp.Handler()` does this automatically.

### 4.2 OpenMetrics — the full feature set the text format lacks

```
# TYPE http_request_duration_seconds histogram
# UNIT http_request_duration_seconds seconds
# HELP http_request_duration_seconds A histogram of request duration.
http_request_duration_seconds_bucket{le="0.05"} 24054 # {trace_id="KOO5S4vxi0oEKfa4"} 0.032 1699999999.412
http_request_duration_seconds_bucket{le="0.1"} 33444
http_request_duration_seconds_bucket{le="+Inf"} 144320
http_request_duration_seconds_sum 53423.0
http_request_duration_seconds_count 144320
http_request_duration_seconds_created 1699900000.0
# TYPE build info
# HELP build Build metadata.
build_info{version="1.4.2",revision="a1b2c3d"} 1
# EOF
```

Differences from classic text that matter in production:

| OpenMetrics feature | What it adds | Why you care |
|---|---|---|
| `# EOF` terminator | Explicit end-of-stream | The scraper can detect a **truncated body** (connection dropped mid-scrape) instead of silently ingesting a partial snapshot. |
| **Exemplars** (`# {trace_id="…"} value ts`) | A sampled trace/span ID attached to a bucket/sample | Metrics-to-traces correlation. Requires server `--enable-feature=exemplar-storage`. |
| `_created` | The Unix time the series was first created | Lets `rate()`/`increase()` detect a counter reset precisely instead of inferring it. |
| `# UNIT` | Machine-readable unit metadata | Enables UI/tooling to render/validate units (`seconds`, `bytes`). |
| `info`, `stateset` types | First-class "labels-as-a-value" and enum state | Cleaner than the `_info`-suffixed gauge=1 hack of classic text. |
| Counter `_total` is **mandatory** | Sample line is `foo_total`, `# TYPE foo counter` | Enforces the naming convention the linter merely warns about. |

### 4.3 UTF-8 names (Prometheus 3.0+)

Since Prometheus 3.0, metric and label **names may contain arbitrary UTF-8** (e.g. dots, to align with OpenTelemetry). Such names are exposed using a **quoted syntax** and negotiated with an `escaping` parameter on the `Accept` header (`allow-utf-8`, `underscores`, `dots`, `values`):

```
# HELP "http.server.request.duration" Request duration.
# TYPE "http.server.request.duration" histogram
{"http.server.request.duration",le="0.1","http.route"="/api"} 33444
```

For an exam whose version is *unknown*, treat this as an advanced, forward-looking capability: know that it exists, that names go inside quotes, and that legacy tooling still expects the `[a-zA-Z_:][a-zA-Z0-9_:]*` charset unless UTF-8 is explicitly negotiated.

---

## 5. Complete, runnable examples

### 5.1 A minimal exporter with nothing but `printf` (proves the "any language" claim)

```bash
#!/usr/bin/env bash
# tiny_exporter.sh — a valid Prometheus target in pure shell + socat.
# Serves the classic text exposition format on :9101/metrics.
set -euo pipefail

render_metrics() {
  local load_1m mem_avail
  load_1m=$(awk '{print $1}' /proc/loadavg)
  mem_avail=$(awk '/MemAvailable/ {print $2 * 1024}' /proc/meminfo)

  cat <<EOF
# HELP node_load1 1m load average (custom shell exporter).
# TYPE node_load1 gauge
node_load1 ${load_1m}
# HELP node_memory_MemAvailable_bytes Available memory in bytes.
# TYPE node_memory_MemAvailable_bytes gauge
node_memory_MemAvailable_bytes ${mem_avail}
# HELP shell_exporter_scrapes_total Number of times metrics were rendered.
# TYPE shell_exporter_scrapes_total counter
shell_exporter_scrapes_total ${SCRAPES:-1}
EOF
}

body=$(render_metrics)
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nContent-Length: %d\r\n\r\n%s' \
  "${#body}" "$body"
```

```bash
$ socat TCP-LISTEN:9101,reuseaddr,fork EXEC:./tiny_exporter.sh &
$ curl -s localhost:9101/metrics
# HELP node_load1 1m load average (custom shell exporter).
# TYPE node_load1 gauge
node_load1 0.42
# HELP node_memory_MemAvailable_bytes Available memory in bytes.
# TYPE node_memory_MemAvailable_bytes gauge
node_memory_MemAvailable_bytes 8128757760
# HELP shell_exporter_scrapes_total Number of times metrics were rendered.
# TYPE shell_exporter_scrapes_total counter
shell_exporter_scrapes_total 1
```

### 5.2 The idiomatic Go instrumentation (what `client_golang` produces)

```go
package main

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var httpDuration = promauto.NewHistogramVec(
	prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "Duration of HTTP requests in seconds.",
		Buckets: prometheus.DefBuckets, // .005 .01 .025 .05 .1 .25 .5 1 2.5 5 10
	},
	[]string{"handler", "method", "code"},
)

func main() {
	// promhttp.Handler() performs content negotiation:
	// classic text, OpenMetrics, or protobuf depending on Accept.
	http.Handle("/metrics", promhttp.Handler())
	_ = http.ListenAndServe(":8080", nil)
}
```

The handler emits, automatically, the process and runtime collectors alongside your custom metrics:

```bash
$ curl -s localhost:8080/metrics | head -n 24
# HELP go_goroutines Number of goroutines that currently exist.
# TYPE go_goroutines gauge
go_goroutines 11
# HELP go_memstats_alloc_bytes Number of bytes allocated and still in use.
# TYPE go_memstats_alloc_bytes gauge
go_memstats_alloc_bytes 2.371456e+06
# HELP http_request_duration_seconds Duration of HTTP requests in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{code="200",handler="/",method="get",le="0.005"} 12
http_request_duration_seconds_bucket{code="200",handler="/",method="get",le="0.01"} 27
http_request_duration_seconds_bucket{code="200",handler="/",method="get",le="+Inf"} 41
http_request_duration_seconds_sum{code="200",handler="/",method="get"} 0.183
http_request_duration_seconds_count{code="200",handler="/",method="get"} 41
# HELP process_cpu_seconds_total Total user and system CPU time spent in seconds.
# TYPE process_cpu_seconds_total counter
process_cpu_seconds_total 0.42
# HELP process_resident_memory_bytes Resident memory size in bytes.
# TYPE process_resident_memory_bytes gauge
process_resident_memory_bytes 1.9349504e+07
```

### 5.3 The scrape configuration that consumes it

```yaml
# prometheus.yml — the server side of the contract
global:
  scrape_interval: 15s
  scrape_timeout: 10s

scrape_configs:
  - job_name: "shell-exporter"
    metrics_path: /metrics          # default; shown for clarity
    scheme: http
    static_configs:
      - targets: ["localhost:9101"]

  - job_name: "go-app"
    static_configs:
      - targets: ["localhost:8080"]
    # Guardrails that protect the server from a misbehaving exposition body:
    sample_limit: 100000            # abort the scrape if the body yields > N samples
    label_limit: 30                 # max labels per series
    label_name_length_limit: 200
    label_value_length_limit: 1000
    body_size_limit: 10MB           # cap the /metrics response body
    # Ask the target for OpenMetrics so we can ingest exemplars:
    # (Prometheus negotiates this automatically; exemplar storage still
    #  requires --enable-feature=exemplar-storage on the server.)
```

### 5.4 Kubernetes: how a Pod becomes a scrape target (ServiceMonitor)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: go-app
  labels:
    app: go-app
spec:
  selector:
    app: go-app
  ports:
    - name: metrics          # named port — referenced by the ServiceMonitor
      port: 8080
      targetPort: 8080
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: go-app
  labels:
    release: kube-prometheus-stack   # matched by the Prometheus CR's serviceMonitorSelector
spec:
  selector:
    matchLabels:
      app: go-app
  endpoints:
    - port: metrics          # matches the Service's named port
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      honorLabels: false     # server-side job/instance labels win over exposed ones
```

---

## 6. Verification and failure diagnosis

The exposition format is where a large fraction of real "my metric is missing" incidents actually live. Here is the diagnostic ladder, cheapest rung first.

### 6.1 Read the body directly (always step one)

```bash
$ curl -sv localhost:8080/metrics -o /dev/null 2>&1 | grep -i content-type
< Content-Type: text/plain; version=0.0.4; charset=utf-8
```

If the `Content-Type` is `text/html` or `application/json`, the endpoint is not an exporter — you are curling the wrong path or a reverse-proxy error page.

### 6.2 Lint with `promtool` (parses + naming-convention checks)

`promtool check metrics` reads an exposition body from **stdin**, fails on parse errors, and warns on naming-convention violations:

```bash
$ curl -s localhost:8080/metrics | promtool check metrics
myapp_requests: counter metrics should have "_total" suffix
myapp_temperature_celsius: non-histogram and non-summary metrics should not have "_sum" suffix

$ echo $?
3          # non-zero → CI can gate on this
```

A clean target:

```bash
$ curl -s localhost:9101/metrics | promtool check metrics
$ echo $?
0
```

Force strict OpenMetrics parsing to catch a missing `# EOF`:

```bash
$ curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' localhost:8080/metrics \
    | promtool check metrics
```

### 6.3 The auto-generated scrape metrics — your black-box telemetry

For **every** scrape, the server synthesizes these series against the target's `{job,instance}`. Query them to diagnose without touching the target:

| Series | Meaning | What a bad value tells you |
|---|---|---|
| `up` | `1` scrape ok, `0` failed | `0` → connection refused, timeout, TLS error, non-2xx status. The body was never parsed. |
| `scrape_duration_seconds` | Wall time of the scrape | Near `scrape_timeout` → the target is slow to render `/metrics` (expensive collectors). |
| `scrape_samples_scraped` | Samples in the body **before** relabeling | `0` with `up=1` → the endpoint returned 200 but an empty/HTML body. |
| `scrape_samples_post_metric_relabeling` | Samples kept **after** `metric_relabel_configs` | Much lower than `scraped` → your `drop` relabel rules are eating series. |
| `scrape_series_added` | New series this scrape vs the target's churn | Persistently high → **cardinality explosion / label churn** from the exposition. |

```
# "Which targets are down right now?"
up == 0

# "Which targets are close to the sample_limit and will soon be dropped?"
scrape_samples_scraped > 90000

# "Where is cardinality churning?"
topk(10, scrape_series_added)
```

Note: when `up == 0`, the scrape metrics *other than `up`* may be absent — the parse never happened.

### 6.4 Catalogue of exposition parse failures

These appear on the target's page in the UI (`Status → Targets`) as the "Error" column, and in the server log.

| Error message (representative) | Root cause | Fix |
|---|---|---|
| `text format parsing error in line N: ...` | Malformed line: bad float, unescaped `"` in a label value, stray whitespace | Fix the offending line; re-run `promtool check metrics`. |
| `second HELP line for metric name "x"` | Duplicate `# HELP`/`# TYPE` for one metric | Emit metadata exactly once, before the samples. |
| `duplicate sample for timestamp` / collector: `collected metric "x" ... was collected before with the same name and label values` | **Two identical series (same name + same label set)** in one scrape | You have a real duplicate — usually a bug generating the same labelset twice. The whole scrape is rejected. |
| `sample_limit exceeded (N)` | Body produced more samples than `sample_limit` | Reduce cardinality (drop high-cardinality labels) or raise the limit deliberately. |
| `label_limit exceeded` / `label_value_length_limit exceeded` | A series has too many labels / an oversized label value | Fix instrumentation; never put unbounded values (request IDs, full URLs) in labels. |
| `server returned HTTP status 404 Not Found` | Wrong `metrics_path` | Point the scrape config at the real path. |
| `unexpected end of OpenMetrics text` / missing `# EOF` | Truncated body or non-conformant OpenMetrics producer | The `# EOF` guard did its job — the scrape was truncated; investigate the target / proxy. |

### 6.5 Reproducing content negotiation for a failing scrape

To see exactly what the server sees, replay its `Accept` header:

```bash
$ curl -s \
    -H 'Accept: application/openmetrics-text;version=1.0.0;q=0.5,text/plain;version=0.0.4;q=0.4' \
    localhost:8080/metrics | tail -n 3
http_request_duration_seconds_count{code="200",handler="/",method="get"} 41
target_info{version="1.4.2"} 1
# EOF          # ← present ⇒ OpenMetrics was served and the body is complete
```

If `# EOF` is missing here, the target did not honour the OpenMetrics negotiation and the server fell back to classic text — verify the returned `Content-Type` before assuming exemplars will be ingested.

### 6.6 Verifying histogram integrity by hand

```bash
$ curl -s localhost:8080/metrics \
  | awk '/http_request_duration_seconds_bucket/ && /method="get"/ {print $NF, $0}' \
  | sort -n
12  http_request_duration_seconds_bucket{...le="0.005"} 12
27  http_request_duration_seconds_bucket{...le="0.01"}  27
41  http_request_duration_seconds_bucket{...le="+Inf"}  41   # == _count ✓, monotonic ✓
```

Two invariants to confirm: bucket counts never decrease as `le` grows, and the `+Inf` bucket equals `_count`. A violation means a broken exporter and will produce nonsensical `histogram_quantile()` results downstream.

---

## 7. Operational takeaways for a design review

- The exposition format is a **stateless full snapshot** in human-readable text; counters are cumulative so rate math is deferred to PromQL.
- **Four wire types** (counter, gauge, histogram, summary); composites are flattened into `_bucket`/`_sum`/`_count` and `quantile`/`_sum`/`_count` series. There is no nesting on the wire.
- Prefer **histograms over summaries** whenever the metric will be aggregated across instances — quantiles cannot be averaged.
- **OpenMetrics** is the standardized evolution: `# EOF`, exemplars, `_created`, `UNIT`. **Protobuf** is required specifically for **native histograms**.
- Your first diagnostic tool is `curl`; your second is `promtool check metrics`; your third is the auto-generated `up` / `scrape_samples_*` / `scrape_series_added` series.
- Protect the server with `sample_limit`, `label_limit`, and `body_size_limit` — a misbehaving exposition body is a real availability risk to the TSDB, not just a data-quality issue.

---

## Referencias

- Prometheus — Exposition formats: https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — Metric and label naming best practices: https://prometheus.io/docs/practices/naming/
- Prometheus — Metric types: https://prometheus.io/docs/concepts/metric_types/
- Prometheus — Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- Prometheus — Configuration (`scrape_config`, limits, relabeling): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — `promtool` and tooling: https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- Prometheus — Native histograms: https://prometheus.io/docs/specs/native_histograms/
- Prometheus 3.0 — UTF-8 support in names: https://prometheus.io/docs/guides/utf8/
- OpenMetrics specification (v1.0.0): https://github.com/prometheus/OpenMetrics/blob/main/specification/OpenMetrics.md
- Exemplars: https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- `client_golang` (`promhttp`, `promauto`): https://github.com/prometheus/client_golang
- prometheus-operator — ServiceMonitor API: https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.ServiceMonitor
- CNCF PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf