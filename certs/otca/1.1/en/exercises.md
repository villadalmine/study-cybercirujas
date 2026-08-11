# Guided Exercises — Topic 1.1: Telemetry Data (OTCA)

These exercises build a real telemetry pipeline on your workstation and use it to dissect the OpenTelemetry data model signal by signal. You will stand up an OpenTelemetry Collector as a passive sink, drive synthetic telemetry into it with `telemetrygen`, and read the raw OTLP payloads the Collector prints. Reading real payloads — rather than diagrams — is how the span, metric, and log data models actually stop being abstract.

**Reference sources**
- OTCA Curriculum — https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
- Signals overview — https://opentelemetry.io/docs/concepts/signals/
- OTLP specification — https://opentelemetry.io/docs/specs/otlp/
- Data model spec (traces/metrics/logs) — https://opentelemetry.io/docs/specs/otel/

---

## Prerequisites

- Docker (or Podman) available to run the Collector container.
- Go ≥ 1.21 to install `telemetrygen`, **or** the ability to run it from a container image. Both paths are shown.
- A free `4317` (OTLP/gRPC) and `4318` (OTLP/HTTP) on `localhost`.

> All expected outputs below are **abbreviated and representative** — trace/span IDs, timestamps, and ordering vary per run. Focus on the *fields*, not the literal values.

---

## Exercise 1 — Stand up a Collector as a telemetry sink

The Collector's `debug` exporter (the component formerly named `logging`, renamed in Collector v0.86.0) writes decoded OTLP to stdout. That makes it the ideal microscope for looking at telemetry data.

**Steps**

1. Create a working directory and a Collector config file:

   ```bash
   mkdir -p ~/otca-1.1 && cd ~/otca-1.1
   ```

2. Write `config.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   exporters:
     debug:
       verbosity: detailed

   service:
     pipelines:
       traces:
         receivers: [otlp]
         exporters: [debug]
       metrics:
         receivers: [otlp]
         exporters: [debug]
       logs:
         receivers: [otlp]
         exporters: [debug]
   ```

3. Start the Collector, mounting the config:

   ```bash
   docker run --rm --name otelcol \
     -p 4317:4317 -p 4318:4318 \
     -v "$(pwd)/config.yaml:/etc/otelcol-contrib/config.yaml" \
     otel/opentelemetry-collector-contrib:latest
   ```

4. Confirm the three pipelines came up. In the startup log you should see the receiver and exporter start, and lines resembling:

   ```
   info    service@v0.x.x/service.go   Everything is ready. Begin running and processing data.
   ```

5. Install `telemetrygen` (native), or note the container alternative used in later steps:

   ```bash
   # Native install:
   go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest
   # Container alternative (use --network host so localhost:4317 resolves):
   #   docker run --rm --network host \
   #     ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
   #     traces --otlp-insecure --duration 2s
   ```

**Comprehension questions**

- **Q1.1** — The config declares `otlp` under *receivers* and `debug` under *exporters*. In the OpenTelemetry pipeline model, what is the directional role of each, and which one is *receiving* telemetry over the network here?
- **Q1.2** — Why are there three separate `pipelines` (`traces`, `metrics`, `logs`) instead of one? What does this tell you about how OpenTelemetry treats the different signals internally?
- **Q1.3** — The receiver exposes both `4317` (gRPC) and `4318` (HTTP). Both speak the same wire protocol. What is that protocol, and what serialization format does it use by default?

---

## Exercise 2 — Traces: dissect a span

A trace is a tree of spans sharing one Trace ID. `telemetrygen traces` emits a small client→server call graph you can read field by field.

**Steps**

1. With the Collector still running, in a second terminal send a single trace:

   ```bash
   telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 1
   ```

2. Switch to the Collector terminal. You should see a `ResourceSpans` block. Abbreviated:

   ```
   ResourceSpans #0
   Resource attributes:
        -> service.name: Str(telemetrygen)
   ScopeSpans #0
   InstrumentationScope telemetrygen
   Span #0
       Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
       Parent ID      :
       ID             : 00f067aa0ba902b7
       Name           : lets-go
       Kind           : Client
       Start time     : 2026-08-10 12:00:00.000000 +0000 UTC
       End time       : 2026-08-10 12:00:00.000123 +0000 UTC
       Status code    : Unset
   Span #1
       Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
       Parent ID      : 00f067aa0ba902b7
       ID             : a1b2c3d4e5f60718
       Name           : okey-dokey-0
       Kind           : Server
       Status code    : Unset
   Attributes:
        -> net.peer.ip: Str(1.2.3.4)
        -> peer.service: Str(telemetrygen-server)
   ```

3. Identify the **root span**: it is the one whose `Parent ID` is empty. Note that both spans carry the *same* `Trace ID`.

4. Match the child's `Parent ID` to the root's `ID`. That linkage is the parent-child edge of the trace tree.

5. Increase the fan-out and re-run to see multiple traces, each an independent tree:

   ```bash
   telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 3
   ```

**Comprehension questions**

- **Q2.1** — A Trace ID is 16 bytes (32 hex chars) and a Span ID is 8 bytes (16 hex chars). Given the output above, which field establishes that Span #1 is a *child* of Span #0, and how does a backend reconstruct the full tree from a flat stream of spans?
- **Q2.2** — Span #0 has `Kind: Client` and Span #1 has `Kind: Server`. Enumerate the five valid `SpanKind` values and explain why the *same* logical operation (one HTTP call) often produces both a Client span and a Server span.
- **Q2.3** — Every span carries `Status code: Unset`. What are the three possible span status values, and which side (instrumentation vs. backend) is responsible for setting `Error`?
- **Q2.4** — The W3C Trace Context `traceparent` header has the form `00-<trace-id>-<parent-id>-<flags>`. Using Span #1's values, write the `traceparent` header the server would have received. (Assume sampled, `flags = 01`.)

---

## Exercise 3 — Metrics: instruments, data points, and temporality

The metrics data model is where OTCA candidates most often lose points. `telemetrygen metrics` lets you emit each core data type and observe how the Collector renders it.

**Steps**

1. Emit a monotonic **Sum** (the data type a Counter produces):

   ```bash
   telemetrygen metrics --otlp-insecure --otlp-endpoint localhost:4317 \
     --metric-type Sum --metrics 1
   ```

   Collector output (abbreviated):

   ```
   Metric #0
   Descriptor:
        -> Name: gen
        -> DataType: Sum
        -> IsMonotonic: true
        -> AggregationTemporality: Cumulative
   NumberDataPoints #0
   StartTimestamp: 2026-08-10 12:00:00 +0000 UTC
   Timestamp:      2026-08-10 12:00:05 +0000 UTC
   Value: 1
   ```

2. Now emit a **Gauge**:

   ```bash
   telemetrygen metrics --otlp-insecure --otlp-endpoint localhost:4317 \
     --metric-type Gauge --metrics 1
   ```

   ```
   Metric #0
   Descriptor:
        -> Name: gen
        -> DataType: Gauge
   NumberDataPoints #0
   Timestamp: 2026-08-10 12:00:10 +0000 UTC
   Value: 42
   ```

3. Compare the two descriptors carefully. Note which fields are present on the Sum but **absent** on the Gauge (`IsMonotonic`, `AggregationTemporality`, `StartTimestamp`).

4. (Conceptual) A **Histogram** data point renders with `Count`, `Sum`, `ExplicitBounds`, and per-bucket `BucketCounts` rather than a single `Value`. Sketch on paper what a request-latency histogram with bounds `[5, 10, 25, 50, 100]` ms would carry after observing latencies `4, 8, 8, 30, 200` ms.

**Comprehension questions**

- **Q3.1** — The Sum descriptor shows `AggregationTemporality: Cumulative`. Contrast **Cumulative** vs. **Delta** temporality: for a Counter observed at t=1s (value 10) and t=2s (value 25), what does each data point report under each temporality?
- **Q3.2** — The Gauge has no `StartTimestamp` and no `AggregationTemporality`. Why are those fields meaningless for a Gauge but essential for a Sum?
- **Q3.3** — Name the six synchronous/asynchronous **API instruments** (Counter, UpDownCounter, Histogram, Gauge, and the observable variants) and map each to the **data type** it produces in the OTLP data model (Sum / Gauge / Histogram).
- **Q3.4** — For the histogram in step 4, fill in `Count`, `Sum`, and `BucketCounts` (six buckets: five bounded + one overflow). Which single bucket does the `200 ms` observation land in?

---

## Exercise 4 — Logs and trace correlation

An OpenTelemetry `LogRecord` is a first-class signal with a defined structure — not just a text line. Its power comes from carrying the *same* Trace ID and Span ID as the span that was active when it was emitted.

**Steps**

1. Send a batch of log records:

   ```bash
   telemetrygen logs --otlp-insecure --otlp-endpoint localhost:4317 --logs 2
   ```

2. Read the `LogRecord` blocks (abbreviated):

   ```
   LogRecord #0
   ObservedTimestamp: 2026-08-10 12:00:00 +0000 UTC
   Timestamp:         2026-08-10 12:00:00 +0000 UTC
   SeverityText:      Info
   SeverityNumber:    Info(9)
   Body:              Str(the message)
   Attributes:
        -> app: Str(server)
   Trace ID:
   Span ID:
   ```

3. Note that the standalone log records above have **empty** `Trace ID` / `Span ID` — they were emitted with no active span. In real instrumented code, a log emitted inside a span is automatically stamped with that span's context.

4. Compare the two timestamp fields: `Timestamp` (when the event *happened*) vs. `ObservedTimestamp` (when the collection layer *saw* it). They differ when logs are scraped from files after the fact.

5. Locate the `SeverityNumber: Info(9)`. Map it against the numeric severity ranges to understand why `9` means "Info."

**Comprehension questions**

- **Q4.1** — `SeverityText` is a free-form string (`"Info"`, `"WARNING"`, `"emerg"`), but `SeverityNumber` is normalized 1–24. Give the numeric range for each of the six severity classes (TRACE, DEBUG, INFO, WARN, ERROR, FATAL). Why does the spec define a normalized number *in addition to* the text?
- **Q4.2** — What two fields on a `LogRecord` enable **log↔trace correlation**, and what must be true at emit time for them to be populated? Why is this correlation impossible to reconstruct reliably if you only ship logs as plain text lines?
- **Q4.3** — Explain a concrete scenario where `Timestamp` and `ObservedTimestamp` legitimately diverge, and which one you would sort by when investigating an incident.

---

## Exercise 5 — Resource, attributes, and semantic conventions

Every signal in the previous exercises was wrapped in a `Resource` (`service.name: telemetrygen`). The Resource identifies *what* produced the telemetry; semantic conventions make attribute names portable across vendors. This exercise also draws the line between attributes and **Baggage**.

**Steps**

1. Override the Resource's `service.name` and add a custom telemetry attribute:

   ```bash
   telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 1 \
     --otlp-attributes 'service.name="checkout"' \
     --telemetry-attributes 'tenant="acme"'
   ```

2. In the Collector output, confirm the split:

   ```
   ResourceSpans #0
   Resource attributes:
        -> service.name: Str(checkout)      # ← Resource-level (the producer)
   ...
   Span #0
   Attributes:
        -> tenant: Str(acme)                 # ← Span-level (this operation)
   ```

3. Notice the placement: `service.name` sits under **Resource attributes** (applies to *every* span/metric/log from this service), while `tenant` sits under the **Span's** own `Attributes` (applies to that one operation).

4. Cross-check `service.name`, `net.peer.ip`, and `peer.service` against the OpenTelemetry Semantic Conventions registry (https://opentelemetry.io/docs/specs/semconv/) to confirm they are standardized, not invented per-team.

5. (Conceptual) **Baggage** is a separate mechanism: key-value pairs propagated across the W3C `baggage` header alongside `traceparent`, so downstream services can *read* context set upstream. Baggage is **not** automatically written onto spans as attributes — copying it requires an explicit processor or code.

**Comprehension questions**

- **Q5.1** — Distinguish **Resource attributes** from **span/metric/log attributes** by scope and lifetime. Why is `service.name` a Resource attribute rather than a per-span one?
- **Q5.2** — What problem do **semantic conventions** solve for a backend that ingests telemetry from dozens of independently instrumented services? Give one example attribute and what would break if each team named it freely.
- **Q5.3** — **Baggage** rides on the same context propagation as trace context but is a *distinct* signal-adjacent concept. State (a) what Baggage is for, and (b) the common security/cost pitfall of assuming Baggage values automatically appear as span attributes.
- **Q5.4** — `service.name` is the one Resource attribute the spec treats as required. What is the defined fallback value if instrumentation fails to set it, and why does a missing/duplicated `service.name` degrade a backend's service map?

---

## Cleanup

```bash
docker stop otelcol
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** — In the Collector pipeline, a **receiver** ingests telemetry *into* the Collector and an **exporter** sends telemetry *out*. Here the `otlp` receiver is receiving data over the network (gRPC/HTTP), and the `debug` exporter "exports" it to stdout as decoded text. Data flows receiver → (processors) → exporter.

**A1.2** — OpenTelemetry models **traces, metrics, and logs as three distinct signals**, each with its own data model, wire representation, and pipeline. A pipeline is signal-typed: a `traces` pipeline can only carry spans, a `metrics` pipeline only metric data points, etc. This separation is why a component (receiver/processor/exporter) must declare which signals it supports.

**A1.3** — The protocol is **OTLP** (OpenTelemetry Protocol). Its canonical encoding is **Protocol Buffers**; OTLP/gRPC always uses protobuf, and OTLP/HTTP defaults to binary protobuf (`application/x-protobuf`) with an optional JSON encoding. Port 4317 is OTLP/gRPC, 4318 is OTLP/HTTP.

### Exercise 2

**A2.1** — Span #1's **`Parent ID` field equals Span #0's `ID`**; that back-reference is the parent-child edge. A backend groups all spans sharing one **Trace ID**, then reconstructs the tree by linking each span to the span whose `ID` matches its `Parent ID`. The root is the span with an empty `Parent ID`. Because the linkage is carried *in each span*, the stream can arrive out of order and still be reassembled.

**A2.2** — The five `SpanKind` values are **INTERNAL, SERVER, CLIENT, PRODUCER, CONSUMER**. A single remote call yields two spans because both sides instrument it: the caller records a **CLIENT** span (time spent awaiting the response, including network), and the callee records a **SERVER** span (time spent handling the request). The CLIENT span is the parent of the SERVER span via propagated trace context. PRODUCER/CONSUMER are the async messaging analogues.

**A2.3** — The three span status values are **Unset**, **Ok**, and **Error**. `Unset` is the default and means "no explicit judgment." Instrumentation (the SDK/application), not the backend, sets `Error` when the operation failed; backends must not infer it. `Ok` is set only to explicitly override a heuristic — most successful spans are left `Unset`.

**A2.4** — Using Span #1 (`Trace ID = 4bf92f3577b34da6a3ce929d0e0e4736`, its own `ID = a1b2c3d4e5f60718`) — but the header the server *received* carries the **parent's** span ID (`00f067aa0ba902b7`):

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
```

`00` = version, then trace-id, then the caller's span-id, then `01` = sampled flag. (The server generates `a1b2c3d4e5f60718` locally as its own span ID; it is not in the incoming header.)

### Exercise 3

**A3.1** — Under **Cumulative** temporality each data point reports the running total since `StartTimestamp`: t=1s → `10`, t=2s → `25`. Under **Delta** temporality each point reports only the change over its own interval: t=1s → `10`, t=2s → `15` (25−10). Cumulative is resilient to lost data points and is the OTLP default for many exporters; Delta is cheaper to aggregate statelessly but a single lost point loses that increment permanently.

**A3.2** — A Gauge is an **instantaneous, non-additive** measurement (e.g., current temperature or queue depth). There is no interval to accumulate over, so `AggregationTemporality` is undefined, and there is no "start" of an accumulation, so `StartTimestamp` is meaningless. A Sum accumulates over time, so both fields are required to interpret its `Value` (a total *relative to* the start, aggregated *cumulatively or as a delta*).

**A3.3** — Mapping instrument → data type:
- **Counter** (sync) → Sum, monotonic
- **UpDownCounter** (sync) → Sum, non-monotonic
- **Histogram** (sync) → Histogram
- **Gauge** (sync) → Gauge
- **ObservableCounter** (async) → Sum, monotonic
- **ObservableUpDownCounter** (async) → Sum, non-monotonic
- **ObservableGauge** (async) → Gauge

(The synchronous **Gauge** is the most recent addition; older SDKs only had the observable gauge.)

**A3.4** — Bounds `[5, 10, 25, 50, 100]` create six buckets: `(-∞,5], (5,10], (10,25], (25,50], (50,100], (100,+∞)`. Observations `4, 8, 8, 30, 200`:
- `Count = 5`, `Sum = 4+8+8+30+200 = 250`
- `BucketCounts = [1, 2, 0, 1, 0, 1]` → `4`→b0; `8,8`→b1; `30`→b3 `(25,50]`; `200`→**b5**, the `(100,+∞)` overflow bucket.

### Exercise 4

**A4.1** — Severity ranges: **TRACE 1–4, DEBUG 5–8, INFO 9–12, WARN 13–16, ERROR 17–20, FATAL 21–24**. `SeverityNumber` is normalized so that backends can **filter and compare across sources** ("show me ≥ WARN") without parsing every project's idiosyncratic level strings, while `SeverityText` preserves the *original* label from the source for fidelity. Numbers within a class (e.g., 9–12) let a source express relative severity.

**A4.2** — **`Trace ID` and `Span ID`** on the `LogRecord` enable log↔trace correlation. They are populated only if a span was **active in the current context** when the log was emitted (the logging bridge reads the active span). If logs are shipped as plain text, that context is gone — you would have to reverse-engineer correlation from timestamps and message contents, which is unreliable under concurrency.

**A4.3** — They diverge whenever collection is decoupled from emission: e.g., an app writes a log line to a file at 12:00:00 (`Timestamp`), and a file-tailing receiver reads and converts it at 12:00:07 (`ObservedTimestamp`). When investigating an incident you sort by **`Timestamp`** (when the event actually happened); `ObservedTimestamp` is a fallback used only when the real event time is unknown.

### Exercise 5

**A5.1** — **Resource attributes** describe the *entity producing telemetry* (a service instance, host, container) and apply to **every** signal that entity emits, for its whole lifetime. **Span/metric/log attributes** describe a *single* operation or measurement and vary per record. `service.name` is a Resource attribute because it is a property of the producer, constant across all its spans — storing it per-span would be redundant and would prevent the backend from grouping telemetry by service.

**A5.2** — Semantic conventions define **standard names, types, and meanings** for common attributes, so a backend can build cross-service dashboards, service maps, and alerts without per-team mapping. Example: `http.request.method`. If one team called it `method`, another `httpMethod`, and a third `verb`, no backend query could aggregate HTTP traffic across services, and correlation/enrichment features would silently miss data.

**A5.3** — (a) **Baggage** carries user-defined key-value pairs *across* service boundaries via the W3C `baggage` header, so a downstream service can read context (e.g., `tenant.id`, `feature.flag`) set upstream without re-deriving it. (b) The pitfall: **Baggage is not automatically written onto spans as attributes** — you need an explicit processor/code to copy it. Worse, if you *do* blanket-copy Baggage to attributes, you risk (i) propagating **sensitive data** onto every downstream service and into telemetry stores, and (ii) **cost/cardinality blow-ups**. Baggage should be treated as untrusted, unencrypted, and size-bounded.

**A5.4** — If instrumentation does not set `service.name`, the spec defines the fallback value **`unknown_service`** (SDKs often append the process name, e.g., `unknown_service:python`). A missing or duplicated `service.name` breaks the **service map**: telemetry from distinct services collapses into one `unknown_service` node (or a real service is fragmented), making dependency graphs, per-service SLOs, and error attribution meaningless.

</details>