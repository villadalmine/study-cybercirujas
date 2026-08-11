# OTCA 3.1 — Configuration (OpenTelemetry Collector)

> **Domain:** OpenTelemetry Collector · **Subtopic:** Configuration · **Exam weight:** ~5.2%
>
> These guided exercises build a working Collector configuration from the ground up, one component class at a time, and then stress the parts the exam actually probes: pipeline wiring rules, processor ordering, component-instance semantics, environment substitution, and configuration validation. Every command is runnable with nothing but Docker.
>
> **Reference distribution used below:** `otel/opentelemetry-collector-contrib:0.119.0` (Contrib). Pin whatever tag you like — the configuration *schema* used here is stable across recent releases; only log line numbers and the version string in the output change. Sources are cited at the end of each exercise.

---

## Exercise 1 — The four-block anatomy and `validate`

**Goal:** Understand that a Collector configuration is *declaration* (top-level component maps) plus *activation* (the `service` block), and that nothing runs until it is referenced in a pipeline.

1. Create a working directory and a minimal config file `otelcol.yaml`:

   ```bash
   mkdir -p ~/otca-3.1 && cd ~/otca-3.1
   ```

   ```yaml
   # otelcol.yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     batch: {}

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

2. Validate the configuration *without* starting the Collector. The `validate` subcommand loads, merges and type-checks the config, then exits:

   ```bash
   docker run --rm -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml
   echo "exit=$?"
   ```

   Expected: **no output**, and

   ```
   exit=0
   ```

3. Now deliberately break the wiring. Change the `service` pipeline to reference an exporter you never declared:

   ```yaml
   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [otlp/backend]   # <-- not declared in the exporters block
   ```

4. Re-run the validate command from step 2. Expected (exit non-zero):

   ```
   Error: invalid configuration: service::pipelines::traces: references exporter "otlp/backend" which is not configured
   exit=1
   ```

5. Revert step 3 back to `exporters: [debug]` before continuing.

**Check your understanding**

- **1a.** What are the four component classes declared at the top level of every Collector config, and which *fifth* top-level block turns them on?
- **1b.** In step 1, the `otlp` receiver is *declared*. What single additional thing was required to make it actually listen on `:4317`?
- **1c.** The error in step 4 is a *validation* error, not a runtime error. Why is `validate` cheaper and safer to run in CI than starting the Collector to test a config?
- **1d.** If you had instead *declared* an extra exporter but never listed it in any pipeline, would `validate` fail? What happens to that component at runtime?

*Sources: [Collector Configuration](https://opentelemetry.io/docs/collector/configuration/), [Collector components](https://opentelemetry.io/docs/collector/configuration/#basics).*

---

## Exercise 2 — Named components and multi-signal pipelines

**Goal:** Use the `type/name` component-identifier syntax to run two exporters of the same type, and wire independent `traces`, `metrics`, and `logs` pipelines.

1. Replace `otelcol.yaml` with a three-signal configuration that exports to a real backend **and** the debug console. Note the two `otlp`-typed exporters distinguished by name:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     batch: {}

   exporters:
     debug:
       verbosity: normal
     otlp/backend:                       # named instance #1
       endpoint: tempo:4317
       tls:
         insecure: true
     otlp/metrics-backend:               # named instance #2, different endpoint
       endpoint: mimir:4317
       tls:
         insecure: true

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [otlp/backend, debug]
       metrics:
         receivers: [otlp]
         processors: [batch]
         exporters: [otlp/metrics-backend]
       logs:
         receivers: [otlp]
         processors: [batch]
         exporters: [debug]
   ```

2. Validate it (the backends `tempo`/`mimir` do not need to exist for *validation* to pass — DNS is only resolved at export time):

   ```bash
   docker run --rm -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml && echo OK
   ```

   Expected: `OK`

3. Start the Collector for real and watch it bring up each pipeline:

   ```bash
   docker run --rm --name otca-col -p 4317:4317 -p 4318:4318 \
     -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     --config=/etc/otelcol/config.yaml
   ```

   Expected (abridged):

   ```
   info  service@v0.119.0/service.go:...  Starting otelcol-contrib...  {"Version": "0.119.0", "NumCPU": 8}
   info  otlpreceiver@v0.119.0/otlp.go:...  Starting GRPC server  {"endpoint": "0.0.0.0:4317"}
   info  otlpreceiver@v0.119.0/otlp.go:...  Starting HTTP server  {"endpoint": "0.0.0.0:4318"}
   info  service@v0.119.0/service.go:...  Everything is ready. Begin running and processing data.
   ```

   Leave it running; open a second terminal for the next step.

4. In the second terminal, send three real spans with `telemetrygen` and confirm the debug exporter prints them:

   ```bash
   docker run --rm --network host \
     ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
     traces --otlp-insecure --traces 3
   ```

   In the first terminal you should see the receiver accept the batch and the `debug` exporter emit a summary such as:

   ```
   info  Traces  {"kind": "exporter", "data_type": "traces", "name": "debug", "resource spans": 3, "spans": 6}
   ```

5. Stop the Collector with `Ctrl-C` (it drains, then logs `Shutdown complete.`).

**Check your understanding**

- **2a.** `otlp/backend` and `otlp/metrics-backend` share the *type* `otlp`. What makes them two distinct exporter instances, and why is a bare second `otlp:` key impossible in the same block?
- **2b.** The `traces` pipeline fans out to *two* exporters. In what order does telemetry reach `otlp/backend` versus `debug` — sequential, or is each exporter fed independently?
- **2c.** The same receiver id `otlp` appears in all three pipelines. Is one OTLP listener created or three? (This is the receiver-sharing rule — see Exercise 5.)
- **2d.** Why did validation in step 2 succeed even though `tempo:4317` is unresolvable in your environment?

*Sources: [Configuring components (type/name)](https://opentelemetry.io/docs/collector/configuration/#basics), [OTLP Exporter](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/otlpexporter/README.md).*

---

## Exercise 3 — Processor ordering: `memory_limiter` and `batch`

**Goal:** Learn that `processors: [...]` is an *ordered chain* and that placement is semantically meaningful, not cosmetic.

1. Add a `memory_limiter` and give `batch` explicit tuning. Order matters — put `memory_limiter` **first**:

   ```yaml
   processors:
     memory_limiter:
       check_interval: 1s
       limit_mib: 512
       spike_limit_mib: 128
     batch:
       timeout: 5s
       send_batch_size: 1024
       send_batch_max_size: 2048

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, batch]   # limiter guards the door; batch groups on exit
         exporters: [otlp/backend, debug]
   ```

2. Validate and start (reuse the run command from Exercise 2, step 3). Confirm it boots cleanly.

3. Now invert the order to `processors: [batch, memory_limiter]` and re-validate.

   ```bash
   docker run --rm -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml && echo OK
   ```

   Observe that validation still prints `OK` — the ordering mistake is **not** a schema error. It is a *design* error the validator cannot catch.

4. Restore `[memory_limiter, batch]`.

**Check your understanding**

- **3a.** Data flows through the processor list top-to-bottom. Concretely, what goes wrong if `batch` runs *before* `memory_limiter` under a memory-pressure spike?
- **3b.** `send_batch_size` vs `send_batch_max_size`: one is a soft target, one is a hard cap. Which is which, and what does `batch` do to a batch that exceeds the max?
- **3c.** Step 3 shows a semantically wrong config passing `validate`. Which rung of the verification ladder catches ordering bugs, and why can't static validation?
- **3d.** `memory_limiter` also accepts `limit_percentage`/`spike_limit_percentage` instead of `_mib`. In a container with a cgroup memory limit, why might the percentage form be more robust than a hard-coded `limit_mib`?

*Sources: [Memory Limiter processor](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md), [Batch processor](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md).*

---

## Exercise 4 — Environment substitution, defaults, and config merging

**Goal:** Externalize environment-specific values with `${env:...}`, supply defaults, and layer configuration from multiple providers.

1. Parameterize the backend endpoint and verbosity. Use the `${env:VAR}` provider syntax with a `:-` default:

   ```yaml
   exporters:
     debug:
       verbosity: ${env:DEBUG_VERBOSITY:-normal}
     otlp/backend:
       endpoint: ${env:BACKEND_ENDPOINT:-tempo:4317}
       tls:
         insecure: true
   ```

2. Run with the variable **unset** and confirm the default is used (add `--dry-run`-style validation via the `validate` command, or start it). Start it and check the resolved endpoint via the debug logs — first with no env:

   ```bash
   docker run --rm -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml && echo "defaulted OK"
   ```

3. Now override at runtime by injecting the environment variable:

   ```bash
   docker run --rm \
     -e BACKEND_ENDPOINT=otlp-gateway.observability.svc:4317 \
     -e DEBUG_VERBOSITY=detailed \
     -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml && echo "override OK"
   ```

4. Demonstrate **multi-source merging**. Create an overlay file `overlay.yaml` that only tweaks verbosity, and pass *two* `--config` flags plus an inline `yaml:` provider. Later sources win on scalar keys:

   ```yaml
   # overlay.yaml
   exporters:
     debug:
       verbosity: basic
   ```

   ```bash
   docker run --rm \
     -v "$PWD/otelcol.yaml:/etc/otelcol/base.yaml" \
     -v "$PWD/overlay.yaml:/etc/otelcol/overlay.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate \
       --config=/etc/otelcol/base.yaml \
       --config=/etc/otelcol/overlay.yaml \
       --config="yaml:exporters::debug::verbosity: detailed"
   ```

   The last `yaml:` provider wins, so the effective `debug.verbosity` is `detailed`.

**Check your understanding**

- **4a.** What does `${env:BACKEND_ENDPOINT:-tempo:4317}` evaluate to when `BACKEND_ENDPOINT` is (i) unset, (ii) set to the empty string, (iii) set to a value?
- **4b.** When the same scalar key is set in `base.yaml`, `overlay.yaml`, and an inline `yaml:` provider, which value is effective? State the precedence rule for `--config` sources.
- **4c.** Name two configuration *providers* other than `env:` that the Collector can read a `--config` value from.
- **4d.** Why is `${env:...}` substitution safer than baking secrets/endpoints into the committed YAML — and what is the risk of using it for a *secret* passed as a plain container env var?

*Sources: [Environment variables & providers](https://opentelemetry.io/docs/collector/configuration/#environment-variables), [Configuration structure](https://opentelemetry.io/docs/collector/configuration/).*

---

## Exercise 5 — Extensions, `service::telemetry`, and component-instance semantics

**Goal:** Enable non-pipeline components (extensions), expose the Collector's own health and internal telemetry, and reason about how many *instances* of a component the Collector actually creates.

1. Add extensions and self-telemetry to the `service` block. Extensions are declared like any component but activated under `service.extensions`, **not** in a pipeline:

   ```yaml
   extensions:
     health_check:
       endpoint: 0.0.0.0:13133
     pprof:
       endpoint: 0.0.0.0:1777
     zpages:
       endpoint: 0.0.0.0:55679

   service:
     extensions: [health_check, pprof, zpages]
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
         processors: [memory_limiter, batch]
         exporters: [otlp/backend, debug]
       metrics:
         receivers: [otlp]
         processors: [memory_limiter, batch]
         exporters: [otlp/backend]
   ```

2. Start the Collector, exposing the new ports:

   ```bash
   docker run --rm --name otca-col \
     -p 4317:4317 -p 4318:4318 -p 13133:13133 -p 55679:55679 -p 8888:8888 \
     -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     --config=/etc/otelcol/config.yaml
   ```

3. From a second terminal, probe the health-check extension:

   ```bash
   curl -s localhost:13133/ ; echo
   ```

   Expected (JSON, abridged):

   ```json
   {"status":"Server available","upSince":"2026-08-10T14:22:03.457Z","uptime":"12.ol s"}
   ```

4. Scrape the Collector's **own** internal metrics (exposed by `service::telemetry::metrics`) and look for the receiver/exporter counters:

   ```bash
   curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver_accepted|exporter_sent)_spans' | head
   ```

   Expected (values depend on traffic):

   ```
   otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc"} 6
   otelcol_exporter_sent_spans_total{exporter="otlp/backend"} 6
   ```

5. Open `http://localhost:55679/debug/pipelinez` (zpages) in a browser to see the live pipeline topology, then `Ctrl-C` the Collector.

**Check your understanding**

- **5a.** Extensions do not appear in any `receivers`/`processors`/`exporters` pipeline. How are they activated, and what kind of capability do they provide that pipeline components do not?
- **5b.** In the step-1 config, `otlp` (receiver) appears in both `traces` and `metrics`; `memory_limiter` and `batch` appear in both; `otlp/backend` appears in both. Which of these end up as a **single shared instance** and which are **instantiated per pipeline**? State the rule.
- **5c.** `service::telemetry::metrics` exposes `otelcol_*` metrics on `:8888`. Distinguish these from the telemetry the Collector *processes* — why is scraping `:8888` the first move when debugging a pipeline that "drops" data?
- **5d.** If you deleted the `zpages` line from `service.extensions` but left it declared under `extensions:`, would `:55679` still serve? Why?

*Sources: [Health Check extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/extension/healthcheckextension/README.md), [Internal telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/), [zPages extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/extension/zpagesextension/README.md).*

---

## Exercise 6 — Connectors: joining two pipelines (`spanmetrics`)

**Goal:** Use a *connector* — a component that is simultaneously an exporter of one pipeline and a receiver of another — to derive RED metrics from spans without an external processor.

1. Add the `spanmetrics` connector. It consumes the `traces` pipeline and emits into a `metrics` pipeline:

   ```yaml
   connectors:
     spanmetrics:
       histogram:
         explicit:
           buckets: [100us, 1ms, 10ms, 100ms, 1s]
       dimensions:
         - name: http.method
         - name: http.status_code

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, batch]
         exporters: [otlp/backend, spanmetrics]   # connector as an EXPORTER here
       metrics/spanmetrics:
         receivers: [spanmetrics]                  # same connector as a RECEIVER here
         processors: [batch]
         exporters: [otlp/backend]
   ```

2. Validate — note the connector must appear as an exporter in **exactly one** pipeline and a receiver in **exactly one** other, of the appropriate signal types:

   ```bash
   docker run --rm -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml && echo OK
   ```

3. Break it: remove `spanmetrics` from the `metrics/spanmetrics` receivers list (so it is used only as an exporter). Re-validate and read the error:

   ```
   Error: invalid configuration: connectors::spanmetrics: must be used as both receiver and exporter but is not used as receiver
   ```

4. Restore the connector on both ends.

**Check your understanding**

- **6a.** What structurally distinguishes a *connector* from a *processor*? Why can't `spanmetrics` be a processor?
- **6b.** In step 1, the connector converts *traces → metrics*. Which pipeline's signal type is on the exporter side, and which on the receiver side?
- **6c.** The error in step 3 states the connector "must be used as both receiver and exporter." Why is a connector that is wired on only one side always a configuration error?
- **6d.** Name one operational advantage of generating span metrics inside the Collector via `spanmetrics` rather than in each instrumented application.

*Sources: [Connectors](https://opentelemetry.io/docs/collector/configuration/#connectors), [Spanmetrics connector](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/spanmetricsconnector/README.md).*

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
- **1a.** The four component classes are `receivers`, `processors`, `exporters`, and `extensions` (a fifth optional class, `connectors`, appears in Exercise 6). The block that activates them is `service` — specifically `service.pipelines` (and `service.extensions`). Declaration ≠ activation: a component listed only at the top level is inert.
- **1b.** It had to be *referenced in a pipeline*. The `otlp` receiver only starts its gRPC/HTTP listeners because `service.pipelines.traces.receivers` includes `otlp`. Declaration alone starts nothing.
- **1c.** `validate` loads every config source, merges them, and unmarshals each component's settings against its schema, then exits — it never opens listener ports, dials backends, or allocates pipeline buffers. So it is fast, side-effect-free, and safe to run in CI on every commit, whereas starting the Collector binds ports and can disturb a running system.
- **1d.** No — `validate` would *pass*. A component that is declared but not referenced in any pipeline is simply **never instantiated** at runtime; it is dead configuration. The error only fires the other way: a pipeline referencing a component that was never declared.

### Exercise 2
- **2a.** The `type/name` identifier syntax: `otlp/backend` and `otlp/metrics-backend` are both of type `otlp` but carry distinct names, making them two separate map keys and two independent instances with their own settings. A second bare `otlp:` key is impossible because YAML maps cannot have duplicate keys within the `exporters` block.
- **2b.** Each exporter is fed **independently** (fan-out). The pipeline hands the same batch to every listed exporter; they are not chained in sequence and one exporter's slowness or failure does not, by itself, reorder or block the delivery to the others (each has its own queue/retry).
- **2c.** **One** OTLP listener. A receiver id reused across multiple pipelines is a single shared instance that fans out to all connected pipelines — you do not get three sockets bound to `:4317`. (Full rule in 5b.)
- **2d.** `validate` only checks that the config *parses and type-checks*. It does not resolve DNS or dial exporters; connection to `tempo:4317` is attempted lazily at export time, so an unresolvable endpoint is a runtime concern, not a validation failure.

### Exercise 3
- **3a.** If `batch` runs first, spans accumulate in the batcher's buffers *before* `memory_limiter` gets to see and refuse them. Under a spike the batched data inflates heap the limiter is supposed to protect, defeating its purpose — the limiter can only shed load for data that reaches it, so it must sit at the front of the chain, closest to the receivers.
- **3b.** `send_batch_size` is the **soft target**: the batch processor flushes when the buffer reaches this many items (or when `timeout` elapses). `send_batch_max_size` is the **hard cap**: no single outgoing batch may exceed it; if an incoming batch would push past the cap, the processor splits it so every emitted batch is ≤ max. `0` (default) means no upper bound.
- **3c.** Nothing on the free static ladder catches it — `validate`, schema checks and provenance all pass because the YAML is well-formed and every referenced component exists. Ordering is a *semantic/behavioral* property; only running the Collector under load (or the "is the behavior correct" rung) reveals that the limiter never sheds. Static validation checks *shape*, not *meaning*.
- **3d.** `limit_percentage`/`spike_limit_percentage` compute the threshold from the memory the process actually observes (honoring the cgroup limit), so the same config self-adjusts across a 256 MiB dev pod and a 4 GiB prod pod. A hard-coded `limit_mib: 512` set higher than the container's cgroup limit is worse than useless — the kernel OOM-kills the process before the limiter ever trips.

### Exercise 4
- **4a.** (i) unset → the default `tempo:4317` is used (the `:-` default applies when the variable is unset **or empty**); (ii) empty string → same as unset, the default `tempo:4317` is used; (iii) set to a value → that value is used verbatim.
- **4b.** The **last** source wins for a conflicting scalar. `--config` sources are merged left-to-right, so the inline `yaml:...verbosity: detailed` (given last) overrides `overlay.yaml` (`basic`), which overrides `base.yaml` (`${env:...}`). Later `--config` flags override earlier ones on the same scalar key; maps are deep-merged.
- **4c.** Any two of: `file:` (a path), `yaml:` (inline YAML fragment), `http:`/`https:` (fetch a remote config), plus `env:` itself. (These are the config *providers*.)
- **4d.** It keeps environment-specific and rotating values out of version control, so one committed YAML serves dev/staging/prod. The risk with secrets is that a plain container env var is visible to anything that can read the process environment (`/proc/<pid>/environ`, `docker inspect`, `kubectl describe pod`), so secrets should come from a mounted file/secret store rather than a plain `-e` variable.

### Exercise 5
- **5a.** Extensions are activated by listing them under `service.extensions`, not inside a pipeline. They provide Collector-wide capabilities that are *not* part of telemetry data flow — health checking, profiling (`pprof`), live diagnostics (`zpages`), authentication, storage — rather than receiving/processing/exporting signals.
- **5b.** Rule: **receivers and exporters are shared as a single instance** when the same component id is reused across pipelines (fan-out from one receiver, fan-in to one exporter); **processors are instantiated once per pipeline**. So here: `otlp` → one shared receiver; `otlp/backend` → one shared exporter; `memory_limiter` and `batch` → two instances each (one per pipeline). This is why per-pipeline `batch`/`memory_limiter` tuning is independent.
- **5c.** `:8888` serves the Collector's **own** operational metrics (`otelcol_receiver_accepted_*`, `otelcol_processor_dropped_*`, `otelcol_exporter_sent_*`, `otelcol_exporter_send_failed_*`), which describe the *pipeline machinery*, not the customer telemetry passing through. When data appears to "drop," comparing accepted-vs-sent-vs-failed counters localizes the loss to a receiver, a processor (e.g. `refused`/`dropped`), or a failing exporter — far faster than guessing.
- **5d.** No. Declaring `zpages` under `extensions:` without listing it in `service.extensions` leaves it inert — like any component, an extension only starts when the `service` block activates it. `:55679` would not be served.

### Exercise 6
- **6a.** A connector is wired *between two pipelines*: it is an exporter in one and a receiver in another, so it can bridge signal types (e.g. traces→metrics) and cross pipeline boundaries. A processor lives *within a single pipeline* and cannot emit into a different pipeline or change the pipeline's signal type, so `spanmetrics` — which reads spans and produces a new metrics stream feeding a separate metrics pipeline — cannot be expressed as a processor.
- **6b.** The **traces** pipeline is the exporter side (it exports spans *into* the connector); the **metrics** pipeline (`metrics/spanmetrics`) is the receiver side (it receives the generated metrics *from* the connector).
- **6c.** A connector's entire purpose is to bridge two pipelines; wired on only one side it has either no source or no sink, which is meaningless. The Collector therefore enforces that a connector appears as both an exporter (in one pipeline) and a receiver (in another) of the correct signal types, and fails validation otherwise — as seen in step 3.
- **6d.** Any one of: it is instrumentation-agnostic (works for every service already emitting spans, no per-app code change); it produces consistent RED metrics with uniform dimensions/bucketing across all services; and it offloads aggregation from the application to the Collector, reducing per-service overhead and cardinality drift.

</details>