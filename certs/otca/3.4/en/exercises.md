# OTCA 3.4 — Pipelines (Guided Exercises)

> **Domain 3 — The OpenTelemetry Collector · Topic 3.4 Pipelines**
> A *pipeline* is the ordered path a single signal type (traces, metrics or logs) follows inside the Collector: **receivers → processors → exporters**, declared under `service::pipelines`. These labs build one from scratch, then exercise the sharing rules, processor ordering, and connectors that the exam probes.
>
> **Prerequisites.** A single static binary of the contrib distribution (`otelcol-contrib`) and the load generator `telemetrygen`. Both are published on the [releases page](https://github.com/open-telemetry/opentelemetry-collector-releases/releases). Verify:
> ```console
> $ otelcol-contrib --version
> otelcol-contrib version 0.109.0
> $ telemetrygen --help | head -1
> Usage: telemetrygen [command]
> ```
> Everything below runs locally — no external backend required, because the `debug` exporter prints to stdout.

---

## Exercise 1 — Anatomy of a pipeline: define vs. use

The Collector separates *declaring* a component (top-level `receivers:`, `processors:`, `exporters:` maps) from *using* it (referencing it inside a `service::pipelines` entry). A component that is declared but never referenced is built lazily — effectively idle. A component that is referenced but never declared is a fatal config error. This exercise makes both halves visible.

**Steps**

1. Create `01-min.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     batch:

   exporters:
     debug:
       verbosity: detailed

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [debug]
   ```

2. Statically validate it (loads and builds the config graph, but does **not** start listeners):

   ```console
   $ otelcol-contrib validate --config=01-min.yaml
   $
   ```
   A clean exit `0` with no output means the pipeline graph resolves.

3. Now break the *use* side. Add `zpages` to the `processors` list of the traces pipeline **without** declaring it, and re-validate:

   ```console
   $ otelcol-contrib validate --config=01-min.yaml
   Error: invalid configuration: service::pipelines::traces: references processor "zpages" which is not configured
   ```

4. Revert step 3. Now break the *shape* rule — delete the `exporters: [debug]` line from the pipeline and validate:

   ```console
   $ otelcol-contrib validate --config=01-min.yaml
   Error: invalid configuration: service::pipelines::traces: must have at least one exporter
   ```

5. Restore the exporter. Add a **declared-but-unused** exporter (`nop`) to the top-level `exporters:` map but do *not* reference it in any pipeline. Validate again — it passes. Then run the Collector and generate data:

   ```console
   $ otelcol-contrib --config=01-min.yaml &
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=2
   ```
   Observe the `debug` exporter output:
   ```
   info    TracesExporter  {"kind": "exporter", "data_type": "traces", "name": "debug", "resource spans": 1, "spans": 2}
   info    ResourceSpans #0
   Resource attributes:
        -> service.name: Str(telemetrygen)
   ScopeSpans #0
   ScopeSpans SchemaURL:
   InstrumentationScope telemetrygen
   Span #0
       Trace ID       : 6d3f... 
       Name           : okey-dokey-0
       Kind           : Server
   ```

**Comprehension check**

- **Q1.1** A component appears under `receivers:` but in no pipeline. Does the Collector start it, warn, or fail? Contrast that with referencing it in a pipeline without declaring it.
- **Q1.2** Both `must have at least one receiver` and `must have at least one exporter` are enforced, but there is no `must have at least one processor` rule. Why is `processors:` optional in a pipeline?
- **Q1.3** What is the operational value of `validate` returning non-zero *before* you ever bind port 4317?

---

## Exercise 2 — Multiple named pipelines & component sharing

Pipelines are keyed by `<type>[/<name>]`. You may run several pipelines of the same signal type — `traces`, `traces/sampled`, `traces/audit` — each an independent path. When the **same declared component** is referenced by more than one pipeline, the Collector applies precise sharing rules that the exam tests directly.

**Steps**

1. Create `02-share.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     batch:

   exporters:
     debug/full:
       verbosity: detailed
     debug/counts:
       verbosity: normal

   service:
     telemetry:
       metrics:
         level: none
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [debug/full]
       traces/mirror:
         receivers: [otlp]
         processors: [batch]
         exporters: [debug/counts]
   ```

2. Validate, then run it and send **one** batch of traces:

   ```console
   $ otelcol-contrib --config=02-share.yaml &
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=1
   ```

3. Note that a single OTLP stream reaches **both** exporters — one span batch appears rendered as `detailed` (from `debug/full`) and again as `normal` counts (from `debug/counts`). The `otlp` receiver was declared once and is bound to port 4317 exactly once.

4. Reason about `batch`: it is referenced by both `traces` and `traces/mirror`. Consult the [architecture doc](https://opentelemetry.io/docs/collector/architecture/): receivers and exporters referenced in multiple pipelines are **single shared instances** (fan-out / fan-in), but each pipeline receives its **own instance** of every processor.

**Comprehension check**

- **Q2.1** Port 4317 is not opened twice even though two pipelines list `otlp`. Which sharing rule explains that, and what would happen if the receiver were instantiated once per pipeline instead?
- **Q2.2** The `batch` processor is stateful — it accumulates items across calls until a size or timeout threshold. Given the per-pipeline-instance rule, do `traces` and `traces/mirror` share one accumulation buffer or two? Why does this matter for a `tail_sampling` or `groupbytrace` processor placed in two pipelines?
- **Q2.3** You want *exactly one* copy of every span sent to two different backends. Should you use two pipelines each with its own exporter, or one pipeline with two exporters? What does each choice cost in receiver instances and buffering?

---

## Exercise 3 — Processor order is semantic

Receiver order and exporter order inside a pipeline are irrelevant. **Processor order is not** — items flow through processors strictly left-to-right, so placement decides both correctness and cost. This lab demonstrates the canonical ordering: `memory_limiter` first, filtering next, `batch` last (nearest the exporters).

**Steps**

1. Create `03-order.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     memory_limiter:
       check_interval: 1s
       limit_mib: 512
       spike_limit_mib: 128
     filter/drop_health:
       error_mode: ignore
       traces:
         span:
           - 'attributes["http.target"] == "/healthz"'
     batch:
       timeout: 5s
       send_batch_size: 8192
       send_batch_max_size: 10000

   exporters:
     debug:
       verbosity: normal

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, filter/drop_health, batch]
         exporters: [debug]
   ```

2. Validate and run. Send two kinds of traffic — normal spans and health-check spans:

   ```console
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=5
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=5 \
       --span-duration=1ms --attributes='http.target="/healthz"'
   ```
   Only the first group survives to the `debug` exporter; the `filter/drop_health` OTTL condition drops the health spans before they are batched.

3. Mentally simulate two *wrong* orderings and predict the effect:
   - `[batch, memory_limiter, filter/drop_health]` — data is batched, then the memory limiter may reject an already-assembled batch, and filtering happens after batching effort was spent.
   - `[filter/drop_health, batch, memory_limiter]` — the memory limiter now guards *after* the CPU-heavy batching work is already done, defeating its purpose as a back-pressure valve.

4. Confirm the recommended ordering against the official processor docs: [`memory_limiter` README](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md) ("should be the first processor defined in the pipeline") and [`batch` README](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md).

**Comprehension check**

- **Q3.1** Why must `memory_limiter` be first rather than last, given that its job is to shed load under memory pressure?
- **Q3.2** Why is `batch` placed *after* filtering/sampling processors and nearest the exporters? What is wasted if you batch first and drop later?
- **Q3.3** `filter/drop_health` uses `error_mode: ignore`. If a span lacked the `http.target` attribute, what would `ignore` do versus `propagate`, and how could the wrong choice silently drop or halt data?
- **Q3.4** If you swap the position of `otlp` with a second receiver in the `receivers:` list, does pipeline behavior change? Why is receiver order — unlike processor order — irrelevant?

---

## Exercise 4 — Connectors: bridging two pipelines

A **connector** is a component that is simultaneously an *exporter* in one pipeline and a *receiver* in another, letting a signal in one pipeline produce (possibly different-typed) signal in another. This is how a single Collector derives metrics from traces without an external service. Here we use the `count` connector to turn a traces pipeline into span-count metrics.

**Steps**

1. Create `04-connector.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     batch:

   connectors:
     count:

   exporters:
     debug:
       verbosity: detailed

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [count]          # connector acts as EXPORTER here
       metrics:
         receivers: [count]          # same connector acts as RECEIVER here
         processors: [batch]
         exporters: [debug]
   ```

2. Validate. Note the graph is acyclic: `otlp → traces → count → metrics → debug`. Run and feed traces:

   ```console
   $ otelcol-contrib --config=04-connector.yaml &
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=4
   ```

3. Observe that the `debug` exporter now prints **metrics**, not traces — the `count` connector emitted a `trace.span.count` sum derived from the traces it consumed:

   ```
   info    MetricsExporter {"kind": "exporter", "data_type": "metrics", "name": "debug", "resource metrics": 1, "metrics": 1, "data points": 1}
   Metric #0
   Descriptor:
        -> Name: trace.span.count
        -> Description: The number of spans observed.
        -> DataType: Sum
   NumberDataPoint #0
   Value: 8
   ```
   (Four traces × two spans each = 8.)

4. Break it: reference `count` as an exporter in `traces` but **remove** the `metrics` pipeline that consumes it. Validate:

   ```console
   $ otelcol-contrib validate --config=04-connector.yaml
   Error: connector "count" used as exporter in [traces] pipeline but not used in any supported receiver pipeline
   ```

**Comprehension check**

- **Q4.1** In `04-connector.yaml`, in which pipeline does `count` behave as an exporter and in which as a receiver? What determines each role?
- **Q4.2** The exporter of the `traces` pipeline is a connector, yet no trace ever leaves the Collector. Where did the spans "go", and what does the `metrics` pipeline actually receive?
- **Q4.3** A connector referenced only as an exporter (no consuming pipeline) is a validation error. Why is that stricter than a plain declared-but-unused exporter (Exercise 1, step 5), which is allowed?
- **Q4.4** Name one signal-type combination a connector enables that a receiver/exporter pair cannot (hint: think traces-in / metrics-out within a single process, e.g. `spanmetrics`, `servicegraph`, `routing`, `forward`).

---

## Exercise 5 — Observing the pipeline itself

A pipeline you cannot see is a pipeline you cannot debug. The Collector exposes its own health through `service::telemetry` (self-metrics/logs) and through extensions like `zpages` and `health_check`. Extensions are **not** part of any pipeline — they attach to `service::extensions`.

**Steps**

1. Create `05-observe.yaml`:

   ```yaml
   extensions:
     health_check:
       endpoint: 0.0.0.0:13133
     zpages:
       endpoint: 0.0.0.0:55679

   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     batch:

   exporters:
     debug:
       verbosity: normal

   service:
     extensions: [health_check, zpages]
     telemetry:
       logs:
         level: info
       metrics:
         level: detailed
         readers:
           - pull:
               exporter:
                 prometheus:
                   host: 0.0.0.0
                   port: 8888
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [debug]
   ```

2. Run it. Check liveness and the pipeline z-page:

   ```console
   $ curl -s localhost:13133 | head
   {"status":"Server available","upSince":"2026-08-11T10:22:04Z"}

   $ curl -s localhost:55679/debug/pipelinez | head
   Pipelines
   Pipeline           Receivers        Processors     Exporters
   traces             [otlp]           [batch]        [debug]
   ```

3. Send traffic and scrape the Collector's **own** metrics to see throughput per component:

   ```console
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=10
   $ curl -s localhost:8888/metrics | grep -E 'receiver_accepted_spans|exporter_sent_spans'
   otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 20
   otelcol_exporter_sent_spans{exporter="debug"} 20
   ```

4. Correlate: `receiver_accepted_spans` should equal `exporter_sent_spans` when nothing is dropped. If a `filter` or `memory_limiter` sheds data, `refused`/`dropped` counters diverge — that gap *is* your pipeline diagnosis.

**Comprehension check**

- **Q5.1** `zpages` and `health_check` appear under `service::extensions`, never inside `service::pipelines`. Why are extensions deliberately outside the receiver→processor→exporter path?
- **Q5.2** You observe `otelcol_receiver_accepted_spans = 20` but `otelcol_exporter_sent_spans = 12`. List two pipeline-internal causes and the counter you'd check next to confirm each.
- **Q5.3** What is the difference between `service::telemetry` and a `metrics` pipeline built from the `prometheus` receiver? Which one reports on the *Collector itself*?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**

- **A1.1** A declared-but-unreferenced receiver is simply not wired into any pipeline; the Collector builds only components that a pipeline uses, so it neither binds a port nor errors — it is effectively idle (and does not appear on the `pipelinez` z-page). The reverse — referencing an undeclared component — is a fatal build error (`references processor "zpages" which is not configured`) caught at `validate` time, because the config graph cannot be resolved.
- **A1.2** Processors are optional because a valid pipeline is just "get data in, get data out" — a receiver and an exporter suffice. Processors only *transform* the stream; a pipeline with none passes data straight through. Receivers and exporters are mandatory because without a source there is nothing to move and without a sink there is nowhere to move it, so both minimums are enforced.
- **A1.3** `validate` resolves and builds the entire component graph without opening sockets or contacting backends, so a bad config fails in CI or a pre-flight check — before it ever claims port 4317, drops traffic, or half-starts in production. It converts a runtime outage into a build-time error.

**Exercise 2**

- **A2.1** Receivers referenced in multiple pipelines are a **single shared instance**; the receiver's output is *fanned out* (duplicated) to every pipeline that lists it. If it were instantiated per pipeline, each instance would try to bind `0.0.0.0:4317` and the second would fail with an address-already-in-use error at startup.
- **A2.2** Two separate buffers. Each pipeline gets its **own** processor instance, so `traces` and `traces/mirror` accumulate independently. This matters critically for stateful processors: a `tail_sampling` or `groupbytrace` shared across two pipelines does **not** pool spans of the same trace across them — each instance sees only its pipeline's slice, so sampling decisions are made on partial data. If you need one global decision, route all data through one pipeline.
- **A2.3** One pipeline with two exporters. Receivers/exporters are fanned out, so a single pipeline delivers one copy of every span to each exporter with a single receiver instance and one processor chain (one batch buffer). Two pipelines each replaying the same receiver also work but duplicate the processor instances (two batch buffers, double the memory/CPU for identical work) — pay that cost only when the two paths need *different* processing.

**Exercise 3**

- **A3.1** `memory_limiter` is a back-pressure valve: when memory crosses its soft/hard limits it *refuses* incoming data and forces receivers to apply back-pressure to clients. Placed first, it rejects load before any downstream processor spends CPU/memory on it. Placed last, the expensive work (filtering, batching) has already consumed memory by the time the limiter reacts — too late to protect the process from OOM.
- **A3.2** `batch` is placed last so it only ever batches data that will actually be exported. Filtering/sampling *before* batching means dropped items never enter a batch. Batch-then-drop wastes the memory and CPU of assembling batches whose contents are then discarded, and it dilutes batch efficiency.
- **A3.3** `error_mode: ignore` skips OTTL evaluation errors (e.g. a missing `http.target` yields nil, the condition is simply false, the span is kept and processing continues). `propagate` would surface the OTTL error up the pipeline, potentially failing the whole batch. Choosing `propagate` where nil attributes are normal can halt/error otherwise-valid data; choosing `ignore` where you *expected* a match can silently keep spans you meant to drop — either way the misconfiguration is invisible without checking counters.
- **A3.4** No behavioral change. Receivers are fan-in sources merged into one stream and exporters are fan-out sinks; neither has an inter-component ordering. Only processors form a strict left-to-right chain where each mutates the stream handed to the next, so only their order is semantic.

**Exercise 4**

- **A4.1** `count` is an **exporter** in the `traces` pipeline (it terminates that pipeline) and a **receiver** in the `metrics` pipeline (it originates that one). The role is determined purely by *where it is listed* — in the `exporters:` list vs. the `receivers:` list of a pipeline — not by any config on the connector itself.
- **A4.2** The spans are consumed by the connector and never exported externally; the `count` connector transforms them into a derived `trace.span.count` metric. The `metrics` pipeline therefore receives **metrics** produced from the trace stream, not the traces themselves.
- **A4.3** A connector must form a complete bridge: something must consume what it produces, or the produced signal has nowhere to go — a dangling half-graph. The Collector treats that as a config error. A plain exporter, by contrast, is a terminal sink; declaring one and not using it wastes nothing structurally, so it is merely idle, not invalid.
- **A4.4** A connector can perform **cross-signal** derivation inside one process: traces-in → metrics-out (`count`, `spanmetrics`, `servicegraph`). A receiver/exporter pair only moves a signal in and out of the Collector; it cannot change the signal type or synthesize new signals from another. (Connectors also do same-signal work like `forward` and attribute-based `routing`.)

**Exercise 5**

- **A5.1** Extensions provide Collector-wide capabilities — health, profiling, page serving, auth — that are orthogonal to data flow. They do not receive, transform, or emit telemetry, so putting them in a pipeline would be meaningless; `service::extensions` is the lifecycle hook that starts/stops them alongside the pipelines without being part of any signal path.
- **A5.2** (1) A `filter`/sampling processor dropped 8 spans — confirm with a divergence in the processor-level accepted/refused counters or the exporter `sent` vs. receiver `accepted` gap. (2) The exporter failed to deliver 8 — confirm with `otelcol_exporter_send_failed_spans` and/or `otelcol_exporter_enqueue_failed_spans` (queue full / backend rejecting). A `memory_limiter` refusal would instead show up as `otelcol_receiver_refused_spans`.
- **A5.3** `service::telemetry` is the Collector's **self-observability** — metrics/logs/traces *about the Collector process* (throughput counters, queue sizes, its own logs), exposed here on `:8888`. A `metrics` pipeline fed by the `prometheus` receiver scrapes *external* targets and moves their metrics through the Collector as ordinary data. The former reports on the Collector itself; the latter treats the Collector as a conduit for someone else's metrics.

</details>

---

**Sources**
- OpenTelemetry Collector — Configuration (pipelines, receivers/processors/exporters/connectors/extensions): https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry Collector — Architecture (component sharing, fan-out/fan-in, per-pipeline processor instances): https://opentelemetry.io/docs/collector/architecture/
- Connectors overview: https://opentelemetry.io/docs/collector/building/connector/ and https://github.com/open-telemetry/opentelemetry-collector/tree/main/connector
- `memory_limiter` processor (ordering guidance): https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
- `batch` processor: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md
- `count` connector: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/countconnector
- Collector internal telemetry & `zpages`: https://opentelemetry.io/docs/collector/internal-telemetry/