# Topic 4.1 — Context Propagation: Guided Exercises

> **Certification:** OpenTelemetry Certified Associate (OTCA) — Domain 4 (Instrumenting Applications), Topic 4.1
> **Exam weight:** 2.5
> **Reference:** [CNCF OTCA Curriculum](https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf) · [W3C Trace Context](https://www.w3.org/TR/trace-context/) · [W3C Baggage](https://www.w3.org/TR/baggage/) · [OpenTelemetry Context specification](https://opentelemetry.io/docs/specs/otel/context/) · [Propagators API](https://opentelemetry.io/docs/specs/otel/context/api-propagators/)

Context propagation is the mechanism that turns isolated per-service spans into a single distributed trace. It has two halves that the exam consistently separates:

- **In-process propagation** — the `Context` object carries the *active span* (and Baggage) implicitly across function calls within one process, without you passing it as an argument.
- **Cross-process propagation** — a `Propagator` serializes the `SpanContext` and `Baggage` into a carrier (usually HTTP headers) on the way out, and deserializes it on the way in, so the downstream service continues the same trace.

These exercises are runnable end-to-end with the Python SDK, but every concept (W3C headers, propagator selection, Baggage, extraction/injection) is language-agnostic and maps directly to the specification.

---

## Prerequisites

You need Python 3.8+ and the OpenTelemetry packages. Everything runs locally; no collector or backend is required — we print spans to the console.

```bash
python3 -m venv .otca && source .otca/bin/activate
pip install \
  opentelemetry-api==1.27.0 \
  opentelemetry-sdk==1.27.0 \
  opentelemetry-propagator-b3==1.27.0
python3 -c "import opentelemetry; print('otel', opentelemetry.version.__version__)"
```

Expected output:

```
otel 1.27.0
```

---

## Exercise 1 — Decode a W3C `traceparent` header by hand

The default OpenTelemetry propagator implements **W3C Trace Context**. Before writing any code, you must be able to read the wire format, because half of context-propagation debugging is staring at a header and deciding whether it is malformed.

### Steps

1. Take this header captured from a real inbound request:

   ```
   traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
   ```

2. Split it on `-` into its four fields and label each one:

   ```bash
   echo "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" | tr '-' '\n'
   ```

   Expected output:

   ```
   00                                  # version
   4bf92f3577b34da6a3ce929d0e0e4736    # trace-id (16 bytes / 32 hex chars)
   00f067aa0ba902b7                    # parent-id / span-id (8 bytes / 16 hex chars)
   01                                  # trace-flags (1 byte)
   ```

3. Interpret the `trace-flags` byte. It is an 8-bit field; only the least-significant bit (`0x01`, the **sampled** flag) is currently defined:

   ```bash
   python3 -c "print('sampled' if 0x01 & 0x01 else 'not sampled')"
   ```

   Expected output:

   ```
   sampled
   ```

4. Now inspect a companion header that may or may not be present:

   ```
   tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
   ```

   Note that `tracestate` is an **ordered, comma-separated list of `key=value` vendor entries**, left-most = most recently written.

### Verification questions

- **Q1.1** — A middlebox forwards `traceparent: 00-00000000000000000000000000000000-00f067aa0ba902b7-01`. Why must a receiver treat this as invalid and start a *new* trace instead of continuing?
- **Q1.2** — What is the difference in purpose between `traceparent` and `tracestate`? Which one carries the identifiers OpenTelemetry needs to link spans, and which one is for vendor-specific data?
- **Q1.3** — A downstream service receives `traceparent` but the `trace-flags` byte is `00`. What does the receiver learn about the sampling decision, and is it still obligated to propagate the header?
- **Q1.4** — You see `version` = `01` on an incoming header, but your library only knows version `00`. Per the spec, do you reject the request or parse the first four fields anyway?

---

## Exercise 2 — Observe in-process context propagation (no propagator involved)

Before anything crosses a process boundary, the *active span* has to flow through your call stack. This is pure `Context` mechanics: `start_as_current_span` mutates the implicit context, and any span started underneath it automatically becomes a child.

### Steps

1. Save this as `inproc.py`:

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

   tracer = trace.get_tracer("otca.inproc")

   def inner():
       # We do NOT pass any span or context in — it is read implicitly.
       current = trace.get_current_span()
       ctx = current.get_span_context()
       print(f"inner sees active span_id={ctx.span_id:016x} "
             f"trace_id={ctx.trace_id:032x}")
       with tracer.start_as_current_span("inner-work"):
           pass

   with tracer.start_as_current_span("outer") as outer:
       octx = outer.get_span_context()
       print(f"outer  span_id={octx.span_id:016x} "
             f"trace_id={octx.trace_id:032x}")
       inner()
   ```

2. Run it:

   ```bash
   python3 inproc.py
   ```

3. Read the two `print` lines first (not the JSON spans). Confirm that `inner` observed the **same** `trace_id` and the **same active `span_id`** as `outer`, even though nothing was passed as an argument.

   Expected shape (IDs will differ each run):

   ```
   outer  span_id=a1b2c3d4e5f60718 trace_id=9f8e7d6c5b4a39281706f5e4d3c2b1a0
   inner sees active span_id=a1b2c3d4e5f60718 trace_id=9f8e7d6c5b4a39281706f5e4d3c2b1a0
   ```

4. Now inspect the exported spans. In the `inner-work` span's JSON, find `parent_id` and confirm it equals `outer`'s `span_id`:

   ```
   "name": "inner-work",
   "parent_id": "0xa1b2c3d4e5f60718",
   "context": { "trace_id": "0x9f8e...", "span_id": "0x...." }
   ```

### Verification questions

- **Q2.1** — `inner()` received no span and no context argument, yet it correctly saw `outer` as the active span. Which OpenTelemetry object made that possible, and where is it stored?
- **Q2.2** — If you replaced `start_as_current_span` with `start_span` (which starts a span **without** setting it active), would `inner-work` still be a child of `outer`? Explain in terms of the active context.
- **Q2.3** — You spawn `inner()` on a new `threading.Thread`. Would it still see `outer` as active by default? What does this tell you about how the implicit `Context` is scoped in most language implementations?

---

## Exercise 3 — Inject context into a carrier and extract it (round trip)

This is the core cross-process mechanic. We simulate two services by injecting into a plain `dict` (the "carrier") in service A, then extracting from that same `dict` in service B — exactly what an HTTP client and server do with headers.

### Steps

1. Save this as `roundtrip.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.propagate import inject, extract
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import (
       ConsoleSpanExporter,
       SimpleSpanProcessor,
   )

   provider = TracerProvider()
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.roundtrip")

   # ---- Service A: create a span and inject into outbound headers ----
   carrier = {}
   with tracer.start_as_current_span("A: outgoing request"):
       inject(carrier)          # reads the CURRENT context implicitly
   print("A injected headers:", carrier)

   # ...network hop... the dict is what would travel as HTTP headers ...

   # ---- Service B: extract inbound context, start a child span ----
   parent_ctx = extract(carrier)   # returns a Context, NOT a span
   with tracer.start_as_current_span("B: handle request", context=parent_ctx):
       cur = trace.get_current_span().get_span_context()
       print(f"B running under trace_id={cur.trace_id:032x}")
   ```

2. Run it:

   ```bash
   python3 roundtrip.py
   ```

3. Look at the printed carrier. It must contain a `traceparent` key produced by the default W3C propagator:

   ```
   A injected headers: {'traceparent': '00-<32 hex>-<16 hex>-01'}
   ```

4. Compare the three trace IDs you now have visibility into:
   - the `traceparent` in the carrier,
   - `A: outgoing request` span's `trace_id` in the console JSON,
   - the `B running under trace_id=...` print line.

   **All three must be identical.** If they are, propagation worked; the two spans are one trace across a (simulated) process boundary.

5. Confirm parent linkage: in the exported `B: handle request` span, `parent_id` must equal the `span_id` embedded in the injected `traceparent`.

### Verification questions

- **Q3.1** — `inject(carrier)` took no span argument. Where did it get the trace/span IDs it wrote into `traceparent`?
- **Q3.2** — `extract(carrier)` returns a `Context`, not a `Span`. Why is that the correct return type, and what would go wrong if you tried to `start_as_current_span` on service B *without* passing that context?
- **Q3.3** — If service B calls `extract({})` on an **empty** carrier (headers stripped by a proxy), what does it get back, and what happens to the span it then starts — is it an error, or a new root trace?
- **Q3.4** — Why is a plain `dict` a valid carrier here, but real HTTP frameworks need a custom *getter/setter* to read headers? (Hint: think about case-insensitivity and multi-valued headers.)

---

## Exercise 4 — Propagate Baggage alongside the trace

**Baggage** is a separate key–value set that rides in its own `baggage` header. It is *not* attached to a span automatically — that is the single most common Baggage misconception the exam probes.

### Steps

1. Save this as `baggage.py`:

   ```python
   from opentelemetry import baggage, trace
   from opentelemetry.context import attach, detach
   from opentelemetry.propagate import inject, extract

   # ---- Service A: set a baggage entry, then inject ----
   ctx = baggage.set_baggage("user.tier", "premium")
   carrier = {}
   inject(carrier, context=ctx)          # inject reads THIS context
   print("A injected:", carrier)

   # ---- Service B: extract, read baggage back ----
   incoming = extract(carrier)
   token = attach(incoming)              # make it the active context
   try:
       print("B sees user.tier =", baggage.get_baggage("user.tier"))
       print("B full baggage    =", dict(baggage.get_all()))
   finally:
       detach(token)
   ```

2. Run it:

   ```bash
   python3 baggage.py
   ```

   Expected output:

   ```
   A injected: {'traceparent': '00-...-...-00', 'baggage': 'user.tier=premium'}
   B sees user.tier = premium
   B full baggage    = {'user.tier': 'premium'}
   ```

   > Note the `baggage` header appears **separately** from `traceparent`. They are propagated by two different propagators composed together (covered in Exercise 5).

3. Now prove the "Baggage is not a span attribute" point. Add this at the end and re-run:

   ```python
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor

   provider = TracerProvider()
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.baggage")

   token = attach(incoming)
   try:
       with tracer.start_as_current_span("B work") as span:
           # Baggage is available in context, but is NOT copied onto the span.
           span.set_attribute("user.tier", baggage.get_baggage("user.tier"))
   finally:
       detach(token)
   ```

   Inspect the `B work` span JSON: `user.tier` shows up under `attributes` **only because you explicitly copied it**. Without that `set_attribute` line, it would never appear on the span.

### Verification questions

- **Q4.1** — Does setting Baggage on service A cause `user.tier` to automatically appear as an attribute on service A's or service B's spans? What must you do to get it onto a span?
- **Q4.2** — Baggage travels in every downstream hop and is often written to logs. Name one security/privacy risk this creates and one class of data you should therefore never put in Baggage.
- **Q4.3** — `baggage.set_baggage(...)` returns a **new** `Context` instead of mutating in place. Why does the Context API favor immutable, copy-on-write semantics here?
- **Q4.4** — In the injected carrier, why did `traceparent` and `baggage` end up as two independent header keys rather than one combined header?

---

## Exercise 5 — Configure and compose propagators (W3C vs B3, and both at once)

OpenTelemetry's global propagator is configurable. Many production meshes still emit **B3** (Zipkin) headers, so you must interoperate. This exercise shows how to select a propagator, and how a **composite** propagator injects several formats at once for a gradual migration.

### Steps

1. First, confirm the default. Save as `whichprop.py`:

   ```python
   from opentelemetry.propagate import get_global_textmap
   print(type(get_global_textmap()).__name__)
   ```

   ```bash
   python3 whichprop.py
   ```

   Expected output (the default is W3C trace context + W3C baggage, composed):

   ```
   CompositePropagator
   ```

2. Now switch to **B3 multi-header** via the standard `OTEL_PROPAGATORS` environment variable (no code change — this is how you'd do it in production):

   ```bash
   OTEL_PROPAGATORS=b3multi python3 - <<'PY'
   from opentelemetry import trace
   from opentelemetry.propagate import inject
   from opentelemetry.sdk.trace import TracerProvider
   provider = TracerProvider(); trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.b3")
   carrier = {}
   with tracer.start_as_current_span("out"):
       inject(carrier)
   print(carrier)
   PY
   ```

   Expected output — B3 multi emits **separate** headers, not `traceparent`:

   ```
   {'x-b3-traceid': '<32 hex>', 'x-b3-spanid': '<16 hex>', 'x-b3-sampled': '1'}
   ```

3. Now run a **composite** so both W3C and B3 are injected — the safe way to migrate a fleet where some services only understand one format:

   ```bash
   OTEL_PROPAGATORS=tracecontext,baggage,b3multi python3 - <<'PY'
   from opentelemetry import trace
   from opentelemetry.propagate import inject
   from opentelemetry.sdk.trace import TracerProvider
   provider = TracerProvider(); trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.multi")
   carrier = {}
   with tracer.start_as_current_span("out"):
       inject(carrier)
   for k in sorted(carrier):
       print(k, "=", carrier[k])
   PY
   ```

   Expected output — both formats present, carrying the **same** IDs:

   ```
   traceparent = 00-<32 hex>-<16 hex>-01
   x-b3-sampled = 1
   x-b3-spanid = <16 hex>
   x-b3-traceid = <32 hex>
   ```

4. Verify interoperability: the `x-b3-traceid` value and the trace-id field inside `traceparent` must be byte-for-byte equal. One trace, two wire formats.

### Verification questions

- **Q5.1** — What is the exact purpose of a `CompositePropagator` on the **inject** side versus the **extract** side? (Consider: on extract, what happens when both `traceparent` and `x-b3-traceid` are present?)
- **Q5.2** — You are migrating a fleet from B3 to W3C. Why is `OTEL_PROPAGATORS=tracecontext,baggage,b3multi` a safer intermediate step than flipping every service from `b3multi` to `tracecontext` at once?
- **Q5.3** — `b3multi` produces `x-b3-traceid` / `x-b3-spanid` / `x-b3-sampled` as separate headers, while `b3` (single) packs them into one `b3: {traceid}-{spanid}-{sampled}-{parentspanid}` header. Which one is friendlier to systems that limit header count, and which is easier to grep in logs?
- **Q5.4** — `OTEL_PROPAGATORS` accepts a **comma-separated ordered list**. On extraction, if the list is `tracecontext,b3multi` and both header sets exist but disagree, which one wins, and why does order matter?

---

## Exercise 6 — Diagnose a broken trace (the "two disconnected traces" symptom)

Production context-propagation bugs almost never throw an error. Instead you get **two half-traces with different `trace_id`s** where you expected one. This exercise reproduces and fixes the classic cause: injecting with the wrong (or empty) active context.

### Steps

1. Save this **buggy** version as `broken.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.propagate import inject, extract
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor

   provider = TracerProvider()
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.debug")

   carrier = {}
   # BUG: inject is OUTSIDE the span's `with` block, so no span is active.
   with tracer.start_as_current_span("A: request") as a:
       print("A trace_id =", f"{a.get_span_context().trace_id:032x}")
   inject(carrier)                       # <-- runs after the span ended
   print("carrier:", carrier)

   ctx = extract(carrier)
   with tracer.start_as_current_span("B: handle", context=ctx) as b:
       print("B trace_id =", f"{b.get_span_context().trace_id:032x}")
   ```

2. Run it and observe the failure:

   ```bash
   python3 broken.py
   ```

   Expected (buggy) output — note `carrier` is **empty** and the two trace IDs **differ**:

   ```
   A trace_id = 1111...aaaa
   carrier: {}
   B trace_id = 2222...bbbb        # different trace — B started a NEW root
   ```

3. Diagnose: the carrier is empty because at the moment `inject` ran, there was no valid active span in the context, so the W3C propagator had nothing to write. `extract({})` then returned an empty context, so B started a fresh root trace.

4. Fix it by moving `inject(carrier)` **inside** the `with` block (so the span is active when you inject):

   ```python
   with tracer.start_as_current_span("A: request") as a:
       print("A trace_id =", f"{a.get_span_context().trace_id:032x}")
       inject(carrier)                   # span is active here
   ```

5. Re-run. Now `carrier` contains a `traceparent`, and A's and B's `trace_id` values match. One trace restored.

### Verification questions

- **Q6.1** — In the buggy run, why was the carrier empty rather than raising an exception? What does this teach you about how propagation failures typically surface?
- **Q6.2** — Given only the two console outputs (before you saw the code), what single observable symptom told you propagation had failed?
- **Q6.3** — You inspect a live carrier and it *does* contain `traceparent: 00-<id>-<id>-00`. The downstream trace still looks "missing" in your backend. Given the `trace-flags` value, what is the most likely non-bug explanation, and how would you confirm it?
- **Q6.4** — Name two real-world infrastructure culprits (not application code) that strip or rewrite `traceparent`/`x-b3-*` headers and produce this exact "two disconnected traces" symptom.

---

## Answers

<details>
<summary>Click to reveal answers</summary>

### Exercise 1

- **A1.1** — The `trace-id` field is all zeros, which the W3C Trace Context spec explicitly defines as **invalid**. An all-zero trace-id (or span-id) MUST be rejected; a conforming receiver discards the incoming context and starts a new trace/root span rather than adopting an unusable identifier. This prevents "poisoned" all-zero IDs from linking unrelated requests. (See [W3C Trace Context §3.2.2.3](https://www.w3.org/TR/trace-context/#trace-id).)
- **A1.2** — `traceparent` carries the **standard, required identifiers** — version, trace-id, parent span-id, and trace-flags — that OpenTelemetry needs to reconstruct parent/child links across services. `tracestate` carries **optional, vendor-specific** key=value data (e.g., a vendor's own sampling state) and is a mutable, ordered list. Linking spans depends on `traceparent`; `tracestate` is auxiliary and can be dropped without breaking the trace graph.
- **A1.3** — `trace-flags = 00` means the **sampled bit is unset**: the upstream indicated this trace was (probably) not sampled. The receiver still receives valid trace/span IDs and **is still obligated to propagate `traceparent` unchanged** downstream (and may make its own sampling decision depending on the configured sampler, e.g. `ParentBased`). "Not sampled" ≠ "no context"; propagation and sampling are independent concerns.
- **A1.4** — You **parse it anyway**. The spec mandates forward compatibility: a receiver that supports version `00` must still parse the first four known fields of a higher version it doesn't fully understand, ignoring any extra trailing data, rather than rejecting the request. Only a genuinely malformed header (wrong field lengths, invalid hex, all-zero IDs) is rejected.

### Exercise 2

- **A2.1** — The **`Context`** object (the active/current context), stored in an implicit, ambient location managed by the `ContextManager` — in Python that is a `contextvars.ContextVar`. `start_as_current_span` pushed `outer` into that context, and `trace.get_current_span()` inside `inner()` read it back out without any argument passing.
- **A2.2** — **No.** `start_span` creates the span but does **not** set it as the active span in the context. So when `inner()` runs and starts `inner-work`, the active span is still whatever it was before (potentially the invalid/root context), and `inner-work` would *not* be parented to `outer`. Only `start_as_current_span` (or an explicit `attach`) updates the active context that children read.
- **A2.3** — By default, **no** — a freshly created `threading.Thread` does **not** inherit the parent thread's active context in most implementations (each thread has its own `contextvars` copy taken at creation time, and worker threads started later don't get it automatically). This shows the implicit `Context` is **execution-unit-scoped** (per thread / per async task), which is exactly why crossing thread, async, or process boundaries requires explicit context handling (`attach`, or inject/extract).

### Exercise 3

- **A3.1** — From the **current context**. `inject(carrier)` with no explicit context argument reads the globally-active `Context`, pulls the active span's `SpanContext` out of it, and serializes its trace-id/span-id/flags into `traceparent`. Because the call is inside the span's `with` block, that span is the active one.
- **A3.2** — `extract` returns a **`Context`** because the remote data is not a live span object — it is just serialized `SpanContext` values describing a *remote parent*. The correct use is to pass that `Context` into `start_as_current_span(..., context=parent_ctx)` so the new local span becomes a child of the remote span. If you started B's span **without** passing that context, B would ignore the incoming parent and start a **new root trace** — the two services would show up as two disconnected traces.
- **A3.3** — `extract({})` returns effectively an **empty/root context** (no valid remote span). The span B then starts is **not an error** — it simply becomes a **new root span of a new trace**. This is the graceful-degradation design: missing headers never crash the service, they just break the trace linkage silently.
- **A3.4** — A plain `dict` works because the getter/setter defaults do simple key lookups. Real HTTP requires a custom getter/setter because HTTP header names are **case-insensitive** (`Traceparent` vs `traceparent`) and headers can be **multi-valued** (a list per key). The framework-specific propagator getter normalizes case and knows how to return/append list values correctly.

### Exercise 4

- **A4.1** — **No.** Baggage lives in the `Context` and is propagated in its own `baggage` header, but it is **never automatically copied onto spans** in either service. To attach it to a span you must explicitly read it (`baggage.get_baggage(...)`) and call `span.set_attribute(...)` — as shown in step 3.
- **A4.2** — Baggage is propagated to **every** downstream service and frequently logged, so it is trivial to accidentally leak sensitive data across trust boundaries and into log stores. **Never put secrets, PII, tokens, or auth credentials in Baggage** — treat it as broadcast, unencrypted, potentially-persisted metadata.
- **A4.3** — Because the OpenTelemetry `Context` is specified as **immutable**: every mutation (`set_baggage`, `attach`) returns a *new* Context rather than editing shared state. This copy-on-write model makes context safe to share across concurrent execution units — a child task or thread can't accidentally corrupt a parent's context, and there are no data races on the ambient context.
- **A4.4** — Because trace context and Baggage are handled by **two different propagators** (`TraceContextTextMapPropagator` and `W3CBaggagePropagator`) composed in the default `CompositePropagator`. Each writes to its own header key per the respective W3C spec (`traceparent`/`tracestate` vs `baggage`). They are orthogonal concerns kept in separate, independently-parseable headers.

### Exercise 5

- **A5.1** — On **inject**, a `CompositePropagator` calls each child propagator in turn so the carrier ends up with **all** formats (e.g., both `traceparent` and `x-b3-*`). On **extract**, it also calls each child in order, and each successive extractor operates on the context produced by the previous one — so with the default ordering the **later-listed** propagator can overwrite an earlier one's result. In practice you order them so the format you trust most is applied last (wins) when multiple header sets are present.
- **A5.2** — Because during migration some services still only read B3 and others only read W3C. Injecting **both** formats simultaneously means *every* downstream service finds a header it understands, so no trace is broken mid-migration. If you flipped services to `tracecontext`-only one at a time, any B3-only service downstream of a switched service would fail to extract context and start a new root trace — producing disconnected traces until the whole fleet is converted.
- **A5.3** — Single-header `b3` (one `b3:` header) is friendlier to systems that **limit the number of headers** or where every header adds overhead. Multi-header `b3multi` (`x-b3-traceid`, `x-b3-spanid`, `x-b3-sampled`) is **easier to grep/inspect** in logs and proxies because each value is its own named header rather than a packed, dash-delimited string.
- **A5.4** — With `tracecontext,b3multi`, extraction runs `tracecontext` first, then `b3multi`, and because the composite applies them in sequence the **last one that finds valid data effectively wins** — here `b3multi` would override the W3C-derived context if both are present and differ. Order matters because it deterministically resolves conflicts when a request arrives carrying multiple, disagreeing propagation formats; you list your authoritative format last.

### Exercise 6

- **A6.1** — Because propagation is designed to **fail silently / degrade gracefully**, never to raise. When `inject` ran there was no valid active span, so the W3C propagator simply had nothing to serialize and wrote nothing — an empty carrier, not an exception. The lesson: context-propagation bugs manifest as **missing or broken traces in your backend**, not as stack traces in your logs, so you must detect them by observing trace shape.
- **A6.2** — The two `trace_id` values were **different** (`A trace_id` ≠ `B trace_id`). When A and B belong to the same logical request but report different trace-ids, propagation has failed and you're looking at two roots instead of one parent/child trace. (A secondary tell: the injected `carrier` was empty.)
- **A6.3** — The `trace-flags` byte is `00`, i.e. **sampled = false**. This is very likely **not a bug**: the trace was intentionally not sampled, so a `ParentBased` sampler downstream also dropped it and nothing reached your backend. Confirm by forcing/raising the sample rate (or using an always-on sampler) and re-issuing the request, then checking whether the trace now appears with `trace-flags = 01`.
- **A6.4** — Common infrastructure culprits: (1) **API gateways / reverse proxies / load balancers** (e.g., misconfigured NGINX, Envoy, ALB) that drop or don't forward custom/`traceparent` headers; (2) **service meshes** emitting a *different* propagation format than the app expects (B3 vs W3C mismatch); also CDNs, WAFs, and message brokers that don't carry headers across a queue. Any of these strips or rewrites the propagation headers and yields the "two disconnected traces" symptom.

</details>