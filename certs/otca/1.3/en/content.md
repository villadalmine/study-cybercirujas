# 1.3 Instrumentation

> **Domain:** Fundamentals of Observability · **Exam weight:** 4.5%
> **Scope:** What instrumentation *is* in the OpenTelemetry (OTel) model, the three production strategies (zero-code, library, manual), how each runtime physically injects telemetry-emitting code, and how a Platform team rolls this out to a fleet with the OpenTelemetry Operator.

---

## 1. The production problem: the instrumentation gap

A telemetry backend — Tempo, Jaeger, Prometheus, a vendor — is worthless until the workload *emits* signals. **Instrumentation is the act of making an application produce traces, metrics and logs.** Everything else in the pipeline (Collector, exporters, storage) only *moves and stores* what instrumentation created. If the process is not instrumented, the pipeline is a set of empty pipes.

In a monolith you could hand-wire logging and a few timers and call it observable. In a 300-service mesh that model collapses for three concrete reasons:

1. **Coverage vs. effort.** A single request touches a gateway, an auth service, three business services, a cache and two databases across two languages. To reconstruct that path you need *every* hop to emit a span **and** propagate the same trace context. One un-instrumented hop breaks the trace into disconnected fragments — you get a "broken trace" with a gap exactly where the latency usually hides.
2. **Consistency.** If team A names the HTTP status attribute `status`, team B `http_status` and team C `http.response.status_code`, no query spans all three. Cross-service dashboards and SLOs require a *shared vocabulary*, which is what **semantic conventions** provide (§6).
3. **Cost of change.** Manually editing 300 services to add tracing — then re-editing them when the SDK changes — is a program of work no platform team can sustain. This is the economic driver behind **zero-code instrumentation** and the **OpenTelemetry Operator** (§7).

The architectural insight OTCA tests: **instrumentation is a spectrum, not a binary.** You almost always run a *hybrid* — zero-code for breadth (every DB call, every HTTP handler, for free) plus a thin layer of manual spans and attributes for the business context a generic agent can never infer (`order.id`, `tenant.tier`, `payment.provider`).

```
        broad, generic, zero effort                deep, business-specific, high effort
   ├──────────────────────────────┼──────────────────────────────────────────────────┤
   Zero-code (auto)        Instrumentation libraries              Manual (API/SDK)
   agent / operator        framework-aware plugins                your code, your spans
```

---

## 2. Instrumentation taxonomy

OpenTelemetry defines three distinct strategies. They are **not mutually exclusive** — the SDK merges spans from all three into one trace.

| # | Strategy | What it is | Who writes it | Code change to app? |
|---|----------|-----------|---------------|---------------------|
| 1 | **Zero-code** (a.k.a. automatic / auto-instrumentation) | An external agent injects telemetry into a *running* app without touching source | OTel maintainers + you (config only) | **None** (repackage/relaunch only) |
| 2 | **Instrumentation libraries** | Per-framework plugins (`requests`, `net/http`, `Spring`, `gRPC`) that produce spans/metrics for that library | OTel/community maintainers | Import + register (a few lines) |
| 3 | **Manual / code-based** | You call the OTel **API** directly to create spans, record metrics, set attributes | You | Yes — real business logic edits |

A fourth term you must not confuse: **native instrumentation** — a library that emits OTel telemetry *itself*, with no plugin needed (the OTel API is a dependency of the library). This is the end-state the project is pushing toward; today it is rare.

### 2.1 Trade-off matrix (the money table)

| Dimension | Zero-code | Instrumentation library | Manual |
|-----------|-----------|-------------------------|--------|
| **Coverage breadth** | High — all supported libs at once | Medium — one framework | Low — only where you write it |
| **Business context** | None (can't know `order.id`) | None | **Full** |
| **Source changes** | Zero | Minimal | Extensive |
| **Fleet rollout** | Trivial (annotation/env var) | Per-service | Per-service, ongoing |
| **Runtime overhead** | Highest (patches everything) | Medium | Lowest (only what you add) |
| **Version coupling** | Agent must track lib versions | Plugin must match lib | Loose (API is stable) |
| **Failure blast radius** | Whole process (bad agent → crash/lag) | One library | One code path |
| **Startup cost** | High (bytecode scan / monkey-patch) | Low | ~Zero |
| **Go support** | eBPF or compile-time only (§3.5) | Yes | Yes |

**Rule of thumb for a platform:** default the fleet to zero-code (breadth, zero per-team effort), and give teams a thin **manual** SDK layer to enrich the auto-spans with domain attributes. Reserve pure-manual-only for Go services where eBPF injection is not acceptable.

---

## 3. How zero-code instrumentation actually works, per runtime

"Automatic" is not magic — each runtime has a concrete injection mechanism, and the mechanism dictates the operational constraints (privileges, restart, sidecar). This is the single most-tested mechanics area of this topic.

| Runtime | Mechanism | Injection point | Extra requirement |
|---------|-----------|-----------------|-------------------|
| **Java** | Bytecode manipulation via a `-javaagent` JAR (ByteBuddy) | JVM class-load time | `JAVA_TOOL_OPTIONS` / `-javaagent:` |
| **Python** | Monkey-patching of modules at import | `opentelemetry-instrument` wrapper | Wrapper launches the process |
| **Node.js** | Module hooks (`require-in-the-middle` / `import-in-the-middle`) | `--require`/`--import` at startup | `NODE_OPTIONS` |
| **.NET** | CLR Profiler API rewrites IL | JIT compile time | `CORECLR_ENABLE_PROFILING=1` + profiler env |
| **Go** | **eBPF uprobes** (no runtime patching possible) | Kernel probes on the binary | Privileged/`CAP_SYS_ADMIN`, sidecar, target-exe path |

### 3.1 Java — the bytecode agent

The JVM exposes a class-load hook. The OTel Java agent (`opentelemetry-javaagent.jar`) attaches to it and rewrites the bytecode of *supported* libraries the moment their classes load, wrapping methods (e.g. `HttpServlet.service`, JDBC `Statement.execute`) with span start/end. No `.java` file is touched.

```console
$ java -javaagent:/otel/opentelemetry-javaagent.jar \
       -Dotel.service.name=checkout \
       -Dotel.exporter.otlp.endpoint=http://otel-collector:4317 \
       -jar checkout.jar
[otel.javaagent 2026-08-10 12:01:03] - opentelemetry-javaagent - version: 2.11.0
[otel.javaagent 2026-08-10 12:01:04] - Auto-instrumentation for: [jdbc, spring-web, tomcat, kafka-clients]
[otel.javaagent 2026-08-10 12:01:04] - Exporting spans via OTLP gRPC to http://otel-collector:4317
```

### 3.2 Python — the wrapper + monkey-patch

`opentelemetry-instrument` is a launcher. It runs a `sitecustomize`-style bootstrap that imports OTel and monkey-patches library modules (`requests`, `flask`, `psycopg2`) so their calls emit spans. `opentelemetry-bootstrap` detects which libraries you have installed and pulls the matching instrumentation packages.

```console
$ pip install opentelemetry-distro opentelemetry-exporter-otlp
$ opentelemetry-bootstrap -a install          # installs instrumentation libs for detected deps
$ OTEL_SERVICE_NAME=cart \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318 \
  OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
  opentelemetry-instrument python app.py
Instrumenting: flask, requests, psycopg2
Exporting traces, metrics, logs to http://otel-collector:4318 (http/protobuf)
```

### 3.3 Node.js — the require hook

Node's module loader is intercepted via `--require`. The registered hook (`@opentelemetry/auto-instrumentations-node/register`) patches CommonJS `require` and ESM `import` so framework calls are wrapped.

```console
$ npm install @opentelemetry/api \
              @opentelemetry/auto-instrumentations-node
$ export OTEL_SERVICE_NAME=frontend
$ export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
$ node --require @opentelemetry/auto-instrumentations-node/register server.js
@opentelemetry/instrumentation-http Applying patch for http
@opentelemetry/instrumentation-express Applying patch for express@4.19.2
```

### 3.4 .NET — the CLR profiler

The .NET auto-instrumentation registers a **CLR Profiler** (via `CORECLR_ENABLE_PROFILING=1`, `CORECLR_PROFILER`, `CORECLR_PROFILER_PATH`). The profiler rewrites IL at JIT time to insert span calls. No recompile of your assemblies.

### 3.5 Go — the exception that proves the rule

Go compiles to a static native binary with **no VM, no class loader, no import hook** — so runtime monkey-patching is impossible. There are two production options, both with real constraints:

- **eBPF auto-instrumentation** (`opentelemetry-go-instrumentation`): a *separate privileged process/sidecar* attaches eBPF uprobes to your target binary's functions and reconstructs spans from the kernel. Requires the path to the target executable (`OTEL_GO_AUTO_TARGET_EXE`), elevated capabilities (`CAP_SYS_ADMIN` / `privileged: true`), and `hostPID` in some setups.
- **Compile-time instrumentation:** source/build-time weaving.

Consequence for the platform: **Go cannot be auto-instrumented by simple env vars like Java/Python/Node.** The Operator injects Go instrumentation as a privileged sidecar, not an init container that copies an agent (§7.4). For most Go shops, **manual instrumentation is the pragmatic default**.

---

## 4. Instrumentation libraries vs. native instrumentation

An **instrumentation library** is a shim that produces telemetry *for a library it does not own* — e.g. `opentelemetry-instrumentation-requests` teaches the un-aware `requests` package to emit HTTP client spans. Zero-code agents are, under the hood, orchestrators that load a bundle of these libraries.

**Native (natural) instrumentation** is when a library emits OTel telemetry itself, depending directly on the OTel **API** (never the SDK — a library must not force an SDK on its consumers). The distinction the exam wants:

| | Instrumentation library | Native instrumentation |
|--|-------------------------|------------------------|
| Who owns the telemetry code | OTel/community, *outside* the target lib | The library maintainers, *inside* |
| Dependency added | An extra plugin package | Nothing — it's built in |
| Depends on | OTel API (+ patch logic) | OTel **API only** |
| Break risk on lib upgrade | Higher (patch may not match new version) | None (moves with the lib) |
| Availability today | Broad | Sparse, growing |

**API vs SDK — the load-bearing concept.** The **API** is the surface your code (and libraries) call to create spans/metrics — it is a *no-op* by default. The **SDK** is the concrete implementation that samples, batches and exports. A library instruments against the API so that if the *app* never installs an SDK, the library's telemetry costs nothing. Instrumentation = calling the API; **making it do something** = installing and configuring the SDK.

---

## 5. Manual (code-based) instrumentation

This is where you add the context a generic agent cannot know. You obtain a `Tracer`/`Meter` from the (globally configured) provider and create spans/measurements around business operations.

### 5.1 Python — enriching an auto-instrumented service

```python
from opentelemetry import trace, metrics
from opentelemetry.trace import Status, StatusCode

tracer = trace.get_tracer("checkout.service", "1.4.0")
meter  = metrics.get_meter("checkout.service", "1.4.0")

orders_total = meter.create_counter(
    "checkout.orders.completed",
    unit="1",
    description="Number of successfully completed orders",
)

def complete_order(order):
    # Child of the HTTP server span the auto-instrumentation already created.
    with tracer.start_as_current_span("complete_order") as span:
        span.set_attribute("order.id", order.id)
        span.set_attribute("order.items", len(order.items))
        span.set_attribute("tenant.tier", order.tenant.tier)   # business context
        try:
            charge(order)               # DB/HTTP spans appear automatically as children
            orders_total.add(1, {"tenant.tier": order.tenant.tier})
            span.set_status(Status(StatusCode.OK))
        except PaymentError as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            raise
```

Because the SDK is already wired by the zero-code layer, this span slots in as a child of the auto-generated HTTP span, and any `charge()` DB/HTTP call is captured as a grandchild — **one coherent trace from three instrumentation sources.**

### 5.2 Java — a manual span with the same agent running

```java
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.*;

Tracer tracer = GlobalOpenTelemetry.getTracer("checkout.service", "1.4.0");

Span span = tracer.spanBuilder("complete_order")
        .setAttribute("order.id", order.id())
        .setAttribute("tenant.tier", order.tenant().tier())
        .startSpan();
try (Scope scope = span.makeCurrent()) {
    charge(order);                       // JDBC/HTTP spans auto-attach as children
} catch (PaymentException e) {
    span.recordException(e);
    span.setStatus(StatusCode.ERROR, e.getMessage());
    throw e;
} finally {
    span.end();
}
```

### 5.3 Context propagation — why instrumentation stitches, not just emits

A span is useless in isolation; instrumentation's second job is to **propagate context** across process boundaries so the child on service B knows its parent on service A. On the wire this is the W3C **`traceparent`** header (and optional `baggage`). Auto-instrumentation injects/extracts it for you; when you make a *manual* outbound call you must not defeat it. Configure the propagators explicitly:

```console
$ export OTEL_PROPAGATORS=tracecontext,baggage
```

A mismatch — service A emitting `b3` while B only extracts `tracecontext` — is the classic cause of *broken traces* even when both services are "instrumented."

---

## 6. Semantic conventions — the contract that makes instrumentation useful

Instrumentation that names things arbitrarily produces telemetry you cannot query across services. **Semantic conventions** are OpenTelemetry's standardized attribute names and values, so every language and library agrees on the vocabulary.

| Concept | Conventional attribute (stable) |
|---------|-------------------------------|
| HTTP method | `http.request.method` |
| HTTP status code | `http.response.status_code` |
| URL path | `url.path` |
| Server address | `server.address` |
| DB system | `db.system.name` |
| DB statement | `db.query.text` |
| Service identity | `service.name`, `service.version` (Resource) |

`service.name` is special: it is a **Resource** attribute (identifies the *producer*, not a single span) and is effectively mandatory — without it the backend labels your data `unknown_service`. All zero-code layers set it from `OTEL_SERVICE_NAME` / `OTEL_RESOURCE_ATTRIBUTES`.

> **Test trap:** the correct interop attribute for HTTP status is `http.response.status_code`, **not** `http.status_code` (the old, pre-stable name). Following conventions is part of instrumenting *correctly*, not an optional nicety.

---

## 7. Fleet-scale zero-code: the OpenTelemetry Operator

For a Kubernetes fleet you do not bake agents into images or edit 300 Dockerfiles. The **OpenTelemetry Operator** ships a mutating admission webhook that, driven by a single pod annotation, injects the agent as an **init container** and sets the env vars — at pod-creation time, no image change.

### 7.1 Install the Operator (requires cert-manager)

```console
$ kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
$ kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
$ kubectl -n opentelemetry-operator-system get pods
NAME                                        READY   STATUS    RESTARTS   AGE
opentelemetry-operator-7c4f9d8b6d-2xk5p     2/2     Running   0          41s
```

### 7.2 A Collector for the agents to export to (`v1beta1`)

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otelcol
  namespace: observability
spec:
  mode: deployment
  replicas: 2
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        send_batch_size: 8192
        timeout: 5s
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
    exporters:
      debug:
        verbosity: detailed
      otlp/tempo:
        endpoint: tempo.observability.svc:4317
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug, otlp/tempo]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
```

### 7.3 The `Instrumentation` custom resource (`v1alpha1`)

This CR is the *policy*: which endpoint, which sampler, which propagators, and per-language agent images. One CR can serve a whole namespace.

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: fleet-instrumentation
  namespace: payments
spec:
  exporter:
    endpoint: http://otelcol-collector.observability.svc:4317
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "0.25"                 # keep 25% of root traces, always keep children of sampled roots
  resource:
    addK8sUIDAttributes: true
  env:
    - name: OTEL_EXPORTER_OTLP_PROTOCOL
      value: grpc
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.11.0
    resources:
      limits:
        cpu: 200m
        memory: 256Mi
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:0.49b0
    env:
      - name: OTEL_EXPORTER_OTLP_PROTOCOL
        value: http/protobuf     # Python defaults to http/protobuf; override the grpc default above
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.53.0
  dotnet:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-dotnet:1.9.0
  go:
    image: ghcr.io/open-telemetry/opentelemetry-go-instrumentation/autoinstrumentation-go:v0.19.0-alpha
```

### 7.4 Opt a workload in with an annotation

The annotation goes on the **pod template**, not the Deployment metadata. Value semantics: `"true"` → the single CR in this namespace; `"name"` → CR by name; `"ns/name"` → CR in another namespace; `"false"` → skip.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: payments
spec:
  replicas: 3
  selector:
    matchLabels: { app: checkout }
  template:
    metadata:
      labels: { app: checkout }
      annotations:
        instrumentation.opentelemetry.io/inject-java: "fleet-instrumentation"
        # Multi-container pod? pick the app container explicitly:
        instrumentation.opentelemetry.io/container-names: "checkout"
    spec:
      containers:
        - name: checkout
          image: registry.internal/checkout:1.4.0
          ports:
            - containerPort: 8080
```

For **Go**, the annotation is `inject-go` and the pod additionally needs the elevated security context the eBPF sidecar requires:

```yaml
      annotations:
        instrumentation.opentelemetry.io/inject-go: "fleet-instrumentation"
        instrumentation.opentelemetry.io/otel-go-auto-target-exe: "/app/checkout"
```

### 7.5 What the webhook actually injected

```console
$ kubectl -n payments get pod checkout-6b9f7c8d5-abcde -o jsonpath='{.spec.initContainers[*].name}'
opentelemetry-auto-instrumentation-java

$ kubectl -n payments get pod checkout-6b9f7c8d5-abcde \
    -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
JAVA_TOOL_OPTIONS= -javaagent:/otel-auto-instrumentation-java/javaagent.jar
OTEL_SERVICE_NAME=checkout
OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol-collector.observability.svc:4317
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
OTEL_PROPAGATORS=tracecontext,baggage
OTEL_RESOURCE_ATTRIBUTES=k8s.pod.name=checkout-6b9f7c8d5-abcde,k8s.namespace.name=payments,...
```

The init container copied the agent JAR into a shared `emptyDir` (`/otel-auto-instrumentation-java`), the operator mounted it into the app container, and `JAVA_TOOL_OPTIONS` makes the JVM pick it up — all with the application image untouched.

---

## 8. Verification and failure diagnosis

Instrumentation fails silently: the app runs fine, but no spans arrive. Diagnose top-down along the path **inject → emit → propagate → export → receive.**

### 8.1 Was the pod even mutated?

```console
$ kubectl -n payments describe pod checkout-6b9f7c8d5-abcde | grep -A2 'Init Containers'
Init Containers:
  opentelemetry-auto-instrumentation-java:
    Image:  ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.11.0
```

No init container ⇒ the webhook did not fire. Check, in order:

```console
$ kubectl get mutatingwebhookconfiguration | grep opentelemetry     # webhook registered?
$ kubectl -n payments get instrumentation                           # CR exists in the pod's namespace?
NAME                     ENDPOINT                                              AGE
fleet-instrumentation    http://otelcol-collector.observability.svc:4317       6m

$ kubectl -n opentelemetry-operator-system logs deploy/opentelemetry-operator | grep -i inject
```

Most common causes: annotation on the Deployment metadata instead of the **pod template**; `"true"` used while zero or several CRs exist in the namespace; pod created *before* the CR existed (recreate it — injection is at admission time only).

### 8.2 Is the agent emitting?

```console
$ kubectl -n payments logs checkout-6b9f7c8d5-abcde -c checkout | head
[otel.javaagent 2026-08-10 12:14:22] - opentelemetry-javaagent - version: 2.11.0
[otel.javaagent 2026-08-10 12:14:23] - Auto-instrumentation for: [jdbc, spring-web, tomcat]
```

Silence here ⇒ agent not attached (check `JAVA_TOOL_OPTIONS` is set and not overwritten by the app's own env).

### 8.3 Is anything reaching the Collector?

Point the pipeline at the `debug` exporter and watch:

```console
$ kubectl -n observability logs deploy/otelcol-collector | grep -A6 'ResourceSpans'
2026-08-10T12:15:04Z info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
     -> k8s.namespace.name: Str(payments)
ScopeSpans #0
Span #0  Name: POST /api/checkout  Kind: SERVER  Status: STATUS_CODE_UNSET
```

If the Collector is empty, generate a known-good signal to isolate app vs. pipeline:

```console
$ kubectl -n observability run telemetrygen --rm -it --restart=Never \
    --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest -- \
    traces --otlp-insecure --otlp-endpoint otelcol-collector:4317 --traces 5
2026-08-10T12:16:10Z info generated 5 traces
```

Test traces arrive but app traces don't ⇒ problem is in the app/agent, not the Collector.

### 8.4 The protocol/port trap

`OTEL_EXPORTER_OTLP_PROTOCOL=grpc` must hit **4317**; `http/protobuf` must hit **4318**. Java defaults to gRPC, Python defaults to `http/protobuf` — a fleet CR that hard-codes one protocol will silently drop the other language's data. Symptom: connection-refused or `UNAVAILABLE` in the app log:

```console
$ kubectl -n payments logs checkout-... -c checkout | grep -i 'export\|otlp'
[BatchSpanProcessor] Failed to export spans. Server responded UNAVAILABLE: endpoint 4318 (http) but exporter is grpc
```

### 8.5 Broken/disconnected traces

Spans exist but don't link across services ⇒ **propagation** mismatch. Confirm every service shares a propagator set:

```console
$ kubectl -n payments exec checkout-... -c checkout -- printenv OTEL_PROPAGATORS
tracecontext,baggage
```

If one service was manually instrumented and forgets to inject `traceparent` on outbound calls, its downstream shows up as a new root trace — the tell-tale "orphan" span with no parent.

### 8.6 Verification checklist

| Check | Command / signal | Healthy result |
|-------|------------------|----------------|
| Webhook fired | `describe pod` → Init Containers | Agent init container present |
| CR resolved | `kubectl get instrumentation -n <ns>` | Exactly one match for `"true"` |
| Agent attached | app container logs | `opentelemetry-javaagent - version:` line |
| Env injected | `printenv OTEL_SERVICE_NAME` | Correct service name (not `unknown_service`) |
| Protocol/port match | exporter proto vs receiver port | grpc↔4317, http/protobuf↔4318 |
| Collector receiving | `debug` exporter logs | `ResourceSpans` with your `service.name` |
| Pipeline vs app | `telemetrygen` test span | Test arrives ⇒ isolate to app |
| Traces connected | span parent IDs across services | No orphan roots; shared `OTEL_PROPAGATORS` |

---

## 9. References

- OpenTelemetry — Instrumentation (concepts): https://opentelemetry.io/docs/concepts/instrumentation/
- OpenTelemetry — Zero-code instrumentation: https://opentelemetry.io/docs/zero-code/
- OpenTelemetry — Instrumentation libraries: https://opentelemetry.io/docs/concepts/instrumentation/libraries/
- OpenTelemetry — Manual (code-based) instrumentation: https://opentelemetry.io/docs/concepts/instrumentation/code-based/
- OpenTelemetry — Semantic Conventions: https://opentelemetry.io/docs/specs/semconv/
- OpenTelemetry — Context propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- W3C Trace Context specification: https://www.w3.org/TR/trace-context/
- OpenTelemetry Operator: https://github.com/open-telemetry/opentelemetry-operator
- Operator — auto-instrumentation injection: https://github.com/open-telemetry/opentelemetry-operator/blob/main/docs/api/instrumentations.md
- Java zero-code agent: https://opentelemetry.io/docs/zero-code/java/agent/
- Python zero-code: https://opentelemetry.io/docs/zero-code/python/
- Node.js zero-code: https://opentelemetry.io/docs/zero-code/js/
- .NET zero-code: https://opentelemetry.io/docs/zero-code/dotnet/
- Go eBPF auto-instrumentation: https://github.com/open-telemetry/opentelemetry-go-instrumentation
- OTLP exporter environment variables: https://opentelemetry.io/docs/specs/otel/protocol/exporter/
- `telemetrygen` utility: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
- OTCA certification & curriculum: https://training.linuxfoundation.org/certification/opentelemetry-certified-associate-otca/