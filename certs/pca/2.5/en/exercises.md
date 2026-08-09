# 2.5 Exposition Format — Guided Exercises

> **Scope.** These labs make you *read, write, validate and negotiate* the two text-based exposition formats Prometheus understands — the classic **Prometheus text format `0.0.4`** and **OpenMetrics `1.0.0`** — plus the mechanics of how a scrape actually pulls them over HTTP. Exam weight: 4.
>
> **Prerequisites.** A working `docker` (or `podman`), `curl`, and a shell. `promtool` ships *inside* the `prom/prometheus` image, so you do not need a separate install; we invoke it with `docker exec`.

**Spin up the target once and leave it running** — every exercise reuses it:

```bash
docker run -d --name prom -p 9090:9090 prom/prometheus:v2.53.0
# wait ~2s for the server to start, then confirm it answers:
curl -s -o /dev/null -w '%{http_code}\n' localhost:9090/metrics
```

Expected:

```
200
```

Prometheus exposes its **own** internals on `/metrics` using the Go client library, which conveniently gives us all four core metric types (`counter`, `gauge`, `histogram`, `summary`) from a single endpoint.

---

## Exercise 1 — The three kinds of line

An exposition is line-oriented, `\n`-separated UTF-8 text. Every line is exactly one of: a `# HELP` metadata line, a `# TYPE` metadata line, a **sample** (a `# ...` comment that is neither HELP nor TYPE is ignored). Let's see all three.

**Steps**

1. Pull the raw endpoint and read the first metric block:

   ```bash
   curl -s localhost:9090/metrics | grep -A2 '^# HELP go_goroutines'
   ```

   Expected:

   ```
   # HELP go_goroutines Number of goroutines that currently exist.
   # TYPE go_goroutines gauge
   go_goroutines 42
   ```

2. Count how many lines are metadata vs. samples for a busier metric:

   ```bash
   curl -s localhost:9090/metrics | grep '^prometheus_http_requests_total'
   ```

   Expected (values will differ):

   ```
   prometheus_http_requests_total{code="200",handler="/-/ready"} 3
   prometheus_http_requests_total{code="200",handler="/metrics"} 8
   prometheus_http_requests_total{code="200",handler="/api/v1/query"} 2
   ```

3. Confirm the metadata appears **once per metric family**, not once per sample:

   ```bash
   curl -s localhost:9090/metrics | grep -c '^# TYPE prometheus_http_requests_total'
   ```

   Expected:

   ```
   1
   ```

**Comprehension**

- **Q1.1** A single `# HELP`/`# TYPE` pair described three `prometheus_http_requests_total` samples in step 2. What distinguishes those three samples from one another, given they share the same metric name?
- **Q1.2** If an exporter emitted a line `# some free-form note here`, how does the parser treat it?
- **Q1.3** The `# TYPE go_goroutines gauge` line — is it mandatory for a valid exposition? What does Prometheus assume if it is absent?

---

## Exercise 2 — Anatomy of a sample line

A sample is `metric_name [ "{" label_name="value",… "}" ] SP value [ SP timestamp ]`. Dissect each field.

**Steps**

1. Isolate one fully-labelled counter sample:

   ```bash
   curl -s localhost:9090/metrics \
     | grep '^prometheus_http_requests_total{code="200",handler="/metrics"}'
   ```

   Expected:

   ```
   prometheus_http_requests_total{code="200",handler="/metrics"} 8
   ```

2. Verify the metric-name character rule. Valid names match `[a-zA-Z_:][a-zA-Z0-9_:]*`; the colon is **reserved for recording rules**, so exporters must not use it. Prove no exporter metric contains a colon:

   ```bash
   curl -s localhost:9090/metrics | grep -E '^[a-zA-Z_]+:[a-zA-Z_]*' | head
   ```

   Expected: *(no output — exit non-zero from grep)*

3. Observe that values are Go-parseable floats, including scientific notation:

   ```bash
   curl -s localhost:9090/metrics | grep '^go_memstats_alloc_bytes '
   ```

   Expected:

   ```
   go_memstats_alloc_bytes 1.8874e+07
   ```

4. Note that Prometheus's own endpoint omits the optional per-sample **timestamp** (it lets the scraper stamp the sample at scrape time — the normal case). The wire grammar *allows* a trailing int64 timestamp in **milliseconds** since the Unix epoch, e.g. `my_metric 42 1609459200000`.

**Comprehension**

- **Q2.1** In `prometheus_http_requests_total{code="200",handler="/metrics"} 8`, name the four syntactic fields present and the one field that is absent.
- **Q2.2** `1.8874e+07` — what plain-decimal value is this, and why is scientific notation acceptable on the wire?
- **Q2.3** A junior engineer hard-codes a per-sample timestamp of `1609459200` (Unix **seconds**) into an exporter. What goes wrong, and what is the correct unit for the classic text format?
- **Q2.4** Besides ordinary numbers, which three special float tokens are legal as a value?

---

## Exercise 3 — The four types as they appear on the wire

`counter` and `gauge` are single samples. `histogram` and `summary` are **composite**: each expands into several samples that the parser stitches back together by suffix.

**Steps**

1. Read the histogram expansion:

   ```bash
   curl -s localhost:9090/metrics \
     | grep '^prometheus_http_request_duration_seconds' | head -n 12
   ```

   Expected (abridged):

   ```
   # HELP prometheus_http_request_duration_seconds Histogram of latencies for HTTP requests.
   # TYPE prometheus_http_request_duration_seconds histogram
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="0.1"} 12
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="0.2"} 12
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="1"} 12
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="+Inf"} 12
   prometheus_http_request_duration_seconds_sum{handler="/metrics"} 0.0123
   prometheus_http_request_duration_seconds_count{handler="/metrics"} 12
   ```

2. Confirm the buckets are **cumulative** ("less than or equal to `le`") and that the last bucket is always `le="+Inf"`, whose value equals `_count`:

   ```bash
   curl -s localhost:9090/metrics \
     | grep 'prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="+Inf"}'
   curl -s localhost:9090/metrics \
     | grep 'prometheus_http_request_duration_seconds_count{handler="/metrics"}'
   ```

   Both values should match.

3. Read the summary expansion:

   ```bash
   curl -s localhost:9090/metrics | grep '^go_gc_duration_seconds' | head -n 10
   ```

   Expected (abridged):

   ```
   # HELP go_gc_duration_seconds A summary of the wall-time pause (in seconds) spent in GC.
   # TYPE go_gc_duration_seconds summary
   go_gc_duration_seconds{quantile="0"} 4.5e-05
   go_gc_duration_seconds{quantile="0.5"} 0.000105
   go_gc_duration_seconds{quantile="1"} 0.000345
   go_gc_duration_seconds_sum 0.008589
   go_gc_duration_seconds_count 65
   ```

**Comprehension**

- **Q3.1** What three reserved suffixes make up a `histogram` family, and which special label carries the bucket boundary?
- **Q3.2** Why must the `le="+Inf"` bucket exist, and what is the relationship between its value and the `_count` sample?
- **Q3.3** Both `histogram` and `summary` publish `_sum` and `_count`. What is the one structural difference between them on the wire, and which of the two computes its percentiles **client-side, inside the exporter**?
- **Q3.4** A histogram bucket sample carries a label `le`; a summary carries `quantile`. Why can neither of these label names be safely reused by you as an ordinary business label on the *same* metric?

---

## Exercise 4 — Author a valid exposition and validate it with `promtool`

`promtool check metrics` reads an exposition over **stdin**, parses it, and lints it. This is the tool you will use in CI to guard an exporter.

**Steps**

1. Write a small, correct exposition:

   ```bash
   cat > demo.prom <<'EOF'
   # HELP myapp_requests_total Total number of processed requests.
   # TYPE myapp_requests_total counter
   myapp_requests_total{method="get",status="200"} 1027
   myapp_requests_total{method="post",status="500"} 3
   # HELP myapp_temperature_celsius Current sensor temperature.
   # TYPE myapp_temperature_celsius gauge
   myapp_temperature_celsius 23.5
   EOF
   ```

2. Validate it:

   ```bash
   cat demo.prom | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Expected (clean parse, no lint findings):

   ```
   exit=0
   ```

3. **Break the syntax** — add a second `# HELP` for the same metric:

   ```bash
   printf '# HELP x_total help one.\n# TYPE x_total counter\n# HELP x_total help two.\nx_total 5\n' \
     | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Expected:

   ```
   error while linting: text format parsing error in line 3: second HELP line for metric name "x_total"
   exit=1
   ```

4. **Break the value** — a non-float where a float is required:

   ```bash
   printf '# TYPE y_total counter\ny_total abc\n' \
     | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Expected:

   ```
   error while linting: text format parsing error in line 2: expected float as value, got "abc"
   exit=1
   ```

5. **Trip a lint rule (not a syntax error)** — a counter without the `_total` suffix:

   ```bash
   printf '# HELP myapp_requests requests.\n# TYPE myapp_requests counter\nmyapp_requests 5\n' \
     | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Expected:

   ```
   myapp_requests counter metrics should have "_total" suffix
   exit=1
   ```

**Comprehension**

- **Q4.1** The clean file in step 1 declared each `# HELP`/`# TYPE` once but had **two** `myapp_requests_total` samples. Why is that legal, whereas two `# HELP` lines (step 3) is not?
- **Q4.2** Step 5 produced a *lint* message, not a *parsing error*. Explain the difference between the two classes of problem `promtool check metrics` reports, and why both still yield exit code 1.
- **Q4.3** Your CI runs `curl -s http://exporter/metrics | promtool check metrics`. Give two distinct real defects this catches *before* the metrics ever reach a Prometheus TSDB.

---

## Exercise 5 — Label-value escaping

Label **values** may contain arbitrary UTF-8, but three characters must be escaped: backslash `\` → `\\`, double-quote `"` → `\"`, and line-feed → `\n`. (In `# HELP` docstrings, backslash and line-feed are escaped; the quote is not special there.) Label **names** are strict: `[a-zA-Z_][a-zA-Z0-9_]*`, and names beginning `__` are reserved for internal use.

**Steps**

1. Author a metric whose labels contain each tricky character:

   ```bash
   cat > escapes.prom <<'EOF'
   # HELP myapp_build_info Build metadata.
   # TYPE myapp_build_info gauge
   myapp_build_info{path="C:\\logs\\app.log",quote="he said \"hi\"",multi="line1\nline2"} 1
   EOF
   ```

2. Validate — correct escaping parses cleanly:

   ```bash
   cat escapes.prom | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Expected:

   ```
   exit=1
   ```

   …because of a **lint** finding (`_info` metrics have a naming convention). Confirm there is **no parse error** — the escaping itself is valid:

   ```bash
   cat escapes.prom | docker exec -i prom promtool check metrics 2>&1 | grep -i 'parsing error'; echo "found=$?"
   ```

   Expected:

   ```
   found=1
   ```

   *(grep found nothing → the value escaping is syntactically fine.)*

3. **Break it** — an unescaped literal quote inside a value ends the value early:

   ```bash
   printf 'myapp_build_info{note="say "hi""} 1\n' \
     | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Expected:

   ```
   error while linting: text format parsing error in line 1: expected "=" after label name, found ...
   exit=1
   ```

4. **Break the label name** — a hyphen is illegal in a label name:

   ```bash
   printf 'myapp_x{trace-id="abc"} 1\n' \
     | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Expected: a parse error (`invalid label name` / unexpected character), exit `1`.

**Comprehension**

- **Q5.1** Which exactly three characters require escaping inside a label **value**, and what does each become?
- **Q5.2** In step 3, why does the *parser* — not a lint rule — reject `note="say "hi""`? Trace what the tokenizer sees after the first closing quote.
- **Q5.3** A colleague wants a label named `trace-id`. Give the rule they violated and a compliant name.
- **Q5.4** Is the empty-string label value `foo{bar=""} 1` the same, to Prometheus, as omitting the `bar` label entirely? Justify.

---

## Exercise 6 — OpenMetrics vs. the classic text format (content negotiation)

Prometheus (as scraper) and the Go client (as exporter) both speak **two** formats. The client picks one based on the request's `Accept` header. OpenMetrics `1.0.0` is the IETF-track successor: it mandates a trailing `# EOF`, requires the `_total` suffix on counters, uses **seconds** (float) for timestamps, adds `# UNIT` metadata and `_created` series, and supports **exemplars**.

**Steps**

1. See what the *default* request negotiates (curl sends `Accept: */*`):

   ```bash
   curl -s -D - -o /dev/null localhost:9090/metrics | grep -i '^content-type'
   ```

   Expected:

   ```
   Content-Type: text/plain; version=0.0.4; charset=utf-8
   ```

2. Explicitly ask for OpenMetrics and inspect the negotiated type:

   ```bash
   curl -s -D - -o /dev/null \
     -H 'Accept: application/openmetrics-text; version=1.0.0; charset=utf-8' \
     localhost:9090/metrics | grep -i '^content-type'
   ```

   Expected:

   ```
   Content-Type: application/openmetrics-text; version=1.0.0; charset=utf-8
   ```

3. Confirm the OpenMetrics body terminates with the mandatory sentinel:

   ```bash
   curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' \
     localhost:9090/metrics | tail -n 1
   ```

   Expected:

   ```
   # EOF
   ```

4. Compare a counter's presentation across the two formats. In classic text format a counter may appear with or without `_total`; in OpenMetrics the `_total` suffix is **required** and the type line describes the family without it. Note also that OpenMetrics forbids blank lines and may add `_created` timestamp series.

5. **Exemplars** attach a trace reference to a sample; they exist *only* in OpenMetrics and *only* on counter (`_total`) and histogram `_bucket` samples. Their wire shape is a `#`-delimited suffix:

   ```
   myapp_requests_total{method="get"} 1027 # {trace_id="abcd1234"} 1.0 1609459200.0
   #                                    │   └ exemplar labels    │   └ optional ts (seconds)
   #                                    └ separates sample from   └ exemplar value
   #                                      exemplar
   ```

**Comprehension**

- **Q6.1** How does an exporter decide whether to emit classic text format or OpenMetrics for a given scrape? Which HTTP header drives it, and which side (scraper or exporter) sends it?
- **Q6.2** Name three concrete differences a byte-level `diff` would reveal between the two formats for the *same* set of metrics.
- **Q6.3** A per-sample timestamp reads `1609459200000` in one format and `1609459200.000` in the other. Which is which, and what are the units?
- **Q6.4** You want to attach a `trace_id` exemplar to a gauge. Why is that impossible, and on which two sample kinds *are* exemplars allowed?
- **Q6.5** A parser reaches EOF on an OpenMetrics stream but never saw `# EOF`. What must a strict OpenMetrics parser do, and why does the classic text format not need such a marker?

---

## Exercise 7 — Beyond text: protobuf and native histograms (awareness)

The two text formats are not the only wire encoding. Prometheus retains a **Protocol Buffer** exposition format, and it is the *only* transport for **native (sparse) histograms**, which encode exponential buckets far more compactly than the fixed `le` buckets of a classic histogram.

**Steps**

1. Observe that the modern Prometheus scraper advertises protobuf in its own scrape requests. Inspect the `Accept` header Prometheus *sends* by pointing a throwaway listener at it — or simply reason from the config: native histograms require `--enable-feature=native-histograms`, and Prometheus then negotiates `application/vnd.google.protobuf` first in its `Accept`.

2. Confirm your text-format skills still hold: native histograms *fall back* to a classic bucketed representation when scraped over text, so a classic histogram remains the interoperable baseline.

**Comprehension**

- **Q7.1** Why can a **native histogram** not be represented in the classic `0.0.4` text format without loss, and what transport carries it losslessly?
- **Q7.2** Given that protobuf exists and is more compact, why is the text format still the recommended default for hand-written exporters and quick debugging?

---

## Answers

<details>
<summary>Click to reveal answers</summary>

### Exercise 1
- **Q1.1** Their **label sets** differ (`code`/`handler` combinations). A "metric" (a time series) is identified by the metric name **plus** its unique set of label name/value pairs; the three lines are three distinct series of the same metric *family*.
- **Q1.2** As a plain comment: any `#` line that is not `# HELP` or `# TYPE` is ignored by the parser.
- **Q1.3** No, `# TYPE` is optional. If absent, the metric is treated as **`untyped`** (classic text format) / **`unknown`** (OpenMetrics) — Prometheus still ingests the samples but with no type semantics. `# HELP` is likewise optional.

### Exercise 2
- **Q2.1** Present: (1) metric name `prometheus_http_requests_total`, (2) label set `{code="200",handler="/metrics"}`, (3) value `8`. Absent: (4) the optional per-sample **timestamp**.
- **Q2.2** `1.8874e+07` = `18,874,000`. Values are parsed by Go's `ParseFloat`, which accepts scientific notation, so exporters may emit large/small numbers compactly.
- **Q2.3** Providing seconds where **milliseconds** are expected makes Prometheus interpret the sample as ~January 1970, so it is either rejected as too far outside the scrape window or lands with a wildly wrong timestamp. Classic text-format timestamps are int64 **milliseconds** since the Unix epoch. (OpenMetrics, by contrast, uses seconds as a float.) The correct habit is to emit **no** timestamp and let the scraper stamp it.
- **Q2.4** `NaN`, `+Inf`, `-Inf`.

### Exercise 3
- **Q3.1** `_bucket`, `_sum`, `_count`. The bucket boundary is carried by the reserved `le` ("less than or equal") label.
- **Q3.2** `le="+Inf"` counts every observation regardless of size, so it is the total; therefore its value **equals** the `_count` sample. Without it there would be no way to know how many observations fell above the largest finite bucket.
- **Q3.3** Structural difference: a `histogram` carries `_bucket{le=…}` samples; a `summary` carries `{quantile=…}` samples instead of buckets. The **summary** computes its φ-quantiles client-side inside the exporter (they cannot be aggregated across instances afterwards), whereas a histogram ships raw buckets and quantiles are estimated later via `histogram_quantile()` in PromQL.
- **Q3.4** Because on those metrics `le` and `quantile` are **reserved, structural** labels the parser uses to reconstruct the composite type. Reusing them as business labels collides with the type machinery and corrupts bucket/quantile interpretation.

### Exercise 4
- **Q4.1** Multiple **samples** of one family are the normal case — they are distinct series differing by labels. But `# HELP`/`# TYPE` are **family-level metadata**; the format permits exactly one of each per metric name, so a second `# HELP` is a syntax error.
- **Q4.2** A **parsing error** means the bytes are not a well-formed exposition (the parser cannot build samples at all). A **lint** finding means the input parsed fine but violates a best-practice/naming convention (e.g. counter without `_total`). Both are treated as failures by `promtool check metrics`, so both exit `1` — which is what lets it gate CI.
- **Q4.3** Any two of: a counter missing/using the wrong `_total` suffix; a non-float value; a duplicate `# HELP`/`# TYPE`; a malformed label (bad name, unescaped quote); a histogram missing its `+Inf` bucket; missing HELP text; non-base units.

### Exercise 5
- **Q5.1** `\` → `\\`, `"` → `\"`, line-feed → `\n`.
- **Q5.2** After `note="say "`, the parser has already consumed a complete, closed value (`say `). The next character `h` is where it expects either a comma (another label) or `}`. Seeing `hi` there, it reports it cannot find the `=`/`,`/`}` it needs — a **grammar** violation, hence a parse error, not a lint warning.
- **Q5.3** Label names must match `[a-zA-Z_][a-zA-Z0-9_]*`; `-` is not allowed. Use `trace_id`.
- **Q5.4** Yes — an **empty label value is equivalent to the label being absent**. `foo{bar=""} 1` and `foo 1` refer to the same time series.

### Exercise 6
- **Q6.1** The **scraper** sends an `Accept` header; the **exporter** honours it and picks the best format it can serve (content negotiation). `Accept: application/openmetrics-text…` yields OpenMetrics; `Accept: */*` (or a text/plain preference) yields classic `0.0.4`.
- **Q6.2** Any three of: OpenMetrics ends with `# EOF` (text format does not); OpenMetrics `Content-Type` is `application/openmetrics-text; version=1.0.0`; counters are always `_total`-suffixed in OpenMetrics; timestamps are float **seconds** vs. int **milliseconds**; OpenMetrics may add `_created` series and `# UNIT` lines and exemplars; OpenMetrics forbids blank lines.
- **Q6.3** `1609459200000` is the **classic text format** (int64 **milliseconds**); `1609459200.000` is **OpenMetrics** (float **seconds**).
- **Q6.4** Exemplars are a feature of OpenMetrics and are permitted **only** on counter (`_total`) samples and histogram `_bucket` samples — the points to which a trace of "one representative event" meaningfully attaches. A gauge is a current level, not a count of discrete events, so no exemplar slot exists for it.
- **Q6.5** A strict OpenMetrics parser must treat a stream that ends without `# EOF` as **truncated/invalid** and reject it — the marker guarantees the scraper received the complete payload (guarding against a connection cut mid-transfer). The classic text format has no such guarantee; it simply parses whatever lines arrive.

### Exercise 7
- **Q7.1** A native histogram uses a dynamic, exponentially-spaced sparse bucket schema with a resolution that the fixed-string `le` buckets of `0.0.4` cannot express without either huge bucket counts or precision loss. It is carried losslessly over the **Protocol Buffer** exposition format (`application/vnd.google.protobuf`).
- **Q7.2** The text format is human-readable, trivial to emit from any language (just print lines), and instantly debuggable with `curl`/`grep`/`promtool` — no schema or codec needed. Protobuf's compactness matters at scale but costs tooling and legibility, so text remains the default for authoring and troubleshooting.

</details>

---

### Sources
- Prometheus — *Exposition formats* (text format `0.0.4`, escaping, histogram/summary rules): https://prometheus.io/docs/instrumenting/exposition_formats/
- OpenMetrics specification `1.0.0` (`# EOF`, `_total`, `_created`, exemplars, seconds timestamps): https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
- Prometheus — *Metric and label naming* best practices (`_total`, base units, reserved characters): https://prometheus.io/docs/practices/naming/
- Prometheus — *Metric types* (counter, gauge, histogram, summary; native histograms): https://prometheus.io/docs/concepts/metric_types/
- `promtool` reference (`check metrics` lint/validate): https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- CNCF PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf