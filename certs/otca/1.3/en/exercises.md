# Topic 1.3 — Instrumentation · Guided Exercises

> **Domain 1 — Fundamentals of Observability.** *Instrumentation* is the act of making a system emit telemetry (traces, metrics, logs). In OpenTelemetry it happens on two paths that you must be able to tell apart on the exam:
>
> - **Code-based (manual) instrumentation** — you call the OpenTelemetry **API** in your own source to create spans, record metrics, set attributes.
> - **Zero-code (automatic) instrumentation** — an agent or injector wires up telemetry for supported libraries and frameworks *without editing application source*.
>
> A load-bearing distinction underneath both: the **API** defines the surface you call; the **SDK** is the implementation that actually produces and exports data. With the API present but no SDK configured, every call is a **no-op**. Keep this in mind — three of the four exercises hinge on it.
>
> Reference: OpenTelemetry — *Instrumentation* concept (https://opentelemetry.io/docs/concepts/instrumentation/), *Zero-code* (https://opentelemetry.io/docs/concepts/instrumentation/zero-code/), *Code-based* (https://opentelemetry.io/docs/concepts/instrumentation/code-based/).

The exercises use Python because its two instrumentation paths are the clearest to run locally, plus one Kubernetes exercise with the OpenTelemetry Operator. Have Python 3.9+ and (for Exercise 4) a cluster with `kubectl` access.

---

## Exercise 1 — Zero-code instrumentation of a running service

**Goal:** emit traces and metrics from an unmodified Flask app using `opentelemetry-instrument`, and read the exported spans.

1. Create an isolated environment and a minimal, **uninstrumented** web app:

   ```bash
   mkdir otca-13 && cd otca-13
   python3 -m venv .venv && source .venv/bin/activate
   pip install flask
   ```

   ```python
   # app.py  — note: NOT one line of OpenTelemetry code
   from flask import Flask
   from random import randint

   app = Flask(__name__)

   @app.route("/rolldice")
   def roll():
       return str(randint(1, 6))
   ```

2. Install the OpenTelemetry **distro** (API + SDK + the auto-instrumentation launcher) and the OTLP exporter:

   ```bash
   pip install opentelemetry-distro opentelemetry-exporter-otlp
   ```

3. Let the bootstrapper detect installed libraries and pull the matching **instrumentation libraries**:

   ```bash
   opentelemetry-bootstrap -a install
   ```

   Expected (abridged) — it discovers Flask and installs its bridge:

   ```
   ...
   Installing opentelemetry-instrumentation-flask
   Installing opentelemetry-instrumentation-requests
   Installing opentelemetry-instrumentation-dbapi
   ...
   ```

4. Run the app **through** the launcher, sending telemetry to the console so you can read it:

   ```bash
   OTEL_SERVICE_NAME=dice-service \
   opentelemetry-instrument \
     --traces_exporter console \
     --metrics_exporter console \
     --logs_exporter none \
     flask run -p 8080
   ```

5. In another terminal, generate one request:

   ```bash
   curl http://localhost:8080/rolldice
   # -> 4
   ```

6. Look at the launcher's terminal. A **SERVER** span was created for the HTTP handler with no code change on your part (values are representative):

   ```json
   {
       "name": "GET /rolldice",
       "context": {
           "trace_id": "0x9c4f1e2a7b3d5f6081a2b3c4d5e6f7a8",
           "span_id": "0x1a2b3c4d5e6f7a8b",
           "trace_state": "[]"
       },
       "kind": "SpanKind.SERVER",
       "parent_id": null,
       "start_time": "2026-08-10T14:03:11.402193Z",
       "end_time":   "2026-08-10T14:03:11.404517Z",
       "status": { "status_code": "UNSET" },
       "attributes": {
           "http.request.method": "GET",
           "url.path": "/rolldice",
           "http.response.status_code": 200,
           "server.address": "localhost",
           "server.port": 8080
       },
       "resource": {
           "attributes": {
               "service.name": "dice-service",
               "telemetry.sdk.language": "python",
               "telemetry.sdk.name": "opentelemetry"
           }
       }
   }
   ```

   > Exact attribute keys depend on the installed instrumentation library's semantic-convention version (e.g. `http.request.method` vs the older `http.method`); the *presence* of the span is what matters here.

Reference: *Python — Zero-code / Automatic* (https://opentelemetry.io/docs/zero-code/python/), *Getting Started* (https://opentelemetry.io/docs/languages/python/getting-started/).

**Check your understanding — Block 1**

1. You wrote no OpenTelemetry code, yet a span appeared. What component actually created it, and how did it get loaded into the process?
2. What is the job of `opentelemetry-bootstrap -a install`? Why isn't it enough to just `pip install opentelemetry-distro`?
3. `OTEL_SERVICE_NAME` set `service.name` on the **resource**, not on the span. Why does that distinction matter for a backend?
4. Name one class of telemetry that zero-code instrumentation on its own will typically **not** capture without you adding code.

---

## Exercise 2 — Code-based instrumentation: your own spans

**Goal:** produce a span from application code, and prove that it fails silently without an SDK.

1. In the same venv, write a script that uses **only the API** — no SDK setup:

   ```python
   # manual_noop.py
   from opentelemetry import trace

   tracer = trace.get_tracer("dice.tracer")

   with tracer.start_as_current_span("roll-dice") as span:
       span.set_attribute("dice.count", 3)
       print("span type:", type(span).__name__)
   ```

   ```bash
   python manual_noop.py
   ```

   Expected:

   ```
   span type: NonRecordingSpan
   ```

   Nothing is exported. The API returned a **no-op** because no `TracerProvider` from the SDK was registered.

2. Now wire up the **SDK** explicitly and create the same span:

   ```python
   # manual.py
   from opentelemetry import trace
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import (
       BatchSpanProcessor,
       ConsoleSpanExporter,
   )
   from opentelemetry.trace import Status, StatusCode

   # 1) Resource: who is emitting this telemetry
   resource = Resource.create({"service.name": "dice-service"})

   # 2) Provider + processor + exporter pipeline
   provider = TracerProvider(resource=resource)
   provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)

   # 3) Acquire a tracer from the *global* provider
   tracer = trace.get_tracer("dice.tracer")

   def roll(count):
       # parent span
       with tracer.start_as_current_span("roll-dice") as parent:
           parent.set_attribute("dice.count", count)
           results = []
           for i in range(count):
               # child span, nested by "current span" context
               with tracer.start_as_current_span("roll-one") as child:
                   value = (i * 7 + 3) % 6 + 1   # deterministic for the demo
                   child.set_attribute("dice.value", value)
                   child.add_event("die rolled", {"index": i})
                   results.append(value)
           if sum(results) == 0:
               parent.set_status(Status(StatusCode.ERROR, "impossible roll"))
           return results

   print(roll(2))
   provider.shutdown()   # flush the BatchSpanProcessor before exit
   ```

   ```bash
   python manual.py
   ```

   Expected — two spans, the child carrying your **event**, the parent carrying `parent_id: null` and the child pointing back at it (representative):

   ```json
   {
       "name": "roll-one",
       "context": { "trace_id": "0x7f...", "span_id": "0xaa..." },
       "kind": "SpanKind.INTERNAL",
       "parent_id": "0xbb...",
       "attributes": { "dice.value": 3 },
       "events": [
           { "name": "die rolled", "attributes": { "index": 0 } }
       ]
   }
   {
       "name": "roll-dice",
       "context": { "trace_id": "0x7f...", "span_id": "0xbb..." },
       "kind": "SpanKind.INTERNAL",
       "parent_id": null,
       "attributes": { "dice.count": 2 }
   }
   ```

   Note the **shared `trace_id`** and that `roll-one.parent_id` equals `roll-dice.span_id` — nesting came for free from `start_as_current_span`, which set the child as the *current* span inside the `with` block.

Reference: *Python — Instrumentation / Manual* (https://opentelemetry.io/docs/languages/python/instrumentation/), Span/Status API in the spec glossary (https://opentelemetry.io/docs/specs/otel/glossary/).

**Check your understanding — Block 2**

1. In `manual_noop.py` the type was `NonRecordingSpan`. Which architectural rule of OpenTelemetry does that demonstrate, and why is it *deliberate* rather than a bug?
2. What is the difference between `start_span()` and `start_as_current_span()`? Which one made the nesting in `manual.py` work?
3. Why does the code call `provider.shutdown()` at the end? What does the `BatchSpanProcessor` risk if you skip it?
4. You added `add_event(...)` to a span rather than creating a new span. When would you choose an **event** over a child **span**?

---

## Exercise 3 — Instrumentation libraries vs. native instrumentation

**Goal:** enable one instrumentation library by hand (not via the launcher) and see it produce spans against the SDK you configured in Exercise 2 — this is the seam between code-based and zero-code.

1. Install the `requests` instrumentation library and `requests` itself:

   ```bash
   pip install requests opentelemetry-instrumentation-requests
   ```

2. Reuse the SDK setup, then activate the instrumentation library **once** at startup:

   ```python
   # lib_instrumented.py
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
   from opentelemetry.instrumentation.requests import RequestsInstrumentor
   import requests

   provider = TracerProvider()
   provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)

   # Monkey-patch the requests library so every call emits a CLIENT span
   RequestsInstrumentor().instrument()

   requests.get("https://opentelemetry.io", timeout=10)
   provider.shutdown()
   ```

   ```bash
   python lib_instrumented.py
   ```

   Expected — a **CLIENT** span you never explicitly created, emitted by the library bridge (representative):

   ```json
   {
       "name": "GET",
       "kind": "SpanKind.CLIENT",
       "attributes": {
           "http.request.method": "GET",
           "url.full": "https://opentelemetry.io/",
           "http.response.status_code": 200,
           "server.address": "opentelemetry.io"
       }
   }
   ```

3. Prove the library is only a bridge — disable the SDK by *not* registering a provider (comment out the three provider lines) and rerun. No span is printed: the instrumentation library calls the **API**, which no-ops without an SDK, exactly as in Exercise 2.

Reference: *Instrumentation — libraries* (https://opentelemetry.io/docs/concepts/instrumentation/libraries/), *Python — using instrumentation libraries* (https://opentelemetry.io/docs/zero-code/python/#configuring-instrumentation).

**Check your understanding — Block 3**

1. Define an **instrumentation library** in one sentence. How does it differ from a library that is **natively instrumented**?
2. In Exercise 1 you never called `RequestsInstrumentor().instrument()`, yet Flask was traced. What did `opentelemetry-instrument` do that this exercise did by hand?
3. The `requests` span had `kind: CLIENT` while the Flask span in Exercise 1 had `kind: SERVER`. What does `SpanKind` communicate to a tracing backend, and why does it matter for a distributed trace?
4. Would a **natively** instrumented library still emit telemetry if you removed the OpenTelemetry SDK from the process? Explain.

---

## Exercise 4 — Zero-code instrumentation in Kubernetes with the OpenTelemetry Operator

**Goal:** inject auto-instrumentation into a pod with a single annotation — no image rebuild, no code change — and confirm the injection by inspecting the pod.

1. Install the prerequisites and the operator (the operator needs cert-manager for its webhooks):

   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
   kubectl wait --for=condition=Available deploy --all -n cert-manager --timeout=120s

   kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
   kubectl wait --for=condition=Available deploy/opentelemetry-operator -n opentelemetry-operator-system --timeout=120s
   ```

2. Create an **`Instrumentation`** custom resource. This tells the operator *what* to inject and *where telemetry goes* — it does not instrument anything by itself:

   ```yaml
   # instrumentation.yaml
   apiVersion: opentelemetry.io/v1alpha1
   kind: Instrumentation
   metadata:
     name: dice-instrumentation
   spec:
     exporter:
       endpoint: http://otel-collector:4318   # Python auto-instr defaults to OTLP/HTTP
     propagators:
       - tracecontext
       - baggage
     sampler:
       type: parentbased_traceidratio
       argument: "1"                            # sample everything in the lab
     python:
       env:
         - name: OTEL_EXPORTER_OTLP_PROTOCOL
           value: http/protobuf
   ```

   ```bash
   kubectl apply -f instrumentation.yaml
   kubectl get instrumentation
   ```

3. Deploy an ordinary Python app and **opt it in** with the injection annotation on the **pod template** (not on the Deployment metadata):

   ```yaml
   # deploy.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: dice
   spec:
     replicas: 1
     selector: { matchLabels: { app: dice } }
     template:
       metadata:
         labels: { app: dice }
         annotations:
           instrumentation.opentelemetry.io/inject-python: "true"   # <- the switch
       spec:
         containers:
           - name: dice
             image: python:3.12-slim
             command: ["python", "-c", "import time; time.sleep(3600)"]
   ```

   ```bash
   kubectl apply -f deploy.yaml
   kubectl rollout status deploy/dice
   ```

4. Inspect the created pod and confirm the operator mutated it:

   ```bash
   kubectl get pod -l app=dice -o jsonpath='{.items[0].spec.initContainers[*].name}'; echo
   ```

   Expected:

   ```
   opentelemetry-auto-instrumentation-python
   ```

5. Confirm the injected environment and shared volume:

   ```bash
   kubectl describe pod -l app=dice | grep -E 'PYTHONPATH|OTEL_|opentelemetry-auto'
   ```

   Expected (abridged):

   ```
   PYTHONPATH:                     /otel-auto-instrumentation-python/opentelemetry/instrumentation/auto_instrumentation:/otel-auto-instrumentation-python
   OTEL_SERVICE_NAME:              dice
   OTEL_EXPORTER_OTLP_ENDPOINT:    http://otel-collector:4318
   OTEL_TRACES_EXPORTER:           otlp
   ...
   opentelemetry-auto-instrumentation-python   (volume mounted at /otel-auto-instrumentation-python)
   ```

   The operator's mutating webhook added an **init container** that copies the auto-instrumentation into a shared `emptyDir` volume, mounted it into your app container, and set `PYTHONPATH` so the agent loads at interpreter startup — the same mechanism as `opentelemetry-instrument` in Exercise 1, delivered by the platform instead of your Dockerfile.

Reference: *Kubernetes — Operator, auto-instrumentation injection* (https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/), *Instrumentation CR spec* (https://github.com/open-telemetry/opentelemetry-operator/blob/main/docs/api.md).

**Check your understanding — Block 4**

1. The `Instrumentation` CR existed *before* any pod was injected, and injection only happened after you added the annotation. Which of the two is the actual trigger, and what is the CR's role?
2. A teammate puts the annotation on `Deployment.metadata.annotations` instead of `spec.template.metadata.annotations` and reports "nothing is injected." Why does location matter?
3. Explain the purpose of the **init container** and the shared `emptyDir` volume. Why does the operator use them instead of baking the agent into the image?
4. The Python injection defaults its OTLP endpoint to port **4318**, while Java auto-instrumentation commonly uses **4317**. What underlying difference does that reflect, and where would you look first if spans never reach the collector?

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1 — Zero-code instrumentation

1. The **Flask instrumentation library** (`opentelemetry-instrumentation-flask`) created the span; the SDK's provider/exporter turned it into console output. It was loaded because `opentelemetry-instrument` runs your program as a child and injects the auto-instrumentation before your code executes (in Python it prepends the agent to `PYTHONPATH`/`sitecustomize`), monkey-patching Flask at import time. You never referenced OpenTelemetry in `app.py`.
2. `opentelemetry-bootstrap -a install` scans the packages already installed in the environment and installs the **matching instrumentation libraries** (Flask → `opentelemetry-instrumentation-flask`, etc.). `opentelemetry-distro` only ships the API, SDK, and the launcher; without the per-library bridges the launcher has nothing to patch, so it would run but emit few or no spans.
3. `service.name` on the **resource** identifies the *producer* of all telemetry from that process; it is attached once and applies to every span, metric, and log. Backends group, name, and route data by resource (this is the "service" in a service map). Putting it on a span would scope it to that single span and break aggregation.
4. Your own **business logic / custom spans, attributes, and domain metrics**. Zero-code instrumentation covers supported frameworks and libraries (HTTP, DB, messaging), but it cannot know what "checkout completed" or "risk score = 0.8" means — that requires code-based instrumentation. (Logs are also often opt-in.)

### Block 2 — Code-based instrumentation

1. It shows OpenTelemetry's **API/SDK separation**: the API always returns a valid object, but with no SDK registered that object is a **no-op** (`NonRecordingSpan`). This is deliberate so that libraries can call the API unconditionally and remain **safe and dependency-light** even in a process where the application chose not to install/configure an SDK — instrumentation never crashes or forces telemetry on a host that doesn't want it.
2. `start_span()` creates a span but does **not** make it the current span — you must manage context yourself. `start_as_current_span()` creates the span **and** sets it as the active span for the duration of the `with` block, so any span started inside becomes its child automatically. The latter is what produced the parent/child nesting.
3. `BatchSpanProcessor` **buffers** spans and exports them asynchronously in batches. Without `shutdown()` (or `force_flush()`) at process exit, buffered spans may never be exported — you'd lose the tail of your telemetry. `shutdown()` flushes the queue and stops the worker cleanly.
4. Use an **event** for a point-in-time annotation *within* an operation that has no meaningful duration or independent timing (a log-like marker: "cache miss", "retry #2"). Use a **child span** when the sub-operation has its own **duration**, status, and attributes you want to measure and see as a distinct node in the trace (e.g. a downstream call).

### Block 3 — Instrumentation libraries

1. An **instrumentation library** is a separate package that wraps/patches a *third-party* library which is not itself OTel-aware, translating its operations into OpenTelemetry API calls. A **natively instrumented** library calls the OpenTelemetry API directly from its own source — no bridge package needed.
2. `opentelemetry-instrument` discovered every installed instrumentation library and called their `instrument()` hooks automatically at startup (plus configured the SDK from env vars). Exercise 3 did the same activation manually for one library — the launcher is essentially "auto-activate all bridges + auto-configure the SDK."
3. `SpanKind` describes the span's **role in a request flow**: `SERVER` receives a request, `CLIENT` makes an outbound call, plus `PRODUCER`/`CONSUMER`/`INTERNAL`. In a distributed trace a `CLIENT` span on one service and the `SERVER` span it triggers on another are matched to reconstruct the call graph and to compute network vs. server time. Getting the kind right is what lets a backend draw the correct topology.
4. Yes — but only no-op calls. A natively instrumented library still calls the API, and without an SDK those calls become `NonRecordingSpan`s, so **no telemetry is exported**. Native instrumentation removes the need for a bridge package; it does **not** remove the need for a configured SDK.

### Block 4 — OpenTelemetry Operator

1. The **annotation on the pod** is the trigger; the operator's mutating webhook only acts on pods carrying `instrumentation.opentelemetry.io/inject-<lang>`. The `Instrumentation` CR is **configuration** the webhook reads when it fires — exporter endpoint, propagators, sampler, per-language env — but it injects nothing on its own.
2. The webhook mutates **pods**, and pods are created from `spec.template`. An annotation on `Deployment.metadata` is never copied to the pod, so the webhook sees an un-annotated pod and skips it. The annotation must live on `spec.template.metadata.annotations`.
3. The **init container** ships the language agent and copies it into a shared **`emptyDir`** volume that is also mounted into the app container; env like `PYTHONPATH` then points the runtime at that volume so the agent loads at startup. This keeps the **application image unchanged and language-agnostic** — you can add, upgrade, or remove instrumentation by editing the CR/annotation, with no rebuild and no OTel dependency baked into the app.
4. It reflects the default **OTLP transport** each language's auto-instrumentation selects: Python's operator injection defaults to **OTLP/HTTP** (`http/protobuf`, port **4318**), while Java commonly defaults to **OTLP/gRPC** (port **4317**). If spans never arrive, check first that the `Instrumentation` **exporter endpoint's port and protocol match** (4318↔http/protobuf vs 4317↔grpc) and that the collector actually has that receiver/port open — a protocol/port mismatch is the most common silent failure.

</details>