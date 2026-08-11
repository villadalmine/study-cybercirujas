# Topic 2.6 — Context Propagation

**Certification:** OpenTelemetry Certified Associate (OTCA) · **Exam weight:** 6.57%

> These guided exercises take you from *in-process* context (how a single process remembers "which span am I inside right now?") to *cross-process* propagation (how that identity survives a network hop), through Baggage, propagator selection, and finally the diagnosis of a **snapped trace** — the single most common production incident in this domain.
>
> **Prerequisites.** Python 3.9+, and a scratch virtualenv:
> ```bash
> python -m venv .venv && source .venv/bin/activate
> pip install "opentelemetry-api==1.*" "opentelemetry-sdk==1.*"
> ```
> The mechanics you observe here are language-agnostic — the OpenTelemetry *specification* defines Context, Propagators, and Baggage independently of any SDK. Python is used because its output is easy to read.
>
> **Sources referenced throughout:**
> - Context propagation concept — https://opentelemetry.io/docs/concepts/context-propagation/
> - Context specification — https://opentelemetry.io/docs/specs/otel/context/
> - Propagators API — https://opentelemetry.io/docs/specs/otel/context/api-propagators/
> - Baggage API — https://opentelemetry.io/docs/specs/otel/baggage/api/
> - W3C Trace Context — https://www.w3.org/TR/trace-context/
> - W3C Baggage — https://www.w3.org/TR/baggage/
> - SDK configuration (`OTEL_PROPAGATORS`) — https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/

---

## Exercise 1 — The Context object: immutable, and *not* thread-local by accident

The `Context` is an **immutable** key/value container. Every "mutation" returns a *new* Context; the "current" Context is what makes `start_as_current_span` know its parent. You will prove both properties.

1. Create `ex1_context.py`:

    ```python
    from opentelemetry import context, baggage

    # 1. Context is immutable: set_baggage returns a NEW context,
    #    it does not modify the one you passed in.
    root = context.get_current()
    ctx_a = baggage.set_baggage("tenant", "acme", context=root)
    ctx_b = baggage.set_baggage("tenant", "globex", context=root)

    print("root  :", baggage.get_all(context=root))
    print("ctx_a :", baggage.get_all(context=ctx_a))
    print("ctx_b :", baggage.get_all(context=ctx_b))

    # 2. The "current" context is separate from any local variable.
    print("current (before attach):", baggage.get_all())
    token = context.attach(ctx_a)          # attach makes ctx_a current
    print("current (after attach) :", baggage.get_all())
    context.detach(token)                  # detach restores the previous current
    print("current (after detach) :", baggage.get_all())
    ```

2. Run it:

    ```bash
    python ex1_context.py
    ```

    Expected output:

    ```
    root  : {}
    ctx_a : {'tenant': 'acme'}
    ctx_b : {'tenant': 'globex'}
    current (before attach): {}
    current (after attach) : {'tenant': 'acme'}
    current (after detach) : {}
    ```

3. Now **forget the token** to see why `detach` exists. Add a second `attach` without detaching in between, then detach in the wrong order:

    ```python
    t1 = context.attach(baggage.set_baggage("layer", "one"))
    t2 = context.attach(baggage.set_baggage("layer", "two"))
    context.detach(t1)   # detaching t1 first — out of order
    print("out-of-order current:", baggage.get_all())
    ```

    Observe that this either warns or leaves a value you did not expect — `attach`/`detach` behave like a **stack**, and must be unwound Last-In-First-Out.

**Check your understanding**

- Q1.1 — `ctx_a` and `ctx_b` were both derived from `root`. Why does modifying one never affect the other, and why is that property essential for concurrent request handling?
- Q1.2 — `context.attach()` returns a *token*. What is the token for, and what breaks if you never call `detach()` with it?
- Q1.3 — In step 3, why must `attach`/`detach` be unwound in Last-In-First-Out order?
- Q1.4 — In an `async`/threaded server, what underlying mechanism does the Python SDK use so that "current context" is correct per-task, not shared globally? (Name the concept the specification requires.)

---

## Exercise 2 — Dissecting the W3C `traceparent`

Cross-process propagation is, physically, just HTTP headers. The W3C Trace Context standard defines `traceparent` (mandatory fields) and `tracestate` (vendor data). You will generate one and decode every byte.

1. Create `ex2_traceparent.py`:

    ```python
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import inject

    trace.set_tracer_provider(TracerProvider())
    tracer = trace.get_tracer("ex2")

    carrier = {}
    with tracer.start_as_current_span("checkout") as span:
        sc = span.get_span_context()
        print("trace_id   :", format(sc.trace_id, "032x"))
        print("span_id    :", format(sc.span_id, "016x"))
        print("trace_flags:", format(int(sc.trace_flags), "02x"))
        inject(carrier)                       # serialize CURRENT context into carrier

    print("carrier    :", carrier)
    ```

2. Run it (values are random per run):

    ```bash
    python ex2_traceparent.py
    ```

    Example output:

    ```
    trace_id   : 4bf92f3577b34da6a3ce929d0e0e4736
    span_id    : 00f067aa0ba902b7
    trace_flags: 01
    carrier    : {'traceparent': '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'}
    ```

3. Map the `traceparent` string to its four dash-separated fields:

    ```
    00 - 4bf92f3577b34da6a3ce929d0e0e4736 - 00f067aa0ba902b7 - 01
    │    │                                  │                  │
    │    │                                  │                  └─ trace-flags (1 byte): bit 0 = sampled
    │    │                                  └─ parent-id / span-id (8 bytes, 16 hex)
    │    └─ trace-id (16 bytes, 32 hex) — globally unique per trace
    └─ version (1 byte) — currently 00
    ```

4. Confirm the "all-zero is invalid" rule. A `trace-id` of 32 zeros or a `span-id` of 16 zeros is defined as invalid by the spec and MUST be rejected. Feed a malformed header to the extractor and watch it refuse:

    ```python
    from opentelemetry.propagate import extract
    from opentelemetry import trace

    bad = {"traceparent": "00-00000000000000000000000000000000-00f067aa0ba902b7-01"}
    ctx = extract(bad)
    sc = trace.get_current_span(ctx).get_span_context()
    print("is_valid:", sc.is_valid)          # False — invalid trace-id rejected
    ```

**Check your understanding**

- Q2.1 — How many *bytes* (not hex characters) are the `trace-id` and the `span-id`, and why does the length matter for uniqueness guarantees across a fleet?
- Q2.2 — The `traceparent` you generated ended in `-01`. What does the byte `01` mean, and what would `-00` tell a downstream service about whether to record?
- Q2.3 — A downstream service receives `version` byte `cc` (a future version it does not understand). Per the W3C spec, must it drop the header or can it still use it? Explain the forward-compatibility rule.
- Q2.4 — What is `tracestate` *for*, and why is it a separate header from `traceparent` instead of more fields inside it?

---

## Exercise 3 — Manual inject / extract: stitching two processes together

Instrumentation libraries call `inject`/`extract` for you. Here you do it by hand across a real socket boundary so you can *see* the trace survive the hop.

1. Create the **caller** `ex3_client.py`:

    ```python
    import http.client, json
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import inject

    trace.set_tracer_provider(TracerProvider())
    tracer = trace.get_tracer("client")

    with tracer.start_as_current_span("client.request") as span:
        headers = {}
        inject(headers)                                  # <-- writes traceparent
        print("CLIENT trace_id:", format(span.get_span_context().trace_id, "032x"))
        print("CLIENT sending headers:", headers)
        conn = http.client.HTTPConnection("localhost", 8080)
        conn.request("GET", "/", headers=headers)
        conn.getresponse().read()
    ```

2. Create the **callee** `ex3_server.py`:

    ```python
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import extract

    trace.set_tracer_provider(TracerProvider())
    tracer = trace.get_tracer("server")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            ctx = extract(dict(self.headers))            # <-- reads traceparent
            with tracer.start_as_current_span("server.handle", context=ctx) as span:
                sc = span.get_span_context()
                parent = getattr(span, "parent", None)
                print("SERVER trace_id  :", format(sc.trace_id, "032x"))
                print("SERVER parent set:", parent is not None)
            self.send_response(200); self.end_headers()

    HTTPServer(("localhost", 8080), Handler).serve_forever()
    ```

3. In terminal A start the server, in terminal B run the client:

    ```bash
    # terminal A
    python ex3_server.py
    # terminal B
    python ex3_client.py
    ```

    Expected (the trace_id is identical on both sides — that is the whole point):

    ```
    # client
    CLIENT trace_id: 9c8f1e2a...d31b
    CLIENT sending headers: {'traceparent': '00-9c8f1e2a...d31b-a1b2...-01'}
    # server
    SERVER trace_id  : 9c8f1e2a...d31b
    SERVER parent set: True
    ```

4. Now **break** it deliberately: comment out the `inject(headers)` line in the client and re-run. The server prints a *different* `trace_id` and `SERVER parent set: False` — with no incoming context, `extract` returns an empty context and the server span becomes a new **root**. This is a snapped trace, reproduced in one line.

**Check your understanding**

- Q3.1 — On the server side, why did `start_as_current_span(..., context=ctx)` make the server span a *child* rather than a root? What did `ctx` carry that the default (current) context did not?
- Q3.2 — In step 4, with `inject` removed, `extract` still returned *something*. What did it return, and why did that cause a new root span instead of an error?
- Q3.3 — `extract` takes a "carrier" (here `dict(self.headers)`). What interface must a carrier satisfy for a `TextMapPropagator`, and why is that abstraction (Getter/Setter) important for non-HTTP transports like Kafka?
- Q3.4 — Where in a real service would you normally *not* write `inject`/`extract` yourself, and what component does it for you?

---

## Exercise 4 — Baggage: carrying business context across the whole call graph

`traceparent` propagates *identity*. **Baggage** propagates *arbitrary key/value data* (e.g. `user.tier=premium`) so every downstream service can read it. You will set baggage, watch it serialize into its own header, and read it three hops later.

1. Create `ex4_baggage.py`:

    ```python
    from opentelemetry import baggage, context
    from opentelemetry.propagate import inject, extract

    # Set two baggage entries on a fresh context.
    ctx = baggage.set_baggage("user.tier", "premium")
    ctx = baggage.set_baggage("cart.experiment", "checkout-v3", context=ctx)

    carrier = {}
    inject(carrier, context=ctx)
    print("wire headers:", carrier)

    # Simulate the next service extracting from the same carrier.
    downstream = extract(carrier)
    print("downstream tier      :", baggage.get_baggage("user.tier", downstream))
    print("downstream experiment:", baggage.get_baggage("cart.experiment", downstream))
    print("downstream all       :", baggage.get_all(downstream))
    ```

2. Run it:

    ```bash
    python ex4_baggage.py
    ```

    Expected output:

    ```
    wire headers: {'baggage': 'user.tier=premium,cart.experiment=checkout-v3'}
    downstream tier      : premium
    downstream experiment: checkout-v3
    downstream all        : {'user.tier': 'premium', 'cart.experiment': 'checkout-v3'}
    ```

3. Observe URL-encoding. Baggage values with reserved characters are percent-encoded on the wire per W3C Baggage:

    ```python
    from opentelemetry import baggage
    from opentelemetry.propagate import inject
    ctx = baggage.set_baggage("server.node", "DF 28")   # value contains a space
    carrier = {}
    inject(carrier, context=ctx)
    print(carrier)          # {'baggage': 'server.node=DF%2028'}
    ```

4. Understand the **cost**. Baggage rides on *every* outbound request in the trace. Add a large value and note that it inflates every header on every hop:

    ```python
    big = "x" * 4000
    ctx = baggage.set_baggage("dump", big)
    carrier = {}
    inject(carrier, context=ctx)
    print("header bytes:", len(carrier.get("baggage", "")))   # ~4008
    ```

**Check your understanding**

- Q4.1 — Baggage and `traceparent` are *both* forms of propagated context, but they answer different questions. State the one-sentence difference in purpose.
- Q4.2 — The value `"DF 28"` appeared on the wire as `DF%2028`. Which specification mandates this encoding, and what would break if the space were sent raw?
- Q4.3 — A developer stores a customer's full JWT in baggage so every service can authorize. Give **two** distinct reasons this is a serious anti-pattern (hint: one is about bytes, one is about trust/PII).
- Q4.4 — By default, does an entry in Baggage automatically become an attribute on your spans? What must you do explicitly to record baggage onto a span, and why is that separation deliberate?

---

## Exercise 5 — Choosing propagators: composite, B3, and `OTEL_PROPAGATORS`

The propagator is *configurable*. If two services disagree on the wire format, context does not cross. You will switch formats with a single environment variable.

1. Confirm the default. With no configuration, the global propagator is the **composite** `tracecontext,baggage`. Create `ex5_default.py`:

    ```python
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import inject

    trace.set_tracer_provider(TracerProvider())
    tracer = trace.get_tracer("ex5")

    carrier = {}
    with tracer.start_as_current_span("op"):
        inject(carrier)
    print("headers:", sorted(carrier))
    ```

    ```bash
    python ex5_default.py
    # headers: ['traceparent']         (and 'baggage' too, if any baggage is set)
    ```

2. Install and select **B3 multi-header** (the Zipkin format), via `OTEL_PROPAGATORS`:

    ```bash
    pip install opentelemetry-propagator-b3
    OTEL_PROPAGATORS=b3multi python ex5_default.py
    ```

    Expected — the wire format changes completely, no code edit required:

    ```
    headers: ['x-b3-sampled', 'x-b3-spanid', 'x-b3-traceid']
    ```

3. Select **B3 single-header** and inspect its packed form:

    ```bash
    OTEL_PROPAGATORS=b3 python - <<'PY'
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import inject
    trace.set_tracer_provider(TracerProvider())
    with trace.get_tracer("x").start_as_current_span("op"):
        c = {}; inject(c); print(c)
    PY
    # {'b3': '<traceid>-<spanid>-1'}     # trace-span-sampled packed in one header
    ```

4. **Interoperate.** A fleet migrating from Zipkin to W3C runs both formats during the cutover. Emit *both* by listing multiple propagators — the composite injects each and extracts whichever arrives:

    ```bash
    OTEL_PROPAGATORS=tracecontext,b3multi,baggage python ex5_default.py
    # headers: ['traceparent', 'x-b3-sampled', 'x-b3-spanid', 'x-b3-traceid']
    ```

**Check your understanding**

- Q5.1 — What is the default value of `OTEL_PROPAGATORS` per the OpenTelemetry specification, and which two propagators does it contain?
- Q5.2 — Service A is configured `OTEL_PROPAGATORS=b3multi`; Service B is left at the default. A calls B. Describe exactly what B's extract step produces and what happens to the trace.
- Q5.3 — In step 4 you set `tracecontext,b3multi,baggage`. On *extraction*, if an incoming request carries **both** a `traceparent` and B3 headers that disagree, how does a composite propagator resolve the conflict? (Think about ordering / last-writer.)
- Q5.4 — Why is putting the interoperability at the *propagator* layer (env var) — rather than forking your instrumentation code — the correct design during a vendor migration?

---

## Exercise 6 — Diagnosing a snapped trace (production scenario)

You are on-call. A trace that should span `gateway → orders → payments` shows up in the backend as **two** disconnected traces: `gateway` alone, and `orders → payments`. The link between the gateway and orders is gone. Work the diagnosis.

1. Reproduce the fault. Simulate the gateway emitting **B3 only** while orders extracts **W3C only**:

    ```bash
    # gateway injects b3multi
    OTEL_PROPAGATORS=b3multi python - <<'PY'
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import inject
    trace.set_tracer_provider(TracerProvider())
    with trace.get_tracer("gw").start_as_current_span("gateway"):
        c = {}; inject(c)
    import json; print(json.dumps(c))     # save these headers
    PY
    ```

    You get, for example: `{"x-b3-traceid": "...", "x-b3-spanid": "...", "x-b3-sampled": "1"}`

2. Feed those exact headers to a service configured for **W3C only** and see the link snap:

    ```bash
    OTEL_PROPAGATORS=tracecontext python - <<'PY'
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import extract
    trace.set_tracer_provider(TracerProvider())
    incoming = {"x-b3-traceid": "8f2e...", "x-b3-spanid": "aa11...", "x-b3-sampled": "1"}
    ctx = extract(incoming)
    with trace.get_tracer("orders").start_as_current_span("orders", context=ctx) as s:
        p = getattr(s, "parent", None)
        print("parent linked:", p is not None)      # False -> NEW ROOT -> snapped
    PY
    ```

    Output: `parent linked: False`. The `tracecontext` extractor never looks at `x-b3-*` headers, so it returns an empty context and `orders` starts a fresh trace.

3. Walk the diagnostic ladder, top to bottom, stopping at the first "no":

    1. **Is the header on the wire at all?** `curl -v` or a proxy access log — confirm a `traceparent` (or `b3`) header actually leaves the gateway.
    2. **Do both sides agree on the format?** Compare `OTEL_PROPAGATORS` on each service. (This is the fault here.)
    3. **Did a proxy strip it?** Some ingress/WAF configurations drop unknown headers — check the allow-list.
    4. **Is the client instrumented?** An un-instrumented HTTP client never calls `inject`; the header is simply absent.

4. **Fix** by aligning propagators. Set both services to a superset that covers the migration:

    ```bash
    OTEL_PROPAGATORS=tracecontext,b3multi
    ```

    Re-run step 2 with this value and confirm `parent linked: True`.

**Check your understanding**

- Q6.1 — The symptom was "one logical request appears as two traces." What is the precise root cause, in terms of what `extract` returned?
- Q6.2 — Order the diagnostic checks in step 3 from cheapest to most expensive to verify, and justify why "compare `OTEL_PROPAGATORS`" is worth doing early even though it is not first.
- Q6.3 — The fix set `tracecontext,b3multi` on *both* services. Explain why listing *both* propagators is safe (no double-counting of spans) and what each side now does on inject and on extract.
- Q6.4 — Give one class of snapped-trace failure that aligning `OTEL_PROPAGATORS` would **not** fix, and name the layer where you would look instead.

---

<details>
<summary><strong>Answer key — expand after attempting all exercises</strong></summary>

### Exercise 1 — The Context object

- **A1.1** — `Context` is **immutable**: `set_baggage` (and every write) returns a brand-new Context sharing nothing mutable with its parent, so `ctx_a` and `ctx_b` are independent snapshots of `root`. This is essential for concurrency because thousands of in-flight requests each hold their own Context; if a write to one request's context could leak into another's, you would get cross-request trace corruption (a span from request X parented under request Y). Immutability makes context sharing across tasks safe by construction. (Spec: https://opentelemetry.io/docs/specs/otel/context/)
- **A1.2** — `attach()` sets a new *current* Context and returns a **token** representing the context that was current *before* the attach. `detach(token)` restores that previous context. If you never detach, the context is never unwound: subsequent operations in that execution unit inherit stale baggage/parent spans, producing mis-parented spans and leaked baggage. The token is the SDK's undo handle.
- **A1.3** — `attach`/`detach` model a **stack**. Each `attach` pushes; each `detach` should pop the top. Detaching a lower token first (`t1` before `t2`) leaves the stack inconsistent — the runtime cannot correctly restore intermediate states, so you get a warning and/or a "current" context that does not match what you expect. Always unwind Last-In-First-Out (which `with`-blocks and try/finally give you for free).
- **A1.4** — The specification requires that Context be propagated **implicitly per execution unit** without leaking across units. In Python this is implemented with **`contextvars.ContextVar`**, which is coroutine-/thread-aware: each async task and thread sees its own current context. (Other languages use the equivalent: Go passes `context.Context` explicitly, Java uses thread-locals / Scope.)

### Exercise 2 — W3C `traceparent`

- **A2.1** — `trace-id` is **16 bytes** (128 bits → 32 hex chars); `span-id` is **8 bytes** (64 bits → 16 hex chars). The 128-bit trace-id is large enough that randomly generated ids across a global fleet have negligible collision probability, so any two services can mint ids independently and still expect uniqueness — no central coordinator needed. (Spec: https://www.w3.org/TR/trace-context/#trace-id)
- **A2.2** — `01` is `trace-flags` with **bit 0 (the `sampled` flag) set**, meaning the caller recorded/sampled this trace and is signalling the downstream to do the same. `-00` means *not sampled*: the upstream did not record it, and a downstream honoring the flag would also not record — keeping a trace consistently sampled or unsampled end-to-end. (Note: flags are a *hint*; sampling decisions ultimately depend on the configured sampler, e.g. `ParentBased`.)
- **A2.3** — It must **still use it**. The W3C spec mandates forward compatibility: an unknown higher `version` is parsed as if it were the highest version the implementation understands; the receiver reads the known fields (trace-id, parent-id, flags) and ignores anything after them, rather than dropping the header. Dropping would needlessly snap traces every time the standard evolves. (Spec: https://www.w3.org/TR/trace-context/#versioning-of-traceparent)
- **A2.4** — `tracestate` carries **vendor-specific / multi-vendor position information** as an ordered list of `key=value` pairs (e.g. a vendor's own span id in their format). It is separate from `traceparent` because `traceparent` is a fixed, mandatory, universally-understood structure, whereas `tracestate` is variable-length, optional, and per-vendor — mixing them would break `traceparent`'s simple, forward-compatible parse. `tracestate` also survives even when a hop doesn't understand a given vendor's entry.

### Exercise 3 — Manual inject / extract

- **A3.1** — `ctx` was built by `extract` from the incoming headers and therefore held the **remote SpanContext** (the client's trace-id and span-id) as its "current span." Passing it as `context=ctx` told `start_as_current_span` to use that remote span as the **parent**, so the new server span inherited the client's trace-id and pointed its `parent` at the client span. The default current context (a fresh process with no active span) had no such parent, which is why omitting `context=ctx` yields a root.
- **A3.2** — `extract` returned an **empty (root) Context** — specifically a context whose current span is the invalid/no-op span. It is not an error: absence of a `traceparent` header is a legitimate, common case (the very first service in a chain, or an un-instrumented caller). With no valid parent SpanContext, `start_as_current_span` correctly begins a new trace root. Returning an error would make every entry-point service fail.
- **A3.3** — A `TextMapPropagator` reads via a **Getter** (`get(carrier, key)`, `keys(carrier)`) and writes via a **Setter** (`set(carrier, key, value)`). Any carrier that can be adapted to those operations works — an HTTP header map, a Kafka record's headers, a gRPC metadata object, an AMQP message. This decoupling is why the *same* propagator serializes context over HTTP and over a message queue: the format (traceparent) is fixed; only the Getter/Setter changes per transport. (Spec: https://opentelemetry.io/docs/specs/otel/context/api-propagators/)
- **A3.4** — In a real service you almost never call `inject`/`extract` by hand — the **instrumentation libraries** do it: server-side middleware (e.g. the ASGI/WSGI/Flask/gRPC instrumentation) calls `extract` on the incoming request, and the instrumented HTTP/gRPC/messaging **client** calls `inject` on the outgoing request. Manual calls are only needed for custom or unsupported transports.

### Exercise 4 — Baggage

- **A4.1** — `traceparent` propagates **trace identity** (which trace/span am I part of — used to stitch spans together); **Baggage** propagates **arbitrary application key/value data** (e.g. `user.tier`, `experiment.id`) so downstream services can read business context. Identity vs. data.
- **A4.2** — The **W3C Baggage** specification (https://www.w3.org/TR/baggage/) requires percent-encoding of characters that are not allowed in the header value (spaces, commas, `=`, control chars, etc.). Sending a raw space or comma would corrupt parsing — commas separate list members and `=` separates key from value, so an un-encoded value could be split into bogus entries or truncated.
- **A4.3** — (1) **Byte cost / performance**: baggage is appended to *every* outbound request header for the remainder of the trace; a multi-KB JWT multiplies bandwidth and can exceed proxy/server header size limits (causing 431/400 errors), and it is paid on every hop. (2) **Security / PII & trust**: baggage is plaintext, forwarded to *every* downstream service including ones outside your trust boundary or third-party vendors, and is easily logged; putting credentials or PII there leaks them broadly and can enable token replay. Baggage should hold small, non-sensitive routing/experiment hints only.
- **A4.4** — **No.** Baggage entries are *not* automatically copied onto spans. To record them you must explicitly read baggage and call `span.set_attribute(...)`, typically via a **`BaggageSpanProcessor`** or manual code. The separation is deliberate for privacy and cost control: since baggage crosses trust boundaries and may hold data you do *not* want persisted in your telemetry backend, the spec makes writing it to spans an explicit, opt-in act rather than an automatic leak.

### Exercise 5 — Choosing propagators

- **A5.1** — The specification default for `OTEL_PROPAGATORS` is **`tracecontext,baggage`** — the W3C Trace Context propagator plus the W3C Baggage propagator. (Ref: https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)
- **A5.2** — B's `tracecontext` extractor looks only for a `traceparent` header. A sent only `x-b3-*` headers, so extract finds no `traceparent`, returns an **empty context**, and B's entry span becomes a **new root** — the trace snaps into two disconnected traces. No error is raised; the break is silent.
- **A5.3** — A composite propagator runs its extractors **in list order, each writing into the context**, so a *later* propagator that finds a valid value **overwrites** what an earlier one set (last-writer-wins for the current span). With `tracecontext,b3multi,baggage`, if both `traceparent` and B3 are present and disagree, the **B3 result wins** because `b3multi` runs after `tracecontext`. The practical guidance: list your canonical format **last** so it takes precedence during a migration.
- **A5.4** — Because the wire format is a **cross-cutting transport concern**, not business logic. Moving it to the propagator layer means you flip one env var per service to add/remove a format, roll the change out gradually, and run both formats simultaneously during cutover — with zero changes to instrumentation or application code, and instantly revertible. Forking instrumentation code would couple format to logic, require redeploys to change, and be far harder to roll back.

### Exercise 6 — Diagnosing a snapped trace

- **A6.1** — Root cause: **propagator format mismatch**. The gateway injected B3 (`x-b3-*`) headers, but `orders` was configured with `tracecontext` only, whose extractor ignores `x-b3-*`. `extract` therefore returned an **empty context** (no valid parent SpanContext), so `orders` started a **new root span** and its trace-id diverged from the gateway's — one logical request rendered as two traces.
- **A6.2** — Cheapest→most expensive: (1) **Compare `OTEL_PROPAGATORS`** on both services — a config/env diff, no traffic needed, and it directly explains a *silent, consistent* break, which is why it's worth checking very early. (2) **Check the header on the wire** (`curl -v` / proxy log) — needs a request but is quick. (3) **Check whether a proxy strips the header** — needs proxy config access and possibly a test request. (4) **Verify the client is instrumented** — may need code/deploy inspection. Config diff and wire check are both near-free; put the config diff early because a mismatch reproduces 100% of the time whereas an occasionally-stripped header does not.
- **A6.3** — Listing `tracecontext,b3multi` on both sides does **not** create duplicate spans, because propagators only **serialize/deserialize context** — they never start spans. On **inject**, each side writes *both* a `traceparent` and `x-b3-*` headers (same trace-id, just two encodings). On **extract**, each side tries both extractors and links the trace from whichever header is present, so a caller speaking either dialect is understood. This is exactly the safe superset for a mixed fleet during migration.
- **A6.4** — Aligning propagators does **not** fix a break where the header **never leaves the caller** or is **stripped in transit** — e.g. an un-instrumented HTTP client that never calls `inject`, or an ingress/WAF/service-mesh proxy that drops unknown headers from its allow-list. There the trace-id is absent on the wire regardless of format, so you look at the **instrumentation layer** (is the client library instrumented and `inject` being called?) or the **network/proxy layer** (header allow-list, mesh header propagation config), not `OTEL_PROPAGATORS`.

</details>