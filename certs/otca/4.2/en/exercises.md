# OTCA — Domain 4: Maintaining and Debugging Observability Pipelines
## Topic 4.2 — Debugging Pipelines (Guided Exercises)

> **Scope.** These exercises target the OpenTelemetry **Collector** pipeline — the place where OTCA locates "debugging pipelines." You will make a running pipeline observable to *itself*, then use its three native debugging surfaces — the **debug exporter**, the **Collector's own internal telemetry** (`:8888/metrics` + `zpages`), and **configuration validation** — to localize where telemetry is dropped, refused, or silently discarded.
>
> **Reference sources (official):**
> - Collector troubleshooting guide — https://opentelemetry.io/docs/collector/troubleshooting/
> - Collector internal telemetry — https://opentelemetry.io/docs/collector/internal-telemetry/
> - `debug` exporter — https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/debugexporter/README.md
> - `zpages` extension — https://github.com/open-telemetry/opentelemetry-collector/blob/main/extension/zpagesextension/README.md
> - `pprof` extension — https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/extension/pprofextension/README.md
> - `telemetrygen` load tool — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
> - OTCA curriculum — https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf

---

## Exercise 0 — Build a debuggable test rig

You need a Collector you can break on purpose and a traffic generator you fully control.

1. Install a Collector that includes the debugging extensions. The `contrib` distribution ships `zpages`, `pprof`, and `health_check`:

   ```bash
   # Any recent contrib binary works; version pin is up to you.
   otelcol-contrib --version
   telemetrygen --help | head -n 5
   ```

2. Write the baseline config `collector.yaml`. Note the three debugging surfaces wired in from the start — `extensions` (zpages/pprof/health_check), the `debug` exporter, and `service.telemetry`:

   ```yaml
   extensions:
     health_check:
       endpoint: 0.0.0.0:13133
     pprof:
       endpoint: 0.0.0.0:1777
     zpages:
       endpoint: 0.0.0.0:55679

   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     batch: {}
     memory_limiter:
       check_interval: 1s
       limit_mib: 128
       spike_limit_mib: 32

   exporters:
     debug:
       verbosity: basic
     otlp/backend:
       endpoint: 127.0.0.1:4319       # deliberately points at nothing yet
       tls:
         insecure: true

   service:
     extensions: [health_check, pprof, zpages]
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, batch]
         exporters: [debug, otlp/backend]
     telemetry:
       logs:
         level: info
       metrics:
         level: detailed
         address: 0.0.0.0:8888
   ```

3. Start it and confirm it reached the running state:

   ```bash
   otelcol-contrib --config collector.yaml
   # In another shell:
   curl -s http://localhost:13133/ | jq .
   ```

   Expected:

   ```json
   { "status": "Server available", "upSince": "2026-08-11T12:00:00Z", "uptime": "3.1s" }
   ```

4. Send a controlled burst of 10 spans over OTLP/gRPC:

   ```bash
   telemetrygen traces --otlp-insecure --traces 10 --otlp-endpoint localhost:4317
   ```

> **Check your understanding (0):**
> - **0a.** Which distribution decision (`core` vs `contrib`) affects whether `zpages` and `pprof` are even *available* to enable, and why does that matter before you can debug a pipeline in the field?
> - **0b.** In step 2, the `otlp/backend` exporter points at `127.0.0.1:4319` where nothing is listening. Will the Collector refuse to start? Justify using the distinction between *config validation* and *runtime connectivity*.
> - **0c.** Why is `telemetrygen` a better first diagnostic than re-instrumenting your real application when a pipeline "isn't working"?

---

## Exercise 1 — Make the pipeline speak: the `debug` exporter and its verbosity ladder

The `debug` exporter writes a representation of every batch it receives to the Collector's own logs. It is the fastest way to answer "is data even reaching this pipeline?"

1. With `verbosity: basic` (from Exercise 0), re-send traffic and watch the Collector's stdout:

   ```bash
   telemetrygen traces --otlp-insecure --traces 3 --otlp-endpoint localhost:4317
   ```

   Expected log line (one summary per batch):

   ```
   2026-08-11T12:01:07.512Z  info  Traces  {"kind": "exporter", "data_type": "traces", "name": "debug", "resource spans": 1, "spans": 3}
   ```

2. Raise the resolution. Edit the exporter and restart:

   ```yaml
   exporters:
     debug:
       verbosity: detailed
   ```

3. Re-send one span and read the full record:

   ```bash
   telemetrygen traces --otlp-insecure --traces 1 --otlp-endpoint localhost:4317
   ```

   Expected (truncated):

   ```
   ResourceSpans #0
   Resource attributes:
        -> service.name: Str(telemetrygen)
   ScopeSpans #0
   Span #0
       Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
       ID             : 00f067aa0ba902b7
       Name           : okey-dokey-0
       Kind           : Server
       Start time     : 2026-08-11 12:01:40.11 +0000 UTC
       End time       : 2026-08-11 12:01:40.11 +0000 UTC
       Status code    : Unset
       Attributes:
            -> net.peer.ip: Str(1.2.3.4)
            -> peer.service: Str(telemetrygen-server)
   ```

4. Now prove the exporter's placement matters. Temporarily move `debug` so it sits **after** a processor that drops data — insert a filter (contrib) that drops everything, *before* the debug exporter can see it. Change the pipeline to route through a second pipeline where `debug` is first vs last, and compare what each `debug` prints.

   ```yaml
   processors:
     filter/dropall:
       error_mode: ignore
       traces:
         span:
           - 'true'          # matches every span -> drops it
   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [filter/dropall, batch]
         exporters: [debug, otlp/backend]
   ```

   Re-send traffic. Observe that the `debug` exporter now prints **nothing** — the batch is empty by the time it reaches the exporters.

> **Check your understanding (1):**
> - **1a.** A teammate leaves `verbosity: detailed` on a production Collector ingesting 50k spans/s. Name two concrete operational risks and the single-word config change that mitigates them.
> - **1b.** In step 1 the log says `"resource spans": 1, "spans": 3`. What is the difference between a *resource span* count and a *span* count, and what does a ratio of `1:3` tell you about the batch?
> - **1c.** In step 4 the `debug` exporter went silent even though `telemetrygen` reported success. What does this prove about *where* in the pipeline data is being lost, and why is the `debug` exporter alone insufficient to distinguish "dropped by a processor" from "never received"?

---

## Exercise 2 — Localize loss with the Collector's internal metrics

The `debug` exporter tells you what reaches the *end*. The internal metrics at `:8888/metrics` tell you what happened at every *stage* — receiver, processor, exporter — and let you compute the loss precisely.

1. Scrape the internal telemetry endpoint while traffic flows:

   ```bash
   telemetrygen traces --otlp-insecure --traces 1000 --otlp-endpoint localhost:4317
   curl -s http://localhost:8888/metrics | grep -E 'otelcol_(receiver|processor|exporter)_.*spans'
   ```

2. Read the pipeline as a flow. A healthy pipeline balances at each hop:

   ```
   otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 1000
   otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 0
   otelcol_exporter_sent_spans{exporter="debug"} 1000
   otelcol_exporter_sent_spans{exporter="otlp/backend"} 0
   otelcol_exporter_send_failed_spans{exporter="otlp/backend"} 1000
   otelcol_exporter_queue_size{exporter="otlp/backend"} 1000
   otelcol_exporter_queue_capacity{exporter="otlp/backend"} 1000
   ```

3. Interpret before you fix. The receiver *accepted* all 1000 (ingress is fine). `debug` *sent* 1000 (the pipeline is wired correctly). But `otlp/backend` has `send_failed = 1000` and `queue_size == queue_capacity` — the downstream endpoint is dead (that was our deliberate `127.0.0.1:4319`) and the sending queue is saturated.

4. Stand up a real sink so the exporter has somewhere to go, then re-scrape:

   ```bash
   # Minimal second Collector acting as the backend on :4319
   cat > backend.yaml <<'EOF'
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4319
   exporters:
     debug: {verbosity: basic}
   service:
     pipelines:
       traces:
         receivers: [otlp]
         exporters: [debug]
   EOF
   otelcol-contrib --config backend.yaml
   ```

   Re-send 1000 spans and confirm the counters now balance:

   ```
   otelcol_exporter_sent_spans{exporter="otlp/backend"} 1000
   otelcol_exporter_send_failed_spans{exporter="otlp/backend"} 0
   otelcol_exporter_queue_size{exporter="otlp/backend"} 0
   ```

5. Now provoke *receiver-side* refusal to see the other loss class. Drop the memory limiter hard and flood it:

   ```yaml
   processors:
     memory_limiter:
       check_interval: 1s
       limit_mib: 20        # unrealistically low on purpose
       spike_limit_mib: 5
   ```

   ```bash
   telemetrygen traces --otlp-insecure --duration 20s --rate 20000 --otlp-endpoint localhost:4317
   curl -s http://localhost:8888/metrics | grep -E 'refused|otelcol_processor'
   ```

   Expected to see non-zero:

   ```
   otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 43120
   otelcol_processor_refused_spans{processor="memory_limiter"} 43120
   ```

> **Check your understanding (2):**
> - **2a.** Write the general formula for "spans lost in the export stage" using two `otelcol_exporter_*` series, and explain why `send_failed` alone can understate loss when a queue is involved.
> - **2b.** In step 2, `otelcol_exporter_sent_spans{exporter="debug"}` is 1000 but `otelcol_exporter_sent_spans{exporter="otlp/backend"}` is 0. Why does the same pipeline show one exporter succeeding and another failing, and what does that immediately rule out as a cause?
> - **2c.** Contrast `otelcol_receiver_refused_spans` with `otelcol_exporter_send_failed_spans`: which one signals **backpressure working as designed** versus **a downstream outage**, and how would each look different to the *application* sending data?
> - **2d.** Why is `queue_size == queue_capacity` a leading indicator you should alert on *before* `send_failed` climbs, in an exporter configured with retries?

---

## Exercise 3 — Inspect the live pipeline with `zpages`

`zpages` gives you a no-dependencies, in-process view of the running Collector: which pipelines are wired, which components are healthy, and a sampled ring buffer of recent spans *the Collector itself emitted* while processing.

1. Open the pipeline view:

   ```bash
   curl -s http://localhost:55679/debug/pipelinez
   ```

   You will see each pipeline, its data type, and the ordered receivers → processors → exporters — the authoritative answer to "is `otlp/backend` actually attached to the traces pipeline?"

2. Open the service/extensions view to confirm every extension started:

   ```bash
   curl -s http://localhost:55679/debug/servicez
   curl -s http://localhost:55679/debug/extensionz
   ```

3. Open `tracez` to see sampled internal operations bucketed by latency and by error:

   ```
   http://localhost:55679/debug/tracez
   ```

   Columns show running / latency-bucketed / error samples per span name. When exports are failing, the error bucket for the export operation fills up — a visual confirmation of what Exercise 2's `send_failed` counter measured.

4. Correlate: with the backend still **down**, load `tracez`, click the error sample for the export span, and read the recorded status message. Then bring the backend up and watch the error bucket stop growing.

> **Check your understanding (3):**
> - **3a.** `zpages` requires zero external systems (no Prometheus, no backend). Name one debugging scenario where that property makes it strictly more useful than the `:8888/metrics` endpoint.
> - **3b.** `/debug/pipelinez` shows `otlp/backend` correctly attached, yet no data arrives at the backend. Which two *other* surfaces from Exercises 1–2 do you consult next, and in what order?
> - **3c.** Why should `zpages` (like `pprof`) generally be bound to `localhost` or protected in production, rather than `0.0.0.0`?

---

## Exercise 4 — The silent misconfiguration: a component defined but never wired

The most common "pipeline is broken and nothing errors" bug: a component exists under `receivers:`/`processors:`/`exporters:` but is not listed in a `service.pipelines` entry, so it is instantiated for validation but never actually runs.

1. Introduce the bug. Add a redaction processor but "forget" to add it to the pipeline:

   ```yaml
   processors:
     batch: {}
     redaction/pii:
       allow_all_keys: true
       blocked_values:
         - '4[0-9]{12}(?:[0-9]{3})?'   # naive card-number pattern
   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]            # redaction/pii is NOT here
         exporters: [debug, otlp/backend]
   ```

2. Restart and observe: **no error**. The Collector validates `redaction/pii` (it parses), so startup succeeds. PII flows straight through.

3. Confirm the processor is inert using `zpages`:

   ```bash
   curl -s http://localhost:55679/debug/pipelinez | grep -A3 traces
   ```

   The processor list will show only `[batch]` — proof the redactor is not in the data path.

4. Now introduce a *fatal* misconfiguration to contrast the two failure classes — reference an exporter that isn't defined:

   ```yaml
   service:
     pipelines:
       traces:
         exporters: [debug, otlp/backendz]   # typo: no such exporter
   ```

   Restart. Expected — the Collector **refuses to start**:

   ```
   Error: failed to build pipelines: pipeline "traces": references exporter "otlp/backendz" which is not configured
   2026/08/11 12:20:03 collector server run finished with error
   ```

5. Validate config without running the whole Collector — the fast pre-flight check:

   ```bash
   otelcol-contrib validate --config collector.yaml
   ```

> **Check your understanding (4):**
> - **4a.** Steps 2 and 4 are both "misconfigurations," yet one starts cleanly and one aborts. State the precise rule that determines which errors are caught at startup and which pass silently.
> - **4b.** Given that a defined-but-unwired component produces *no* log and *no* metric of its own, which single debugging surface reliably exposes it, and why do `:8888/metrics` and the `debug` exporter both fail to?
> - **4c.** Where does `otelcol validate` sit on the "sources exist vs. sources say what you claim" ladder — i.e., what class of error can it *never* catch?

---

## Exercise 5 — Backpressure, the sending queue, and retry tuning

When the destination is slow rather than dead, data isn't lost instantly — it queues, retries, and eventually spills. Reading these dynamics is core to pipeline debugging.

1. Configure the exporter's queue and retry explicitly so the behavior is observable:

   ```yaml
   exporters:
     otlp/backend:
       endpoint: 127.0.0.1:4319
       tls:
         insecure: true
       sending_queue:
         enabled: true
         num_consumers: 2
         queue_size: 1000
       retry_on_failure:
         enabled: true
         initial_interval: 5s
         max_interval: 30s
         max_elapsed_time: 300s
   ```

2. Kill the backend (`Ctrl-C` on `backend.yaml`), flood the front Collector, and watch the queue fill and then reject:

   ```bash
   telemetrygen traces --otlp-insecure --duration 30s --rate 5000 --otlp-endpoint localhost:4317
   curl -s http://localhost:8888/metrics | grep -E 'queue_size|queue_capacity|enqueue_failed|send_failed'
   ```

   Expected progression (queue saturates, then enqueue starts failing):

   ```
   otelcol_exporter_queue_capacity{exporter="otlp/backend"} 1000
   otelcol_exporter_queue_size{exporter="otlp/backend"} 1000
   otelcol_exporter_enqueue_failed_spans{exporter="otlp/backend"} 88240
   otelcol_exporter_send_failed_spans{exporter="otlp/backend"} 3000
   ```

3. Restore the backend and confirm the queue **drains** (retries succeed, `queue_size` falls toward 0) rather than the spans being lost — the whole point of the queue.

4. Reason about the tuning: doubling `queue_size` buys more buffer for transient outages but costs memory and can hide a chronic downstream problem; `num_consumers` raises export concurrency.

> **Check your understanding (5):**
> - **5a.** Distinguish `otelcol_exporter_enqueue_failed_spans` from `otelcol_exporter_send_failed_spans`. Which one means "the queue is full" and which means "the send attempt itself failed"?
> - **5b.** With `retry_on_failure` enabled, a single logical batch can increment `send_failed` multiple times. What does that imply about using `send_failed` as a raw "spans lost" number?
> - **5c.** A queue that is *permanently* near capacity but never overflows is not healthy either. What chronic condition does that steady-state indicate, and which metric ratio would you graph to catch it?
> - **5d.** Why does simply enlarging `queue_size` risk turning a visible outage into an invisible data-quality problem (stale/late data), and what upstream signal tells you the queue is masking a real capacity deficit?

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Exercise 0
- **0a.** `zpages`, `pprof`, and many receivers/exporters live only in the **contrib** distribution (or a custom build via the OpenTelemetry Collector Builder). If you deploy the slim `core`/base image, those extensions simply don't exist to enable — so the first field question is always "which distribution/components did we actually ship?" You cannot debug with a tool your binary doesn't contain.
- **0b.** It **starts**. Config *validation* only checks that the YAML parses, that referenced components are defined, and that types are valid. Runtime *connectivity* (can I reach `127.0.0.1:4319`?) is only exercised when the exporter tries to send. So a dead endpoint surfaces as `send_failed`/queue growth at runtime, not as a startup error. (Some exporters attempt a connection lazily on first export, not at boot.)
- **0c.** `telemetrygen` produces a **known, exact quantity** of well-formed OTLP data on demand, with no application code, no sampling, and no instrumentation ambiguity. That turns "is it the app, the SDK, or the Collector?" into a controlled experiment: if 1000 generated spans don't arrive, the fault is at or after the receiver — the application is eliminated as a variable.

### Exercise 1
- **1a.** Risks: (1) **log volume explosion / disk & I/O pressure** — every span is serialized to logs; (2) **CPU and latency overhead** plus potential **PII leakage into logs**. Mitigation: set `verbosity: basic` (or remove the debug exporter). "Single-word change" = `basic`.
- **1b.** A **resource span** is one `ResourceSpans` block — all spans sharing the same `Resource` (e.g., same `service.name`/host). The **span** count is individual spans. `1:3` means all three spans came from a single resource (one service instance) in that batch — useful for spotting whether a batch mixes many services or is dominated by one noisy source.
- **1c.** It proves the loss happens **upstream of the exporters, inside the pipeline** (the `filter` processor dropped everything before the exporter stage). The `debug` exporter only observes the *end* of the pipeline, so it can tell you "nothing arrived at the exporters" but **cannot** distinguish "a processor dropped it" from "the receiver never accepted it" — for that you need the per-stage internal metrics (Exercise 2) or `zpages` (Exercise 3).

### Exercise 2
- **2a.** Export-stage loss ≈ `otelcol_exporter_send_failed_spans + otelcol_exporter_enqueue_failed_spans` (data rejected because sending failed *and* data rejected because the queue was full). `send_failed` alone understates loss because items that never made it *into* the queue are counted under `enqueue_failed`, not `send_failed`.
- **2b.** The two exporters have **independent destinations**; the pipeline fans out to both. `debug` writes to local logs (always reachable) while `otlp/backend` targets a dead endpoint. Because ingestion succeeded for one branch, this immediately rules out the **receiver, processors, and pipeline wiring** as the cause — the fault is isolated to the `otlp/backend` exporter's downstream.
- **2c.** `receiver_refused` = the Collector **pushed back on the client** (e.g., `memory_limiter` refused) — backpressure working as designed; the *application* sees gRPC/HTTP errors (e.g., `RESOURCE_EXHAUSTED`) and can retry. `exporter_send_failed` = the Collector accepted data but the **downstream is failing** — the application sees success while data dies inside the Collector. The first is visible to the producer; the second is silent to it.
- **2d.** With retries enabled, a full queue means new data has nowhere to go the moment one more failure occurs; `send_failed`/`enqueue_failed` only climb *after* saturation. `queue_size == queue_capacity` is the earliest deterministic signal that you are one hiccup away from dropping data, so it's the better leading alert.

### Exercise 3
- **3a.** When there is **no metrics backend / no network** to the outside — e.g., an isolated node, a locked-down prod box, or the very outage you're debugging is the telemetry path itself. `zpages` is served in-process over a local port with no dependencies, so it works when Prometheus scraping doesn't.
- **3b.** Next: (1) the **`:8888/metrics`** counters to see whether `otlp/backend` shows `sent` vs `send_failed`/queue growth, then (2) the **`debug` exporter** logs / `tracez` error samples to read the actual failure status. Order: metrics first (quantify + classify), then the log/trace detail (root-cause the specific error).
- **3c.** `zpages` and `pprof` expose **internal state, sampled payloads, and profiling/memory data** that can leak sensitive information or aid an attacker; binding to `0.0.0.0` publishes that to the network. Bind to `localhost` or put it behind auth/network policy.

### Exercise 4
- **4a.** Rule: the Collector fails at startup for errors detectable by **static graph construction** — undefined components, type mismatches, unpar---seable YAML, a pipeline referencing a name that doesn't exist. It **cannot** catch *semantic* mistakes that are individually valid — a real processor that you simply chose not to wire in is a legal (empty-effect) configuration, so no error.
- **4b.** **`zpages` `/debug/pipelinez`**, which prints the *actual* ordered component list per pipeline. `:8888/metrics` fails because an unwired processor never runs, so it emits **no** `otelcol_processor_*` series to be missing-in-an-obvious-way; the `debug` exporter fails because data still flows correctly to the exporters — nothing looks wrong at the end.
- **4c.** `otelcol validate` sits on the lowest rung: **"the config is structurally well-formed and self-consistent."** It can never catch **semantic/behavioral** errors — a valid-but-wrong pipeline (unwired redactor, wrong endpoint that happens to resolve, a processor that transforms data incorrectly). Analogous to "the URL resolves" ≠ "the page says what you claim."

### Exercise 5
- **5a.** `enqueue_failed` = the item **could not enter the sending queue because it was full** (drop at the door). `send_failed` = the item was dequeued and the **actual send attempt to the destination failed**. Full queue → `enqueue_failed`; failed transmission → `send_failed`.
- **5b.** With retries, one batch can fail-and-retry several times, incrementing `send_failed` on each attempt. So `send_failed` is an **attempt counter, not a unique-spans-lost counter** — using it raw overcounts loss. True loss is better approximated by `enqueue_failed` (never got in) plus items whose retries exhausted `max_elapsed_time`.
- **5c.** A permanently near-full queue means **sustained ingress > sustained egress** — the destination's *throughput* is chronically below your data rate (not a transient outage). Graph `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity` over time; a line that sits high without draining is the signature.
- **5d.** A bigger queue absorbs more backlog, so instead of visibly dropping data the Collector **delivers it late** — spans/metrics arrive minutes stale, silently degrading alerting and correlation while every "loss" metric reads zero. The tell that the queue is masking a real deficit is a **queue that fills faster than it drains during normal load** (rising `queue_size` at steady traffic) and elevated `otelcol_receiver_refused_*` upstream once the buffer finally saturates — the deficit reappears as backpressure at the receiver.

</details>