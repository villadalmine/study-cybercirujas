# Topic 2.1 — Data Model — Guided Exercises

> **Goal of this topic.** OpenTelemetry defines telemetry in terms of a *language-agnostic data model*, not in terms of any particular SDK or backend. Every signal — traces, metrics, logs — has a precise structure that survives serialization, and everything is anchored to a **Resource** and produced by an **Instrumentation Scope**. In these exercises you will not *read about* the model — you will materialize it, dump the exact fields the specification defines, and correlate them across signals. By the end you should be able to point at any field in an OTLP payload and say what it is, why it exists, and what invariants it must hold.
>
> **Reference sources (official):**
> - Traces API / SpanContext — https://opentelemetry.io/docs/specs/otel/trace/api/
> - Metrics data model — https://opentelemetry.io/docs/specs/otel/metrics/data-model/
> - Logs data model — https://opentelemetry.io/docs/specs/otel/logs/data-model/
> - Common (attributes) — https://opentelemetry.io/docs/specs/otel/common/
> - Resource SDK — https://opentelemetry.io/docs/specs/otel/resource/sdk/
> - OTLP & proto — https://opentelemetry.io/docs/specs/otlp/ and https://github.com/open-telemetry/opentelemetry-proto

---

## Prerequisites — build the sandbox

You will use the OpenTelemetry Python SDK because its console exporters print the data model verbatim. Later you will use the Collector to see the OTLP wire encoding. No backend (Jaeger, Prometheus…) is required.

**Steps**

1. Create an isolated environment and install the SDK plus the OTLP exporter:

   ```bash
   mkdir otca-datamodel && cd otca-datamodel
   python3.12 -m venv .venv
   source .venv/bin/activate
   pip install \
     'opentelemetry-sdk==1.27.0' \
     'opentelemetry-exporter-otlp-proto-grpc==1.27.0'
   ```

2. Confirm the API and SDK packages resolved to the same version:

   ```bash
   pip list | grep opentelemetry
   ```

   Expected (versions aligned):

   ```
   opentelemetry-api                        1.27.0
   opentelemetry-exporter-otlp-proto-grpc   1.27.0
   opentelemetry-sdk                        1.27.0
   opentelemetry-semantic-conventions       0.48b0
   ```

**Check your understanding**

- **Q1.1** The `opentelemetry-api` and `opentelemetry-sdk` packages are separate. Which one *defines* the data model types you will inspect, and which one *implements* how they are produced and exported?
- **Q1.2** Nothing here installs Jaeger or Prometheus. Why is the data model observable *without* any observability backend at all?

---

## Exercise 1 — Anatomy of a Span

**Steps**

1. Create `span.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.trace import SpanKind

   resource = Resource.create({
       "service.name": "checkout-svc",
       "service.version": "2.4.1",
   })

   provider = TracerProvider(resource=resource)
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)

   # get_tracer(name, version) -> this pair IS the Instrumentation Scope
   tracer = trace.get_tracer("checkout.instrumentation", "0.1.0")

   with tracer.start_as_current_span("checkout", kind=SpanKind.SERVER) as parent:
       parent.set_attribute("cart.item_count", 3)
       parent.set_attribute("cart.currency", "EUR")
       with tracer.start_as_current_span("charge-card", kind=SpanKind.CLIENT) as child:
           child.set_attribute("payment.provider", "stripe")
   ```

2. Run it and pretty-print the first (child) span:

   ```bash
   python span.py
   ```

   Expected output (two JSON documents; the `charge-card` child is emitted first because it ends first, abbreviated):

   ```json
   {
       "name": "charge-card",
       "context": {
           "trace_id": "0x8f3a1c9d2b7e4f60a1b2c3d4e5f60718",
           "span_id": "0x1a2b3c4d5e6f7081",
           "trace_state": "[]"
       },
       "kind": "SpanKind.CLIENT",
       "parent_id": "0x9f8e7d6c5b4a3021",
       "start_time": "2026-08-10T14:03:11.482113Z",
       "end_time":   "2026-08-10T14:03:11.482461Z",
       "status": { "status_code": "UNSET" },
       "attributes": { "payment.provider": "stripe" },
       "events": [],
       "links": [],
       "resource": {
           "attributes": {
               "service.name": "checkout-svc",
               "service.version": "2.4.1",
               "telemetry.sdk.language": "python",
               "telemetry.sdk.name": "opentelemetry",
               "telemetry.sdk.version": "1.27.0"
           },
           "schema_url": ""
       }
   }
   ```

3. Note three identifiers: `trace_id`, `span_id`, and the child's `parent_id`. Count the hex digits in each (ignore the `0x`).

**Check your understanding**

- **Q2.1** Count the hex characters. How many *bytes* is a `trace_id`, and how many is a `span_id`? Which fields of the child span, taken together, form its **SpanContext**?
- **Q2.2** The child's `parent_id` equals the parent's `span_id`, and both spans share the same `trace_id`. Which of these two identifiers defines the *trace*, and which one is unique *per span*?
- **Q2.3** `status_code` is `UNSET` even though nothing failed. What are the three possible `StatusCode` values, and why is `UNSET` — not `OK` — the correct default for a span that completed normally?
- **Q2.4** `SpanKind` is `CLIENT` on the child and `SERVER` on the parent. Name all five span kinds and state which one is the default when you omit `kind=`.
- **Q2.5** You never wrote `telemetry.sdk.*` into the resource, yet they appear. Where did they come from, and does the Resource belong to the *span* or to the *process producing it*?

---

## Exercise 2 — Resource and Instrumentation Scope

**Steps**

1. The Resource is meant to describe *the entity producing telemetry* and is normally left to auto-detection plus environment. Re-run `span.py` with a resource attribute supplied out-of-band:

   ```bash
   OTEL_RESOURCE_ATTRIBUTES="deployment.environment=prod,service.instance.id=pod-7c9" \
     python span.py
   ```

   The `resource.attributes` block now additionally contains:

   ```json
   "deployment.environment": "prod",
   "service.instance.id": "pod-7c9"
   ```

2. Now delete the `service.name` from the `Resource.create({...})` call and remove any env override, then run again. Observe the resource:

   ```json
   "service.name": "unknown_service"
   ```

**Check your understanding**

- **Q3.1** Both spans in Exercise 1 carried an *identical* `resource` block. In the OTLP encoding the Resource is **not** repeated per span. Where is it factored out to (what is the containing message called), and why is that both a size optimization and a semantic statement?
- **Q3.2** `service.name` fell back to `unknown_service` instead of erroring. What does that tell you about whether `service.name` is *required* by the data model, and what is the practical cost of shipping telemetry with the default value?
- **Q3.3** The tracer was obtained with `get_tracer("checkout.instrumentation", "0.1.0")`. That `(name, version)` pair is the **Instrumentation Scope**. How does the Scope differ in *purpose* from the Resource — i.e. what question does each one answer about a given span?

---

## Exercise 3 — Events, Links, and Status

**Steps**

1. Create `span_rich.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor
   from opentelemetry.trace import Status, StatusCode, Link

   provider = TracerProvider()
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("lab")

   # A span whose context we will LINK to from another trace
   with tracer.start_as_current_span("enqueue") as producer:
       enqueue_ctx = producer.get_span_context()

   with tracer.start_as_current_span(
       "process-message",
       links=[Link(enqueue_ctx, attributes={"messaging.operation": "process"})],
   ) as span:
       span.add_event("dequeued", {"queue.depth": 12})
       try:
           raise ValueError("malformed payload")
       except ValueError as exc:
           span.record_exception(exc)
           span.set_status(Status(StatusCode.ERROR, "malformed payload"))
   ```

2. Run it and inspect the `process-message` span:

   ```bash
   python span_rich.py
   ```

   Relevant fields (abbreviated):

   ```json
   "status": { "status_code": "ERROR", "description": "malformed payload" },
   "events": [
       { "name": "dequeued", "timestamp": "...", "attributes": { "queue.depth": 12 } },
       { "name": "exception", "timestamp": "...",
         "attributes": {
             "exception.type": "ValueError",
             "exception.message": "malformed payload",
             "exception.stacktrace": "Traceback (most recent call last): ..."
         }
       }
   ],
   "links": [
       { "context": { "trace_id": "0x...", "span_id": "0x..." },
         "attributes": { "messaging.operation": "process" } }
   ]
   ```

**Check your understanding**

- **Q4.1** An **Event** and a child **Span** are both "something that happened inside this span." What is the structural difference, and which one would you use for an instantaneous point-in-time occurrence versus a nested unit of work that has its own duration?
- **Q4.2** `record_exception()` did *not* set the status to `ERROR` by itself — you called `set_status(...)` separately. What does that tell you about the relationship between recording an exception event and marking the span failed?
- **Q4.3** The `enqueue` span lived in a *different* trace, yet `process-message` references it via a **Link**. In the classic producer/consumer (queue) pattern, why is a Link — rather than a normal parent/child relationship — the correct data-model construct?
- **Q4.4** Every Event carries its own `timestamp`, and it falls *between* the span's `start_time` and `end_time`. Why must an Event's timestamp be independent of the span's start, rather than an offset the reader computes?

---

## Exercise 4 — The Metrics data model: Sum, Gauge, Histogram

**Steps**

1. Create `metrics.py`:

   ```python
   from opentelemetry import metrics
   from opentelemetry.sdk.metrics import MeterProvider
   from opentelemetry.sdk.metrics.export import (
       ConsoleMetricExporter, PeriodicExportingMetricReader,
   )

   reader = PeriodicExportingMetricReader(
       ConsoleMetricExporter(), export_interval_millis=2000,
   )
   metrics.set_meter_provider(MeterProvider(metric_readers=[reader]))
   meter = metrics.get_meter("lab")

   requests = meter.create_counter(
       "http.server.request.count", unit="{request}",
       description="Total inbound requests",
   )
   in_flight = meter.create_up_down_counter(
       "http.server.active_requests", unit="{request}",
   )
   duration = meter.create_histogram(
       "http.server.request.duration", unit="ms",
   )

   for ms in (23.0, 57.0, 512.0):
       requests.add(1, {"http.route": "/checkout", "http.response.status_code": 200})
       in_flight.add(1);  duration.record(ms, {"http.route": "/checkout"});  in_flight.add(-1)

   import time; time.sleep(3)   # let the periodic reader flush once
   ```

2. Run it and read the three metric shapes:

   ```bash
   python metrics.py
   ```

   Abbreviated output (one `ScopeMetrics` block containing three metrics):

   ```
   Metric(name='http.server.request.count', unit='{request}', data=Sum(
       aggregation_temporality=AggregationTemporality.CUMULATIVE,
       is_monotonic=True,
       data_points=[NumberDataPoint(attributes={'http.route':'/checkout',
           'http.response.status_code':200}, start_time_unix_nano=..., time_unix_nano=...,
           value=3)]))

   Metric(name='http.server.active_requests', data=Sum(
       aggregation_temporality=AggregationTemporality.CUMULATIVE,
       is_monotonic=False,
       data_points=[NumberDataPoint(..., value=0)]))

   Metric(name='http.server.request.duration', unit='ms', data=Histogram(
       aggregation_temporality=AggregationTemporality.CUMULATIVE,
       data_points=[HistogramDataPoint(count=3, sum=592.0, min=23.0, max=512.0,
           bucket_counts=[0,0,1,1,0,0,0,0,0,0,1,0,0,0,0,0],
           explicit_bounds=[0,5,10,25,50,75,100,250,500,750,1000,2500,5000,7500,10000])]))
   ```

**Check your understanding**

- **Q5.1** A `Counter` produced a `Sum` with `is_monotonic=True`; an `UpDownCounter` produced a `Sum` with `is_monotonic=False`. What does `is_monotonic` promise a backend it may assume, and why is "active requests" *not* allowed to make that promise?
- **Q5.2** The counter's value is `3` and the up/down counter's value is `0`. You called `.add()` on both. In the data model, what is the essential difference between the *instrument* (Counter) and the *metric point* (Sum) — i.e. which one you interact with in code, and which one appears on the wire?
- **Q5.3** The Histogram data point carries `count`, `sum`, `min`, `max`, `bucket_counts`, and `explicit_bounds`. Given a request of 57 ms and bounds `[…50,75…]`, into which bucket does it fall, and why does a Histogram store *bucket counts* rather than the individual 23/57/512 measurements?
- **Q5.4** A `Gauge` is the fourth point type you did not emit here (it comes from an *asynchronous/observable* gauge). Unlike a `Sum`, a `Gauge` has **no** `aggregation_temporality` field. Why is temporality meaningless for a gauge?

---

## Exercise 5 — Aggregation temporality: cumulative vs delta

**Steps**

1. Copy `metrics.py` to `metrics_delta.py` and change only the exporter construction to prefer **delta** temporality for sums and histograms:

   ```python
   from opentelemetry.sdk.metrics.export import AggregationTemporality
   from opentelemetry.sdk.metrics import Counter, UpDownCounter, Histogram

   delta = {
       Counter: AggregationTemporality.DELTA,
       UpDownCounter: AggregationTemporality.CUMULATIVE,   # up/down stays cumulative
       Histogram: AggregationTemporality.DELTA,
   }
   reader = PeriodicExportingMetricReader(
       ConsoleMetricExporter(preferred_temporality=delta),
       export_interval_millis=2000,
   )
   ```

2. Wrap the record loop so it runs across **two** export intervals:

   ```python
   for cycle in range(2):
       for ms in (23.0, 57.0, 512.0):
           requests.add(1, {"http.route": "/checkout"})
           duration.record(ms, {"http.route": "/checkout"})
       time.sleep(2.5)   # force a flush between cycles
   ```

3. Run it and compare the counter's `value` in the *first* exported batch versus the *second*:

   ```bash
   python metrics_delta.py
   ```

   Under **delta**, each batch reports only what happened *in that interval*:

   ```
   # first flush
   Sum(aggregation_temporality=DELTA, is_monotonic=True,
       data_points=[NumberDataPoint(start_time_unix_nano=T0, time_unix_nano=T1, value=3)])
   # second flush
   Sum(aggregation_temporality=DELTA, is_monotonic=True,
       data_points=[NumberDataPoint(start_time_unix_nano=T1, time_unix_nano=T2, value=3)])
   ```

   Re-run the original `metrics.py` (cumulative) with the same two-cycle loop and you will instead see `value=3` then `value=6`.

**Check your understanding**

- **Q6.1** Delta reported `3` then `3`; cumulative reported `3` then `6`. State the definition of each temporality in one sentence each, in terms of *what the reported value is measured relative to*.
- **Q6.2** Notice that under delta the second point's `start_time_unix_nano` (`T1`) equals the first point's `time_unix_nano`. Why do delta points form an *adjacent, non-overlapping* time window, and what would double-counting look like if two exporters both re-emitted the same window?
- **Q6.3** Prometheus scrapes cumulative counters; many push-based systems prefer delta. Given that the SDK can convert cumulative → delta but converting delta → cumulative requires *stateful* memory of every series, which temporality is the safer default to emit from the SDK, and why?

---

## Exercise 6 — The Logs data model and trace correlation

**Steps**

1. Create `logs.py` (the Logs SDK lives under `_logs` because the API is still stabilizing — that is expected):

   ```python
   import logging
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
   from opentelemetry.sdk._logs.export import ConsoleLogExporter, SimpleLogRecordProcessor

   trace.set_tracer_provider(TracerProvider())
   tracer = trace.get_tracer("lab")

   lp = LoggerProvider()
   lp.add_log_record_processor(SimpleLogRecordProcessor(ConsoleLogExporter()))
   logging.getLogger().addHandler(LoggingHandler(logger_provider=lp))
   logging.getLogger().setLevel(logging.INFO)
   log = logging.getLogger("orders")

   log.info("startup complete")                       # emitted OUTSIDE any span
   with tracer.start_as_current_span("place-order"):
       log.warning("inventory low for sku=%s", "A-19")  # emitted INSIDE a span
   ```

2. Run and compare the two emitted `LogRecord`s:

   ```bash
   python logs.py
   ```

   Abbreviated (the second record is correlated to the active span):

   ```json
   {
     "body": "startup complete",
     "severity_text": "INFO", "severity_number": 9,
     "trace_id": "0x00000000000000000000000000000000",
     "span_id": "0x0000000000000000",
     "attributes": {},
     "observed_timestamp": "..."
   }
   {
     "body": "inventory low for sku=A-19",
     "severity_text": "WARN", "severity_number": 13,
     "trace_id": "0x8f3a1c9d2b7e4f60a1b2c3d4e5f60718",
     "span_id": "0x1a2b3c4d5e6f7081",
     "attributes": { "code.filepath": "logs.py", "code.lineno": 15 }
   }
   ```

**Check your understanding**

- **Q7.1** The first record's `trace_id`/`span_id` are all zeros; the second carries the enclosing span's IDs. What in the data model makes a `LogRecord` "belong" to a trace, and why is that correlation *automatic* here rather than something you hand-wrote into the message?
- **Q7.2** `INFO` mapped to `severity_number=9` and `WARN` to `13`. The spec defines `SeverityNumber` on a `1–24` scale. What is the point of a *numeric* severity in addition to `severity_text`, given that two systems might spell the same level `"WARN"` vs `"WARNING"`?
- **Q7.3** A `LogRecord` has **both** a `timestamp` and an `observed_timestamp`. When would these differ, and which one is guaranteed to be present even for a log the pipeline picked up from a file with no embedded time?
- **Q7.4** The `body` here is a plain string, but the data model types it as an *any-value*. What does that allow a structured log to carry that a line of text cannot, and how does that overlap with (yet stay distinct from) the record's `attributes`?

---

## Exercise 7 — The OTLP wire format via the Collector

Everything above was the *in-memory* model. OTLP is how it crosses the network. You will send real spans to a Collector and read the decoded payload.

**Steps**

1. Write `collector.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
   exporters:
     debug:
       verbosity: detailed
   service:
     pipelines:
       traces:
         receivers: [otlp]
         exporters: [debug]
   ```

2. Run the Collector:

   ```bash
   docker run --rm -p 4317:4317 \
     -v "$(pwd)/collector.yaml":/etc/otelcol-contrib/config.yaml \
     otel/opentelemetry-collector-contrib:0.108.0
   ```

3. In the venv, send spans over OTLP/gRPC instead of the console:

   ```python
   # otlp_send.py
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

   provider = TracerProvider(resource=Resource.create({"service.name": "checkout-svc"}))
   provider.add_span_processor(BatchSpanProcessor(
       OTLPSpanExporter(endpoint="http://localhost:4317", insecure=True)))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("checkout.instrumentation", "0.1.0")

   with tracer.start_as_current_span("checkout"):
       with tracer.start_as_current_span("charge-card"):
           pass
   provider.shutdown()   # flush the batch
   ```

   ```bash
   python otlp_send.py
   ```

4. Read the Collector's `debug` output. Note the **three levels of nesting**:

   ```
   ResourceSpans #0
   Resource attributes:
        -> service.name: Str(checkout-svc)
   ScopeSpans #0
   ScopeSpans[0].Scope: checkout.instrumentation 0.1.0
       Span #0
           Trace ID       : 8f3a1c9d2b7e4f60a1b2c3d4e5f60718
           Parent ID      :
           ID             : 9f8e7d6c5b4a3021
           Name           : checkout
           Kind           : Internal
           Start time     : 2026-08-10 14:20:01.1 +0000 UTC
           End time       : 2026-08-10 14:20:01.1 +0000 UTC
           Status code    : Unset
       Span #1
           Trace ID       : 8f3a1c9d2b7e4f60a1b2c3d4e5f60718
           Parent ID      : 9f8e7d6c5b4a3021
           ID             : 1a2b3c4d5e6f7081
           Name           : charge-card
   ```

**Check your understanding**

- **Q8.1** The payload is `ResourceSpans → ScopeSpans → Span`, three levels deep. Map each level back to the three "anchors" you met earlier (Resource, Instrumentation Scope, Span). Why is this hierarchy a *deduplication* of exactly the fields that repeat across many spans?
- **Q8.2** On the wire the `Trace ID` prints as bare hex with **no** `0x` and the `Start time` is a human string — but the OTLP protobuf actually encodes them as a 16-byte `bytes` field and a `fixed64` nanosecond count. Why does the binary model avoid strings for IDs and timestamps, and what would you lose by transmitting `"8f3a…"` as text?
- **Q8.3** You switched from `SimpleSpanProcessor`+`ConsoleSpanExporter` to `BatchSpanProcessor`+`OTLPSpanExporter`, and you had to call `provider.shutdown()` to see output. The *data model of each span is byte-for-byte identical* to Exercise 1. What does that prove about the relationship between the data model and the transport/exporter that carries it?
- **Q8.4** The metrics pipeline has `ResourceMetrics → ScopeMetrics → Metric → data_points`, and logs have `ResourceLogs → ScopeLogs → LogRecord`. State the single structural pattern all three signals share, and why that uniformity is what lets one Collector pipeline handle all of them.

---

<details>
<summary><strong>Answers</strong></summary>

**Prerequisites**

- **A1.1** The **API** package (`opentelemetry-api`) *defines* the types and interfaces — `Span`, `SpanContext`, `SpanKind`, the instrument interfaces, `SeverityNumber`, etc. — as a stable contract. The **SDK** (`opentelemetry-sdk`) *implements* the production, sampling, aggregation and export of those types. Instrumentation depends only on the API; the application wires in the SDK. This split is itself a data-model principle: the shape of telemetry is fixed independently of who produces or ships it.
- **A1.2** Because the data model is *serialization-* and *backend-agnostic*. A backend is just one possible consumer of an OTLP payload. The console exporters emit the same structured objects that would otherwise be encoded to OTLP and sent onward, so the model is fully observable with nothing downstream.

**Exercise 1 — Span**

- **A2.1** `trace_id` is **32 hex chars = 16 bytes = 128 bits**; `span_id` is **16 hex chars = 8 bytes = 64 bits**. The **SpanContext** is the immutable, propagatable tuple `{trace_id, span_id, trace_flags, trace_state}` — the identity of the span that travels across process boundaries (it does *not* include the name, attributes, or timing).
- **A2.2** `trace_id` defines the **trace** and is shared by every span in it; `span_id` is **unique per span**. A child references its parent by copying the parent's `span_id` into its own `parent_id`.
- **A2.3** The three values are **`UNSET`, `OK`, `ERROR`**. `UNSET` is the default because a normally-completed span should *not* assert success. `OK` is reserved for when application code explicitly decides the operation succeeded (overriding any downstream interpretation); leaving it `UNSET` lets backends and instrumentation apply their own error heuristics. Defaulting to `OK` would suppress that.
- **A2.4** The five kinds are **`INTERNAL`, `SERVER`, `CLIENT`, `PRODUCER`, `CONSUMER`**. **`INTERNAL`** is the default when `kind=` is omitted.
- **A2.5** They were injected by the **SDK's default resource detector**. The Resource describes **the process/entity producing the telemetry**, not any individual span — which is exactly why it is identical across every span from that process and is factored out in OTLP.

**Exercise 2 — Resource & Scope**

- **A3.1** It is hoisted into the enclosing **`ResourceSpans`** message (and `ResourceMetrics`/`ResourceLogs` for the other signals). It is a size optimization (one copy per batch instead of per span) *and* a semantic statement: every span underneath shares one producing entity.
- **A3.2** `service.name` is **required** by the data model — so required that the SDK synthesizes `unknown_service` rather than omit it. The practical cost is that all such telemetry collapses into one unnamed service in the backend, destroying per-service grouping, dashboards, and alerts.
- **A3.3** The **Resource** answers *"what entity produced this?"* (service, host, pod, environment). The **Instrumentation Scope** answers *"which instrumentation library/module emitted this?"* (its name and version). One identifies the runtime source; the other identifies the code path that created the signal — useful for attributing bugs or version-specific behavior to a particular instrumentation.

**Exercise 3 — Events, Links, Status**

- **A4.1** An **Event** is a *timestamped annotation with a name and attributes but no duration* embedded in the span; a child **Span** is a *separately-identified unit of work with its own start/end, context, and status*. Use an Event for an instantaneous occurrence ("cache miss", "exception"); use a child Span for nested work that has measurable duration.
- **A4.2** They are **orthogonal**. `record_exception()` adds an `exception` *event* to the span (type/message/stacktrace), which is a factual record; it does **not** change the span's outcome. Marking the span failed is a separate, deliberate act via `set_status(ERROR, …)`. A caught-and-handled exception can legitimately leave the span `UNSET`/`OK`.
- **A4.3** In a queue, the consumer runs *asynchronously and possibly long after* the producer, and one message may be batched with others — there is no synchronous parent/child call relationship. A **Link** expresses a causal association between spans in *different traces* without forcing them into one parent/child chain, which is precisely the producer→consumer (and fan-in batch) case.
- **A4.4** Because an Event marks a *real wall-clock instant* that must be comparable across spans, services, and clocks — not a relative position inside one span. Storing it as an offset would make it meaningless once the span is split from its context, re-timed, or correlated with events from other spans.

**Exercise 4 — Metric point types**

- **A5.1** `is_monotonic=True` promises the value **only ever increases (resets to 0 on restart)**, so a backend may compute rates and assume any decrease is a counter reset. "Active requests" goes up *and* down, so it cannot make that promise; asserting monotonicity would make a legitimate decrease look like a reset and corrupt rate math.
- **A5.2** The **instrument** (`Counter`, `UpDownCounter`, `Histogram`) is the API object you call `.add()`/`.record()` on. The **metric point** (`Sum`, `Histogram`, …) is the *aggregated result* the SDK produces and puts on the wire. Many instrument calls collapse into one aggregated data point per series per interval. You program against instruments; backends receive points.
- **A5.3** 57 falls into the bucket bounded by `(50, 75]`. A Histogram stores **pre-aggregated bucket counts** (plus count/sum/min/max) so that arbitrarily many measurements compress to a fixed, mergeable structure — you can aggregate across instances and time and estimate quantiles without transmitting or storing every raw sample.
- **A5.4** A **Gauge** is an *instantaneous last-value* reading (e.g. current temperature, current memory). "Change since start" vs "change since last export" is nonsensical for a value that isn't accumulated — there is nothing to accumulate, so temporality does not apply.

**Exercise 5 — Temporality**

- **A6.1** **Cumulative**: the value is measured *relative to a fixed start time* (`start_time_unix_nano` stays constant), so it grows monotonically. **Delta**: the value is measured *relative to the previous export*, i.e. only what happened in this interval, and the start time advances each interval.
- **A6.2** Delta points are defined over `[start_time_unix_nano, time_unix_nano)`, and the next point's start equals this point's end — adjacent, non-overlapping windows that tile time exactly once. If two exporters both re-emitted the same window, the backend would **sum overlapping intervals** and double-count that traffic.
- **A6.3** **Cumulative** is the safer SDK default. Cumulative→delta conversion is a cheap stateless subtraction downstream, but delta→cumulative requires the pipeline to *remember running totals for every series* and survive restarts — stateful, memory-hungry, and lossy on gaps. Emitting cumulative keeps that burden out of the SDK.

**Exercise 6 — Logs**

- **A7.1** A `LogRecord` "belongs" to a trace when it carries a non-zero **`trace_id`/`span_id`** (and `trace_flags`). The correlation is automatic because the `LoggingHandler` reads the **active span from the current context** at emit time and stamps those IDs onto the record — the same context that parents spans also parents logs.
- **A7.2** The numeric `SeverityNumber` (1–24) is the **normalized, comparable** severity: you can range-query `>= 17` (all errors) regardless of how each source spells its text. `severity_text` preserves the *original* label for fidelity, but it is free-form and not reliably ordered; the number is what backends filter and alert on.
- **A7.3** `timestamp` is *when the event actually occurred* (may be absent if unknown); `observed_timestamp` is *when the telemetry pipeline observed/collected the record*. They differ when a log is read late from a file or queue. **`observed_timestamp`** is always present — the collector sets it even when the record has no embedded time.
- **A7.4** An any-value `body` can carry a **structured payload** (map, array, typed scalar), not just text — so a JSON log stays structured end-to-end. It overlaps with `attributes` in that both hold structured data, but they are distinct in intent: `body` is *the message/content itself*, while `attributes` are *metadata describing the record* (source file, http fields, etc.) meant for indexing and filtering.

**Exercise 7 — OTLP**

- **A8.1** `ResourceSpans` = the **Resource** (producing entity), `ScopeSpans` = the **Instrumentation Scope** (emitting library), `Span` = the individual span. The nesting deduplicates exactly the two anchors that are identical across many spans, so a batch of 10 000 spans from one service/library carries the Resource and Scope **once each** rather than 10 000 times.
- **A8.2** IDs are `bytes` and timestamps are `fixed64` nanoseconds because that is **compact and unambiguous**: 16 raw bytes vs 32 text chars, no case/`0x`/encoding variance, and integer times sort and diff without parsing. Transmitting them as strings doubles the size and reintroduces formatting ambiguity and parse cost.
- **A8.3** It proves the **data model is independent of the exporter and transport**. `Simple`/`Batch` processors and console/OTLP exporters change *when and how* spans are buffered and serialized, but the span's fields are identical. Transport is a carrier; the model is the payload.
- **A8.4** All three follow **`Resource<Signal> → Scope<Signal> → <SignalItem>`** — a uniform two-level anchoring of every signal under a shared Resource and Scope. That uniformity is why one Collector receiver/pipeline can ingest, process, and route traces, metrics, and logs through the same structural machinery.

</details>