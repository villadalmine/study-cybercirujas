# Topic 2.2 — Composability and Extension

**Guided Exercises · OTCA · Domain: The OpenTelemetry API and SDK**

OpenTelemetry is not a monolithic agent — it is a set of **interfaces with swappable implementations**. Composability is the property that lets you assemble a telemetry pipeline out of small, independently-replaceable parts (processors, samplers, exporters, propagators, resource detectors, Collector components); extension is the ability to write your *own* implementation of any of those interfaces without forking the project. These exercises walk you through the concrete extension points, from the SDK boundary all the way to building a custom Collector distribution.

> Reference syllabus: OTCA Curriculum — *The OpenTelemetry API and SDK* (`https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf`).

### Prerequisites

- Go 1.22+ (`go version`)
- `go.opentelemetry.io/otel` v1.28+ and matching `sdk` modules
- The OpenTelemetry Collector Builder (`ocb`/`builder`) for Exercise 5 — install with
  `go install go.opentelemetry.io/collector/cmd/builder@latest`
- A scratch module: `mkdir otca-22 && cd otca-22 && go mod init example.com/otca22`

---

## Exercise 1 — The API/SDK boundary: why OpenTelemetry is composable at all

The single most important design decision in OpenTelemetry is that **instrumentation depends only on the API**, and the **SDK is wired in by the application at startup**. If no SDK is registered, the API is a no-op. This is what lets a library be instrumented once and dropped into *any* application, regardless of which exporter or sampler that application chooses.

### Steps

1. Create `main.go` with instrumentation that imports **only the API** (no `sdk/*`):

    ```go
    package main

    import (
        "context"
        "fmt"

        "go.opentelemetry.io/otel"
        "go.opentelemetry.io/otel/attribute"
    )

    func doWork(ctx context.Context) {
        // A library would write exactly this and nothing else.
        tracer := otel.Tracer("example.com/otca22")
        _, span := tracer.Start(ctx, "doWork")
        defer span.End()
        span.SetAttributes(attribute.String("work.kind", "demo"))

        fmt.Printf("recording=%v  spanID=%s\n",
            span.IsRecording(), span.SpanContext().SpanID())
    }

    func main() {
        doWork(context.Background())
    }
    ```

2. Run it with **no SDK registered**:

    ```console
    $ go run .
    recording=false  spanID=0000000000000000
    ```

    The global `TracerProvider` defaults to a **no-op**: spans are non-recording, the span ID is all-zeros, nothing is emitted. The code is valid, safe, and costs almost nothing.

3. Now, **without touching `doWork`**, add the SDK in `main`:

    ```go
    import (
        sdktrace "go.opentelemetry.io/otel/sdk/trace"
        "go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
    )

    func main() {
        exp, _ := stdouttrace.New(stdouttrace.WithPrettyPrint())
        tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp))
        otel.SetTracerProvider(tp)            // <-- the wiring happens ONCE, here
        defer tp.Shutdown(context.Background())

        doWork(context.Background())
    }
    ```

4. Run again:

    ```console
    $ go run .
    recording=true  spanID=8f2a1c...
    {
      "Name": "doWork",
      "SpanContext": { "TraceID": "…", "SpanID": "8f2a1c…" },
      "Attributes": [ { "Key": "work.kind", "Value": { "Type": "STRING", "Value": "demo" } } ]
      ...
    }
    ```

    The **same instrumentation code** is now live — because the SDK, not the API, decided what happens.

### Check your understanding

- **1a.** Why does `span.IsRecording()` return `false` in step 2 even though `Start`/`End`/`SetAttributes` all executed successfully?
- **1b.** A third-party HTTP library instruments itself with `otel.Tracer(...)`. Why is it a design error for that library to import `go.opentelemetry.io/otel/sdk/trace` or call `otel.SetTracerProvider`?
- **1c.** What is the practical benefit of `IsRecording()` being cheap when no SDK is installed?

---

## Exercise 2 — Extending the pipeline with a custom `SpanProcessor`

A `SpanProcessor` is the SDK's per-span hook. The built-in `BatchSpanProcessor` batches spans to an exporter; you can write your own to enrich, filter, or redact. The interface has four methods, and the crucial detail is the **read/write asymmetry**: `OnStart` receives a **ReadWrite** span (mutable), `OnEnd` receives a **ReadOnly** span (immutable).

### Steps

1. Add a processor that stamps a tenant ID (pulled from context) onto every span:

    ```go
    package main

    import (
        "context"

        "go.opentelemetry.io/otel/attribute"
        sdktrace "go.opentelemetry.io/otel/sdk/trace"
    )

    type tenantKey struct{}

    type tenantProcessor struct{}

    func (tenantProcessor) OnStart(parent context.Context, s sdktrace.ReadWriteSpan) {
        if t, ok := parent.Value(tenantKey{}).(string); ok {
            s.SetAttributes(attribute.String("tenant.id", t)) // mutation allowed here
        }
    }
    func (tenantProcessor) OnEnd(s sdktrace.ReadOnlySpan)  {}
    func (tenantProcessor) Shutdown(context.Context) error { return nil }
    func (tenantProcessor) ForceFlush(context.Context) error { return nil }
    ```

2. Register it **alongside** the batch exporter. Processors compose in registration order:

    ```go
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithSpanProcessor(tenantProcessor{}),   // 1st: enrich
        sdktrace.WithBatcher(exp),                       // 2nd: export
    )
    ```

3. Feed a tenant through context and run:

    ```go
    ctx := context.WithValue(context.Background(), tenantKey{}, "acme")
    doWork(ctx)
    ```

    ```console
    $ go run .
    {
      "Name": "doWork",
      "Attributes": [
        { "Key": "work.kind", "Value": { "Type": "STRING", "Value": "demo" } },
        { "Key": "tenant.id", "Value": { "Type": "STRING", "Value": "acme" } }
      ]
      ...
    }
    ```

4. **Break it on purpose.** Move the `SetAttributes` call into `OnEnd` (where the argument is `ReadOnlySpan`) and try to compile:

    ```console
    $ go build .
    ./main.go:XX:4: s.SetAttributes undefined (type trace.ReadOnlySpan has no field or method SetAttributes)
    ```

    The type system enforces *when* mutation is legal — a span is only writable while it is live.

### Check your understanding

- **2a.** Why must span enrichment happen in `OnStart` and not in `OnEnd`? What real change did step 4 prove?
- **2b.** You register `tenantProcessor{}` **after** `WithBatcher(exp)` instead of before. Does the exporter still see `tenant.id`? Explain in terms of which callback runs when.
- **2c.** Name one task that genuinely belongs in `OnEnd` rather than `OnStart`.

---

## Exercise 3 — Composing samplers with `ParentBased`

Sampling is an extension point *and* a composition point. `Sampler` has two methods (`ShouldSample`, `Description`), and the built-in `ParentBased` sampler is itself a **composite** that delegates based on the parent's decision. You write a "root" sampler; `ParentBased` decides when to consult it.

### Steps

1. Write a sampler that keeps only a set of business-critical root operations:

    ```go
    package main

    import (
        sdktrace "go.opentelemetry.io/otel/sdk/trace"
        "go.opentelemetry.io/otel/trace"
    )

    type criticalOps struct{ names map[string]struct{} }

    func (c criticalOps) ShouldSample(p sdktrace.SamplingParameters) sdktrace.SamplingResult {
        psc := trace.SpanContextFromContext(p.ParentContext)
        decision := sdktrace.Drop
        if _, ok := c.names[p.Name]; ok {
            decision = sdktrace.RecordAndSample
        }
        return sdktrace.SamplingResult{
            Decision:   decision,
            Tracestate: psc.TraceState(), // propagate upstream tracestate unchanged
        }
    }
    func (criticalOps) Description() string { return "CriticalOps" }
    ```

2. **Compose** it with `ParentBased` so downstream children honor the root decision instead of re-sampling:

    ```go
    root := criticalOps{names: map[string]struct{}{"checkout": {}, "payment": {}}}

    sampler := sdktrace.ParentBased(
        root,
        sdktrace.WithRemoteParentSampled(sdktrace.AlwaysSample()),
        sdktrace.WithRemoteParentNotSampled(sdktrace.NeverSample()),
    )

    tp := sdktrace.NewTracerProvider(
        sdktrace.WithSampler(sampler),
        sdktrace.WithBatcher(exp),
    )
    ```

3. Emit a root span named `login` (not critical) and one named `checkout` (critical):

    ```console
    $ go run .            # login: Drop → nothing exported
    $ go run .            # checkout: RecordAndSample → span exported
    {
      "Name": "checkout",
      "SpanContext": { "TraceFlags": "01" }   # sampled bit set
      ...
    }
    ```

4. Now compare against the **environment-variable** equivalent — the SDK spec defines a composable sampler grammar too:

    ```console
    $ export OTEL_TRACES_SAMPLER=parentbased_traceidratio
    $ export OTEL_TRACES_SAMPLER_ARG=0.25
    ```

    `parentbased_*` is the same `ParentBased` composition, declared through config instead of code.

### Check your understanding

- **3a.** A remote service already decided a trace is sampled (`traceparent` flag = `01`) and calls your service. With the `ParentBased` config in step 2, does your `criticalOps` root sampler even run for the child span? Why is that the desired behavior in a distributed trace?
- **3b.** Why does `ShouldSample` return the parent's `Tracestate` in the result rather than an empty one?
- **3c.** If you had used the bare `criticalOps` sampler as the *global* sampler (no `ParentBased`), what inconsistency could appear within a single distributed trace?

---

## Exercise 4 — Composite propagators: interoperating across services

Context propagation is pluggable and **composable by design**: the global propagator is usually a *composite* that injects/extracts several formats at once. Mismatched propagators between two services is the classic cause of "broken traces" — spans that never join into one trace.

### Steps

1. Set a composite of W3C Trace Context **and** Baggage:

    ```go
    import "go.opentelemetry.io/otel/propagation"

    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{}, // traceparent / tracestate headers
        propagation.Baggage{},      // baggage header
    ))
    ```

2. Confirm the injected headers on an outgoing request carrier:

    ```go
    carrier := propagation.MapCarrier{}
    otel.GetTextMapPropagator().Inject(ctx, carrier)
    fmt.Println(carrier) // map[baggage:... traceparent:00-<trace>-<span>-01 ...]
    ```

3. Make the propagator **configuration-driven** instead of hard-coded, using the contrib autoconfig helper that reads `OTEL_PROPAGATORS`:

    ```go
    import "go.opentelemetry.io/contrib/propagators/autoprop"

    otel.SetTextMapPropagator(autoprop.NewTextMapPropagator())
    ```

    ```console
    $ export OTEL_PROPAGATORS=tracecontext,baggage,b3
    $ go run .
    # traceparent + baggage + X-B3-* all injected
    ```

4. **Reproduce a broken trace.** Set service A to `OTEL_PROPAGATORS=b3` and service B to `OTEL_PROPAGATORS=tracecontext`. Observe that B extracts no parent from A's `X-B3-*` headers and starts a brand-new root trace.

### Check your understanding

- **4a.** In step 4, why does B create a new root trace even though A sent perfectly valid B3 headers?
- **4b.** What does adding `propagation.Baggage{}` give you that `TraceContext{}` alone does not?
- **4c.** Why is a *composite* propagator (rather than a single format) the safe default when you don't control every service in the mesh?

---

## Exercise 5 — Composing and extending the Collector (pipelines, connectors, OCB)

The Collector is composability made physical: a pipeline is `receivers → processors → exporters`, and **connectors** bridge one pipeline's output into another pipeline's input across signal types. The **OpenTelemetry Collector Builder (OCB)** extends this to the binary itself — you compose a custom distribution from exactly the modules you need.

### Steps

1. Write a config that uses the `spanmetrics` **connector** to derive metrics from traces — one component acting as an *exporter* in the traces pipeline and a *receiver* in the metrics pipeline:

    ```yaml
    # config.yaml
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }

    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 512
      batch: {}

    connectors:
      spanmetrics: {}

    exporters:
      otlp/traces:
        endpoint: tempo:4317
        tls: { insecure: true }
      prometheus:
        endpoint: 0.0.0.0:8889

    service:
      pipelines:
        traces:
          receivers:  [otlp]
          processors: [memory_limiter, batch]
          exporters:  [otlp/traces, spanmetrics]   # connector as exporter
        metrics/spanmetrics:
          receivers:  [spanmetrics]                # same connector as receiver
          processors: [batch]
          exporters:  [prometheus]
    ```

2. Validate the composition without starting traffic:

    ```console
    $ otelcol-contrib validate --config config.yaml
    # (no output, exit 0 == valid)
    ```

3. Now **extend the binary itself**. Write an OCB manifest that includes only the components you use:

    ```yaml
    # builder-config.yaml
    dist:
      name: otelcol-otca
      description: Minimal custom OTCA distribution
      output_path: ./_build
      otelcol_version: 0.116.0

    receivers:
      - gomod: go.opentelemetry.io/collector/receiver/otlpreceiver v0.116.0
    processors:
      - gomod: go.opentelemetry.io/collector/processor/batchprocessor v0.116.0
    exporters:
      - gomod: go.opentelemetry.io/collector/exporter/debugexporter v0.116.0
    connectors:
      - gomod: go.opentelemetry.io/collector/connector/forwardconnector v0.116.0
    ```

4. Build and inspect the result:

    ```console
    $ builder --config builder-config.yaml
    ...
    2026-... info  Compiling
    2026-... info  Compiled  {"binary": "./_build/otelcol-otca"}

    $ ./_build/otelcol-otca components
    # lists ONLY otlp, batch, debug, forward — nothing else is in the binary
    ```

### Check your understanding

- **5a.** What makes a *connector* fundamentally different from a processor or an exporter? What did the `spanmetrics` example demonstrate that a processor could not?
- **5b.** The traces pipeline lists `[memory_limiter, batch]` in that order. Why does `memory_limiter` come first, and would reordering change behavior under memory pressure?
- **5c.** Give two operational reasons (beyond binary size) to build a trimmed custom distribution with OCB instead of shipping `otelcol-contrib`.
- **5d.** Both the SDK `SpanProcessor` chain from Exercise 2 and the Collector pipeline here are "compose small components in order." State the key difference in *where* each runs and *what* each can therefore do.

---

## Answers

<details>
<summary><strong>Show answers (Exercises 1–5)</strong></summary>

### Exercise 1 — API/SDK boundary
- **1a.** The global `TracerProvider` is the **no-op provider** by default. `Tracer`, `Start`, `End`, and `SetAttributes` are all valid API calls that resolve to no-op implementations: they return a non-recording span (`IsRecording()==false`), an all-zero `SpanID`, and emit nothing. Success of the call says nothing about recording — recording is the SDK's job, and no SDK was registered.
- **1b.** Because the API/SDK split is what makes the library **portable**. A library that imports `sdk/trace` or calls `SetTracerProvider` would force *its* choice of processors/exporters/sampler onto every application that uses it, and could clobber the application's own global provider. Libraries depend on the API only; **the application** owns the SDK wiring, exactly once, at startup.
- **1c.** Zero-cost-when-disabled instrumentation. Libraries can be instrumented liberally; if the consuming app installs no SDK (or hasn't yet), the overhead is a few no-op calls and a cheap `IsRecording()` guard, so shipping instrumentation is safe by default.

### Exercise 2 — Custom SpanProcessor
- **2a.** A span may only be mutated while it is **live**. `OnStart` hands you a `ReadWriteSpan`; by `OnEnd` the span is finished and immutable (`ReadOnlySpan`), because it may already be queued/serialized for export. Step 4 proved this at the *type level*: `ReadOnlySpan` has no `SetAttributes`, so the compiler rejects late mutation — the invariant is enforced, not merely documented.
- **2b.** Yes. Registration order controls the sequence of `OnStart`/`OnEnd` callbacks, **but the exporter reads the span at `OnEnd`**, which runs after the whole span lifetime. Since `tenant.id` was set in `OnStart` (during the span's life), it is present on the finished span regardless of whether `tenantProcessor` was registered before or after the batcher. Order matters when two processors' side effects depend on each other, not for this enrich-then-export case.
- **2c.** Anything that needs the *completed* span: exporting/batching it, computing duration-based metrics, recording final status, or making a sampling/tail decision on the finished span. These read final state and must run in `OnEnd`.

### Exercise 3 — Sampler composition
- **3a.** No — your `criticalOps` root sampler does **not** run for that child. `ParentBased` sees a *remote, sampled* parent and applies `WithRemoteParentSampled(AlwaysSample())`, so the child is sampled to match the parent. This is desirable because sampling decisions must be **consistent across a whole distributed trace**: if the root was kept, dropping a downstream child would produce a broken, partial trace.
- **3b.** To preserve `tracestate`, the W3C vendor-specific state that travels with the trace (e.g. other systems' sampling metadata). Returning an empty `Tracestate` would silently discard upstream state; a well-behaved sampler passes the parent's `tracestate` through untouched unless it deliberately adds an entry.
- **3c.** Each span would be sampled **independently** by name, ignoring the parent decision. A single trace could then have a kept root and dropped intermediate spans (or vice-versa), yielding orphaned/partial traces. `ParentBased` exists precisely to make the root decision authoritative for the rest of the trace.

### Exercise 4 — Composite propagators
- **4a.** B's propagator is `tracecontext`, which only reads `traceparent`/`tracestate`. A sent context as `X-B3-*` (B3 format). B never looks at those headers, extracts no `SpanContext`, and therefore starts a **new root trace**. Propagation only works when injector and extractor agree on the wire format.
- **4b.** `Baggage{}` propagates the W3C `baggage` header — arbitrary application-level key/values (tenant, request class, feature flags) that ride along the request and can be read by any downstream service or attached to spans. `TraceContext{}` only carries trace/span IDs and flags; it does not move user data.
- **4c.** A composite injects/extracts **multiple formats simultaneously**, so a service can *understand* whichever format an upstream sent (e.g. accept both `tracecontext` and `b3` during a migration) and emit the format its downstreams need. In a heterogeneous mesh where you don't control every hop, this maximizes the chance that context survives across boundaries.

### Exercise 5 — Collector composability
- **5a.** A **connector** is simultaneously an exporter for one pipeline and a receiver for another — it *joins* pipelines, and can cross signal types (traces → metrics). A processor only transforms data *within* one pipeline and cannot emit into a different pipeline or a different signal. `spanmetrics` produced a **metrics** stream out of **trace** data, which no processor or exporter alone can do.
- **5b.** `memory_limiter` must run **first** so it can reject/backpressure incoming data before the `batch` processor accumulates it in memory. If `batch` ran first, batches would already be buffered before the limiter got a chance to protect the process — under memory pressure the reordering would defeat the guard and risk OOM. Order in a Collector pipeline is significant.
- **5c.** Any two of: (1) **Smaller attack/CVE surface** — fewer modules means fewer dependencies to patch and audit. (2) **Supply-chain / compliance control** — you pin exactly which components (and versions) ship, nothing unexpected. (3) **Faster startup and lower memory** from not loading unused components. (4) **Ability to include private/in-house components** not present in `-contrib`.
- **5d.** Both are ordered chains of small composable components, but they run in **different places with different reach**. The SDK `SpanProcessor` runs **in the application process**, so it sees rich in-process context (request context values, live `ReadWriteSpan`, app memory) but only that one app's telemetry. The Collector pipeline runs **out-of-process** as shared infrastructure: it sees telemetry from *many* services and signals and can do cross-cutting work (tail sampling, cross-signal connectors, fan-out to multiple backends), but it has no access to the originating application's in-process context.

</details>