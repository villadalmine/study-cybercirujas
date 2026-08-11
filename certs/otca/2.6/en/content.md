# 2.6 Context Propagation

> OTCA Domain 2 — *Fundamentals of OpenTelemetry* · Exam weight: **6.57%**
> Authoring language: English · Level: Principal Platform / SRE

---

## 1. The production problem: why a trace is worthless without propagation

A single request in a modern platform is not served by one process. A checkout POST hits an ingress controller, is routed to a `frontend` pod, which calls `cart`, which calls `pricing`, which reads from `redis` and publishes an event to Kafka that a `fulfilment` consumer picks up 40 ms later on a completely different node. That is **six or seven independent processes, three network hops, one async boundary**, and *nothing* in the wire protocol tells `pricing` that its work belongs to the same logical operation as the ingress request — unless you put it there.

Context propagation is the mechanism that carries the identity of the in-flight operation *across every one of those boundaries* so that the spans emitted by seven unrelated processes reassemble into one connected trace. Remove it and you do not get a degraded trace; you get seven disconnected single-span traces, each one useless for answering the only question that matters in an incident: *where did the latency / the error actually happen?*

There are two distinct boundaries, and OpenTelemetry treats them separately:

| Boundary | Example | Mechanism |
|---|---|---|
| **In-process** | An async task, a thread-pool worker, a callback continuing the same request | The `Context` object + a `ContextManager` (implicit thread-local / `contextvars` / Go `context.Context`) |
| **Cross-process** | HTTP call, gRPC call, Kafka/RabbitMQ message, cron trigger | A **Propagator** serializes context into carrier headers and deserializes it on the far side |

The architectural failure mode you are being tested on is the **broken trace**: a child service starts a *new root trace* instead of continuing the caller's, because the two sides disagreed on *how* context is encoded on the wire. This is almost never a bug in the tracer — it is a propagator mismatch, an un-instrumented hop, or a lost in-process context across an async boundary. The rest of this topic is the mechanics required to diagnose exactly that.

### The two things being propagated

OpenTelemetry propagates two conceptually different payloads through the same `Context` container:

1. **`SpanContext`** — the *immutable* identity of the active span: `trace_id`, `span_id`, `trace_flags` (the sampled bit), `trace_state`, and an `is_remote` flag. This is what stitches spans into a tree. It is created by the SDK, never by the user.
2. **`Baggage`** — arbitrary, *user-defined* key/value pairs (`user.tier=premium`, `tenant.id=acme`) that ride along the whole request so any downstream service can read them and, e.g., add them as span attributes or drive a sampling decision. Baggage is application data; SpanContext is telemetry plumbing.

Keeping these straight is the single most common conceptual exam trap: **Baggage is not span attributes, and it is not the trace context.** It propagates; span attributes do not.

---

## 2. Propagators: the wire formats and their trade-offs

A **propagator** implements the `TextMapPropagator` interface, which has exactly two operations plus a `fields()` introspection method:

```
inject(context, carrier, setter)   // Context  -> headers  (client / producer side)
extract(carrier, context, getter)  // headers -> Context   (server / consumer side)
fields()                           // the header names this propagator writes
```

The `carrier` is anything key/value-shaped — usually the HTTP header map. The `getter`/`setter` abstract *how* to read/write it, so the same propagator works for `net/http` headers, gRPC metadata, or Kafka record headers.

### 2.1 W3C Trace Context — the default, standards-track format

This is the IETF/W3C Recommendation and OpenTelemetry's default. It defines **two headers**.

**`traceparent`** — a single, fixed-format ASCII string:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
             │  │                                │                └─ trace-flags  (1 byte, 2 hex; bit 0 = sampled)
             │  │                                └─ parent-id / span-id (8 bytes, 16 hex, non-zero)
             │  └─ trace-id (16 bytes, 32 hex, non-zero)
             └─ version (1 byte, 2 hex; currently 00)
```

Hard rules the extractor enforces (know these — they are the source of "why is my trace broken"):

- `trace-id` all-zero (`000...0`) → **invalid**, header discarded.
- `span-id` all-zero → **invalid**, header discarded.
- Wrong field lengths, non-hex characters, or wrong number of `-` separators → discarded.
- `trace-flags` bit 0 set (`01`) means the *upstream sampler decided to record/sample*. `00` means it did not.

When a `traceparent` is discarded, the receiver has no remote parent, so it starts a **new root** — the classic broken trace.

**`tracestate`** — vendor-specific, mutable, ordered list of up to **32** members, `key=value` comma-separated, recommended ≤ 512 bytes total:

```
tracestate: ot=th:0;p:8,rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

OpenTelemetry uses the `ot=` member to carry SDK-level data such as the consistent-probability sampling threshold (`th`). Each vendor prepends its own key; entries are LRU-ordered (most-recently-mutated first) and older entries are evicted when the 32-member limit is hit.

### 2.2 W3C Baggage

Baggage is propagated by a *separate* propagator writing the **`baggage`** header (percent-encoded values, optional `;`-delimited properties):

```
baggage: userId=alice,serverNode=DF%2028,isProduction=false,tenant=acme;ttl=30
```

Enable it explicitly — it is part of the OTel default set (`tracecontext,baggage`) but is a distinct propagator you can drop.

### 2.3 The alternatives and when you are forced to use them

| Format | Headers | Single/Multi | Baggage support | You need it when… |
|---|---|---|---|---|
| **W3C `tracecontext`** | `traceparent`, `tracestate` | Single | via separate `baggage` | Default. Greenfield, standards-based. |
| **`b3` (single)** | `b3` | Single | No | Interop with Zipkin / legacy Brave-instrumented Java services. |
| **`b3multi`** | `X-B3-TraceId`, `X-B3-SpanId`, `X-B3-ParentSpanId`, `X-B3-Sampled`, `X-B3-Flags` | Multi | No | Older meshes/proxies that only forward the multi-header B3 set. |
| **`jaeger`** | `uber-trace-id`, `uberctx-*` | Single | Yes (`uberctx-`) | Migrating a Jaeger-native fleet before cutting over to W3C. |
| **`xray`** | `X-Amzn-Trace-Id` | Single | No | AWS App Mesh / ALB / X-Ray-terminated edges. |
| **`ottrace`** | `ot-tracer-traceid`, `ot-tracer-spanid`, `ot-tracer-sampled`, `ot-baggage-*` | Multi | Yes (`ot-baggage-`) | Legacy OpenTracing-instrumented services. |

**B3 single header** layout — memorize the field order, exam-relevant:

```
b3: {trace_id}-{span_id}-{sampling_state}-{parent_span_id}
b3: 80f198ee56343ba864fe8b2a57d3eff7-e457b5a2e4d86bd1-1-05e3ac9a4f6e3b90
```

`sampling_state`: `1`=sampled, `0`=not sampled, `d`=debug/force. `parent_span_id` is optional.

**Jaeger** `uber-trace-id` layout (colon-separated, note trace-id can be 64 *or* 128-bit):

```
uber-trace-id: {trace-id}:{span-id}:{parent-span-id}:{flags}
uber-trace-id: 4bf92f3577b34da6a3ce929d0e0e4736:00f067aa0ba902b7:0:1
```

### 2.4 Composite propagators — the real production configuration

You rarely run one propagator. During a migration you must **extract** several formats (accept whatever upstream sends) while **injecting** one canonical format going forward. The `CompositeTextMapPropagator` (a.k.a. composite/global propagator) chains them:

- On `extract`, it tries each child in order and merges results — the first that yields a valid `SpanContext` wins for trace context; baggage from all is merged.
- On `inject`, **every** child writes its headers, so the outbound request carries `traceparent` *and* `b3` *and* `uber-trace-id` simultaneously.

Trade-off: injecting every format bloats headers (B3 multi + Jaeger + W3C can add 400+ bytes per hop) and can confuse a downstream that extracts multiple formats into conflicting contexts. Configure the *minimum* set that covers your fleet, and drop the migration formats once the cutover completes.

### 2.5 In-process vs cross-process — do not conflate them

| | In-process propagation | Cross-process propagation |
|---|---|---|
| Carrier | The `Context` object itself | HTTP/gRPC/Kafka headers |
| Mechanism | `ContextManager` (thread-local / Python `contextvars` / Go explicit `context.Context`) | `TextMapPropagator.inject`/`extract` |
| Failure mode | Context lost across `async`/thread-pool/callback boundary → child span has no parent *within the same process* | Header dropped/rewritten by proxy, or propagator mismatch → new root trace |
| Fix | Attach/detach context correctly; use the runtime's context-aware primitives | Align `OTEL_PROPAGATORS`; ensure proxies forward the headers |

The `Context` object is **immutable**: `context.with_value(key, value)` returns a *new* context. Auto-instrumentation makes the current span implicit; when you cross a boundary the SDK cannot see (a thread you spawned, a message you enqueued), *you* are responsible for capturing the active context and re-attaching it on the other side.

---

## 3. Configuration, code, and infrastructure (complete, unabridged)

### 3.1 Selecting propagators declaratively

The canonical, zero-code control is the environment variable. Comma-separated, order-significant for extraction:

```bash
# Default if unset:
OTEL_PROPAGATORS=tracecontext,baggage

# Accept W3C + legacy B3 + Jaeger during a migration, still carry baggage:
OTEL_PROPAGATORS=tracecontext,baggage,b3multi,jaeger

# Disable all propagation (e.g. a hard trust boundary that must start fresh traces):
OTEL_PROPAGATORS=none
```

Valid tokens: `tracecontext`, `baggage`, `b3`, `b3multi`, `jaeger`, `xray`, `ottrace`, `none`. An unrecognized token is logged and skipped — a silent typo (`traceparent` instead of `tracecontext`) is a real-world cause of "propagation configured but not working."

### 3.2 A complete deployment: two services agreeing on propagators

```yaml
# ---------------------------------------------------------------------------
# frontend.yaml — Deployment + Service. Emits traceparent + baggage downstream.
# ---------------------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: shop
  labels: { app: frontend }
spec:
  replicas: 2
  selector:
    matchLabels: { app: frontend }
  template:
    metadata:
      labels: { app: frontend }
    spec:
      containers:
        - name: frontend
          image: registry.internal/shop/frontend:1.8.0
          ports:
            - { name: http, containerPort: 8080 }
          env:
            - name: OTEL_SERVICE_NAME
              value: frontend
            # Both services MUST agree on this set or the trace breaks at the hop.
            - name: OTEL_PROPAGATORS
              value: "tracecontext,baggage"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability:4317"
            - name: OTEL_EXPORTER_OTLP_PROTOCOL
              value: "grpc"
            - name: OTEL_TRACES_SAMPLER
              value: "parentbased_traceidratio"
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "0.10"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=shop,deployment.environment=prod"
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: shop
spec:
  selector: { app: frontend }
  ports:
    - { name: http, port: 80, targetPort: http }
---
# ---------------------------------------------------------------------------
# pricing.yaml — the downstream. Same propagator set is non-negotiable.
# ---------------------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pricing
  namespace: shop
  labels: { app: pricing }
spec:
  replicas: 3
  selector:
    matchLabels: { app: pricing }
  template:
    metadata:
      labels: { app: pricing }
    spec:
      containers:
        - name: pricing
          image: registry.internal/shop/pricing:2.3.1
          ports:
            - { name: http, containerPort: 8090 }
          env:
            - name: OTEL_SERVICE_NAME
              value: pricing
            - name: OTEL_PROPAGATORS
              value: "tracecontext,baggage"   # identical to frontend
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability:4317"
            # parentbased sampler => it OBEYS the upstream sampled flag in traceparent.
            - name: OTEL_TRACES_SAMPLER
              value: "parentbased_traceidratio"
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "0.10"
```

**Critical sampling interaction:** the `parentbased_*` sampler reads bit 0 of the incoming `traceparent` `trace-flags`. If the frontend sampled the trace (`-01`), a `parentbased` pricing service honors that and records too — the whole trace is consistent. A `traceidratio` (non-parent-based) sampler at pricing would re-decide independently and produce *partial* traces with holes. Sampling and propagation are coupled; this is a favorite exam intersection.

### 3.3 Manual propagation in code (the SDK boundary you must handle yourself)

**Client side — injecting into an outbound request (Python):**

```python
from opentelemetry import trace, propagate
from opentelemetry.trace import SpanKind
import requests

tracer = trace.get_tracer("shop.frontend")

def call_pricing(sku: str) -> dict:
    with tracer.start_as_current_span("GET /price", kind=SpanKind.CLIENT) as span:
        span.set_attribute("shop.sku", sku)
        headers: dict[str, str] = {}
        # Serialize the ACTIVE context (span context + baggage) into the carrier.
        # Uses the globally configured composite propagator honoring OTEL_PROPAGATORS.
        propagate.inject(headers)
        # headers now contains e.g.:
        #   traceparent: 00-<trace_id>-<span_id>-01
        #   baggage:     tenant=acme,user.tier=premium
        resp = requests.get(f"http://pricing/price?sku={sku}", headers=headers, timeout=2)
        return resp.json()
```

**Server side — extracting into the local context (Python / manual, what auto-instrumentation does for you):**

```python
from opentelemetry import trace, propagate
from opentelemetry.trace import SpanKind

tracer = trace.get_tracer("shop.pricing")

def handle_request(request):
    # Rebuild the remote context from the inbound headers.
    ctx = propagate.extract(request.headers)
    # Start the server span AS A CHILD of the remote context.
    with tracer.start_as_current_span(
        "GET /price", context=ctx, kind=SpanKind.SERVER
    ) as span:
        # span.parent is now the frontend's CLIENT span => trace is connected.
        ...
```

**Baggage — set once, read anywhere downstream:**

```python
from opentelemetry import baggage, context

# frontend: attach baggage to the current context
ctx = baggage.set_baggage("user.tier", "premium")
token = context.attach(ctx)
try:
    call_pricing("SKU-42")   # inject() will emit: baggage: user.tier=premium
finally:
    context.detach(token)

# pricing (downstream): read it back after extract()
tier = baggage.get_baggage("user.tier")   # -> "premium"
span.set_attribute("user.tier", tier)      # promote baggage -> attribute for querying
```

**Go — explicit context is the propagation vehicle:**

```go
import (
    "context"
    "net/http"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
)

// Install a composite global propagator once at startup.
func init() {
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{}, // W3C traceparent/tracestate
        propagation.Baggage{},      // W3C baggage
    ))
}

// Inject on the client side.
func callPricing(ctx context.Context, req *http.Request) {
    otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
    // req.Header now carries traceparent + baggage.
}

// Extract on the server side.
func handler(w http.ResponseWriter, r *http.Request) {
    ctx := otel.GetTextMapPropagator().Extract(r.Context(),
        propagation.HeaderCarrier(r.Header))
    ctx, span := tracer.Start(ctx, "GET /price") // child of remote span
    defer span.End()
}
```

### 3.4 Asynchronous / message-queue propagation (the hop instrumentation forgets)

HTTP is auto-instrumented; **your Kafka producers/consumers usually are not**. You must inject into and extract from message headers manually or trace breaks at the async boundary:

```python
from opentelemetry import trace, propagate
from opentelemetry.trace import SpanKind
from confluent_kafka import Producer, Consumer

tracer = trace.get_tracer("shop.fulfilment")

# ---- Producer: inject into Kafka record headers ----
def publish(order_id: str, payload: bytes):
    with tracer.start_as_current_span("orders publish", kind=SpanKind.PRODUCER) as span:
        carrier: dict[str, str] = {}
        propagate.inject(carrier)                       # traceparent -> carrier
        kafka_headers = [(k, v.encode()) for k, v in carrier.items()]
        producer.produce("orders", value=payload, headers=kafka_headers)

# ---- Consumer: extract from Kafka record headers ----
def consume(msg):
    carrier = {k: v.decode() for k, v in (msg.headers() or [])}
    ctx = propagate.extract(carrier)                    # rebuild remote context
    with tracer.start_as_current_span(
        "orders process", context=ctx, kind=SpanKind.CONSUMER
    ) as span:
        span.set_attribute("messaging.system", "kafka")
        ...  # this span links back to the producer 40ms and one node away
```

### 3.5 The Collector's role (and what it does *not* do)

A common misconception: *the Collector propagates context.* It does **not** create or extract wire-format headers for your telemetry — propagation is an SDK/instrumentation concern that already happened on the app side. The Collector *receives* fully-formed spans over OTLP (which carry the trace/span IDs inside the protobuf, not in `traceparent` headers) and processes them. The relevant Collector concern is preserving trace-level consistency during sampling:

```yaml
# otel-collector-config.yaml — tail sampling keeps whole traces intact.
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }

processors:
  batch:
    timeout: 5s
    send_batch_size: 512
  # Tail sampling needs ALL spans of a trace_id together -> only valid on a
  # single collecting instance (or after a trace-ID-aware load-balancing tier).
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    policies:
      - name: keep-errors
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: keep-slow
        type: latency
        latency: { threshold_ms: 500 }
      - name: baseline-probabilistic
        type: probabilistic
        probabilistic: { sampling_percentage: 10 }

exporters:
  otlp/tempo:
    endpoint: tempo.observability:4317
    tls: { insecure: true }

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [tail_sampling, batch]
      exporters:  [otlp/tempo]
```

The propagation implication: **tail sampling only works if every span of a `trace_id` reaches the same decision-making Collector**. That is why fleets front the Collector with a `loadbalancing` exporter that routes by `trace_id` — otherwise a well-propagated trace still gets split across Collector replicas and half its spans are dropped.

---

## 4. CLI and terminal — observing propagation on the wire

### 4.1 Prove which propagators an SDK actually loaded

```console
$ OTEL_PROPAGATORS=tracecontext,baggage,b3 \
  OTEL_SERVICE_NAME=frontend \
  opentelemetry-instrument python -c "from opentelemetry import propagate; print(propagate.get_global_textmap().fields)"
{'traceparent', 'tracestate', 'baggage', 'b3'}
```

The `fields` set is authoritative — if `traceparent` is missing here, no code change will make it appear on the wire.

### 4.2 See the headers a real request carries

Run a header-echo target and curl through your instrumented client, or inject by hand to simulate an upstream:

```console
$ curl -s http://pricing.shop/price?sku=SKU-42 \
    -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
    -H 'baggage: tenant=acme,user.tier=premium' \
    -D - -o /dev/null
HTTP/1.1 200 OK
content-type: application/json
# server echoed its child span id back for correlation:
x-trace-id: 4bf92f3577b34da6a3ce929d0e0e4736
```

Confirm the downstream continued the same trace, not a new one — the `trace-id` in the response matches the `trace-id` you sent (`4bf92f35...`). If it differs, the header was dropped or the propagator mismatched.

### 4.3 Inspect what a proxy/mesh forwards

```console
$ kubectl -n shop exec deploy/pricing -c pricing -- \
    sh -c 'cat /proc/1/environ | tr "\0" "\n" | grep OTEL_PROPAGATORS'
OTEL_PROPAGATORS=tracecontext,baggage

$ kubectl -n shop logs deploy/pricing -c pricing --tail=5 | grep -i traceparent
DEBUG otel.propagation extracted remote context trace_id=4bf92f3577b34da6a3ce929d0e0e4736 \
      span_id=00f067aa0ba902b7 sampled=true is_remote=true
```

`is_remote=true` is the proof that `extract` succeeded and the span is a *continuation*, not a root.

### 4.4 Decode a traceparent by hand

```console
$ echo '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' | \
    awk -F- '{printf "version=%s\ntrace_id=%s (%d hex)\nspan_id=%s (%d hex)\nflags=%s sampled=%d\n", \
             $1,$2,length($2),$3,length($3),$4, ("0x"$4)%2}'
version=00
trace_id=4bf92f3577b34da6a3ce929d0e0e4736 (32 hex)
span_id=00f067aa0ba902b7 (16 hex)
flags=01 sampled=1
```

`length($2)==32` and `length($3)==16` are the validity checks the extractor performs. Any other length → the header is rejected and a new root is started.

### 4.5 Verify propagator symmetry across the fleet in one shot

```console
$ for d in frontend cart pricing fulfilment; do
    printf '%-12s ' "$d"
    kubectl -n shop set env deploy/$d --list 2>/dev/null | grep '^OTEL_PROPAGATORS' || echo 'OTEL_PROPAGATORS=(default) tracecontext,baggage'
  done
frontend     OTEL_PROPAGATORS=tracecontext,baggage
cart         OTEL_PROPAGATORS=tracecontext,baggage
pricing      OTEL_PROPAGATORS=tracecontext,baggage
fulfilment   OTEL_PROPAGATORS=b3multi          # <-- MISMATCH: fulfilment won't read traceparent
```

That last line is a diagnosed incident in one command: `fulfilment` only extracts B3, so every Kafka message carrying `traceparent` is ignored and fulfilment spans start fresh roots.

---

## 5. Verification and failure diagnosis

### 5.1 The broken-trace decision tree

**Symptom: downstream spans appear as separate root traces (no parent).**

1. **Is the hop instrumented at all?**
   Auto-instrumentation covers HTTP/gRPC/DB clients; **message queues, custom protocols, and threads/async tasks are frequently not.** Confirm the client is actually calling `inject` (check `fields` and capture the outbound headers). No `traceparent` on the wire → instrumentation gap, not a propagator problem.

2. **Do both sides list the same propagator?**
   Compare `OTEL_PROPAGATORS` (§4.5). W3C↔B3 mismatch is the #1 cause. The sender emits `traceparent`; the receiver only reads `b3` → header ignored → new root.

3. **Is an intermediary stripping the header?**
   API gateways, WAFs, and service meshes with allow-lists drop unknown headers. `traceparent`/`tracestate`/`baggage`/`b3`/`X-B3-*`/`uber-trace-id` must be in the forward allow-list. Capture headers *as the server receives them*, not as the client sent them.

4. **Is the `traceparent` structurally valid?**
   All-zero `trace-id`/`span-id`, wrong length, or non-hex → silently discarded (§4.4). A buggy hand-rolled injector is a classic source.

5. **Did in-process context survive?**
   If the trace breaks *within one process* (parent and child are the same service), the active `Context` was lost across an async/thread boundary. Capture context before the boundary and re-attach after (§3.4).

### 5.2 Symptom: trace connects but half the spans are missing

This is a **sampling-consistency** failure, not propagation. A downstream using a non-parent-based sampler re-decides independently. Fix: set `OTEL_TRACES_SAMPLER=parentbased_traceidratio` everywhere so downstreams obey the sampled flag in `traceparent` (§3.2). Verify the flag actually arrived:

```console
$ kubectl -n shop logs deploy/pricing | grep 'sampled=' | tail -1
DEBUG extracted remote context ... sampled=true is_remote=true
```

`sampled=true` present but the span is still dropped → the local sampler is not `parentbased`.

### 5.3 Symptom: baggage is empty downstream

- `baggage` propagator not in `OTEL_PROPAGATORS` on **either** side (it is separate from `tracecontext`).
- The mesh dropped the `baggage` header (allow-list).
- You set baggage *after* the outbound call was already dispatched, or on a context you never `attach`ed. Baggage rides the *active* context at `inject` time.
- **Baggage is not automatically span attributes** — you read it and set it yourself (§3.3). Expecting to query on it without promoting it is the usual confusion.

### 5.4 Validation checklist before declaring propagation healthy

```console
# 1. Every service reports the same, correct propagator set
$ kubectl -n shop get deploy -o json | \
    jq -r '.items[] | .metadata.name as $n |
           (.spec.template.spec.containers[].env[]? | select(.name=="OTEL_PROPAGATORS") | "\($n)=\(.value)")'
frontend=tracecontext,baggage
cart=tracecontext,baggage
pricing=tracecontext,baggage
fulfilment=tracecontext,baggage        # fixed

# 2. End-to-end: one request produces ONE trace_id with N connected spans
$ curl -s -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
       http://frontend.shop/checkout >/dev/null
$ curl -s "http://tempo.observability:3200/api/traces/4bf92f3577b34da6a3ce929d0e0e4736" | \
    jq '[.batches[].scopeSpans[].spans[] | {name, kind, parent: .parentSpanId}] | length'
7                                       # 7 connected spans, one trace -> propagation OK
```

If step 2 returns spans with empty/foreign `parentSpanId` mid-tree, walk the tree back to the first orphan — that hop is where propagation broke, and §5.1 tells you which of the five causes it is.

---

## 6. References

- W3C — *Trace Context* (Recommendation): https://www.w3.org/TR/trace-context/
- W3C — *Baggage*: https://www.w3.org/TR/baggage/
- OpenTelemetry — *Context propagation* (concepts): https://opentelemetry.io/docs/concepts/context-propagation/
- OpenTelemetry — *Propagators* (specification): https://opentelemetry.io/docs/specs/otel/context/api-propagators/
- OpenTelemetry — *Context* (specification): https://opentelemetry.io/docs/specs/otel/context/
- OpenTelemetry — *Baggage API* (specification): https://opentelemetry.io/docs/specs/otel/baggage/api/
- OpenTelemetry — *SDK environment variables* (`OTEL_PROPAGATORS`): https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- OpenTelemetry — *TraceState* / `tracestate` handling: https://opentelemetry.io/docs/specs/otel/trace/api/#tracestate
- OpenTelemetry — *Sampling* (parent-based samplers & the sampled flag): https://opentelemetry.io/docs/concepts/sampling/
- OpenTelemetry Collector — *Tail Sampling Processor*: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- OpenTelemetry Collector — *Load-balancing exporter* (trace-ID routing): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- OpenZipkin — *B3 propagation* specification: https://github.com/openzipkin/b3-propagation
- Jaeger — *Trace context propagation format*: https://www.jaegertracing.io/docs/1.53/client-libraries/#propagation-format
- CNCF — *OTCA Curriculum*: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf