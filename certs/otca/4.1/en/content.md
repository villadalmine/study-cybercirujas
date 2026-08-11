# 4.1 Context Propagation

> **Domain:** OpenTelemetry API & SDK · **Exam weight:** 2.5
> **Reference syllabus:** OTCA Curriculum (CNCF)

---

## 1. The production problem: why a trace dies at the process boundary

A span is trivial to create inside one process. The hard part of distributed tracing is not *emitting* spans — it is making the span emitted by `checkout` and the span emitted by `payment` belong to **the same trace**, even though they run in different pods, different languages, different teams, and never share memory.

Consider a request path in a shop:

```
client ──► ingress ──► checkout ──► cart ──► payment ──► ledger
                            │            │
                            └──► shipping └──► inventory
```

Each hop is a fresh OS process with its own SDK, its own random-number generator, and its own idea of "the current span". If nothing crosses the wire, every service starts a **new root span with a new `trace_id`**. The result in your backend is not one trace with 40 spans — it is **40 disconnected single-span traces (orphans)**. You lose the one thing distributed tracing exists to give you: a causal, end-to-end view of a single request.

**Context Propagation** is the mechanism that fixes this. It carries two things across every boundary:

1. **Span context** — `trace_id`, `span_id`, `trace_flags` (the sampling decision), `trace_state`. This is what stitches child spans to their remote parent.
2. **Baggage** — arbitrary application key/value pairs (`user.tier=gold`, `tenant=acme`) that travel *alongside* the trace so downstream services can read business context they never received in their own request body.

The architectural insight for an SRE: **propagation is an instrumentation/SDK concern, not a Collector concern.** The Collector receives spans that *already* carry correct IDs and only transports/enriches them. If your traces are broken, the bug is almost always at the emitting service's inject/extract step — never in the Collector. Debugging the wrong layer here is the single most common time sink.

---

## 2. The Context object and the propagation model

OpenTelemetry splits propagation into two orthogonal halves that the exam expects you to keep straight.

### 2.1 In-process propagation — the `Context`

`Context` is an **immutable**, execution-scoped container. Every operation that "adds" to it returns a *new* `Context`; the previous one is untouched. The "current" context is what a newly started span uses as its parent.

How "current" is stored is language-dependent, and this is where async bugs are born:

| Language | In-process carrier | Async-safe by default | Production gotcha |
|---|---|---|---|
| **Go** | explicit `context.Context` argument | Yes (you thread it manually) | Forgetting to pass `ctx` to a downstream call silently starts a new root → orphan span |
| **Java** | `ThreadLocal` (`Context.current()`) | No | Thread pools / reactive (Reactor, RxJava) lose context; wrap executors with `Context.taskWrapping()` |
| **Python** | `contextvars` | Yes for `asyncio` | `ThreadPoolExecutor` does **not** copy context → use `contextvars.copy_context()` |
| **Node.js** | `AsyncLocalStorage` (`async_hooks`) | Yes | Libraries using old callback patterns or `process.nextTick` tricks can sever the async chain |
| **.NET** | `AsyncLocal` / `Activity.Current` | Yes | Manual `Task` continuations on custom schedulers can drop `Activity` |

### 2.2 Cross-process propagation — Propagators, Inject, Extract

A **Propagator** (formally a `TextMapPropagator`) serializes/deserializes context into a **carrier** (usually HTTP headers or gRPC/message-queue metadata):

- **`inject(context, carrier, setter)`** — writes headers on the **outbound** side (client).
- **`extract(carrier, context, getter)`** — reads headers on the **inbound** side (server) and returns a context whose "remote parent" is set.

`Setter` and `Getter` abstract *how* the carrier is written/read, so the same propagator works for `net/http` headers, gRPC metadata, or a Kafka record's headers.

```
[checkout]                            [payment]
tracer.start_span ──► ctx             extract(req.headers) ──► ctx (remote parent)
inject(ctx, headers) ──► HTTP ───────► tracer.start_span(context=ctx)
   traceparent: 00-4bf9…-00f0…-01         └── child of checkout's span ✔
```

---

## 3. Propagators: wire formats and trade-offs

### 3.1 W3C Trace Context (the default)

Two headers. This is the CNCF-standard, vendor-neutral format and the OTel default.

**`traceparent`** — a fixed-length, dash-delimited field:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
         version│         trace-id (16 B)        │  parent-id     │ trace-flags
          (00)  │          32 hex chars          │  (span-id,8 B) │  (2 hex)
                                                    16 hex chars
```

| Field | Bytes | Rule |
|---|---|---|
| `version` | 1 | Currently `00`. Unknown versions are parsed leniently, never rejected outright. |
| `trace-id` | 16 (128-bit) | 32 lowercase hex. **All-zero is invalid** → restart the trace. |
| `parent-id` | 8 (64-bit) | The caller's `span_id`, becomes this span's parent. **All-zero is invalid.** |
| `trace-flags` | 1 | Bit 0 = `sampled`. `01` = sampled, `00` = not. Only bit 0 is currently defined. |

**`tracestate`** — vendor-specific continuation of state, comma-separated `key=value`:

```
tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

- Max **32** list members; keys/values constrained; keep total under ~512 bytes.
- **Ordering is significant** — the most-recently-mutating vendor prepends its entry to the head.
- If `traceparent` is malformed, you MUST restart the trace **and** discard `tracestate` (it is meaningless without a valid parent).

### 3.2 W3C Baggage

A separate, independent header carrying application context:

```
baggage: userId=alice,tenant=acme,isProduction=false;metadata-key=value
```

- Values are **percent-encoded** (`,`, `;`, `=` and non-ASCII must be escaped).
- Optional per-entry **properties** follow a `;`.
- **Baggage is NOT automatically copied onto spans.** If you want `tenant` as a span attribute, you must read baggage and set it explicitly. This surprises people constantly.
- **Security/cost caveat (SRE-critical):** baggage propagates to *every* downstream service, including third parties you call. Never put secrets or PII in it, and cap its size — a fat baggage header multiplies across every hop and can breach proxy header limits (`431 Request Header Fields Too Large`).

### 3.3 Alternative propagators

| Propagator | `OTEL_PROPAGATORS` value | Header(s) | Wire format | When you need it |
|---|---|---|---|---|
| **W3C Trace Context** | `tracecontext` | `traceparent`, `tracestate` | `00-{trace}-{span}-{flags}` | Default; interoperable standard |
| **W3C Baggage** | `baggage` | `baggage` | `k=v,k=v` | Carry app context downstream |
| **B3 Single** | `b3` | `b3` | `{trace}-{span}-{sampled}-{parent}` | Zipkin / Istio meshes |
| **B3 Multi** | `b3multi` | `X-B3-TraceId`, `X-B3-SpanId`, `X-B3-Sampled`, `X-B3-ParentSpanId`, `X-B3-Flags` | one value per header | Legacy Zipkin fleets |
| **Jaeger** | `jaeger` | `uber-trace-id` | `{trace}:{span}:{parent}:{flags}` (URL-encoded `:` → `%3A`) | Existing Jaeger client instrumentation |
| **OT Trace** | `ottrace` | `ot-tracer-traceid`, `ot-tracer-spanid`, `ot-tracer-sampled` | OpenTracing legacy | Migrating from OpenTracing |
| **AWS X-Ray** | `xray` | `X-Amzn-Trace-Id` | `Root=1-{ts}-{id};Parent=…;Sampled=1` | AWS-native (contrib) |
| **None** | `none` | — | disables propagation | Isolate/edge cases only |

**Trade-off summary:**

| Concern | W3C Trace Context | B3 (single) | Jaeger |
|---|---|---|---|
| Standardization | ✅ W3C Recommendation | De-facto (Zipkin) | Vendor (Jaeger) |
| Header count | 2 | 1 | 1 |
| Carries vendor state | ✅ `tracestate` | ❌ | ❌ |
| Service-mesh support (Istio/Envoy) | ✅ (also emits B3) | ✅ native | partial |
| Header size on hot path | small | smallest | medium (URL-encoded) |
| Recommendation | **Default everywhere** | Only if the mesh mandates it | Only for legacy Jaeger clients |

**Mesh interop trap:** Istio/Envoy propagate B3 by default and only *forward* trace headers — they do **not** create the parent/child link inside your app. Your application must still `extract` on ingress and `inject` on egress. If your services speak `tracecontext` but the mesh only forwards `b3`, configure **both**: `OTEL_PROPAGATORS=tracecontext,baggage,b3multi` so extraction succeeds regardless of which header arrives. A composite propagator tries each in order and merges the result.

---

## 4. Complete manifests and infrastructure

### 4.1 Instrumented workload — the propagation-relevant configuration

The propagation behaviour of a service is driven entirely by environment variables consumed by the SDK. Nothing below is optional for a correct trace.

```yaml
# checkout-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app: checkout
spec:
  replicas: 3
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      containers:
        - name: checkout
          image: registry.example.com/shop/checkout:1.8.2
          ports:
            - containerPort: 8080
          env:
            # --- identity ---
            - name: OTEL_SERVICE_NAME
              value: checkout
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=shop,deployment.environment=prod"

            # --- export target (the Collector) ---
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://otel-collector.observability.svc:4318
            - name: OTEL_EXPORTER_OTLP_PROTOCOL
              value: http/protobuf

            # --- CONTEXT PROPAGATION: the heart of this topic ---
            # Extract/inject BOTH W3C headers AND B3 (mesh interop).
            - name: OTEL_PROPAGATORS
              value: "tracecontext,baggage,b3multi"

            # --- sampling MUST be parent-based to honour the propagated flag ---
            # Without parentbased_*, a downstream service may drop spans whose
            # parent was sampled → half-populated ("gappy") traces.
            - name: OTEL_TRACES_SAMPLER
              value: parentbased_traceidratio
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "0.1"          # 10% head sampling for NEW roots only
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
```

> **Why `parentbased_traceidratio` is non-negotiable for propagation:** the `sampled` bit in `traceparent` (`…-01`) is a *decision made upstream*. A `ParentBased` sampler says "if my remote parent was sampled, I sample too; only if there is no parent do I roll the 10% dice." A plain `traceidratio` sampler ignores the parent and re-rolls at every hop — statistically guaranteeing traces where the root exists but the leaves are missing. Sampling and propagation are coupled by the flag; treat them as one design decision.

### 4.2 The Collector — transport, not propagation

```yaml
# otel-collector-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        timeout: 5s
        send_batch_size: 1024
      # Surfaces the propagated IDs so you can eyeball trace continuity:
      resource:
        attributes:
          - key: collector.received
            value: "true"
            action: upsert

    exporters:
      # 'debug' prints Trace ID / Parent ID / Span ID — your primary
      # verification tool for "did the parent link survive the wire?"
      debug:
        verbosity: detailed
      otlp/jaeger:
        endpoint: jaeger-collector.observability.svc:4317
        tls:
          insecure: true

    service:
      pipelines:
        traces:
          receivers:  [otlp]
          processors: [resource, batch]
          exporters:  [debug, otlp/jaeger]
```

**Conceptual boundary the exam tests:** the Collector re-emits spans with the **exact** `trace_id`/`span_id`/`parent_span_id` it received. It never *re-propagates* between your business services and never repairs a broken parent link. If the parent is wrong when it reaches the Collector, it is wrong forever. Propagation is fixed upstream, in the SDK.

---

## 5. Application code: inject and extract in practice

### 5.1 Go (explicit context — no thread-local magic)

```go
package main

import (
    "net/http"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
)

func init() {
    // Wire up the same composite as OTEL_PROPAGATORS.
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{}, // traceparent / tracestate
        propagation.Baggage{},      // baggage
    ))
}

// SERVER side: rebuild context from inbound headers.
func handler(w http.ResponseWriter, r *http.Request) {
    ctx := otel.GetTextMapPropagator().
        Extract(r.Context(), propagation.HeaderCarrier(r.Header))

    ctx, span := otel.Tracer("checkout").Start(ctx, "GET /api/checkout")
    defer span.End()

    callPayment(ctx) // MUST pass ctx or the child link is lost
}

// CLIENT side: stamp outbound headers.
func callPayment(ctx context.Context) {
    req, _ := http.NewRequestWithContext(ctx, "POST",
        "http://payment.shop.svc/charge", nil)
    otel.GetTextMapPropagator().
        Inject(ctx, propagation.HeaderCarrier(req.Header))
    http.DefaultClient.Do(req)
}
```

### 5.2 Python (contextvars — mind the thread pool)

```python
from opentelemetry import trace, context, baggage
from opentelemetry.propagate import inject, extract

tracer = trace.get_tracer("checkout")

# SERVER: extract remote parent, attach it, start child span.
def handle(request):
    ctx = extract(request.headers)                 # dict-like carrier
    token = context.attach(ctx)
    try:
        with tracer.start_as_current_span("handle", context=ctx):
            ctx = baggage.set_baggage("tenant", "acme")  # returns NEW context
            call_payment(ctx)
    finally:
        context.detach(token)                      # always detach

# CLIENT: inject current context into outbound headers.
def call_payment(ctx):
    headers = {}
    inject(headers, context=ctx)                   # writes traceparent/baggage
    requests.post("http://payment.shop.svc/charge", headers=headers)
```

---

## 6. CLI commands and real terminal output

### 6.1 Confirm the SDK injects `traceparent` on egress

Point the service at a header-echo sink and read what it stamped:

```console
$ kubectl -n shop exec deploy/checkout -- \
    curl -s http://echo.shop.svc/headers | jq '.headers'
{
  "host": "echo.shop.svc",
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-9f0e11c2a7b34d18-01",
  "tracestate": "shop=9f0e11c2a7b34d18",
  "baggage": "tenant=acme"
}
```

The `-01` suffix confirms the span was **sampled**; the presence of `traceparent` confirms injection works.

### 6.2 Manually seed a trace and follow it end-to-end

```console
$ curl -s -o /dev/null -w '%{http_code}\n' \
    -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
    -H 'baggage: tenant=acme,tier=gold' \
    http://checkout.shop.svc:8080/api/checkout
200
```

### 6.3 Read the parent links out of the Collector debug exporter

```console
$ kubectl -n observability logs deploy/otel-collector | grep -A6 "Span #"
Span #0
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Parent ID      : 00f067aa0ba902b7          <-- the seed we curled with ✔
    ID             : 9f0e11c2a7b34d18
    Name           : GET /api/checkout
    Kind           : Server
Span #1
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736   <-- SAME trace ✔
    Parent ID      : 9f0e11c2a7b34d18          <-- child of checkout ✔
    ID             : c31d0a7742e88b90
    Name           : POST /charge  (payment)
    Kind           : Client
```

**Reading it:** every span shares `Trace ID 4bf9…4736`, and each `Parent ID` points at the previous span's `ID`. That chain **is** a working propagation. One mismatched `Trace ID` = the wire broke at that hop.

### 6.4 Generate a root and propagate through a shell command with `otel-cli`

`otel-cli exec` starts a span and exports `TRACEPARENT` into the child process's environment — the canonical way to test propagation without writing code:

```console
$ otel-cli exec \
    --endpoint http://otel-collector.observability.svc:4318 \
    --service load-test --name "smoke" --tp-print \
    -- curl -s -H "traceparent: $TRACEPARENT" http://checkout.shop.svc:8080/api/checkout
# TRACEPARENT=00-1a2b3c4d5e6f70819a2b3c4d5e6f7081-a1b2c3d4e5f60718-01
```

---

## 7. Verification and failure diagnosis

### 7.1 The two-question triage

1. **Do all hops share one `trace_id`?** → No: propagation is broken (Section 7.2, rows 1–5).
2. **Do all hops share one `trace_id` but spans are missing?** → sampling mismatch, not propagation (row 6).

### 7.2 Failure catalogue

| Symptom | Root cause | How to confirm | Fix |
|---|---|---|---|
| Every service is its own root; N orphan traces | Propagator mismatch or not configured | Compare `OTEL_PROPAGATORS` across services; check inbound headers with 6.1 | Align propagators; add `b3multi` if behind a mesh |
| Inbound `traceparent` present, but server span still a root | Server never calls `extract` (missing/disabled auto-instrumentation) | Debug exporter shows `Parent ID` empty despite header arriving | Enable HTTP server instrumentation / call `extract` manually |
| Trace links but leaf spans missing | Downstream uses non-parent-based sampler | `OTEL_TRACES_SAMPLER` is `traceidratio`/`always_off` | Switch to `parentbased_traceidratio` |
| Context lost after a `ThreadPoolExecutor`/reactive hop | In-process context not carried across threads | Reproduces under concurrency; parent span ID resets mid-service | Wrap executor (`copy_context()`, `Context.taskWrapping()`, instrumented scheduler) |
| Headers vanish at the edge | Proxy/ingress header allowlist strips unknown headers | `curl` direct vs through proxy (6.2) | Allowlist `traceparent`, `tracestate`, `baggage`, `b3*` |
| `431 Request Header Fields Too Large` / baggage truncated | Oversized baggage accumulating per hop | Inspect `baggage` header length (6.1) | Cap baggage; never dump maps into it |
| `tracestate` dropped but trace still links | Malformed upstream `traceparent` forced a restart | Debug exporter shows a fresh `trace_id` with no parent | Fix the emitter producing an invalid `traceparent` |

### 7.3 Fast checks to keep in the runbook

```console
# 1. Is the propagator set the same everywhere?
$ kubectl -n shop get deploy -o \
    jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].env[?(@.name=="OTEL_PROPAGATORS")].value}{"\n"}{end}'
checkout    tracecontext,baggage,b3multi
payment     tracecontext,baggage,b3multi
cart        tracecontext,baggage            <-- MISMATCH: no b3multi ✗

# 2. Does a header actually arrive at the server?
$ kubectl -n shop exec deploy/payment -- sh -c \
    'printf "" | nc -l -p 9000 & curl -s -H "traceparent: 00-...-01" localhost:9000'

# 3. Prove parent linkage in the backend, not by eye:
$ kubectl -n observability logs deploy/otel-collector \
    | grep -E "Trace ID|Parent ID" | sort | uniq -c
```

Row 1 above is the textbook bug: `cart` omits `b3multi`, so when Istio hands it a `b3` header (and no `traceparent`), extraction returns an empty context and `cart` starts a new root — one broken hop that fragments every trace that touches it.

---

## 8. Referencias

- OTCA Curriculum (CNCF) — https://github.com/cncf/curriculum
- OpenTelemetry — Context propagation (concepts) — https://opentelemetry.io/docs/concepts/context-propagation/
- OpenTelemetry — Propagators API (specification) — https://opentelemetry.io/docs/specs/otel/context/api-propagators/
- OpenTelemetry — Context (specification) — https://opentelemetry.io/docs/specs/otel/context/
- OpenTelemetry — Baggage (concepts) — https://opentelemetry.io/docs/concepts/signals/baggage/
- OpenTelemetry — SDK environment variables (`OTEL_PROPAGATORS`, samplers) — https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- OpenTelemetry — Sampling (`ParentBased`) — https://opentelemetry.io/docs/specs/otel/trace/sdk/#sampling
- W3C — Trace Context Recommendation — https://www.w3.org/TR/trace-context/
- W3C — Baggage specification — https://www.w3.org/TR/baggage/
- OpenZipkin — B3 propagation — https://github.com/openzipkin/b3-propagation
- OpenTelemetry Collector — debug exporter — https://github.com/open-telemetry/opentelemetry-collector/tree/main/exporter/debugexporter
- `otel-cli` — https://github.com/equinix-labs/otel-cli