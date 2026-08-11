# Topic 1.2 — Semantic Conventions: Guided Exercises

> **What these exercises train.** Semantic Conventions are the *contract* that makes telemetry from different languages, libraries and vendors comparable. They define the canonical names, types, units and requirement levels for attributes on Resources, Spans, Metrics and Logs. In production this is what lets a single dashboard query `http.server.request.duration` across a Go service, a Python service and a third‑party library without translation. These exercises make you *observe* the conventions in emitted telemetry, not just read about them.
>
> **Prerequisites**
> - Docker (to run the Collector and `telemetrygen` without local installs)
> - Python 3.9+ and `pip` (Exercises 2–4)
> - `git`, `grep`, `curl`, `jq`
>
> **Working directory**
> ```bash
> mkdir -p otca-semconv && cd otca-semconv
> ```
>
> Primary source: OpenTelemetry Semantic Conventions specification — <https://opentelemetry.io/docs/specs/semconv/>

---

## Exercise 1 — Read the model: the Attribute Registry as source of truth

The website documentation for semantic conventions is *generated* from machine‑readable YAML in the `open-telemetry/semantic-conventions` repository. Learning to read the model tells you the ground truth: an attribute's `type`, `stability`, `requirement_level` and `brief`.

1. Clone the model repository and inspect the top‑level layout:
   ```bash
   git clone --depth 1 https://github.com/open-telemetry/semantic-conventions.git
   cd semantic-conventions
   ls model/
   ```
   Expected (directory names vary slightly by release):
   ```
   database   faas    http   messaging   registry.yaml   resource   rpc   ...
   ```

2. Locate the canonical definition of the HTTP request method attribute. The registry entry is the single place an attribute is *declared*; everywhere else references it by `ref`:
   ```bash
   grep -rn "id: http.request.method" model/
   ```
   Expected (path depends on release; the shape of the match is what matters):
   ```
   model/http/registry.yaml:12:      - id: http.request.method
   ```

3. Open the surrounding block and read the fields:
   ```bash
   grep -n -A 20 "id: http.request.method" model/http/registry.yaml
   ```
   You should see a definition equivalent to:
   ```yaml
   - id: http.request.method
     type:
       allow_custom_values: true
       members:
         - id: connect
           value: "CONNECT"
         - id: get
           value: "GET"
         - id: post
           value: "POST"
         # ...
     stability: stable
     brief: 'HTTP request method.'
     examples: ["GET", "POST", "HEAD"]
   ```

4. Confirm the same attribute in the *rendered* registry on the website, so you can map YAML → docs:
   - <https://opentelemetry.io/docs/specs/semconv/registry/attributes/http/>

**Comprehension check (Block 1)**
1. What is the difference between an attribute being *declared* in the registry versus *referenced* (`ref:`) in a span or metric group? Why does the project separate the two?
2. The `type` of `http.request.method` is an enum with `allow_custom_values: true`. What canonical value must an instrumentation use when it observes a method that is **not** in the known set, and which companion attribute captures the original string?
3. Why is the generated website documentation considered a derived artifact rather than the source of truth?

---

## Exercise 2 — Resource Semantic Conventions: identity of the producer

Every telemetry stream carries a **Resource**: the immutable set of attributes describing *what* produced it (service, host, container, cloud, SDK). Resource conventions are how a backend groups spans and metrics under one service. Here you set them declaratively via environment variables and verify what the SDK actually emits.

1. Create a Collector config that prints everything it receives, in full:
   ```yaml
   # collector.yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   exporters:
     debug:
       verbosity: detailed

   service:
     pipelines:
       traces:
         receivers: [otlp]
         exporters: [debug]
       metrics:
         receivers: [otlp]
         exporters: [debug]
   ```

2. Start the Collector (leave it running in this terminal):
   ```bash
   docker run --rm --name otelcol -p 4317:4317 -p 4318:4318 \
     -v "$(pwd)/collector.yaml:/etc/otelcol-contrib/config.yaml" \
     otel/opentelemetry-collector-contrib:0.109.0
   ```

3. In a **second** terminal, install the Python SDK and a trace generator app:
   ```bash
   python -m venv .venv && source .venv/bin/activate
   pip install opentelemetry-sdk opentelemetry-exporter-otlp-proto-grpc
   ```

4. Set Resource attributes **only** through the standard environment variables — do not hardcode them:
   ```bash
   export OTEL_SERVICE_NAME="checkout"
   export OTEL_RESOURCE_ATTRIBUTES="service.version=1.4.2,service.namespace=shop,deployment.environment.name=staging,service.instance.id=checkout-7d9f-abc"
   export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
   ```

5. Emit one span so the Resource is transmitted:
   ```python
   # emit.py
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor
   from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

   provider = TracerProvider()                 # picks up OTEL_* env resource automatically
   provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
   trace.set_tracer_provider(provider)

   tracer = trace.get_tracer("my.demo", "0.1.0")
   with tracer.start_as_current_span("warmup"):
       pass

   provider.shutdown()                          # force flush before exit
   ```
   ```bash
   python emit.py
   ```

6. Read the Collector terminal. You should see the Resource block:
   ```
   ResourceSpans #0
   Resource SchemaURL: https://opentelemetry.io/schemas/1.27.0
   Resource attributes:
        -> service.name: Str(checkout)
        -> service.version: Str(1.4.2)
        -> service.namespace: Str(shop)
        -> deployment.environment.name: Str(staging)
        -> service.instance.id: Str(checkout-7d9f-abc)
        -> telemetry.sdk.language: Str(python)
        -> telemetry.sdk.name: Str(opentelemetry)
        -> telemetry.sdk.version: Str(1.27.0)
   ```

7. Notice you never set `telemetry.sdk.*`. Confirm which attributes the SDK injects on its own by unsetting your custom ones and re‑running:
   ```bash
   unset OTEL_RESOURCE_ATTRIBUTES
   python emit.py    # Resource now shows only service.name + telemetry.sdk.*
   ```

**Comprehension check (Block 2)**
1. `service.name` has requirement level **Required**. What value does the SDK fall back to if you never set `OTEL_SERVICE_NAME` nor `service.name`, and why is relying on that fallback an anti‑pattern in production?
2. `telemetry.sdk.language`, `telemetry.sdk.name` and `telemetry.sdk.version` appeared without you setting them. Which component is responsible for populating those, and what is the requirement level that makes them mandatory?
3. The output used `deployment.environment.name`. Older material and older SDKs emit `deployment.environment`. What does that rename tell you about the *stability lifecycle* of an attribute, and how would a backend correlate the two?
4. `service.instance.id` distinguishes replicas of the same `service.name`. Give a concrete metric‑cardinality reason you would want it on Resources but would **not** want it as a metric data‑point attribute.

---

## Exercise 3 — HTTP Span Conventions: names, kinds and attributes

HTTP is the most mature stable convention and the one most exam questions target. Here you generate real HTTP spans and verify the span **name**, **kind** and the **stable attribute set** — including the low‑cardinality rule for span names.

1. With the Collector from Exercise 2 still running, generate a **server‑side** and a **client‑side** HTTP span using `telemetrygen`:
   ```bash
   docker run --rm --network host \
     ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
     traces --otlp-insecure --otlp-endpoint localhost:4317 \
     --traces 1 --service checkout \
     --span-duration 50ms
   ```
   *(`telemetrygen` emits generic spans; use it to confirm the pipeline, then read real HTTP spans from step 3.)*

2. Install a real instrumented app so the HTTP conventions are produced by library instrumentation, not by hand:
   ```bash
   pip install flask requests \
     opentelemetry-instrumentation-flask \
     opentelemetry-instrumentation-requests \
     opentelemetry-exporter-otlp-proto-grpc
   ```
   ```python
   # app.py
   from flask import Flask
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor
   from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
   from opentelemetry.instrumentation.flask import FlaskInstrumentor

   provider = TracerProvider()
   provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
   trace.set_tracer_provider(provider)

   app = Flask(__name__)
   FlaskInstrumentor().instrument_app(app)

   @app.route("/users/<int:user_id>")
   def user(user_id):
       return {"id": user_id}
   ```

3. Run it and drive one request with a path parameter:
   ```bash
   export OTEL_SERVICE_NAME=checkout
   export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
   flask --app app run --port 8080 &
   curl -s http://localhost:8080/users/42 >/dev/null
   ```

4. In the Collector output, inspect the server span:
   ```
   Span #0
       Name           : GET /users/<int:user_id>
       Kind           : Server
       Status code    : Unset
       Attributes:
            -> http.request.method: Str(GET)
            -> url.path: Str(/users/42)
            -> url.scheme: Str(http)
            -> http.route: Str(/users/<int:user_id>)
            -> http.response.status_code: Int(200)
            -> network.protocol.version: Str(1.1)
            -> server.address: Str(localhost)
            -> server.port: Int(8080)
            -> user_agent.original: Str(curl/8.5.0)
            -> client.address: Str(127.0.0.1)
   ```

5. Contrast: the span **name** is `GET /users/<int:user_id>` (the *route template*), while `url.path` is `/users/42` (the *concrete* request). Verify this distinction is deliberate by requesting a second id:
   ```bash
   curl -s http://localhost:8080/users/99 >/dev/null
   ```
   The span name stays `GET /users/<int:user_id>`; only `url.path` changes to `/users/99`.

**Comprehension check (Block 3)**
1. The HTTP **server** span name convention is `{method} {http.route}`. Why is `http.route` (and not `url.path`) used in the name, and what operational failure occurs on a metrics/tracing backend if an implementation names spans with the raw path?
2. A client‑side HTTP span (SpanKind `Client`) carries `url.full` but typically **omits** `http.route`. Explain why `http.route` is a *server‑only* concept.
3. Your app called `GET /users/42` and the response was `200`. Under what response‑status condition does the convention require the span `Status` to be set to `Error`, and does that rule differ between `Client` and `Server` spans?
4. The output shows both `server.address`/`server.port` and `client.address`. These come from the *shared* `network`/`server`/`client` namespaces rather than an `http.`‑prefixed name. What is the design benefit of factoring these out of the `http.*` namespace?

---

## Exercise 4 — Metric Conventions: names, UCUM units and instrument kind

Metric conventions fix the *name*, the *instrument kind* and the *unit* (in UCUM). A subtle, exam‑relevant point: the stable HTTP duration metric is measured in **seconds**, not milliseconds, and its name changed from the experimental era.

1. Query the rendered convention for the stable server duration metric:
   ```bash
   curl -s https://opentelemetry.io/docs/specs/semconv/http/http-metrics/ \
     | grep -iA2 "http.server.request.duration" | head
   ```
   Canonical definition you should confirm:
   - **Name**: `http.server.request.duration`
   - **Instrument**: Histogram
   - **Unit**: `s` (seconds, UCUM)
   - **Stability**: Stable

2. Emit an HTTP‑server duration metric that follows the convention and one that violates it, then compare. First, a correct instrument:
   ```python
   # metric.py
   from opentelemetry import metrics
   from opentelemetry.sdk.metrics import MeterProvider
   from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
   from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter

   reader = PeriodicExportingMetricReader(OTLPMetricExporter(), export_interval_millis=2000)
   metrics.set_meter_provider(MeterProvider(metric_readers=[reader]))
   meter = metrics.get_meter("my.demo", "0.1.0")

   # CORRECT: convention name + UCUM 's'
   hist = meter.create_histogram(
       name="http.server.request.duration",
       unit="s",
       description="Duration of HTTP server requests.",
   )
   hist.record(0.042, {"http.request.method": "GET", "http.response.status_code": 200,
                       "http.route": "/users/{id}"})
   ```
   ```bash
   python metric.py
   ```

3. Read the Collector metrics output:
   ```
   Metric #0
   Descriptor:
        -> Name: http.server.request.duration
        -> Unit: s
        -> DataType: Histogram
   HistogramDataPoints #0
   Data point attributes:
        -> http.request.method: Str(GET)
        -> http.response.status_code: Int(200)
        -> http.route: Str(/users/{id})
   ```

4. Inspect a dimensionless‑count convention. Change the name/unit to model *active requests* (an `UpDownCounter`) and observe the annotated unit:
   - **Name**: `http.server.active_requests`
   - **Instrument**: UpDownCounter
   - **Unit**: `{request}` (a UCUM *annotation* — dimensionless, curly braces)

5. Confirm the *cardinality* discipline: the metric point attributes are exactly the low‑cardinality subset (`http.request.method`, `http.response.status_code`, `http.route`) — **not** `url.path`, `url.full` or `user_agent.original`.

**Comprehension check (Block 4)**
1. The stable metric unit is `s`, yet many legacy dashboards expect milliseconds. What earlier metric name did `http.server.request.duration` replace, and what unit did that predecessor use? Why does mixing the two in one dashboard silently corrupt percentiles?
2. `{request}` and `1` are both "dimensionless" in UCUM. What does the curly‑brace annotation add, and why is it preferred for counters over a bare `1`?
3. The histogram carried `http.route` but not `url.path`. Restate the general rule the conventions impose about which HTTP attributes may appear on **metric** data points versus **span** attributes, and tie it to time‑series cardinality.
4. Instrument kind is part of the convention (Histogram vs UpDownCounter vs Counter). Why is emitting the right *name* with the wrong *instrument kind* still a convention violation that a backend cannot silently repair?

---

## Exercise 5 — Schema URLs and the stability opt‑in: surviving convention changes

Conventions evolve. Two mechanisms keep that from breaking consumers: the **Schema URL** carried on Resources and Instrumentation Scopes (points at a version), and **Telemetry Schema** files that describe transformations between versions. During a breaking migration, SDKs expose `OTEL_SEMCONV_STABILITY_OPT_IN` so you can emit old, new, or both attribute sets.

1. Re‑read the Resource output from Exercise 2 and note the line you skipped:
   ```
   Resource SchemaURL: https://opentelemetry.io/schemas/1.27.0
   ```
   Fetch that schema and see it is a real, versioned artifact:
   ```bash
   curl -s https://opentelemetry.io/schemas/1.27.0 | head -40
   ```
   You should see a `file_format`, a `schema_url`, and `versions:` blocks with `all`/`resources`/`spans` sections containing `rename_attributes` transformations, e.g. an entry mapping `deployment.environment` → `deployment.environment.name`.

2. Reproduce a migration decision locally. Simulate an SDK that supports the HTTP stability opt‑in by inspecting the documented values (the flag was central during the HTTP `net.*`/`http.*` → `url.*`/`server.*` migration):
   ```bash
   # Emit ONLY the new, stable attributes:
   export OTEL_SEMCONV_STABILITY_OPT_IN=http
   # Emit BOTH old and new for a safe cutover window:
   export OTEL_SEMCONV_STABILITY_OPT_IN=http/dup
   # Unset -> legacy attributes only (pre-stable default, for older instrumentations)
   unset OTEL_SEMCONV_STABILITY_OPT_IN
   ```
   Migration guide (authoritative mapping table): <https://opentelemetry.io/docs/specs/semconv/non-normative/http-migration/>

3. Map three old→new HTTP attributes by hand from the guide, then verify against Exercise 3 output:
   | Legacy (experimental) | Stable (current) |
   |---|---|
   | `http.method` | `http.request.method` |
   | `http.status_code` | `http.response.status_code` |
   | `http.url` | `url.full` |

4. Confirm where the Schema URL is attached in the wire format. In the Collector output you saw **two** independent schema URLs: one on the `Resource` and one on the `ScopeSpans`/`InstrumentationScope`. Locate both:
   ```
   Resource SchemaURL: https://opentelemetry.io/schemas/1.27.0
   ...
   ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.27.0
   InstrumentationScope my.demo 0.1.0
   ```

**Comprehension check (Block 5)**
1. The Schema URL appears on **both** the Resource and each Instrumentation Scope. Why does the convention allow two different schema versions in the same exported batch, and what real situation produces that?
2. During the HTTP migration, `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup` doubles the attribute count on every HTTP span. What operational cost does `http/dup` incur, and what is the single reason a team would still accept that cost for a bounded window?
3. A backend receives spans stamped `schema_url = .../1.20.0` carrying `deployment.environment`, and other spans stamped `.../1.27.0` carrying `deployment.environment.name`. Explain, in terms of Telemetry Schema `rename_attributes`, how a schema‑aware processor unifies these into one queryable dimension.
4. If an SDK emits telemetry that follows 1.27.0 conventions but stamps `schema_url = .../1.20.0`, which checks in the ladder (URL resolves / attributes correct) pass, and what breaks downstream? Relate this to why the schema URL is a *claim* that must match the payload.

---

## Exercise 6 — Author a convention: attribute naming rules and validation

The general‑purpose rule set governs any attribute you invent for your own domain. Getting namespacing, casing and requirement levels right is what keeps *your* attributes forward‑compatible with future official ones.

1. Read the naming rules and note the four hard constraints:
   - <https://opentelemetry.io/docs/specs/semconv/general/naming/>
   - lowercase; dots (`.`) separate **namespaces**; underscores (`_`) separate **words within one element**; a namespace segment is never reused as a leaf attribute name.

2. Classify each candidate as valid/invalid *and say why*:
   ```
   payment.card.type          # ?
   Payment.CardType           # ?
   payment.card_holder.name   # ?
   payment                    # ? (used both as namespace and as attribute)
   user_agent.original        # ?
   http                       # ?
   ```

3. Draft a small custom attribute group as YAML in the model style (this is exactly the shape used in `open-telemetry/semantic-conventions`):
   ```yaml
   groups:
     - id: registry.payment
       type: attribute_group
       brief: "Attributes describing a payment operation."
       attributes:
         - id: payment.provider.name
           type: string
           stability: development        # your own attributes start experimental
           requirement_level: required
           brief: "Name of the payment gateway."
           examples: ["stripe", "adyen"]
         - id: payment.card.brand
           type:
             allow_custom_values: true
             members:
               - id: visa
                 value: "visa"
               - id: mastercard
                 value: "mastercard"
           stability: development
           requirement_level: recommended
           brief: "Card network brand."
   ```

4. (Optional, authoritative) Validate the model with **Weaver**, the official tooling the project uses to lint and generate docs from these YAML files:
   ```bash
   docker run --rm -v "$(pwd):/work" \
     otel/weaver:latest registry check -r /work/model
   ```
   - Weaver: <https://github.com/open-telemetry/weaver>

**Comprehension check (Block 6)**
1. For each of the six candidates in step 2, state valid/invalid and the exact rule that decides it.
2. Your new attributes were declared `stability: development`. What obligation does that impose on *consumers* of your telemetry, and what must you do before you may mark one `stable`?
3. The convention forbids using a name that is *also* a namespace (e.g. an attribute literally named `payment` while `payment.*` exists). What concrete parsing/collision problem does this rule prevent in dotted attribute keys?
4. `requirement_level: required` vs `recommended` vs `conditionally_required` vs `opt_in` — which level means "emit it only when the user explicitly turns it on because it may be expensive or sensitive," and give a plausible payment example.

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Block 1 — Attribute Registry
1. **Declared vs referenced.** The *registry* holds one authoritative declaration of each attribute (its `type`, `stability`, `brief`, `examples`). Span, metric and resource groups then `ref:` that id and only override *contextual* fields such as `requirement_level` or `sampling_relevant`. Separation guarantees a single definition of `http.request.method` so its type and stability can't diverge between the HTTP‑span and HTTP‑metric usages — one source of truth, many contexts.
2. When the observed method is not in the known enum, the instrumentation sets `http.request.method` to the sentinel **`_OTHER`** and records the raw value in **`http.request.method_original`**. This caps cardinality on the enum while preserving the original string for debugging.
3. The website docs are **generated** from the model YAML (historically via the build tooling, now Weaver). The rendered Markdown can lag or reformat; the YAML in `open-telemetry/semantic-conventions/model/` is the normative source, which is why you grep the model, not the HTML.

### Block 2 — Resource conventions
1. If neither `OTEL_SERVICE_NAME` nor `service.name` is set, the SDK emits the default **`unknown_service`** (often `unknown_service:<process>`, e.g. `unknown_service:python`). It is an anti‑pattern because every un‑named workload collapses into the same series/grouping in the backend, destroying per‑service isolation and making alerts and quotas meaningless.
2. The **SDK** populates `telemetry.sdk.*` automatically; their requirement level is **Required**, so a conformant SDK must always attach them. They identify which SDK/language/version produced the data — essential for triaging producer‑side bugs.
3. The rename `deployment.environment` → `deployment.environment.name` is a normal step in an attribute's **stability lifecycle** (development → stable, sometimes via rename/deprecation). A schema‑aware backend correlates old and new via the **Telemetry Schema** `rename_attributes` transformation keyed off the Resource's `schema_url` (see Block 5).
4. `service.instance.id` is deliberately **high cardinality** (one value per replica). On a Resource it is fine — it identifies which pod emitted a stream. As a **metric data‑point** attribute it would multiply every time series by the replica count (and churn on every restart/redeploy), causing a cardinality explosion. Keep per‑replica identity on the Resource, keep metric dimensions low‑cardinality.

### Block 3 — HTTP spans
1. The name uses `http.route` (the low‑cardinality **template**, e.g. `/users/{id}`) so that all requests to the same handler share one span name. If an implementation names spans with the raw `url.path`, every distinct id (`/users/42`, `/users/99`, …) becomes a new operation name — a **cardinality explosion** that breaks aggregation, top‑N by operation, and service maps.
2. `http.route` is the *matched server‑side route template* from the receiving application's router. A client does not know the callee's route template — it only knows the URL it dialed. Hence `http.route` is **server‑only**, and clients carry `url.full` instead.
3. Status→Error rules differ by kind. For **Client** spans, a `4xx` **or** `5xx` response status sets span `Status = Error`. For **Server** spans, only **`5xx`** sets `Error` — a `4xx` (e.g. `404`, `403`) is a valid, expected outcome of a correct server and stays `Unset`. (A transport failure with no response sets `Error` on either side.)
4. Factoring `server.*`, `client.*`, `network.*` out of `http.*` lets **non‑HTTP** protocols (gRPC/RPC, database, messaging) reuse the exact same address/port/protocol attributes. One `server.address` convention means a single dashboard filter works across all protocols instead of `http.host`, `db.host`, `rpc.host`, etc.

### Block 4 — Metrics
1. The stable `http.server.request.duration` (unit `s`, seconds) replaced the experimental **`http.server.duration`**, which used **milliseconds (`ms`)**. If both feed one histogram/percentile query, values differ by 1000× so buckets and computed p50/p95/p99 are meaningless — a `0.042 s` point and a `42 ms` point are the same latency but land in wildly different buckets.
2. `{request}` is a UCUM **annotation**: still dimensionless, but it documents *what is being counted*. It is preferred over a bare `1` because it self‑describes the unit ("requests") without changing the numeric semantics, aiding humans and unit‑aware backends. Bare `1` is reserved for genuinely unitless ratios/fractions.
3. Rule: **metric** data‑point attributes must be **low cardinality** (`http.request.method`, `http.response.status_code`, `http.route`, and negotiated protocol fields). High‑cardinality span attributes — `url.path`, `url.full`, `url.query`, `user_agent.original`, `client.address` — **must not** be metric dimensions, because each distinct value spawns a new time series, and unbounded dimensions cause a cardinality explosion in the TSDB.
4. Instrument kind determines aggregation temporality and monotonicity semantics on the wire (a Histogram carries buckets/sum/count; a Counter is monotonic cumulative; an UpDownCounter is non‑monotonic). A backend cannot "repair" a Counter into a Histogram after the fact because the raw distribution was never transmitted — so the wrong instrument kind is an irrecoverable convention violation, not a cosmetic one.

### Block 5 — Schema URLs & stability opt‑in
1. The Resource schema version reflects the **SDK/resource‑detector** era, while each Instrumentation Scope's schema version reflects the era of **that specific library's** instrumentation. A single process can run an SDK built against 1.27.0 while loading an older instrumentation library still emitting 1.20.0 attributes — two schema URLs in one batch is the honest representation of that mix.
2. `http/dup` emits **both** legacy and stable attributes on every HTTP span, roughly doubling HTTP attribute volume (more bytes, more storage, more processing). Teams accept it only during a **bounded cutover window**, so dashboards/alerts written against the old names keep working while new ones are migrated; once migration completes you switch to `http` (new only).
3. A schema‑aware processor reads each stream's `schema_url`, looks up the Telemetry Schema, and applies the `rename_attributes` transformation chain between versions (`deployment.environment` → `deployment.environment.name`). Both streams are normalized to one target version, so a query on `deployment.environment.name` returns data that arrived under either name — no dual dashboards.
4. If the payload is 1.27.0 but stamped `schema_url = 1.20.0`: the **URL resolves** and the **attributes are individually valid**, so the citation‑style checks pass. What breaks is the schema‑aware transformation: a processor applies 1.20.0→target renames to attributes that are *already* in the new form, corrupting or dropping them. The schema URL is a **claim about the payload**; when the claim doesn't match, every consumer that trusts it mis‑transforms the data — the same failure class as a URL that resolves but doesn't say what you claim.

### Block 6 — Authoring conventions
1. Candidate verdicts:
   - `payment.card.type` — **valid** (lowercase, dotted namespaces, single‑word elements).
   - `Payment.CardType` — **invalid** (uppercase letters; `CardType` should be `card_type` or split into namespaces).
   - `payment.card_holder.name` — **valid** (`card_holder` uses an underscore to join words *within one element*).
   - `payment` (used as both namespace and attribute) — **invalid** (a namespace segment must not also be a leaf attribute name).
   - `user_agent.original` — **valid** (underscore joins the words of the `user_agent` element; `original` is the leaf).
   - `http` — **invalid** as an attribute name (it is a namespace, never a leaf).
2. `stability: development` (experimental) means consumers **must not** treat those attributes as stable: names/types may change without notice, so don't build durable dashboards/alerts you can't afford to fix. Before marking one `stable`, it must go through the project's stability process — public review and a commitment that the name/type/semantics won't change without deprecation. (For your *own* private attributes, "stable" is your own guarantee, but the discipline is the same.)
3. Attribute keys are dotted paths parsed as a namespace hierarchy. If `payment` were both a value‑bearing attribute and the prefix of `payment.card.brand`, the key `payment` is ambiguous — is it a scalar or the root of a map? Forbidding the collision keeps every dotted key unambiguously either a namespace prefix or a leaf, which is essential for backends that model attributes as nested structures.
4. **`opt_in`** means "emit only when the user explicitly enables it," used for attributes that are expensive to compute or **sensitive**. Payment example: a full cardholder identifier or the raw request body — valuable for debugging but privacy‑sensitive, so it defaults off and is turned on deliberately. (`conditionally_required` differs: it *must* be emitted when a stated condition holds, e.g. `http.response.status_code` when a response was received.)

</details>

---

### Sources
- Semantic Conventions (spec index) — <https://opentelemetry.io/docs/specs/semconv/>
- Attribute Naming — <https://opentelemetry.io/docs/specs/semconv/general/naming/>
- Attribute Registry — <https://opentelemetry.io/docs/specs/semconv/registry/attributes/>
- Resource conventions — <https://opentelemetry.io/docs/specs/semconv/resource/>
- HTTP spans — <https://opentelemetry.io/docs/specs/semconv/http/http-spans/>
- HTTP metrics — <https://opentelemetry.io/docs/specs/semconv/http/http-metrics/>
- General metrics guidelines / UCUM — <https://opentelemetry.io/docs/specs/semconv/general/metrics/> · <https://ucum.org/>
- HTTP migration & `OTEL_SEMCONV_STABILITY_OPT_IN` — <https://opentelemetry.io/docs/specs/semconv/non-normative/http-migration/>
- Telemetry Schemas — <https://opentelemetry.io/docs/specs/otel/schemas/>
- Model repository — <https://github.com/open-telemetry/semantic-conventions>
- Weaver tooling — <https://github.com/open-telemetry/weaver>
- OTCA curriculum — <https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf>