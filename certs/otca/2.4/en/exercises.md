# OTCA 2.4 — Signals: Tracing, Metrics, Logs (Guided Exercises)

A **signal** in OpenTelemetry is a category of telemetry with its own data model, API and SDK path, but all signals share the same wrapping envelope: a **Resource** (the entity producing the data — a service, host, container) contains one or more **InstrumentationScopes** (the library/module that emitted the data), which contain the signal records themselves (`Span`, `Metric`, `LogRecord`). Understanding that envelope is what lets you *correlate* the three signals later.

These exercises use only the vendor-neutral OpenTelemetry stack — the **Collector** (`otelcol-contrib`), the **`telemetrygen`** load generator, and raw **OTLP** over HTTP — so nothing here depends on a backend vendor.

> Sources:
> - Traces — https://opentelemetry.io/docs/concepts/signals/traces/
> - Metrics — https://opentelemetry.io/docs/concepts/signals/metrics/
> - Logs — https://opentelemetry.io/docs/concepts/signals/logs/
> - OTLP protocol — https://opentelemetry.io/docs/specs/otlp/
> - W3C Trace Context — https://www.w3.org/TR/trace-context/

---

## Exercise 0 — Stand up a Collector (shared setup)

Every exercise below sends OTLP to a local Collector whose only job is to print what it receives, in full detail, to the console via the `debug` exporter.

1. Create `otelcol.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     batch:

   exporters:
     debug:
       verbosity: detailed          # print full Resource/Scope/record detail
     prometheus:                    # used only in Exercise 2
       endpoint: 0.0.0.0:8889

   service:
     pipelines:
       traces:
         receivers:  [otlp]
         processors: [batch]
         exporters:  [debug]
       metrics:
         receivers:  [otlp]
         processors: [batch]
         exporters:  [debug, prometheus]
       logs:
         receivers:  [otlp]
         processors: [batch]
         exporters:  [debug]
   ```

2. Run the Collector (Docker keeps your host clean; the two OTLP ports and the Prometheus scrape port are published):

   ```bash
   docker run --rm --name otelcol \
     -p 4317:4317 -p 4318:4318 -p 8889:8889 \
     -v "$(pwd)/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:latest \
     --config /etc/otelcol/config.yaml
   ```

3. Confirm it is listening. In another terminal:

   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4318/v1/traces -X POST -H "Content-Type: application/json" -d '{}'
   ```

   Expected: `200`.

4. Install the load generator (a Go toolchain gives you the binary directly; otherwise use the `ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen` image):

   ```bash
   go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest
   telemetrygen --help | head -n 5
   ```

**Comprehension check**

- Q0.1 — The Collector exposes gRPC on `4317` and HTTP on `4318`. Both speak "OTLP". What is the *one* protocol here, and what are the two things that differ between those ports?
- Q0.2 — In step 3 you POSTed an empty `{}` and got `200`. Why is that not proof that a real trace would be accepted and exported correctly?
- Q0.3 — `verbosity: detailed` on the `debug` exporter — what changes versus the default `basic`, and why would you *never* leave `detailed` on in production?

---

## Exercise 1 — Traces: the anatomy of a span

A **trace** is a DAG of **spans** sharing one 128-bit `TraceId`. Each span has its own 64-bit `SpanId`, an optional `ParentId`, a `Kind`, a start/end timestamp, a `Status`, `Attributes`, `Events`, and `Links`. `telemetrygen` emits a canonical two-span trace: a `CLIENT` span (`lets-go`) that is the parent of a `SERVER` span (`okey-dokey-0`).

1. Send exactly one trace:

   ```bash
   telemetrygen traces \
     --otlp-endpoint localhost:4317 --otlp-insecure \
     --traces 1
   ```

2. Read the Collector console. You will see something close to:

   ```
   ResourceSpans #0
   Resource attributes:
        -> service.name: Str(telemetrygen)
   ScopeSpans #0
   InstrumentationScope telemetrygen
   Span #0
       Trace ID       : 7d3d1e6a2b9c4f0a8e5c1b2d3a4f5e6c
       Parent ID      :
       ID             : 1a2b3c4d5e6f7a8b
       Name           : lets-go
       Kind           : Client
       Start time     : 2026-08-10 12:00:00.001 +0000 UTC
       End time       : 2026-08-10 12:00:00.124 +0000 UTC
       Status code    : Unset
   Span #1
       Trace ID       : 7d3d1e6a2b9c4f0a8e5c1b2d3a4f5e6c
       Parent ID      : 1a2b3c4d5e6f7a8b
       ID             : 9f8e7d6c5b4a3210
       Name           : okey-dokey-0
       Kind           : Server
       Status code    : Unset
   Attributes:
        -> net.peer.ip: Str(1.2.3.4)
        -> peer.service: Str(telemetrygen-server)
   ```

3. Note three facts from the output: (a) both spans share one `Trace ID`; (b) `Span #0` has an empty `Parent ID`; (c) `Span #1`'s `Parent ID` equals `Span #0`'s `ID`.

4. Now force an error status and add more spans per trace:

   ```bash
   telemetrygen traces \
     --otlp-endpoint localhost:4317 --otlp-insecure \
     --traces 1 --status-code Error --child-spans 3
   ```

   Observe the `Status code : Error` line on the affected span.

**Comprehension check**

- Q1.1 — `Span #0` (`lets-go`) has an empty `Parent ID`. What do we call a span with no parent, and what does that tell you about where the trace was started?
- Q1.2 — The child (`okey-dokey-0`) is `Kind: Server` and the parent (`lets-go`) is `Kind: Client`. Name all five span kinds and explain what makes `CLIENT`/`SERVER` a *pair* versus `PRODUCER`/`CONSUMER`.
- Q1.3 — For a healthy span the `Status code` is `Unset`, not `Ok`. Why does the spec distinguish `Unset` from `Ok`, and who is allowed to set `Ok`?
- Q1.4 — When the `SERVER` span was created inside the downstream service, how did that service learn the `TraceId` and the parent `SpanId`? Name the propagation standard and the exact HTTP header, and give the meaning of each of its four dash-separated fields.
- Q1.5 — You need to model a fan-in: one span caused by *many* upstream operations (e.g., a batch job processing 100 messages). `ParentId` only holds one value. What span feature expresses the other 99 causal relationships?

---

## Exercise 2 — Metrics: instruments and temporality

A metric is produced by an **instrument**. The instrument's *kind* fixes its semantics: `Counter` (monotonic sum), `UpDownCounter` (non-monotonic sum), `Histogram` (distribution), `Gauge` (last value), plus the **asynchronous** (Observable) callback-driven variants. The SDK then aggregates data points with a **temporality** — **cumulative** (value since start) or **delta** (value since the previous export). Prometheus is a cumulative system; this exercise makes that concrete.

1. Send a monotonic `Sum` metric named `gen`:

   ```bash
   telemetrygen metrics \
     --otlp-endpoint localhost:4317 --otlp-insecure \
     --metric-type Sum --metrics 5
   ```

2. In the `debug` output, find the descriptor and confirm the two properties that define a `Counter`-style sum:

   ```
   Metric #0
   Descriptor:
        -> Name: gen
        -> DataType: Sum
   IsMonotonic: true
   AggregationTemporality: Cumulative
   NumberDataPoints #0
   Data point attributes:
        -> foo: Str(bar)
   Value: 5
   ```

3. Now read the *same* metric through the Prometheus exporter, which is scraped, not pushed:

   ```bash
   curl -s http://localhost:8889/metrics | grep -A1 '^# TYPE gen'
   ```

   Expected shape:

   ```
   # TYPE gen_total counter
   gen_total{foo="bar"} 5
   ```

4. Compare a `Gauge` to the `Sum`:

   ```bash
   telemetrygen metrics \
     --otlp-endpoint localhost:4317 --otlp-insecure \
     --metric-type Gauge --metrics 1
   ```

   Note the descriptor now reads `DataType: Gauge` with **no** `IsMonotonic` and **no** `AggregationTemporality` line.

**Comprehension check**

- Q2.1 — The `Sum` descriptor printed `IsMonotonic: true` and `AggregationTemporality: Cumulative`; the `Gauge` printed neither field. Explain why *temporality has no meaning for a Gauge*.
- Q2.2 — In step 3 the Prometheus exporter renamed `gen` to `gen_total` and typed it `counter`. What rule drove the `_total` suffix, and what does the suffix signal to a Prometheus query author?
- Q2.3 — You want to record request *latency* and later compute p50/p95/p99 on the backend. Which instrument do you pick, and what three families of data points does a single OTLP `Histogram` data point carry that make percentile estimation possible?
- Q2.4 — You have a `Counter` and want to observe the number of *currently active* database connections (a value that goes up and down). Why is `Counter` wrong here, and which two instruments (one sync, one async) are correct — and how do you choose between them?
- Q2.5 — Your backend only accepts **delta** temporality, but your SDK defaults to cumulative. Rather than re-instrument the app, where in the pipeline can you convert, and what state must that conversion component keep in memory to do it — and what breaks if that component restarts?

---

## Exercise 3 — Logs: the LogRecord and severity model

OpenTelemetry treats logs as a first-class signal with a structured **LogRecord**: `Timestamp`, `ObservedTimestamp`, `SeverityNumber` (1–24), `SeverityText`, a typed `Body`, `Attributes`, and — crucially — `TraceId`/`SpanId`/`TraceFlags` fields for correlation. Here you emit a LogRecord by hand over OTLP/HTTP so you can see every field, then read it back.

1. Create `log.json`. Note the numeric `severityNumber: 17` (the start of the `ERROR` range) and the hex-encoded `traceId`/`spanId`:

   ```json
   {
     "resourceLogs": [{
       "resource": {
         "attributes": [
           { "key": "service.name", "value": { "stringValue": "checkout" } }
         ]
       },
       "scopeLogs": [{
         "scope": { "name": "manual-test" },
         "logRecords": [{
           "timeUnixNano": "1754827200000000000",
           "severityNumber": 17,
           "severityText": "ERROR",
           "body": { "stringValue": "payment gateway timeout after 3 retries" },
           "attributes": [
             { "key": "http.response.status_code", "value": { "intValue": 504 } },
             { "key": "retry.count", "value": { "intValue": 3 } }
           ],
           "traceId": "7d3d1e6a2b9c4f0a8e5c1b2d3a4f5e6c",
           "spanId": "1a2b3c4d5e6f7a8b"
         }]
       }]
     }]
   }
   ```

2. Send it to the OTLP/HTTP logs endpoint:

   ```bash
   curl -s http://localhost:4318/v1/logs \
     -H "Content-Type: application/json" \
     -d @log.json
   ```

   Expected response: `{"partialSuccess":{}}` (empty partial-success means everything was accepted).

3. Read the Collector console:

   ```
   ResourceLog #0
   Resource attributes:
        -> service.name: Str(checkout)
   ScopeLogs #0
   InstrumentationScope manual-test
   LogRecord #0
   ObservedTimestamp: 2026-08-10 12:00:07.512 +0000 UTC
   Timestamp: 2026-08-10 12:00:00 +0000 UTC
   SeverityText: ERROR
   SeverityNumber: Error(17)
   Body: Str(payment gateway timeout after 3 retries)
   Attributes:
        -> http.response.status_code: Int(504)
        -> retry.count: Int(3)
   Trace ID: 7d3d1e6a2b9c4f0a8e5c1b2d3a4f5e6c
   Span ID: 1a2b3c4d5e6f7a8b
   ```

4. Re-send with `"timeUnixNano"` removed from the record and observe that `Timestamp` becomes empty while `ObservedTimestamp` is still populated by the Collector.

**Comprehension check**

- Q3.1 — Your record set `Timestamp` explicitly, but the Collector also printed a *different* `ObservedTimestamp`. Define both, and describe the real-world scenario in which they legitimately differ by minutes.
- Q3.2 — `severityNumber` was `17` and `severityText` was `"ERROR"`. The spec defines `SeverityNumber` as a 1–24 range grouped into six bands. What is the point of the numeric field when we already have free-text `SeverityText`, and which band does `17` open?
- Q3.3 — In step 1 the `traceId`/`spanId` are written as **hex** strings, yet OTLP/Protobuf defines those fields as `bytes`. What special rule in the OTLP/JSON encoding makes hex correct here (and why would base64 also be accepted by the receiver but is *not* the canonical form for these two fields)?
- Q3.4 — The `Body` used `stringValue`, but the field is an `AnyValue`. Give one concrete advantage of sending a *structured* body (a `kvlistValue`) instead of a pre-formatted string, from the point of view of a backend that indexes logs.

---

## Exercise 4 — Correlation: stitching the three signals together

The payoff of the shared envelope: a single incident can be pivoted across signals. Two mechanisms do the stitching — the **Resource** (same `service.name`/`service.instance.id` binds a service's traces, metrics and logs) and **trace context** (`TraceId`/`SpanId` on a LogRecord, and **exemplars** on a metric, both point back to a specific span).

1. Emit a trace and capture its `Trace ID` from the Collector console:

   ```bash
   telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure --traces 1
   ```

2. Edit `log.json` from Exercise 3 so its `traceId` matches the `Trace ID` you just saw, and its `spanId` matches one of that trace's span `ID`s. Also set the log's `service.name` to `telemetrygen` to match the trace's Resource. Re-send it (step 2 of Exercise 3).

3. You have now produced a log that is joinable to a span on *two* independent axes. Reason about which axis a query uses in each of these cases:
   - "Show me every log line, across all services, emitted while span `1a2b3c4d5e6f7a8b` was active."
   - "Show me this service's request-rate metric next to its error logs for the last hour."

4. (Concept) A metric data point can carry an **exemplar** — a sampled `(value, TraceId, SpanId, timestamp)` tuple. Picture a latency `Histogram` whose p99 bucket carries an exemplar. Trace the click-path an operator follows from a spiking p99 chart down to the one slow request.

**Comprehension check**

- Q4.1 — Two correlation axes were used above: the **Resource** and the **trace context**. Match each of the two queries in step 3 to the axis it relies on, and explain why the *cross-service* query cannot use the Resource.
- Q4.2 — Define an **exemplar** and explain why it is the bridge from the *aggregated* world of metrics (where individual requests are lost to aggregation) back into the *per-request* world of traces.
- Q4.3 — A colleague proposes correlating logs to traces by writing the trace id into the log **body** text (`"... traceId=7d3d..."`) instead of the dedicated `TraceId` field. Give two concrete operational reasons that is inferior.
- Q4.4 — All three signals from one service must agree on `service.name` for Resource-based correlation to work. In the SDK, *where* is that guaranteed to be identical across signals rather than set three times?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0
- **Q0.1** — The one protocol is **OTLP** (OpenTelemetry Protocol). The ports differ in (1) **transport/encoding**: `4317` is OTLP/gRPC (HTTP/2 + Protobuf), `4318` is OTLP/HTTP (Protobuf *or* JSON body); and (2) the **request shape**: gRPC uses service methods (`Export`), HTTP uses signal-specific paths (`/v1/traces`, `/v1/metrics`, `/v1/logs`). Semantically the payload is the same OTLP data model.
- **Q0.2** — A `200` on an empty `{}` only proves the endpoint is reachable and the JSON parses; it contains zero spans, so nothing is validated about a real ResourceSpans/Span structure, attribute encoding, or the exporter pipeline. Reachability ≠ correctness; you must send real telemetry and read it back (as the later exercises do).
- **Q0.3** — `basic` prints a one-line summary (counts of resource spans/metrics/logs). `detailed` prints the full Resource attributes, InstrumentationScope, and every record's fields. You never run `detailed` in production because it serializes and writes *every* record to the log — enormous I/O and log volume, and it re-emits potentially sensitive attributes into stdout. It is a debugging tool only.

### Exercise 1
- **Q1.1** — A span with no parent is the **root span**. It marks where the trace *began* in this system — typically the first service to receive an un-traced request (it generated a fresh `TraceId`), or the process that started the workflow.
- **Q1.2** — The five kinds: **INTERNAL, SERVER, CLIENT, PRODUCER, CONSUMER**. `CLIENT`/`SERVER` are a **synchronous** RPC pair: the client blocks waiting for the server's response, so the two spans overlap in time and are directly parent/child across the wire. `PRODUCER`/`CONSUMER` are an **asynchronous** messaging pair: the producer enqueues and returns immediately, the consumer runs later (possibly much later), so they are usually joined by a **Link** rather than a tight parent/child timing relationship. `INTERNAL` is work with no remote boundary.
- **Q1.3** — `Unset` means "the instrumentation made no claim" — the default, and the normal state of a successful span. `Ok` is an **explicit override** reserved for the *application developer* to force success even when a backend might otherwise infer error; instrumentation libraries must not set `Ok`. Distinguishing them lets tools treat "no opinion" differently from "developer asserts this is fine."
- **Q1.4** — **W3C Trace Context**, carried in the **`traceparent`** HTTP header. Its four dash-separated fields are: `version` (`00`), `trace-id` (32 hex / 16 bytes), `parent-id` a.k.a. the caller's span id (16 hex / 8 bytes), and `trace-flags` (2 hex; bit 0 is the `sampled` flag). The downstream service parses `traceparent`, reuses the `trace-id`, and sets its new SERVER span's parent to the incoming `parent-id`.
- **Q1.5** — **Span Links**. A link references another span (its `SpanContext`) without a parent/child timing relationship, so one span can point back to the many upstream spans that caused it — the canonical batch/fan-in case.

### Exercise 2
- **Q2.1** — Temporality answers "over what time interval is this number accumulated?" A **Gauge** is a *last-value* sample — an instantaneous reading (e.g., current temperature, current queue depth). There is no interval to accumulate over, so cumulative-vs-delta is undefined; only sums and histograms (which accumulate) carry an `AggregationTemporality`.
- **Q2.2** — Prometheus naming conventions: a monotonically increasing counter is exposed with a **`_total`** suffix and TYPE `counter`. It tells the query author this value only ever goes up (resets to 0 on restart), so you must wrap it in `rate()`/`increase()` rather than reading the raw value.
- **Q2.3** — Pick a **Histogram**. A single OTLP histogram data point carries: (1) `count` and `sum` of all recorded values, (2) explicit **bucket boundaries** (`explicit_bounds`), and (3) the per-bucket **`bucket_counts`**. From boundaries + counts the backend interpolates percentiles. (The exponential/native histogram variant carries scale + bucket offsets instead of explicit bounds.)
- **Q2.4** — A `Counter` is **monotonic**; it can only be added to, so it cannot represent a value that decreases (active connections drop when a connection closes). Correct choices: **`UpDownCounter`** (synchronous — you `Add(+1)` on open, `Add(-1)` on close, when you own those events) or **`ObservableGauge`/`ObservableUpDownCounter`** (asynchronous — a callback reads the current pool size on each collection). Use the synchronous UpDownCounter when the change events pass through your code; use the async observable when you can only *poll* the current value from an external source.
- **Q2.5** — Convert in the **Collector**, not the app: the `cumulativetodelta` processor. It must retain, in memory, the **previous cumulative value for every time series (every unique attribute set)** so it can subtract to produce the delta. On restart that state is lost, so the first export after restart has no prior point to diff against — that series' first delta is dropped (or mis-computed), a known gap of stateful conversion.

### Exercise 3
- **Q3.1** — `Timestamp` is when the event *actually occurred* (set by the source). `ObservedTimestamp` is when the OpenTelemetry pipeline *first saw* the record. They diverge when logs are collected out-of-band — e.g., a **file/log-tailer** reading a log file that was written minutes ago (backlog, rotation, a crashed pod's file scraped after the fact): the event time is old, the observed time is now.
- **Q3.2** — `SeverityText` is free-form vendor text (`"warn"`, `"WARNING"`, `"W"`, `"Warn"` — all different strings). `SeverityNumber` is a **normalized 1–24 ordinal** so backends can *filter and compare* severity consistently regardless of the source's wording (`severity >= 17` == "errors and worse"). `17` opens the **ERROR** band (`ERROR` = 17–20; the bands are TRACE 1–4, DEBUG 5–8, INFO 9–12, WARN 13–16, ERROR 17–20, FATAL 21–24).
- **Q3.3** — OTLP/JSON follows proto3 JSON mapping, under which `bytes` fields are base64. But the OTLP spec carves out a **special case: `trace_id` and `span_id` are encoded as case-insensitive lowercase hex strings** (because that is how humans and W3C Trace Context already represent them). A receiver may also accept base64 for other bytes fields, but for these two the canonical, spec-mandated form is hex — send base64 there and you risk a receiver rejecting or mis-decoding it.
- **Q3.4** — A structured `kvlistValue` body keeps fields **individually typed and indexable** — the backend can index/filter on `order_id` or `amount` directly, without regex-parsing a formatted string. It also avoids ambiguity and locale/formatting drift, and survives message-template changes. A pre-formatted string forces the backend to re-extract fields it was handed structured in the first place.

### Exercise 4
- **Q4.1** — First query ("all logs while span X was active") uses the **trace-context** axis (`SpanId`), because it spans *multiple services* — the Resource differs per service, so only the shared trace/span ids can join them. Second query ("this service's metric next to its error logs") uses the **Resource** axis (`service.name`), because both signals come from the *same* service and you're pivoting by service identity, not by a single request. The cross-service query cannot use the Resource precisely because each service has its own distinct Resource.
- **Q4.2** — An **exemplar** is a sampled example measurement attached to a metric data point, recording the raw `value` together with the `TraceId`/`SpanId` (and timestamp) that were active when it was recorded. Aggregation (a histogram bucket, a counter) throws away the identity of individual requests; the exemplar preserves a *pointer* from one aggregated bucket back to one real span, so an operator can jump from "the aggregate looks wrong" to "here is a specific request that caused it."
- **Q4.3** — (1) It is **not queryable as a join key** — the id is buried in unstructured text, so the backend must regex-scrape every line instead of indexing a typed `TraceId` field; automatic trace↔log linking in the UI won't fire. (2) It is **fragile and lossy** — a message-template change, truncation, or a log line that formats the id differently breaks correlation silently, and the dedicated `TraceFlags` (sampled bit) is lost entirely.
- **Q4.4** — In the **shared `Resource`**: the SDK builds one `Resource` (from resource detectors + `OTEL_RESOURCE_ATTRIBUTES`/`service.name`) and injects the *same* instance into all three providers (`TracerProvider`, `MeterProvider`, `LoggerProvider`). Because they share that single Resource object, `service.name` is guaranteed identical across signals rather than typed three times and risking drift.

</details>