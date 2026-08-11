# OTCA · Topic 2.3 — Configuration (Guided Exercises)

> Domain 2 · *The OpenTelemetry API and SDK* — Configuration (exam weight ≈ 6.57%)
>
> These labs drill the one competency the exam tests hardest here: **how the same SDK is configured three different ways — environment variables, programmatic (in-code), and declarative file config — and how those layers override one another.** You will run a real instrumented service and watch each knob change the emitted telemetry.
>
> **Prerequisites**
> - Python 3.9+ and `pip`
> - Docker (to run a throwaway Collector as a sink)
> - A shell where you can `export` variables
>
> **One-time setup** — a minimal app plus a Collector that just prints what it receives, so you can *see* the effect of every configuration change.

```bash
mkdir otca-23-config && cd otca-23-config
python3 -m venv .venv && source .venv/bin/activate

pip install \
  opentelemetry-distro \
  opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
```

```python
# app.py
from flask import Flask
from opentelemetry import trace

app = Flask(__name__)
tracer = trace.get_tracer("dice.tracer")

@app.route("/rolldice")
def roll():
    with tracer.start_as_current_span("do_roll") as span:
        span.set_attribute("dice.result", 4)
        return "4"

if __name__ == "__main__":
    app.run(port=8080)
```

```yaml
# collector-config.yaml  — a sink that logs everything it receives
receivers:
  otlp:
    protocols:
      grpc:  { endpoint: 0.0.0.0:4317 }
      http:  { endpoint: 0.0.0.0:4318 }
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers:  [otlp]
      exporters:  [debug]
```

```bash
docker run --rm --name otelcol -p 4317:4317 -p 4318:4318 \
  -v "$(pwd)/collector-config.yaml:/etc/otelcol-contrib/config.yaml" \
  otel/opentelemetry-collector-contrib:0.104.0
```

Leave the Collector running in one terminal. Do the exercises in a second terminal (with the venv activated).

*Source: [SDK configuration](https://opentelemetry.io/docs/languages/sdk-configuration/), [Zero-code Python](https://opentelemetry.io/docs/zero-code/python/).*

---

## Exercise 1 — Zero-code configuration via environment variables

The exam's core claim: **you can fully configure resource, exporter, and protocol without touching code.** The `opentelemetry-instrument` wrapper reads the standard `OTEL_*` variables and builds the providers for you.

1. Configure the SDK entirely through the environment and launch the auto-instrumented app:

   ```bash
   export OTEL_SERVICE_NAME="dice-server"
   export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=staging,service.version=1.4.2,team=payments"
   export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
   export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
   export OTEL_TRACES_EXPORTER="otlp"

   opentelemetry-instrument python app.py
   ```

2. In a third terminal, generate a trace:

   ```bash
   curl -s http://localhost:8080/rolldice
   ```

3. Watch the **Collector** terminal. You should see a `Resource` block and two spans (`GET /rolldice` from the auto-instrumentation, `do_roll` from your code):

   ```text
   Resource attributes:
        -> service.name: Str(dice-server)
        -> service.version: Str(1.4.2)
        -> deployment.environment: Str(staging)
        -> team: Str(payments)
        -> telemetry.sdk.language: Str(python)
        -> telemetry.sdk.name: Str(opentelemetry)
   ScopeSpans #0
   Span #0
       Name           : GET /rolldice
       Kind           : Server
   Span #1
       Name           : do_roll
       Kind           : Internal
   ```

**Check your understanding**

- **Q1.1** — `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES` both feed the Resource. If you set `OTEL_SERVICE_NAME=dice-server` *and* `OTEL_RESOURCE_ATTRIBUTES=service.name=other`, which value wins for `service.name`, and why?
- **Q1.2** — You set `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318` and `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`. What full URL will the SDK actually POST spans to, and where does the extra path come from?
- **Q1.3** — Nothing in `app.py` mentions a Resource, an exporter, or a processor. What component created all of them, and at what point in the process lifecycle?

---

## Exercise 2 — Protocol and endpoint precedence (the classic gRPC-vs-HTTP trap)

The most-missed configuration detail on the exam is **how the general endpoint differs from the per-signal endpoint** under each protocol.

1. Switch to gRPC. Note the port change and that gRPC needs **no path**:

   ```bash
   export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
   export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

   Spans still arrive at the Collector — this time over its gRPC receiver on `4317`.

2. Now set a **signal-specific** endpoint over HTTP. Deliberately make the mistake first — point it at the base host with *no* path:

   ```bash
   kill %1 2>/dev/null
   export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
   unset OTEL_EXPORTER_OTLP_ENDPOINT
   export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="http://localhost:4318"   # missing /v1/traces
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

   The Collector logs a `404` for the malformed path (it expects `/v1/traces`). Fix it by supplying the **full** path, because the SDK does *not* append a suffix to a signal-specific endpoint:

   ```bash
   kill %1 2>/dev/null
   export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="http://localhost:4318/v1/traces"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

**Check your understanding**

- **Q2.1** — With `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, why does the SDK append `/v1/traces` to the value of the **general** `OTEL_EXPORTER_OTLP_ENDPOINT` but *not* to the **per-signal** `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`?
- **Q2.2** — For gRPC, what are the default port and default path? Why is there no per-signal path at all?
- **Q2.3** — If both `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` are set, which one governs trace export?

---

## Exercise 3 — Sampling configuration (head sampling)

Sampling is a configuration concern that changes *how much* you emit. You configure it with exactly two variables.

1. Set a 0% ratio to prove the sampler is wired in — no spans should reach the Collector:

   ```bash
   kill %1 2>/dev/null
   export OTEL_TRACES_SAMPLER="parentbased_traceidratio"
   export OTEL_TRACES_SAMPLER_ARG="0.0"
   opentelemetry-instrument python app.py &
   for i in $(seq 1 10); do curl -s http://localhost:8080/rolldice > /dev/null; done
   ```

   The Collector terminal stays silent: 0 of 10 requests are recorded.

2. Raise to 50% and re-run 10 requests. Roughly half the traces now appear (the count is probabilistic, keyed off the `trace_id`):

   ```bash
   kill %1 2>/dev/null
   export OTEL_TRACES_SAMPLER_ARG="0.5"
   opentelemetry-instrument python app.py &
   for i in $(seq 1 10); do curl -s http://localhost:8080/rolldice > /dev/null; done
   ```

3. Confirm the default. Unset both variables, restart, and note that **every** trace is exported:

   ```bash
   kill %1 2>/dev/null
   unset OTEL_TRACES_SAMPLER OTEL_TRACES_SAMPLER_ARG
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

**Check your understanding**

- **Q3.1** — What is the default sampler when `OTEL_TRACES_SAMPLER` is unset, and what does its name imply about how it treats an incoming span that already carries a sampling decision?
- **Q3.2** — With `parentbased_traceidratio` and arg `0.5`, a request arrives carrying a W3C `traceparent` whose sampled flag is `01`. Is the local span sampled? What if the flag were `00`?
- **Q3.3** — Why is `traceidratio` deterministic — i.e. why does replaying the *same* trace ID always yield the same sampled/dropped outcome across every service in the request path?

---

## Exercise 4 — Batch Span Processor tuning

The processor sits between the SDK and the exporter and decides *when* to flush. Its defaults are tuned for throughput, not latency; the exam expects you to know the four knobs.

1. Force near-immediate export by shrinking the batch and schedule delay, then watch spans arrive almost instantly:

   ```bash
   kill %1 2>/dev/null
   export OTEL_BSP_SCHEDULE_DELAY="200"          # ms between flushes (default 5000)
   export OTEL_BSP_MAX_EXPORT_BATCH_SIZE="1"     # export as soon as 1 span is queued (default 512)
   export OTEL_BSP_MAX_QUEUE_SIZE="2048"         # drop threshold (default 2048)
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

2. Reset to defaults and observe the ~5 s pause before a single-request trace shows up (the schedule delay dominates when the batch never fills):

   ```bash
   kill %1 2>/dev/null
   unset OTEL_BSP_SCHEDULE_DELAY OTEL_BSP_MAX_EXPORT_BATCH_SIZE OTEL_BSP_MAX_QUEUE_SIZE
   opentelemetry-instrument python app.py &
   time curl -s http://localhost:8080/rolldice   # response is instant; the *export* waits for the schedule delay
   ```

**Check your understanding**

- **Q4.1** — Name the two conditions that trigger the Batch Span Processor to flush, and give the default value of each.
- **Q4.2** — `OTEL_BSP_MAX_QUEUE_SIZE` is 2048 by default. What happens to a span that is created while the queue is already full, and how does that differ from the `SimpleSpanProcessor`?
- **Q4.3** — Your service exports fine under light load but silently loses spans during traffic spikes. Which two BSP variables would you change first, and in which direction?

---

## Exercise 5 — Propagator configuration

Propagators are configured separately from exporters; they decide the *wire format* of context passed between services.

1. Restrict the app to B3 multi-header propagation and confirm it *reads* B3 headers you inject. Start the app, then send a request carrying a pre-made B3 context:

   ```bash
   kill %1 2>/dev/null
   export OTEL_PROPAGATORS="b3multi"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice \
     -H "X-B3-TraceId: 80f198ee56343ba864fe8b2a57d3eff7" \
     -H "X-B3-SpanId: e457b5a2e4d86bd1" \
     -H "X-B3-Sampled: 1"
   ```

   In the Collector output, the server span's `Trace ID` is `80f198ee56343ba864fe8b2a57d3eff7` — the incoming context was honored.

2. Send the *same* request but with a W3C `traceparent` instead. Because you disabled `tracecontext`, it is **ignored** and a new trace begins:

   ```bash
   curl -s http://localhost:8080/rolldice \
     -H "traceparent: 00-11111111111111111111111111111111-2222222222222222-01"
   ```

3. Restore the interoperable default and verify `traceparent` is honored again:

   ```bash
   kill %1 2>/dev/null
   export OTEL_PROPAGATORS="tracecontext,baggage"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice \
     -H "traceparent: 00-11111111111111111111111111111111-2222222222222222-01"
   ```

**Check your understanding**

- **Q5.1** — What is the default value of `OTEL_PROPAGATORS`, and what does each of its two entries carry?
- **Q5.2** — In step 2, why did the incoming `traceparent` produce a *new*, disconnected trace instead of an error?
- **Q5.3** — Two services on the same request path are configured with `OTEL_PROPAGATORS=b3multi` and `OTEL_PROPAGATORS=tracecontext` respectively. What is the observable symptom in your traces, and is it a code bug?

---

## Exercise 6 — Programmatic configuration and precedence

Environment variables are convenient, but the SDK is ultimately built in code. Here you configure the *same* pipeline in Python and observe how env vars still influence it.

1. Bypass the auto-instrumentation wrapper and build the provider yourself:

   ```python
   # manual_setup.py
   from opentelemetry import trace
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor
   from opentelemetry.sdk.trace.sampling import ParentBasedTraceIdRatio
   from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

   provider = TracerProvider(
       resource=Resource.create({"service.name": "dice-server-manual"}),
       sampler=ParentBasedTraceIdRatio(0.25),
   )
   provider.add_span_processor(
       BatchSpanProcessor(OTLPSpanExporter(endpoint="http://localhost:4318/v1/traces"))
   )
   trace.set_tracer_provider(provider)

   tracer = trace.get_tracer("manual.tracer")
   with tracer.start_as_current_span("manual_roll") as span:
       span.set_attribute("dice.result", 6)
   provider.shutdown()   # flush before exit
   ```

   ```bash
   kill %1 2>/dev/null
   python manual_setup.py
   ```

   The Collector shows `service.name: dice-server-manual` and one `manual_roll` span.

2. Now test precedence. `Resource.create()` still *merges* environment-supplied attributes. Set an env attribute and re-run — it appears **alongside** the code-set `service.name`:

   ```bash
   export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=prod"
   python manual_setup.py
   ```

   Output now carries both `service.name=dice-server-manual` **and** `deployment.environment=prod`.

**Check your understanding**

- **Q6.1** — In step 2, the code hard-codes `service.name` but `deployment.environment` came from the environment. Which precedence rule does `Resource.create()` apply when the code Resource and the `OTEL_RESOURCE_ATTRIBUTES` Resource are merged?
- **Q6.2** — Why is the explicit `provider.shutdown()` (or a `force_flush`) important in a short-lived script, given what you learned about the Batch Span Processor in Exercise 4?
- **Q6.3** — You call `trace.set_tracer_provider(provider)` twice with two different providers. What does the SDK do on the second call, and why does it matter for libraries that grabbed a tracer early?

---

## Exercise 7 — Declarative (file-based) configuration

The newest, exam-relevant configuration surface is a **single YAML file** describing the whole SDK, referenced by `OTEL_EXPERIMENTAL_CONFIG_FILE`. It supersedes the individual env vars and supports `${ENV}` substitution.

1. Write a declarative config that reproduces the pipeline from earlier exercises — resource, batch OTLP exporter, and a 25% parent-based sampler:

   ```yaml
   # sdk-config.yaml
   file_format: "0.3"
   disabled: false
   resource:
     attributes:
       - name: service.name
         value: dice-server-declarative
       - name: deployment.environment
         value: ${DEPLOY_ENV}          # substituted from the environment at load time
   propagator:
     composite: [tracecontext, baggage]
   tracer_provider:
     sampler:
       parent_based:
         root:
           trace_id_ratio_based:
             ratio: 0.25
     processors:
       - batch:
           exporter:
             otlp:
               protocol: http/protobuf
               endpoint: http://localhost:4318
   ```

2. Point the SDK at the file and run. Note that the `OTEL_SERVICE_NAME` you exported earlier is now **ignored** — the file is authoritative:

   ```bash
   kill %1 2>/dev/null
   export DEPLOY_ENV="prod"
   export OTEL_SERVICE_NAME="this-value-is-ignored"
   export OTEL_EXPERIMENTAL_CONFIG_FILE="$(pwd)/sdk-config.yaml"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

   The Collector shows `service.name: dice-server-declarative` and `deployment.environment: prod` — the file won; only the `${DEPLOY_ENV}` reference reached into the environment.

3. Flip the global kill-switch without deleting the file, and confirm the SDK emits nothing:

   ```bash
   kill %1 2>/dev/null
   sed -i 's/disabled: false/disabled: true/' sdk-config.yaml
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice        # no spans reach the Collector
   ```

**Check your understanding**

- **Q7.1** — With `OTEL_EXPERIMENTAL_CONFIG_FILE` set, what happens to standalone variables like `OTEL_SERVICE_NAME`, `OTEL_TRACES_SAMPLER`, or `OTEL_EXPORTER_OTLP_ENDPOINT`? Which env-var mechanism *does* still function?
- **Q7.2** — Contrast `disabled: true` in the file with the `OTEL_SDK_DISABLED=true` variable. What do they have in common and how do they differ in scope?
- **Q7.3** — Why does the top-level `file_format` field exist, and what should a tool do if it does not recognize the version?

---

## Exercise 8 — Diagnosing a misconfiguration

Configuration bugs are usually silent — no telemetry, no error. This is the diagnostic drill the exam's "Maintaining and Debugging" mindset rewards.

1. Introduce a realistic fault: an exporter pointed at a dead port.

   ```bash
   kill %1 2>/dev/null
   unset OTEL_EXPERIMENTAL_CONFIG_FILE
   export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4999"   # nothing listening here
   export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

   The app responds `4` normally — the telemetry failure is invisible from the outside.

2. Turn on the SDK's own diagnostics and re-run. Python surfaces exporter errors on the internal logger:

   ```bash
   kill %1 2>/dev/null
   export OTEL_LOG_LEVEL="debug"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   # In the app terminal you now see, e.g.:
   #   Transient error ConnectionError ... Failed to export ... to http://localhost:4999/v1/traces
   ```

3. Prove your pipeline in isolation by swapping the network exporter for the **console** exporter — this removes the network from the equation entirely:

   ```bash
   kill %1 2>/dev/null
   export OTEL_TRACES_EXPORTER="console"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   # Spans are now printed as JSON to stdout — the SDK, resource, and sampler are all fine;
   # the only thing broken was the endpoint.
   ```

4. Fix the endpoint and restore OTLP:

   ```bash
   kill %1 2>/dev/null
   export OTEL_TRACES_EXPORTER="otlp"
   export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

**Check your understanding**

- **Q8.1** — Why does a broken exporter endpoint *not* break the instrumented application's own responses? What does that tell you about where telemetry export runs?
- **Q8.2** — Give an ordered troubleshooting recipe (which variable / which exporter) to distinguish "the SDK isn't producing spans" from "the SDK produces spans but can't ship them."
- **Q8.3** — A colleague reports *zero* telemetry and no error logs at all, even with `OTEL_LOG_LEVEL=debug`. Which single environment variable would you check first, and why would it explain total silence?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**

- **A1.1** — `OTEL_SERVICE_NAME` wins. The spec gives `OTEL_SERVICE_NAME` **higher priority** than a `service.name` supplied inside `OTEL_RESOURCE_ATTRIBUTES`; the dedicated variable is treated as authoritative for that one key.
- **A1.2** — `http://localhost:4318/v1/traces`. Under `http/protobuf`, the SDK treats `OTEL_EXPORTER_OTLP_ENDPOINT` as a *base* URL and appends the per-signal path (`/v1/traces` for spans, `/v1/metrics`, `/v1/logs`).
- **A1.3** — The `opentelemetry-instrument` auto-instrumentation agent. On startup (before your app's `main`/imports fully run) it reads the `OTEL_*` variables, constructs the `TracerProvider`, `Resource`, `BatchSpanProcessor`, and OTLP exporter, and registers them as global — all without code changes.

**Exercise 2**

- **A2.1** — The general endpoint is defined as a *base* to which the SDK appends the signal path; the per-signal endpoint is defined as the *complete* URL and is used verbatim. So `OTEL_EXPORTER_OTLP_ENDPOINT=http://host:4318` becomes `…/v1/traces`, but `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` must already contain `/v1/traces`.
- **A2.2** — Default gRPC port is **4317**, and there is **no path** — the OTLP/gRPC service method (`Export`) identifies the signal, so nothing is appended for either the general or per-signal form.
- **A2.3** — The **signal-specific** one (`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`) takes precedence over the general `OTEL_EXPORTER_OTLP_ENDPOINT` for traces.

**Exercise 3**

- **A3.1** — Default is `parentbased_always_on`. "Parent-based" means it **respects an upstream sampling decision** if the span has a remote parent, and only falls back to its root delegate (here `always_on`) for a root span with no parent — this keeps a trace all-sampled-or-all-dropped end to end.
- **A3.2** — Flag `01` (parent sampled) → the span **is** sampled, because `parentbased_*` honors the parent's decision regardless of the ratio. Flag `00` (parent not sampled) → the span is **dropped**. The `0.5` ratio only applies to *root* spans with no parent.
- **A3.3** — `traceidratio` derives the keep/drop decision from the trace ID's bits compared against a threshold, not from a random draw. Since every service on the path shares the same trace ID, they all compute the same threshold comparison and reach the same decision — no coordination needed.

**Exercise 4**

- **A4.1** — It flushes when **the queued span count reaches `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` (default 512)** *or* when **`OTEL_BSP_SCHEDULE_DELAY` (default 5000 ms)** elapses since the last export, whichever comes first.
- **A4.2** — Once the queue hits `OTEL_BSP_MAX_QUEUE_SIZE` (2048), new spans are **dropped** (with the batch processor emitting an internal warning/metric). The `SimpleSpanProcessor` has no queue — it exports each span synchronously as it ends, which is why it is only recommended for debugging/testing.
- **A4.3** — Raise `OTEL_BSP_MAX_QUEUE_SIZE` (more headroom before dropping) and, if the exporter is the bottleneck, raise `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` and/or lower `OTEL_BSP_SCHEDULE_DELAY` so the queue drains faster.

**Exercise 5**

- **A5.1** — Default is `tracecontext,baggage`. `tracecontext` carries the W3C `traceparent`/`tracestate` (the active span/trace IDs and flags); `baggage` carries the W3C `baggage` header of arbitrary user key/values.
- **A5.2** — With only `b3multi` configured, the `tracecontext` propagator was **not installed**, so the SDK never parsed the `traceparent` header. With no extracted parent context, the server span became a new root — legitimate behavior, not an error.
- **A5.3** — **Broken traces**: the downstream service can't extract the upstream's context (different header format), so it starts a fresh trace and the two halves of the request appear as **two disconnected traces**. It is a **configuration** mismatch, not a code bug — align `OTEL_PROPAGATORS` across the services.

**Exercise 6**

- **A6.1** — `Resource.create()` **merges** the SDK/env Resource with the supplied attributes; on a key collision the explicitly-passed (code) values take precedence, but **non-conflicting** keys from `OTEL_RESOURCE_ATTRIBUTES` are preserved — which is why `deployment.environment` survived alongside the code's `service.name`.
- **A6.2** — The `BatchSpanProcessor` buffers spans and only exports on the schedule delay or a full batch. A script that exits immediately would terminate before the ~5 s flush, losing the span. `shutdown()` (or `force_flush()`) forces a final synchronous export.
- **A6.3** — The SDK **ignores** the second `set_tracer_provider` call and logs a warning — the global provider can only be set once. Any library that already called `get_tracer()` holds a reference bound to the *first* provider (or the no-op default if it ran before setup), which is why the provider must be installed as early as possible.

**Exercise 7**

- **A7.1** — When `OTEL_EXPERIMENTAL_CONFIG_FILE` is set, the file is authoritative and the individual `OTEL_*` configuration variables are **ignored**. The mechanism that still works is **`${ENV_VAR}` substitution inside the file**, so you parameterize the file from the environment rather than override it.
- **A7.2** — Both are global kill-switches that make the SDK a no-op (no spans/metrics/logs produced). `disabled: true` lives inside the declarative file (used when file config is active); `OTEL_SDK_DISABLED=true` is the standalone env-var equivalent used when configuring via variables. Same effect, different configuration surface.
- **A7.3** — `file_format` declares the **version of the configuration schema** the file was written against, so parsers can validate and evolve compatibly. A tool that doesn't recognize the declared version should **fail loudly** (refuse to load) rather than silently ignore fields it doesn't understand.

**Exercise 8**

- **A8.1** — Telemetry export runs on a **background path** (the Batch Span Processor's worker), decoupled from request handling. A failed export is caught and logged internally; it never propagates into the application's own code path, so responses stay green while telemetry silently fails — the reason observability outages are so easy to miss.
- **A8.2** — (1) Set `OTEL_TRACES_EXPORTER=console` — if spans print, the SDK/resource/sampler are fine and the fault is downstream (endpoint/network). (2) If the console shows nothing either, the problem is upstream: check `OTEL_SDK_DISABLED`, the sampler (`OTEL_TRACES_SAMPLER=always_off`/ratio `0`), or that instrumentation is actually loaded. (3) With console proven, switch back to OTLP and turn on `OTEL_LOG_LEVEL=debug` to read the exporter's connection error.
- **A8.3** — `OTEL_SDK_DISABLED` (or `disabled: true` in a declarative file). When set to `true` the SDK is a no-op: no spans are produced at all, so there is nothing to export and therefore no exporter errors — total silence with a clean log is its signature. (A `0`-ratio sampler produces the same silence for traces and is the second thing to check.)

</details>

---

*Primary sources (official):*
- *[OTEL SDK configuration (env vars)](https://opentelemetry.io/docs/languages/sdk-configuration/) and the normative [SDK environment variable spec](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)*
- *[OTLP exporter configuration](https://opentelemetry.io/docs/specs/otel/protocol/exporter/) — endpoint/protocol/path precedence*
- *[Trace SDK — Sampling](https://opentelemetry.io/docs/specs/otel/trace/sdk/#sampling) and [Batch Span Processor](https://opentelemetry.io/docs/specs/otel/trace/sdk/#batching-processor)*
- *[Context propagation](https://opentelemetry.io/docs/concepts/context-propagation/) and [W3C Trace Context](https://www.w3.org/TR/trace-context/)*
- *[Declarative configuration](https://opentelemetry.io/docs/specs/otel/configuration/) and the [opentelemetry-configuration schema](https://github.com/open-telemetry/opentelemetry-configuration)*
- *[OTCA Curriculum](https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf)*