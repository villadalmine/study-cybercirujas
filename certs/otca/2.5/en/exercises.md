# OTCA 2.5 — SDK Pipelines · Guided Exercises

> **Domain weight:** 6.57% · **Exam:** OpenTelemetry Certified Associate (OTCA)
> **Reference syllabus:** [CNCF OTCA Curriculum](https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf)
> **Primary sources:** [SDK spec — Trace](https://opentelemetry.io/docs/specs/otel/trace/sdk/) · [SDK spec — Metrics](https://opentelemetry.io/docs/specs/otel/metrics/sdk/) · [SDK spec — Logs](https://opentelemetry.io/docs/specs/otel/logs/sdk/) · [SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/) · [Python SDK](https://opentelemetry.io/docs/languages/python/)

A **pipeline** is the path a signal takes from your instrumentation to a backend, *inside the process*, before any network hop:

```
                        ┌──────────────── Provider ────────────────┐
  API (get_tracer) ───► │  Sampler → [ Processor → Processor ] ───► Exporter ──► wire (OTLP/…)
                        └───────────────────────────────────────────┘
                                Resource is attached to every record
```

Each signal has its own provider and its own pipeline vocabulary, but the shape is identical:

| Signal | Provider | Stage that batches/hooks | Terminal stage |
|---|---|---|---|
| Traces | `TracerProvider` | `SpanProcessor` (Simple / Batch) | `SpanExporter` |
| Metrics | `MeterProvider` | `MetricReader` (Periodic / Manual) | `MetricExporter` |
| Logs | `LoggerProvider` | `LogRecordProcessor` (Simple / Batch) | `LogRecordExporter` |

These labs use the **opentelemetry-python** SDK because it exposes every pipeline stage as an explicit object you can wire by hand — the exam tests the *concepts*, and building them manually makes the concepts concrete.

### Prerequisites (run once)

```bash
python3 -m venv .otca && source .otca/bin/activate
pip install \
  'opentelemetry-api==1.27.0' \
  'opentelemetry-sdk==1.27.0' \
  'opentelemetry-exporter-otlp-proto-grpc==1.27.0'
python3 -c "import opentelemetry.sdk; print('sdk ready')"
```

Expected:

```
sdk ready
```

---

## Exercise 1 — Anatomy of a trace pipeline

**Goal:** build a `TracerProvider → SpanProcessor → SpanExporter` chain by hand and read a raw exported span.

1. Create `ex1_pipeline.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import (
       SimpleSpanProcessor,
       ConsoleSpanExporter,
   )

   # 1. Resource: identity attached to EVERY span this provider emits
   resource = Resource.create({"service.name": "pipeline-lab", "service.version": "1.0.0"})

   # 2. Provider: owns the sampler + the ordered list of processors
   provider = TracerProvider(resource=resource)

   # 3. Processor -> Exporter: the two pipeline stages
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))

   # 4. Register globally so trace.get_tracer() returns THIS provider
   trace.set_tracer_provider(provider)

   tracer = trace.get_tracer("otca.ex1")
   with tracer.start_as_current_span("checkout") as span:
       span.set_attribute("cart.items", 3)
       with tracer.start_as_current_span("charge-card"):
           pass

   provider.shutdown()   # flush + close the pipeline cleanly
   ```

2. Run it:

   ```bash
   python3 ex1_pipeline.py
   ```

3. Read the output. Two spans print, **child first** (spans export on `end`, and the child ends before the parent). Abridged:

   ```json
   {
       "name": "charge-card",
       "context": { "trace_id": "0x8f2c…", "span_id": "0x41a…", "trace_state": "[]" },
       "kind": "SpanKind.INTERNAL",
       "parent_id": "0x9b7…",
       "status": { "status_code": "UNSET" },
       "attributes": {},
       "resource": { "attributes": { "service.name": "pipeline-lab", "service.version": "1.0.0", "telemetry.sdk.language": "python", … } }
   }
   {
       "name": "checkout",
       "context": { "trace_id": "0x8f2c…", "span_id": "0x9b7…", "trace_state": "[]" },
       "parent_id": null,
       "attributes": { "cart.items": 3 },
       "resource": { … }
   }
   ```

4. Comment out line 4 (`trace.set_tracer_provider(provider)`) and re-run.

**Comprehension check:**

- **Q1.1** In what order do the four stages a span passes through execute, from `span.end()` to stdout?
- **Q1.2** Both spans share the same `trace_id` but different `span_id`, and the parent's `parent_id` is `null`. What does that tell you about who is the root of the trace?
- **Q1.3** The `service.name` you set once on the `Resource` appears on *both* spans. Which pipeline stage is responsible for attaching the resource, and why is it wrong to think of resource as "an attribute you set per span"?
- **Q1.4** With line 4 commented out, no spans print even though the code runs without error. Where did the spans go?

---

## Exercise 2 — SimpleSpanProcessor vs BatchSpanProcessor

**Goal:** observe the behavioural difference between the two built-in processors and understand the queue.

1. Create `ex2_batch.py`:

   ```python
   import time
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter

   provider = TracerProvider()
   provider.add_span_processor(
       BatchSpanProcessor(
           ConsoleSpanExporter(),
           max_queue_size=2048,
           max_export_batch_size=512,
           schedule_delay_millis=5000,   # flush every 5s…
       )
   )
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.ex2")

   for i in range(3):
       with tracer.start_as_current_span(f"job-{i}"):
           pass
   print(">>> 3 spans ended, watch the clock <<<", flush=True)

   time.sleep(6)   # …so nothing prints until ~5s pass
   print(">>> woke up <<<", flush=True)
   provider.shutdown()
   ```

2. Run and watch *when* text appears:

   ```bash
   python3 ex2_batch.py
   ```

   Expected timeline:

   ```
   >>> 3 spans ended, watch the clock <<<
   ( ~5 seconds of silence )
   { "name": "job-0", … }
   { "name": "job-1", … }
   { "name": "job-2", … }
   >>> woke up <<<
   ```

3. Swap `BatchSpanProcessor(...)` for `SimpleSpanProcessor(ConsoleSpanExporter())` and re-run. Now each span prints **immediately** as its span ends, *before* `">>> 3 spans ended"`.

4. Force an early flush: put this line right after the loop in the Batch version and re-run:

   ```python
   provider.force_flush()   # export now, don't wait for schedule_delay
   ```

**Comprehension check:**

- **Q2.1** With `BatchSpanProcessor`, why did the three spans stay invisible for ~5 seconds even though they had already ended?
- **Q2.2** `SimpleSpanProcessor` exports synchronously on every `span.end()`. Name one production risk this creates that `BatchSpanProcessor` is specifically designed to avoid.
- **Q2.3** A service emits spans faster than the exporter can ship them and `max_queue_size` (2048) fills up. What does `BatchSpanProcessor` do with new spans — block the application thread, or drop them? What does that imply about telemetry vs. request latency?
- **Q2.4** Which two things does `shutdown()` guarantee that simply letting the process exit does not?

---

## Exercise 3 — Sampling: the pipeline's first gate

**Goal:** place a `Sampler` on the provider and prove it decides *before* processors run.

1. Create `ex3_sampler.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import SimpleSpanProcessor, ConsoleSpanExporter
   from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased

   # Sample ~50% of ROOT traces; children follow their parent's decision
   sampler = ParentBased(root=TraceIdRatioBased(0.5))

   provider = TracerProvider(sampler=sampler)
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.ex3")

   sampled = 0
   for i in range(20):
       with tracer.start_as_current_span(f"req-{i}") as span:
           if span.get_span_context().trace_flags.sampled:
               sampled += 1
   print(f"\n>>> {sampled}/20 root spans were sampled <<<")
   provider.shutdown()
   ```

2. Run it a few times:

   ```bash
   python3 ex3_sampler.py 2>/dev/null | tail -1
   ```

   Expected (varies run to run, but near half):

   ```
   >>> 11/20 root spans were sampled <<<
   ```

3. Set the ratio to `TraceIdRatioBased(0.0)` and re-run. Count the printed span JSON blocks.

4. Now the exam's favourite subtlety — change the root to force **all** sampled but keep `ParentBased`:

   ```python
   from opentelemetry.sdk.trace.sampling import ALWAYS_ON
   sampler = ParentBased(root=ALWAYS_ON)
   ```

   Then imagine an incoming request whose parent context arrives with `sampled=false`.

**Comprehension check:**

- **Q3.1** With `TraceIdRatioBased(0.0)`, how many span JSON blocks print, and does the `for` loop body still execute? What does that reveal about the difference between *"a span exists in code"* and *"a span is recorded/exported"*?
- **Q3.2** Why does sampling belong on the **provider** (before processors) rather than being a filter inside a `SpanProcessor`? What would you lose by sampling later in the pipeline?
- **Q3.3** In `ParentBased(root=ALWAYS_ON)`, an upstream service sends a context with `sampled=false`. Does your service record the child span? Why is `ParentBased` the recommended default for keeping traces *whole* across services?
- **Q3.4** `TraceIdRatioBased` decides using the trace-id, not a coin flip. Why is deriving the decision from the trace-id essential for consistent sampling across independently-deployed services?

---

## Exercise 4 — Fan-out: many processors, many destinations

**Goal:** show that a provider holds an *ordered list* of processors and can ship the same span to several backends.

1. Create `ex4_fanout.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import (
       BatchSpanProcessor, SimpleSpanProcessor, ConsoleSpanExporter,
   )
   from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

   provider = TracerProvider()

   # Destination A: local debugging tap (synchronous, human-readable)
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))

   # Destination B: real backend via OTLP over gRPC (batched, resilient)
   provider.add_span_processor(
       BatchSpanProcessor(OTLPSpanExporter(endpoint="http://localhost:4317", insecure=True))
   )

   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.ex4")
   with tracer.start_as_current_span("fan-out-demo"):
       pass
   provider.shutdown()
   ```

2. Run **without** a Collector listening on 4317:

   ```bash
   python3 ex4_fanout.py
   ```

   The Console tap still prints its span. The OTLP processor logs a connection failure but does **not** crash your app:

   ```
   { "name": "fan-out-demo", … }
   Transient error StatusCode.UNAVAILABLE encountered while exporting … retrying in 1s.
   Failed to export … to localhost:4317, error code: StatusCode.UNAVAILABLE
   ```

3. (Optional) Start a Collector and re-run to see the OTLP path succeed:

   ```bash
   docker run --rm -p 4317:4317 otel/opentelemetry-collector:0.109.0
   ```

**Comprehension check:**

- **Q4.1** One `start_as_current_span("fan-out-demo")` produced output on two destinations. How many `SpanProcessor` instances did the span traverse, and were they given the *same* span object or copies?
- **Q4.2** The Console span appeared even though OTLP was down. What property of the processor list guarantees that one failing exporter cannot silence another?
- **Q4.3** You want *every* span on the console but only a *sampled* subset shipped to a costly backend. Sampling lives on the provider and affects all processors equally — so a per-processor sampler is not available here. Name one legitimate mechanism (outside the SDK's built-in span pipeline) that *can* apply different retention to different destinations.
- **Q4.4** Why is `ConsoleSpanExporter` paired with `SimpleSpanProcessor` here, but `OTLPSpanExporter` paired with `BatchSpanProcessor`? Match each processor to the exporter's cost profile.

---

## Exercise 5 — The metrics pipeline is *pull-shaped*

**Goal:** build `MeterProvider → MetricReader → MetricExporter` and see why metrics batch on a **timer the reader owns**, not on instrument calls.

1. Create `ex5_metrics.py`:

   ```python
   import time
   from opentelemetry import metrics
   from opentelemetry.sdk.metrics import MeterProvider
   from opentelemetry.sdk.metrics.export import (
       PeriodicExportingMetricReader, ConsoleMetricExporter,
   )

   reader = PeriodicExportingMetricReader(
       ConsoleMetricExporter(),
       export_interval_millis=3000,   # reader COLLECTS+EXPORTS every 3s
   )
   provider = MeterProvider(metric_readers=[reader])
   metrics.set_meter_provider(provider)

   meter = metrics.get_meter("otca.ex5")
   requests = meter.create_counter("http.server.requests", unit="{request}")

   for i in range(5):
       requests.add(1, {"http.route": "/health", "http.status_code": 200})
       time.sleep(1)

   provider.shutdown()   # forces a final collect+export
   ```

2. Run it:

   ```bash
   python3 ex5_metrics.py
   ```

   Expected — output appears on the **reader's 3s cadence**, and the counter is **cumulative**:

   ```json
   {
     "resource_metrics": [{
       "scope_metrics": [{
         "scope": { "name": "otca.ex5" },
         "metrics": [{
           "name": "http.server.requests",
           "sum": {
             "data_points": [{
               "attributes": { "http.route": "/health", "http.status_code": 200 },
               "value": 3,
               "is_monotonic": true,
               "aggregation_temporality": 2
             }],
           }
         }]
       }]
     }]
   }
   ```

   (~3s later, the same series reports `"value": 5` — the accumulated total.)

3. Switch to delta temporality via environment variable and re-run:

   ```bash
   OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta python3 ex5_metrics.py
   ```

   Now each export reports only the increment *since the previous collection*, not the running total.

**Comprehension check:**

- **Q5.1** You called `requests.add(1, …)` five separate times, yet far fewer than five export blocks printed. Why? Which component decided *when* to export — the instrument or the reader?
- **Q5.2** In the default run, the value climbed 3 → 5 across exports. Under `aggregation_temporality: 2` (**cumulative**), what does the number `5` represent, and why is cumulative resilient to a single dropped export?
- **Q5.3** After setting the delta preference, two successive exports for the same series might read `3` then `2`. What does each number now mean, and what must the *backend* do that it didn't have to do under cumulative?
- **Q5.4** A trace pipeline has a `SpanProcessor` between provider and exporter; the metric pipeline has a `MetricReader` in the analogous slot. Why is "reader" the correct word — what does it *pull* that a span processor never does?

---

## Exercise 6 — The logs pipeline and the bridge

**Goal:** wire `LoggerProvider → LogRecordProcessor → LogRecordExporter` and bridge the language's native logging into it.

> The Python logs SDK still lives under the `_logs` namespace because the Logs API is younger than Traces/Metrics. Cite: [Logs SDK spec](https://opentelemetry.io/docs/specs/otel/logs/sdk/).

1. Create `ex6_logs.py`:

   ```python
   import logging
   from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
   from opentelemetry.sdk._logs.export import (
       BatchLogRecordProcessor, ConsoleLogExporter,
   )
   from opentelemetry.sdk.resources import Resource

   provider = LoggerProvider(resource=Resource.create({"service.name": "log-lab"}))
   provider.add_log_record_processor(BatchLogRecordProcessor(ConsoleLogExporter()))

   # The BRIDGE: route stdlib logging records into the OTel pipeline
   handler = LoggingHandler(level=logging.NOTSET, logger_provider=provider)
   logging.getLogger().addHandler(handler)
   logging.getLogger().setLevel(logging.INFO)

   log = logging.getLogger("payments")
   log.info("charge accepted", extra={"order.id": "A-91"})
   log.warning("retrying gateway")

   provider.shutdown()
   ```

2. Run it:

   ```bash
   python3 ex6_logs.py
   ```

   Expected (abridged) — each stdlib record now carries an OTel `resource` and severity:

   ```json
   {
     "body": "charge accepted",
     "severity_text": "INFO",
     "severity_number": 9,
     "attributes": { "order.id": "A-91", "code.function": "<module>" },
     "resource": { "attributes": { "service.name": "log-lab", … } },
     "trace_id": "0x00000000000000000000000000000000"
   }
   ```

3. Wrap the two log calls inside an active span (reuse Exercise 1's tracer setup in the same file) and re-run. Observe that `trace_id` / `span_id` on the log record become **non-zero**.

**Comprehension check:**

- **Q6.1** You never called an OpenTelemetry logging method — you called stdlib `log.info(...)`. Which single object made those records flow into the OTel pipeline, and what is the general name for this kind of component?
- **Q6.2** In step 2 the log record's `trace_id` is all zeros; in step 3 it is populated. What did the log pipeline read from ambient state, and why is that automatic correlation the headline reason to run logs *through* the SDK instead of writing JSON to stdout yourself?
- **Q6.3** `severity_text: "INFO"` maps to `severity_number: 9`. Why does OTel carry a numeric severity *alongside* the text one — what does the number let a backend do across heterogeneous log sources?
- **Q6.4** All three signals used a `BatchLogRecordProcessor` / `BatchSpanProcessor`. State the one architectural rule this repetition reveals about how the SDK is designed across signals.

---

## Exercise 7 — Configure the whole pipeline with zero code changes

**Goal:** drive sampler, exporter, batching and endpoint entirely through the standard environment variables — the exam expects you to recognize these names.

> Cite: [SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/).

1. Create `ex7_env.py` — note it hard-codes **nothing** about sampling or batching:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
   from opentelemetry.sdk.trace.sampling import ParentBasedTraceIdRatio
   import os

   # Read the standard vars the SDK defines (shown explicitly for teaching)
   ratio = float(os.getenv("OTEL_TRACES_SAMPLER_ARG", "1.0"))
   provider = TracerProvider(sampler=ParentBasedTraceIdRatio(ratio))
   provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)

   tracer = trace.get_tracer("otca.ex7")
   count = 0
   for i in range(100):
       with tracer.start_as_current_span(f"r-{i}") as s:
           if s.get_span_context().trace_flags.sampled:
               count += 1
   print(f">>> sampled {count}/100 <<<")
   provider.shutdown()
   ```

2. Run it three ways and compare the last line only:

   ```bash
   OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=1.0  python3 ex7_env.py 2>/dev/null | tail -1
   OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.1  python3 ex7_env.py 2>/dev/null | tail -1
   OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.0  python3 ex7_env.py 2>/dev/null | tail -1
   ```

   Expected:

   ```
   >>> sampled 100/100 <<<
   >>> sampled 9/100 <<<
   >>> sampled 0/100 <<<
   ```

3. Read (do not run) this table of the pipeline knobs OTCA expects you to recognize:

   | Variable | Pipeline stage it tunes | Example |
   |---|---|---|
   | `OTEL_SERVICE_NAME` | Resource | `payments-api` |
   | `OTEL_TRACES_SAMPLER` | Provider sampler | `parentbased_traceidratio` |
   | `OTEL_TRACES_SAMPLER_ARG` | Sampler argument | `0.25` |
   | `OTEL_TRACES_EXPORTER` | Terminal exporter(s) | `otlp,console` |
   | `OTEL_EXPORTER_OTLP_ENDPOINT` | Exporter transport | `http://collector:4317` |
   | `OTEL_EXPORTER_OTLP_PROTOCOL` | Exporter wire format | `grpc` / `http/protobuf` |
   | `OTEL_BSP_SCHEDULE_DELAY` | BatchSpanProcessor timer (ms) | `5000` |
   | `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` | BatchSpanProcessor batch | `512` |
   | `OTEL_METRIC_EXPORT_INTERVAL` | PeriodicExportingMetricReader (ms) | `60000` |
   | `OTEL_SDK_DISABLED` | Whole pipeline off | `true` |

**Comprehension check:**

- **Q7.1** The same binary produced 100, 9, and 0 sampled spans with no recompilation. Which principle of the SDK design makes environment-variable configuration possible, and why does the exam favour it for containerized deployments?
- **Q7.2** `OTEL_TRACES_EXPORTER=otlp,console` accepts a comma-separated list. In pipeline terms, what does supplying two values construct?
- **Q7.3** A teammate sets `OTEL_SDK_DISABLED=true` in a load-test environment. Which stages of *all three* pipelines does this switch off, and what is the intended use case?
- **Q7.4** `OTEL_BSP_SCHEDULE_DELAY` and `OTEL_METRIC_EXPORT_INTERVAL` both control an export cadence, but they belong to different components. Name each component and explain why traces default to seconds while metrics commonly default to 60s.

---

## Exercise 8 — Diagnose a silent pipeline

**Goal:** practice the failure that gives beginners the most trouble — code runs, exits 0, and *nothing* reaches the backend.

1. Create `ex8_broken.py` (three deliberate bugs are hidden in it):

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor
   from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

   provider = TracerProvider()
   provider.add_span_processor(
       BatchSpanProcessor(OTLPSpanExporter(endpoint="http://localhost:4317", insecure=True))
   )
   # (bug: provider never registered globally)

   tracer = trace.get_tracer("otca.ex8")
   with tracer.start_as_current_span("orphan"):
       pass
   # (bug: no force_flush / shutdown before exit)
   # (bug: no Collector is listening on 4317)
   ```

2. Run it — it exits 0 and prints nothing:

   ```bash
   python3 ex8_broken.py ; echo "exit=$?"
   ```

   ```
   exit=0
   ```

3. Turn on the SDK's own diagnostics to make the pipeline talk. Add at the very top and re-run:

   ```python
   import logging
   logging.basicConfig(level=logging.DEBUG)
   ```

4. Add a **debug tap** so you can prove spans are being *created* even while the real exporter fails — insert before the `with`:

   ```python
   from opentelemetry.sdk.trace.export import SimpleSpanProcessor, ConsoleSpanExporter
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   ```

5. Fix the three bugs (register the provider with `trace.set_tracer_provider(provider)`, call `provider.shutdown()` at the end, and either start a Collector or point the endpoint at a live one). Re-run and confirm the `orphan` span reaches both taps.

**Comprehension check:**

- **Q8.1** In the original file, spans were created and the app exited 0, yet the OTLP backend received nothing. List the three independent pipeline defects and, for each, state at which stage the span silently died.
- **Q8.2** Adding a `ConsoleSpanExporter` tap is a diagnostic technique. What single question does the tap answer, and how does its answer let you *split* the problem into "instrumentation side" vs. "export side"?
- **Q8.3** With `BatchSpanProcessor`, why is a missing `shutdown()`/`force_flush()` before process exit a data-loss bug specifically for *short-lived* programs (CLIs, cron jobs, serverless), but rarely noticed in a long-running server?
- **Q8.4** `logging.basicConfig(level=logging.DEBUG)` surfaced the OTLP connection errors that were previously swallowed. Why does the SDK *not* raise export failures as exceptions into your application code by default, and what does that design choice protect?

---

## Answer key

<details>
<summary>Click to reveal answers (Exercises 1–8)</summary>

### Exercise 1
- **A1.1** `span.end()` → the provider's active **SpanProcessor** receives `on_end` → the processor hands the span to its **SpanExporter** (`export()`) → the exporter serializes and writes to stdout. (Sampling already happened at span *start*, upstream of this.)
- **A1.2** The span whose `parent_id` is `null` is the **root** of the trace (`checkout`). `charge-card` carries `parent_id` pointing at `checkout`'s `span_id`. A shared `trace_id` with distinct `span_id`s is exactly how parent/child within one trace is encoded.
- **A1.3** The **Resource** is attached by the **provider** (it is a property of the `TracerProvider`, applied uniformly to every span it emits), not set per span. Thinking of it as a per-span attribute is wrong because resource describes the *producer* (service/host/SDK), is identical for the whole process, and is deduplicated on the wire — not something instrumentation sets on each operation.
- **A1.4** Nowhere/into a **no-op**. Without `set_tracer_provider`, `trace.get_tracer()` returns the default no-op tracer; spans are created as non-recording objects and never enter any pipeline. The code path runs but there is no processor/exporter to emit anything.

### Exercise 2
- **A2.1** `BatchSpanProcessor` enqueues finished spans and exports them on its **`schedule_delay`** timer (5000 ms here), or when a batch fills / on flush. The spans sat in the in-memory queue until the timer fired.
- **A2.2** Synchronous export on the hot path: every `span.end()` blocks the calling thread on a network/IO round-trip, so exporter latency or a slow backend directly inflates request latency (and couples app throughput to exporter throughput). Batching decouples them by exporting asynchronously in bulk.
- **A2.3** When the queue is full, `BatchSpanProcessor` **drops** new spans (it does not block the application). Implication: telemetry is treated as *best-effort* and is sacrificed to protect request latency — losing spans is preferable to slowing the user's request.
- **A2.4** `shutdown()` (a) **flushes** any spans still queued, exporting them before exit, and (b) **closes** the exporter/releases its resources. A bare process exit can lose the queued batch and skip clean teardown.

### Exercise 3
- **A3.1** **Zero** span JSON blocks print with ratio `0.0`, but the `for` body still runs — `start_as_current_span` returns a valid (non-recording) span and the `with` block executes normally. This distinguishes "a span object exists in code" from "the span is *recorded and sampled* for export." Sampling changes recording, not control flow.
- **A3.2** Sampling on the provider runs at span **start**, before any work is recorded, so an unsampled span can be created as non-recording — saving the cost of recording attributes/events and the cost of the whole processor→exporter path. Sampling later (in a processor) would mean you already paid to record and enqueue the span, and you would break the head-sampling guarantee that the `sampled` flag propagates downstream.
- **A3.3** No — with `ParentBased`, a valid parent context that says `sampled=false` is **respected**, so the child is not recorded (the root sampler only applies when there is no parent). `ParentBased` is the default because it keeps a distributed trace **whole**: every service honours the single decision made at the trace's root, so you never get half-sampled, fragmentary traces.
- **A3.4** Because the trace-id is shared by every span in the trace across all services, deriving the keep/drop decision deterministically from it means each independently-deployed service computes the **same** decision for the same trace without coordination. A random coin flip per service would keep the trace on one hop and drop it on the next.

### Exercise 4
- **A4.1** **Two** `SpanProcessor` instances (the Simple+Console pair and the Batch+OTLP pair). The provider fans the *same* span out to each processor in list order; processors receive the same span object and must not mutate it destructively.
- **A4.2** The provider iterates its processor list independently; each processor owns its own exporter and error handling. A failure in one exporter is contained to that processor and does not propagate to the others, so the Console tap prints regardless of OTLP's state.
- **A4.3** The SDK's built-in head sampler is global to the provider, so per-destination retention is not an SDK-pipeline feature. The correct place is the **OpenTelemetry Collector** — e.g. a `tail_sampling` processor plus multiple exporters/pipelines routes a sampled subset to the expensive backend while a cheaper pipeline keeps more. (Any downstream routing/filtering layer works; the point is it lives outside the in-process span pipeline.)
- **A4.4** `ConsoleSpanExporter` writes locally and cheaply, so synchronous `SimpleSpanProcessor` is fine and gives immediate, ordered output for debugging. `OTLPSpanExporter` does a network round-trip that can be slow or fail, so it must be `BatchSpanProcessor` to keep export off the hot path and absorb transient backend outages.

### Exercise 5
- **A5.1** Because the **MetricReader** — not the instrument — decides export timing. `PeriodicExportingMetricReader` collects and exports on its own `export_interval_millis` (3s) timer; the five `add()` calls only mutate an in-memory aggregation. Exports are periodic snapshots, not per-measurement events.
- **A5.2** Under **cumulative** temporality, `5` is the running total since the start of the stream (all increments to date). It is resilient to a dropped export because the *next* successful export still carries the full cumulative total — one lost message doesn't lose the counts it contained.
- **A5.3** Under **delta**, `3` then `2` mean "3 increments in the first interval, 2 more in the second" — each export reports only the change since the previous collection. The backend must now **sum deltas over time** itself to reconstruct a total, and a dropped delta export permanently loses those counts (no self-healing).
- **A5.4** "Reader" is correct because a `MetricReader` **pulls** the current aggregated state from the SDK on demand (on its timer or on collect), rather than being pushed one record per operation. A `SpanProcessor` is push-driven — it receives each span as it ends; it never queries the provider for an accumulated snapshot.

### Exercise 6
- **A6.1** The **`LoggingHandler`** — attached to the stdlib root logger — converts each `logging.LogRecord` into an OTel `LogRecord` and emits it through the `LoggerProvider`'s pipeline. Generically this is a **log appender / bridge** (the API's "Logs Bridge").
- **A6.2** The pipeline read the **active span context** (trace_id/span_id) from ambient Context at emit time. When a span is active, the log is stamped with its ids; when none is, they are zero. Automatic trace↔log correlation is the headline reason to route logs through the SDK — you get logs joined to the exact trace/span for free, which manual stdout JSON cannot do without you plumbing the context yourself.
- **A6.3** The numeric `severity_number` is a normalized scale (1–24) that lets a backend compare and filter severity **consistently across sources** that use different textual level names (WARN vs WARNING vs W). The text is human-facing; the number is machine-comparable and stable across ecosystems.
- **A6.4** The SDK is **symmetric across signals**: every signal is provider → processor(s) → exporter, and each offers the same Simple/Batch processor pattern with the same batching trade-offs. Learn the shape once and it transfers to all three.

### Exercise 7
- **A7.1** **Separation of configuration from code** — the pipeline stages (sampler, exporter, batching, resource) are constructed from external configuration rather than hard-coded, so behaviour changes without rebuilds. The exam favours it because containers ship one immutable image and are tuned per-environment purely through env vars.
- **A7.2** It constructs **two terminal exporters** on that signal's pipeline (OTLP *and* console), so each span/metric/log is emitted to both destinations — the env-var equivalent of adding two processors in Exercise 4.
- **A7.3** `OTEL_SDK_DISABLED=true` turns the SDK into a **no-op for all three signals** — no sampling, no recording, no processing, no export — effectively disabling every pipeline. Intended for temporarily switching telemetry off (e.g. load tests, or narrowing down whether instrumentation is causing an issue) without removing instrumentation code.
- **A7.4** `OTEL_BSP_SCHEDULE_DELAY` is the **BatchSpanProcessor** flush timer; `OTEL_METRIC_EXPORT_INTERVAL` is the **PeriodicExportingMetricReader** collect+export interval. Traces flush in seconds because trace value is timeliness (you want a failing request's spans quickly); metrics default to ~60s because they are periodic aggregates where a coarser cadence dramatically reduces volume with little loss of signal.

### Exercise 8
- **A8.1** (1) **Provider never registered** — `get_tracer` returned a no-op tracer, so `orphan` was non-recording and died at the API before entering any pipeline. (2) **No `shutdown()`/`force_flush()`** — even had it been recording, `BatchSpanProcessor`'s queued batch was discarded at process exit, dying in the queue stage. (3) **No Collector on 4317** — the exporter's network send failed, dying at the export stage.
- **A8.2** The `ConsoleSpanExporter` tap answers: *"is the span being created and reaching a processor at all?"* If the console shows the span, instrumentation and the in-process pipeline are fine and the fault is on the **export/transport** side; if the console shows nothing, the fault is **upstream** (provider not registered, no-op tracer, sampling, or the span never recorded).
- **A8.3** Batching holds spans in memory and flushes on a timer; a short-lived program exits before the first timer tick, so the still-queued spans are lost unless `shutdown()`/`force_flush()` drains them. A long-running server keeps ticking, so most batches flush during normal operation and the omission is masked (only the final, unflushed batch is at risk).
- **A8.4** By design the SDK treats telemetry as best-effort and **must not** let an observability failure crash or block the application; export errors are logged internally, not raised into user code. This protects application availability — a broken backend degrades your telemetry, never your service.

</details>

---

### Sources

- OpenTelemetry — Trace SDK specification: <https://opentelemetry.io/docs/specs/otel/trace/sdk/>
- OpenTelemetry — Metrics SDK specification: <https://opentelemetry.io/docs/specs/otel/metrics/sdk/>
- OpenTelemetry — Logs SDK specification: <https://opentelemetry.io/docs/specs/otel/logs/sdk/>
- OpenTelemetry — Sampling: <https://opentelemetry.io/docs/concepts/sampling/>
- OpenTelemetry — SDK environment variables: <https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/>
- OpenTelemetry — Python SDK (traces / metrics / logs): <https://opentelemetry.io/docs/languages/python/>
- CNCF — OTCA Curriculum: <https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf>