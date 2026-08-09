# PCA — Topic 3.3: Tracing and Spans
## Guided Exercises

> **Format.** Each exercise is a sequence of numbered steps you run on your own machine, followed by a *Comprehension check*. Do the steps first, answer from what you observed, then open the collapsible **Answer key** at the bottom.
>
> **Prerequisites.** `python3.12+`, `pip`, and `docker`. Create an isolated environment once:
> ```bash
> python3 -m venv .otel && source .otel/bin/activate
> pip install \
>   "opentelemetry-api>=1.27" \
>   "opentelemetry-sdk>=1.27" \
>   "opentelemetry-exporter-otlp-proto-grpc>=1.27"
> ```
>
> **Why this sits in a Prometheus/observability track.** A trace is the third signal alongside metrics and logs; a *span* is the atomic unit of a trace. Exercise 6 closes the loop back to Prometheus via **exemplars**, the standard mechanism that links a metric sample to the exact trace that produced it.

---

## Exercise 1 — Anatomy of a single span

**Goal:** emit one span to the console and read every field the specification requires.

1. Create `span01.py`:

    ```python
    from opentelemetry import trace
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import (
        ConsoleSpanExporter,
        SimpleSpanProcessor,
    )

    resource = Resource.create({"service.name": "shop-backend"})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)

    tracer = trace.get_tracer("exercise.tracer")

    with tracer.start_as_current_span("checkout") as span:
        span.set_attribute("cart.items", 3)
        span.set_attribute("cart.currency", "ARS")
    ```

2. Run it:

    ```bash
    python span01.py
    ```

3. Read the JSON printed to stdout. A representative result (your IDs will differ on every run):

    ```json
    {
        "name": "checkout",
        "context": {
            "trace_id": "0x8f2b0a1c9d4e5f60718293a4b5c6d7e8",
            "span_id": "0xa1b2c3d4e5f60718",
            "trace_state": "[]"
        },
        "kind": "SpanKind.INTERNAL",
        "parent_id": null,
        "start_time": "2026-08-08T12:00:00.000000Z",
        "end_time": "2026-08-08T12:00:00.001500Z",
        "status": {
            "status_code": "UNSET"
        },
        "attributes": {
            "cart.items": 3,
            "cart.currency": "ARS"
        },
        "events": [],
        "links": [],
        "resource": {
            "attributes": {
                "service.name": "shop-backend",
                "telemetry.sdk.language": "python",
                "telemetry.sdk.name": "opentelemetry",
                "telemetry.sdk.version": "1.27.0"
            },
            "schema_url": ""
        }
    }
    ```

4. Count the hexadecimal characters in `trace_id` and in `span_id` (ignore the `0x` prefix).

**Comprehension check**

- **Q1.1** How many bytes are a `trace_id` and a `span_id`, and how many hex characters is each printed as?
- **Q1.2** Why is `parent_id` equal to `null` here?
- **Q1.3** The `status_code` is `UNSET`, not `OK`. What does `UNSET` mean, and who is expected to set it to `OK`?
- **Q1.4** `service.name` lives under `resource`, not under `attributes`. What is the semantic difference between a *resource attribute* and a *span attribute*?

---

## Exercise 2 — Parent/child relationships inside one trace

**Goal:** nest spans and prove that the parent link and the shared trace ID are what turn isolated spans into a trace.

1. Create `span02.py`:

    ```python
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import (
        ConsoleSpanExporter,
        SimpleSpanProcessor,
    )

    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("exercise.tracer")

    with tracer.start_as_current_span("checkout") as parent:
        with tracer.start_as_current_span("charge-card") as child:
            child.set_attribute("payment.method", "credit_card")
    ```

2. Run it and capture the output:

    ```bash
    python span02.py
    ```

3. You will see **two** JSON objects. Note the order in which they are printed.
4. Copy these three values into a scratch note:
   - `charge-card` → `context.span_id`
   - `charge-card` → `parent_id`
   - `checkout`    → `context.span_id`
5. Compare `checkout.trace_id` with `charge-card.trace_id`.

**Comprehension check**

- **Q2.1** Which span is printed **first**, and why? (Hint: think about the `SimpleSpanProcessor` and when a span is exported.)
- **Q2.2** Which specific field of `charge-card` equals the `span_id` of `checkout`? What does that prove?
- **Q2.3** Do the two spans share the same `trace_id`? Why is that the property that groups spans into a single trace?
- **Q2.4** If `charge-card` had thrown an unhandled exception, would `checkout` still be exported? Reason about span lifetime with the `with` blocks.

---

## Exercise 3 — Span status, events, and recorded exceptions

**Goal:** distinguish the three status codes and see how an error is attached to a span as an *event*.

1. Create `span03.py`:

    ```python
    from opentelemetry import trace
    from opentelemetry.trace import Status, StatusCode
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import (
        ConsoleSpanExporter,
        SimpleSpanProcessor,
    )

    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("exercise.tracer")

    with tracer.start_as_current_span("charge-card") as span:
        span.add_event("gateway.request.sent", {"gateway": "stripe"})
        try:
            raise RuntimeError("card declined: insufficient_funds")
        except RuntimeError as err:
            span.record_exception(err)
            span.set_status(Status(StatusCode.ERROR, "payment declined"))
    ```

2. Run it:

    ```bash
    python span03.py
    ```

3. In the output, locate:
   - the `status` block,
   - the `events` array (there are now two entries).

    ```json
    "status": {
        "status_code": "ERROR",
        "description": "payment declined"
    },
    "events": [
        {
            "name": "gateway.request.sent",
            "timestamp": "2026-08-08T12:00:00.000200Z",
            "attributes": { "gateway": "stripe" }
        },
        {
            "name": "exception",
            "timestamp": "2026-08-08T12:00:00.000400Z",
            "attributes": {
                "exception.type": "RuntimeError",
                "exception.message": "card declined: insufficient_funds",
                "exception.stacktrace": "Traceback (most recent call last):\n  ...",
                "exception.escaped": "False"
            }
        }
    ]
    ```

**Comprehension check**

- **Q3.1** Name the three `StatusCode` values and state which one is the default before you set anything.
- **Q3.2** `record_exception()` did **not** set the status to `ERROR` by itself — you had to call `set_status()`. Why are recording an exception and setting error status two separate actions?
- **Q3.3** What is the `name` of the event that `record_exception()` produced, and which three attributes does it carry by convention?
- **Q3.4** A span whose `status_code` is `ERROR` is still a valid, exported span. True or false — and what does that tell you about how tracing backends compute an "error rate"?

---

## Exercise 4 — Distributed context propagation with W3C `traceparent`

**Goal:** carry a trace across a process boundary by injecting and extracting the W3C Trace Context HTTP header — the mechanism that makes tracing *distributed*.

1. Create `span04_client.py` — the "caller" that injects context into outbound headers:

    ```python
    from opentelemetry import trace
    from opentelemetry.propagate import inject
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.trace import SpanKind

    trace.set_tracer_provider(TracerProvider())
    tracer = trace.get_tracer("exercise.tracer")

    headers = {}
    with tracer.start_as_current_span("call-payments", kind=SpanKind.CLIENT):
        inject(headers)          # writes W3C headers into the dict
        print(headers)
    ```

2. Run it and read the header the propagator wrote:

    ```bash
    python span04_client.py
    ```
    ```text
    {'traceparent': '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'}
    ```

3. Split that `traceparent` value on the `-` character. It has exactly **four** fields:

    ```text
    00 - 4bf92f3577b34da6a3ce929d0e0e4736 - 00f067aa0ba902b7 - 01
    │      │                                  │                  │
    version  trace-id (16 bytes)              parent-id (8 bytes) trace-flags
    ```

4. Create `span04_server.py` — the "callee" that extracts the context and continues the *same* trace:

    ```python
    from opentelemetry import trace
    from opentelemetry.propagate import extract
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import (
        ConsoleSpanExporter,
        SimpleSpanProcessor,
    )
    from opentelemetry.trace import SpanKind

    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("exercise.tracer")

    incoming = {
        "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    }
    ctx = extract(incoming)
    with tracer.start_as_current_span("handle-payment",
                                      context=ctx,
                                      kind=SpanKind.SERVER):
        pass
    ```

5. Run the server side:

    ```bash
    python span04_server.py
    ```

6. In its output, compare `context.trace_id` and `parent_id` against the header you passed in.

**Comprehension check**

- **Q4.1** In `traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`, what does each of the four fields mean?
- **Q4.2** The last field is `01`. What single behaviour does that bit control, and what would `00` mean for the receiving service?
- **Q4.3** In `span04_server.py`, what will `handle-payment`'s `trace_id` be, and what will its `parent_id` be? Where did those values come from?
- **Q4.4** The client span used `SpanKind.CLIENT` and the server span `SpanKind.SERVER`. Why does the kind matter to a tracing backend rendering the waterfall?
- **Q4.5** There is a companion header, `tracestate`. What is it for, and why is it kept separate from `traceparent`?

---

## Exercise 5 — Head-based sampling with `TraceIdRatioBased`

**Goal:** control trace volume at the source and understand why the *whole trace* is kept or dropped as a unit.

1. Create `span05.py`. It creates 20 independent root traces at a 25% sampling ratio and counts how many spans are actually recorded:

    ```python
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
    from opentelemetry.sdk.trace.export import (
        SpanExporter,
        SpanExportResult,
        SimpleSpanProcessor,
    )

    class CountingExporter(SpanExporter):
        def __init__(self):
            self.count = 0
        def export(self, spans):
            self.count += len(spans)
            return SpanExportResult.SUCCESS
        def shutdown(self):
            print(f"exported spans: {self.count} / 20")

    sampler = ParentBased(root=TraceIdRatioBased(0.25))
    provider = TracerProvider(sampler=sampler)
    counter = CountingExporter()
    provider.add_span_processor(SimpleSpanProcessor(counter))
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("exercise.tracer")

    for i in range(20):
        with tracer.start_as_current_span(f"request-{i}"):
            pass

    provider.shutdown()
    ```

2. Run it a few times:

    ```bash
    python span05.py
    python span05.py
    ```
    ```text
    exported spans: 6 / 20
    exported spans: 4 / 20
    ```

3. Note that the number fluctuates around 5 (25% of 20) but is not exactly 5.

**Comprehension check**

- **Q5.1** Sampling here is *head-based*. At what moment in a trace's life is the keep/drop decision made, and on what input is it computed?
- **Q5.2** Why is the exported count ~5 but not exactly 5 on every run?
- **Q5.3** The sampler is wrapped in `ParentBased`. If this service receives a request whose `traceparent` has the sampled flag `01`, will the child span be recorded regardless of the 0.25 ratio? Why is that behaviour desirable across services?
- **Q5.4** A student wants "keep every trace that contains an error." Can head-based `TraceIdRatioBased` do that? If not, which sampling strategy can, and where does it run?

---

## Exercise 6 — Send real spans to Jaeger and link a metric to a trace

**Goal:** export over OTLP to a running backend, view the waterfall, and connect the trace to a Prometheus metric via an exemplar.

1. Start Jaeger all-in-one with the OTLP receiver enabled:

    ```bash
    docker run -d --name jaeger \
      -e COLLECTOR_OTLP_ENABLED=true \
      -p 16686:16686 \
      -p 4317:4317 \
      -p 4318:4318 \
      jaegertracing/all-in-one:1.60
    ```

2. Install the OTLP exporter (already installed if you did the prerequisites) and create `span06.py`:

    ```python
    import time
    from opentelemetry import trace
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import (
        OTLPSpanExporter,
    )

    resource = Resource.create({"service.name": "shop-backend"})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(
        BatchSpanProcessor(
            OTLPSpanExporter(endpoint="localhost:4317", insecure=True)
        )
    )
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("exercise.tracer")

    with tracer.start_as_current_span("checkout") as parent:
        with tracer.start_as_current_span("charge-card"):
            time.sleep(0.05)
        with tracer.start_as_current_span("write-order"):
            time.sleep(0.02)

    provider.shutdown()   # flush the BatchSpanProcessor before exit
    ```

3. Run it, then open the UI:

    ```bash
    python span06.py
    # Browse to http://localhost:16686
    # Service: "shop-backend"  →  Find Traces
    ```

4. Open the trace. Confirm the waterfall shows `checkout` on top with `charge-card` and `write-order` nested beneath it, and that `charge-card`'s bar is longer (~50 ms vs ~20 ms).
5. Note the **Trace ID** shown in the UI header (32 hex characters).
6. Now read this OpenMetrics exposition snippet — a Prometheus histogram sample carrying an **exemplar** that points at exactly such a trace:

    ```text
    # TYPE http_request_duration_seconds histogram
    http_request_duration_seconds_bucket{le="0.1"} 1 # {trace_id="8f2b0a1c9d4e5f60718293a4b5c6d7e8"} 0.072 1.754e9
    ```

   To store exemplars, Prometheus must be started with the feature flag:

    ```bash
    prometheus --enable-feature=exemplar-storage
    ```

7. Tear down when finished:

    ```bash
    docker rm -f jaeger
    ```

**Comprehension check**

- **Q6.1** The script exports with `BatchSpanProcessor`, not `SimpleSpanProcessor`. Why is `provider.shutdown()` essential here but not in Exercises 1–3?
- **Q6.2** Which OTLP ports did you publish, and what is the difference between `4317` and `4318`?
- **Q6.3** In the exemplar line, identify the three parts after the `#`: the label set, the value `0.072`, and `1.754e9`. What does each represent?
- **Q6.4** Explain, in one sentence, how a Grafana user goes from a spike on a Prometheus latency panel to the individual Jaeger trace responsible for it.
- **Q6.5** Without the `--enable-feature=exemplar-storage` flag, the metric still scrapes fine but the link is lost. What exactly does the flag enable, and why is it off by default?

---

<details>
<summary><strong>Answer key</strong></summary>

### Exercise 1
- **A1.1** A `trace_id` is **16 bytes** (128 bits), printed as **32 hex characters**; a `span_id` is **8 bytes** (64 bits), printed as **16 hex characters**. The `0x` is only a display prefix. (See OpenTelemetry, *Traces*.)
- **A1.2** `checkout` is a **root span** — it has no parent in this process and no incoming trace context — so its `parent_id` is `null`. It is the entry point of the trace.
- **A1.3** `UNSET` is the default: "no explicit status was set; treat as neither success nor failure." Instrumentation authors normally leave it `UNSET` and let the backend infer success; `OK` is reserved for cases where application code *explicitly* asserts the operation succeeded, and `ERROR` is set on failure. Setting `OK` is discouraged unless you have a specific reason to override backend inference.
- **A1.4** A **resource attribute** describes the *entity producing* the telemetry (the service/process/host) and is identical for every span that process emits — e.g. `service.name`. A **span attribute** describes *that one operation* (e.g. `cart.items`). Resource attributes let a backend group all spans by service; span attributes let you filter within a service.

### Exercise 2
- **A2.1** `charge-card` is printed first. With `SimpleSpanProcessor`, a span is exported the instant it **ends**; the inner `with` block closes before the outer one, so the child ends — and is exported — before the parent.
- **A2.2** `charge-card.parent_id` equals `checkout.span_id`. That proves `charge-card` is a **child of** `checkout`: the parent link is a span ID reference, not containment in memory.
- **A2.3** Yes — both spans carry the **same `trace_id`**. A trace is *defined* as the set of all spans sharing one trace ID; the parent/child links then arrange those spans into a tree/DAG.
- **A2.4** Yes, `checkout` would still be exported. Its `with` block still exits (via exception unwinding), which ends the span; it would simply not be marked `ERROR` unless you caught the exception and called `set_status`. Span export is tied to span *end*, which the context manager guarantees.

### Exercise 3
- **A3.1** `UNSET` (the default), `OK`, and `ERROR`. Before you call `set_status`, every span is `UNSET`.
- **A3.2** They answer two different questions. `record_exception()` attaches *diagnostic detail* (type, message, stacktrace) as an event — useful even for a *handled* exception that did not fail the operation. `set_status(ERROR)` asserts *the operation as a whole failed*. You may record an exception you recovered from without failing the span, so the SDK keeps the two decisions independent.
- **A3.3** The event is named **`exception`**. By convention it carries `exception.type`, `exception.message`, and `exception.stacktrace` (plus `exception.escaped`).
- **A3.4** **True.** An errored span is still recorded and exported. Backends compute "error rate" by counting spans whose `status_code == ERROR` against the total — which only works *because* failed spans are emitted, not dropped.

### Exercise 4
- **A4.1** `00` = **version** of the Trace Context spec; `4bf9…4736` = **trace-id** (16 bytes / 32 hex); `00f0…02b7` = **parent-id**, i.e. the span-id of the caller's span (8 bytes / 16 hex); `01` = **trace-flags**.
- **A4.2** The low bit of trace-flags is the **sampled** flag. `01` tells the receiver "this trace was sampled — you should record and export your spans for it too." `00` means "not sampled"; a downstream service honoring the parent decision would then not record.
- **A4.3** `handle-payment.trace_id` will be `4bf92f3577b34da6a3ce929d0e0e4736` and its `parent_id` will be `00f067aa0ba902b7` — both **taken from the incoming `traceparent`** by `extract()`. That is exactly how the callee's span joins the caller's trace across the process boundary.
- **A4.4** `SpanKind` tells the backend the role of the span in a remote call: `CLIENT` (outbound, measured on the caller) and `SERVER` (inbound, measured on the callee). The pair lets the UI place them correctly in the waterfall and compute network/queue time as the gap between the client span and the server span it wraps.
- **A4.5** `tracestate` carries **vendor-specific / multi-vendor key-value context** (e.g. a sampling priority or an APM vendor's own IDs) that must survive propagation. It is separate from `traceparent` so the mandatory, fixed-format identity fields are never corrupted by optional vendor data, and so an intermediary can rewrite its own `tracestate` entry without touching the trace identity.

### Exercise 5
- **A5.1** The decision is **head-based**: taken at the moment the **root span starts**, computed deterministically from the **trace-id** (a hash/ratio test). Every span in the trace then inherits that decision.
- **A5.2** `TraceIdRatioBased(0.25)` keeps a trace when its trace-id falls in the lower 25% of the id space. Trace-ids are effectively random, so over 20 traces you get a *binomial* outcome centered on 5, not exactly 5 — variance is expected with small samples.
- **A5.3** Yes. `ParentBased` says "if there is a parent decision (from an incoming `traceparent`), **respect it**; only apply the ratio for *root* spans." So an inbound `01` forces the child to be recorded regardless of `0.25`. This keeps a distributed trace **whole** — you never end up with a trace that is sampled in service A but dropped in service B, which would produce broken waterfalls.
- **A5.4** No — head-based sampling decides *before* the request runs, so it cannot know an error will occur. "Keep every errored trace" requires **tail-based sampling**, which buffers all spans of a trace and decides *after* completion based on their contents (e.g. any span with `status == ERROR`). It runs in a collector/gateway (e.g. the OpenTelemetry Collector `tail_sampling` processor), not in the application SDK.

### Exercise 6
- **A6.1** `BatchSpanProcessor` **buffers** spans and flushes them asynchronously in batches; if the process exits before a flush, buffered spans are lost. `provider.shutdown()` forces a final flush. Exercises 1–3 used `SimpleSpanProcessor`, which exports synchronously on each span end, so there is nothing pending at exit.
- **A6.2** `4317` is **OTLP over gRPC**; `4318` is **OTLP over HTTP/protobuf**. The script targets gRPC (`localhost:4317`). Both were published so either transport works against this Jaeger.
- **A6.3** After the `#`: `{trace_id="8f2b…d7e8"}` is the **exemplar's label set** identifying the trace; `0.072` is the **observed value** for that single measurement (72 ms, the request whose latency fell in this bucket); `1.754e9` is the **Unix timestamp** (seconds) at which the exemplar was recorded.
- **A6.4** The user clicks the exemplar marker on the Prometheus/Grafana latency panel, which reads the exemplar's `trace_id` label and deep-links straight into the Jaeger/Tempo trace view for that exact request.
- **A6.5** The flag enables Prometheus's **in-memory exemplar storage** (a separate circular buffer attached to series). It is off by default because exemplars add memory overhead and were introduced behind a feature flag; without it, exemplars are parsed during scrape but not retained, so the metric-to-trace link cannot be served to Grafana.

</details>

---

### Sources
- OpenTelemetry — *Traces / Spans* (span fields, SpanKind, status, events): https://opentelemetry.io/docs/concepts/signals/traces/
- OpenTelemetry — *Sampling*: https://opentelemetry.io/docs/concepts/sampling/
- OpenTelemetry — *Context propagation*: https://opentelemetry.io/docs/concepts/context-propagation/
- W3C — *Trace Context* (`traceparent` / `tracestate` format): https://www.w3.org/TR/trace-context/
- Jaeger — *Getting Started / all-in-one, OTLP*: https://www.jaegertracing.io/docs/latest/getting-started/
- Prometheus — *Exemplars* (OpenMetrics exemplar syntax, `exemplar-storage` feature flag): https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- CNCF — *PCA Curriculum*: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf