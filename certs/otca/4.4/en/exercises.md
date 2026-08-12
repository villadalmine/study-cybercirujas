# 4.4 Schema Management

A *telemetry schema* is a versioned, machine-readable description of a set of semantic conventions plus the transformations that carry telemetry from one version to the next. Every Resource and every InstrumentationScope can advertise a **Schema URL** (e.g. `https://opentelemetry.io/schemas/1.21.0`); backends and the Collector use that URL to normalize data produced against different convention versions instead of forcing every producer to upgrade in lock-step.

## Prerequisites

- Docker (to run `otel/opentelemetry-collector-contrib`), **with egress to `opentelemetry.io`** for Exercise 4.
- Python 3.10+ and `pip` (Exercise 1). Optionally Go 1.21+ (Exercise 1 & 5 snippets).
- `curl` and a text editor.

```bash
python3 -m venv venv && source venv/bin/activate
pip install "opentelemetry-api==1.29.0" "opentelemetry-sdk==1.29.0"
```

> Pin versions to whatever your environment provides; the mechanics below are stable across recent releases. The `schema` processor is an **alpha / in-development** contrib component — confirm its stability level for your Collector version.

---

## Exercise 1 — Emit a Schema URL from the SDK (Resource + Scope)

The schema URL is set in *two independent places*: on the Resource (once per process) and on each InstrumentationScope (once per tracer/meter/logger). You will set both and observe them.

**Steps**

1. Save this as `emit.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import (
       ConsoleSpanExporter,
       SimpleSpanProcessor,
   )

   SCHEMA = "https://opentelemetry.io/schemas/1.21.0"

   # (a) Resource-level schema URL — describes the entity producing telemetry.
   resource = Resource.create(
       {"service.name": "checkout"},
       schema_url=SCHEMA,
   )

   provider = TracerProvider(resource=resource)
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)

   # (b) Scope-level schema URL — describes the convention version THIS library follows.
   tracer = trace.get_tracer(
       "checkout.instrumentation",
       "1.0.0",
       schema_url=SCHEMA,
   )

   with tracer.start_as_current_span("checkout") as span:
       span.set_attribute("http.request.method", "POST")  # 1.21.0 name
   ```

2. Run it and read the JSON emitted to the console:

   ```bash
   python emit.py
   ```

   Expected (abridged) output — note the `schema_url` on the `resource` block:

   ```json
   {
       "name": "checkout",
       "kind": "SpanKind.INTERNAL",
       "attributes": { "http.request.method": "POST" },
       "resource": {
           "attributes": {
               "telemetry.sdk.language": "python",
               "telemetry.sdk.name": "opentelemetry",
               "telemetry.sdk.version": "1.29.0",
               "service.name": "checkout"
           },
           "schema_url": "https://opentelemetry.io/schemas/1.21.0"
       }
   }
   ```

3. (Go equivalent — idiomatic form using the `semconv` constant, which *is* the schema URL for that package version):

   ```go
   import (
       "go.opentelemetry.io/otel"
       "go.opentelemetry.io/otel/sdk/resource"
       "go.opentelemetry.io/otel/trace"
       semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
   )

   res, _ := resource.New(ctx,
       resource.WithSchemaURL(semconv.SchemaURL),                 // resource-level
       resource.WithAttributes(semconv.ServiceNameKey.String("checkout")),
   )

   tracer := otel.Tracer(
       "checkout.instrumentation",
       trace.WithInstrumentationVersion("1.0.0"),
       trace.WithSchemaURL(semconv.SchemaURL),                    // scope-level
   )
   ```

**Comprehension**

- **Q1.** The schema URL appears at two levels — Resource and InstrumentationScope. Why is the *scope*-level schema URL necessary in addition to the resource-level one? Give a concrete scenario where a single process needs two different scope schema URLs.
- **Q2.** If you set `schema_url` on the tracer but omit it from `Resource.create(...)`, what does each carry, and can a backend still tell which convention version the *span attributes* follow?

---

## Exercise 2 — Locate the Schema URL on the wire (OTLP)

You will send a hand-crafted OTLP/JSON trace and read exactly where the schema URL lands in the OTLP envelope, using the Collector's `debug` exporter.

**Steps**

1. Create `collector.yaml` (no schema processing yet — pure passthrough):

   ```yaml
   receivers:
     otlp:
       protocols:
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
   ```

2. Start the Collector:

   ```bash
   docker run --rm -p 4318:4318 \
     -v "$(pwd)/collector.yaml:/etc/otelcol-contrib/config.yaml" \
     otel/opentelemetry-collector-contrib:0.116.0
   ```

3. Create `trace.json`. Note `schemaUrl` sits **beside** (not inside) `resource`, and **beside** `scope`:

   ```json
   {
     "resourceSpans": [
       {
         "resource": {
           "attributes": [
             { "key": "service.name", "value": { "stringValue": "orders-db-client" } }
           ]
         },
         "schemaUrl": "https://opentelemetry.io/schemas/1.4.0",
         "scopeSpans": [
           {
             "scope": { "name": "cassandra.instrumentation", "version": "0.9.0" },
             "schemaUrl": "https://opentelemetry.io/schemas/1.4.0",
             "spans": [
               {
                 "traceId": "5b8efff798038103d269b633813fc60c",
                 "spanId": "eee19b7ec3c1b174",
                 "name": "SELECT orders",
                 "kind": 3,
                 "startTimeUnixNano": "1700000000000000000",
                 "endTimeUnixNano": "1700000000500000000",
                 "attributes": [
                   { "key": "db.system", "value": { "stringValue": "cassandra" } },
                   { "key": "db.cassandra.keyspace", "value": { "stringValue": "orders" } }
                 ]
               }
             ]
           }
         ]
       }
     ]
   }
   ```

4. Send it:

   ```bash
   curl -s -X POST http://localhost:4318/v1/traces \
     -H "Content-Type: application/json" \
     --data-binary @trace.json
   ```

5. Read the Collector log. Both schema URLs surface, and the 1.4.0-era attribute passes through unchanged:

   ```
   ResourceSpans #0
   Resource SchemaURL: https://opentelemetry.io/schemas/1.4.0
   Resource attributes:
        -> service.name: Str(orders-db-client)
   ScopeSpans #0
   ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.4.0
   InstrumentationScope cassandra.instrumentation 0.9.0
   Span #0
       Name           : SELECT orders
       Kind           : Client
       Attributes:
            -> db.system: Str(cassandra)
            -> db.cassandra.keyspace: Str(orders)
   ```

**Comprehension**

- **Q3.** In the OTLP protobuf, on which messages does the *resource-level* `schema_url` field live for traces, metrics and logs, and on which messages does the *scope-level* `schema_url` field live?
- **Q4.** A backend ingests spans that carry **no** `schemaUrl` at either level. Which specific capability does the backend lose, and how does that manifest when two teams emit `http.method` vs `http.request.method`?

---

## Exercise 3 — Read the schema file: the transformation language

The schema URL points at a YAML *schema file* that enumerates, version by version, how attributes/metrics/events changed. Learn to read it.

**Steps**

1. Save this **illustrative** file as `schema-1.3.0.yaml`. It exercises every section and change type of file format `1.1.0`:

   ```yaml
   file_format: 1.1.0
   schema_url: https://example.com/schemas/1.3.0
   versions:
     1.3.0:
       all:                         # attribute rename applied to EVERY signal type
         changes:
           - rename_attributes:
               attribute_map:
                 k8s.cluster.name: kubernetes.cluster.name
       resources:                   # resource attributes only
         changes:
           - rename_attributes:
               attribute_map:
                 telemetry.auto.version: telemetry.distro.version
       spans:
         changes:
           - rename_attributes:
               attribute_map:
                 peer.service: network.peer.service
               apply_to_spans:      # limit the rename to these span names
                 - "HTTP GET"
                 - "HTTP POST"
       span_events:
         changes:
           - rename_events:
               name_map:
                 exception.stacktrace.v1: exception.stacktrace
           - rename_attributes:
               attribute_map:
                 message.type: rpc.message.type
               apply_to_events:
                 - message
       metrics:
         changes:
           - rename_metrics:
               process.runtime.jvm.gc.count: jvm.gc.count
           - rename_attributes:
               attribute_map:
                 state: process.state
               apply_to_metrics:
                 - system.memory.usage
           - split:                 # one metric -> several, keyed by an attribute
               apply_to_metric: system.paging.operations
               by_attribute: direction
               metrics_from_attributes:
                 system.paging.operations.in: in
                 system.paging.operations.out: out
       logs:
         changes:
           - rename_attributes:
               attribute_map:
                 log.severity: severity.text
     1.2.0:
   ```

2. Trace the semantics of each block:
   - Each `<version>:` section describes how to convert telemetry **from the previous version up to this version**.
   - `attribute_map` / `name_map` are written as **`old_name: new_name`**.
   - `all` is shorthand that expands to an attribute rename on resources, spans, span events, metric data points, and log records.
   - `apply_to_*` narrows a change to specific span/event/metric names.
   - `split` divides one metric's data points by the value of `by_attribute`, emits them as the named metrics, and **drops that attribute**.

3. Compare with a real, hosted schema to confirm the format:

   ```bash
   curl -s https://opentelemetry.io/schemas/1.9.0 | sed -n '1,40p'
   ```

   You will find the genuine `1.5.0` block renaming `db.cassandra.keyspace → db.name` (spans) and `system.processes.count → system.process.count` (metrics) — the change you will exploit in Exercise 4.

**Comprehension**

- **Q5.** Telemetry tagged `1.2.0` is converted to `1.3.0`. For a span named `"HTTP GET"` carrying `peer.service=payments`, list every change from the file that applies and the resulting attribute state.
- **Q6.** Describe exactly what the `split` change does to `system.paging.operations` data points (values, metric names, attributes) when converting **forward** to `1.3.0`.
- **Q7.** Does the `all` rename of `k8s.cluster.name` affect *metric* data point attributes? How does it coexist with the `metrics` section's own `rename_attributes` of `state`?
- **Q8.** How would a consumer convert telemetry **down** from `1.3.0` to `1.2.0` using this same file? What must the `split` change record for that reverse direction to work?

---

## Exercise 4 — Normalize cross-version telemetry with the schema processor

Now make the Collector *rewrite* old-convention telemetry to a target version automatically.

**Steps**

1. Edit `collector.yaml` to insert the `schema` processor and point it at target `1.9.0`:

   ```yaml
   receivers:
     otlp:
       protocols:
         http:
           endpoint: 0.0.0.0:4318
   processors:
     schema:
       prefetch:                                   # warm the cache at startup (optional)
         - https://opentelemetry.io/schemas/1.9.0
       targets:                                    # convert each matching family to this version
         - https://opentelemetry.io/schemas/1.9.0
   exporters:
     debug:
       verbosity: detailed
   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [schema]
         exporters: [debug]
   ```

2. Restart the Collector (it now needs network egress to fetch the schema file):

   ```bash
   docker run --rm -p 4318:4318 \
     -v "$(pwd)/collector.yaml:/etc/otelcol-contrib/config.yaml" \
     otel/opentelemetry-collector-contrib:0.116.0
   ```

3. Re-send the **same** `trace.json` from Exercise 2 (still tagged `1.4.0`, still carrying `db.cassandra.keyspace`):

   ```bash
   curl -s -X POST http://localhost:4318/v1/traces \
     -H "Content-Type: application/json" --data-binary @trace.json
   ```

4. Compare the debug output with Exercise 2. Two things changed — the schema URLs are rewritten to the target, and the attribute was renamed by the `1.5.0` rule:

   ```
   Resource SchemaURL: https://opentelemetry.io/schemas/1.9.0
   ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.9.0
   Span #0
       Name           : SELECT orders
       Attributes:
            -> db.system: Str(cassandra)
            -> db.name: Str(orders)
   ```

5. Send a span tagged with a schema family the processor does **not** target (e.g. change `schemaUrl` to `https://schemas.acme.internal/1.0.0`) and confirm it passes through untouched.

**Comprehension**

- **Q9.** After processing, `Resource SchemaURL` reads `1.9.0` and `db.cassandra.keyspace` became `db.name`. Explain the chain: which schema version's rule fired, in which direction, and why the *output* schema URL is now `1.9.0`.
- **Q10.** The processor reaches out to `opentelemetry.io`. What does `prefetch` buy you, and what happens to this processor in a fully air-gapped cluster? What would you have to change to make schema translation work there?
- **Q11.** Telemetry arrives whose schema URL belongs to a family absent from `targets`. What does the processor do with it, and why is that the correct default rather than dropping it?

---

## Exercise 5 — Diagnose schema conflicts and failures

Schema management fails in a few characteristic ways. Reproduce and reason about them.

**Steps**

1. **Resource merge conflict (Go).** Construct two resources with *different* schema URLs and merge them:

   ```go
   r1, _ := resource.New(ctx, resource.WithSchemaURL("https://opentelemetry.io/schemas/1.21.0"))
   r2, _ := resource.New(ctx, resource.WithSchemaURL("https://opentelemetry.io/schemas/1.24.0"))

   merged, err := resource.Merge(r1, r2)
   fmt.Println(err)     // cannot merge resource due to conflicting Schema URL
   fmt.Println(merged)  // empty resource
   ```

   `resource.Merge` returns `Empty()` **and** a non-nil error when both operands have non-empty, differing schema URLs.

2. **The real-world trigger.** This most often bites when `resource.Default()` (which carries the SDK's bundled `semconv` schema URL) is merged with a resource you built using a *different* `semconv/vX.Y.Z` import — for example after upgrading one instrumentation library that bumped its embedded semantic-conventions version.

3. **Missing schema URL.** Re-run Exercise 2 but delete both `schemaUrl` lines from `trace.json`. Observe that `Resource SchemaURL` / `ScopeSpans SchemaURL` no longer print — and that the `schema` processor from Exercise 4 can no longer transform those spans.

4. **Unreachable schema file.** Point a `targets` entry (or send telemetry) at a schema URL that 404s (e.g. `https://opentelemetry.io/schemas/9.9.9`) and watch the Collector logs for the fetch error.

**Comprehension**

- **Q12.** Why does `resource.Merge` refuse to merge two differing schema URLs instead of picking one? What does the returned resource contain?
- **Q13.** A service that started fine now panics/errors at startup with a "conflicting Schema URL" after a dependency bump. State the root cause and give **two** distinct fixes.
- **Q14.** The `schema` processor logs that it cannot fetch a schema file (network error / 404). What is the effect on the affected telemetry as it flows through the pipeline, and what monitoring signal would catch this in production?

---

## References (official sources)

- Telemetry Schemas — specification: <https://opentelemetry.io/docs/specs/otel/schemas/>
- Schema file format v1.1.0 (sections, `all`/`resources`/`spans`/`span_events`/`metrics`/`logs`, `split`): <https://opentelemetry.io/docs/specs/otel/schemas/file_format_v1.1.0/>
- Hosted OpenTelemetry schemas (browse real transformations): <https://opentelemetry.io/schemas/1.9.0>
- OTLP specification & proto (`schema_url` on `Resource*`/`Scope*` messages): <https://opentelemetry.io/docs/specs/otlp/> · <https://github.com/open-telemetry/opentelemetry-proto/blob/main/opentelemetry/proto/trace/v1/trace.proto>
- Resource SDK — schema URL semantics & merge rules: <https://opentelemetry.io/docs/specs/otel/resource/sdk/>
- Semantic Conventions (versioning that drives schema changes): <https://opentelemetry.io/docs/specs/semconv/>
- Collector `schemaprocessor` (config: `prefetch`, `targets`; stability): <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/schemaprocessor>
- Collector `debug` exporter: <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/debugexporter>

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** The Resource schema URL describes *the entity* (the service/process) and its resource attributes; the InstrumentationScope schema URL describes *which convention version a specific instrumentation library used for the signals it emitted*. They are decoupled because a single process runs many instrumentation libraries that upgrade independently. Concrete case: your HTTP client library was updated to emit `http.request.method` (scope schema `1.21.0`) while a legacy database library still emits `db.cassandra.keyspace` (scope schema `1.4.0`). Both live in the same process/Resource but must advertise different scope schema URLs so a consumer can normalize each correctly.

**Q2.** The tracer/scope carries `1.21.0`; the Resource carries an **empty** schema URL. A backend can still determine the convention version of the *span* attributes from the scope schema URL — that is precisely why the scope-level field exists. It just can't attribute a convention version to the *resource* attributes (e.g. it wouldn't know whether `telemetry.auto.version` vs `telemetry.distro.version` is expected).

**Q3.** Resource-level `schema_url` lives on **`ResourceSpans`**, **`ResourceMetrics`**, and **`ResourceLogs`**. Scope-level `schema_url` lives on **`ScopeSpans`**, **`ScopeMetrics`**, and **`ScopeLogs`**. In each message it is a top-level string field (field number 3), a sibling of the `resource`/`scope` and the data lists — not nested inside the `Resource` or `InstrumentationScope` messages themselves.

**Q4.** It loses the ability to **normalize/translate** across convention versions. Without a schema URL the backend cannot know which version a given attribute name belongs to, so it cannot map `http.method` and `http.request.method` onto the same logical field. The two teams' data then splits across two attribute keys — dashboards and alerts silently see half the traffic under each name, and cross-version queries require hand-maintained aliases.

**Q5.** Converting `1.2.0 → 1.3.0`, all changes in the `1.3.0` section that match apply, in order:
- `all`: `k8s.cluster.name → kubernetes.cluster.name` (if present on the span).
- `spans` `rename_attributes` with `apply_to_spans: ["HTTP GET","HTTP POST"]`: because the span name is `"HTTP GET"`, `peer.service` is renamed to `network.peer.service`. Result: the span now carries `network.peer.service=payments` (and any `k8s.cluster.name` is renamed). A span named differently (e.g. `"GET /cart"`) would keep `peer.service` unchanged, since the rename is gated by span name.

**Q6.** Forward to `1.3.0`, `split` takes every data point of `system.paging.operations`, reads its `direction` attribute, and routes it: points with `direction=in` become the new metric **`system.paging.operations.in`**, points with `direction=out` become **`system.paging.operations.out`**. The numeric values are preserved; the original `system.paging.operations` metric disappears and the `direction` attribute is **removed** from the resulting data points (its information is now encoded in the metric name).

**Q7.** Yes — `all` renames the attribute on *every* signal type, including metric data point attributes, so `k8s.cluster.name → kubernetes.cluster.name` also applies to metrics. It coexists with the `metrics`-section rename of `state → process.state` because they target *different* attributes; both renames apply and do not conflict. (`all` is simply expanded into a rename on each signal; a per-signal change to a different key composes independently.)

**Q8.** Converting **down** `1.3.0 → 1.2.0`, the consumer applies the `1.3.0` changes **in reverse and inverted**: attribute/metric/event maps are read `new_name → old_name` (e.g. `network.peer.service → peer.service`, `jvm.gc.count → process.runtime.jvm.gc.count`). Schema transformations are designed to be reversible. For `split` to reverse, the change definition must record the attribute it split on (`direction`) and the value each derived metric represents (`system.paging.operations.in → in`), so the reverse ("merge") re-creates `system.paging.operations` and re-adds `direction=in`/`direction=out` from the metric names.

**Q9.** The span entered tagged `1.4.0`. The processor identifies the schema *family* (`https://opentelemetry.io/schemas/…`) and the target `1.9.0`, fetches the `1.9.0` schema file, and applies every change with version in `(1.4.0, 1.9.0]` in the **forward** direction. The `1.5.0` block's `spans` rule `db.cassandra.keyspace → db.name` fires, renaming the attribute. Because the telemetry has been translated *to* `1.9.0`, the processor rewrites both the Resource and Scope schema URLs to `1.9.0`, so downstream consumers see internally consistent `1.9.0` data.

**Q10.** `prefetch` downloads and caches the listed schema files at startup, avoiding a fetch (and its latency/failure) on the first matching batch. In a fully air-gapped cluster the processor cannot reach `opentelemetry.io`, so it cannot obtain the transformation rules and cannot translate. To make it work you must host the schema files on an internal server, use internal schema URLs (`https://schemas.corp.internal/…`), **and ensure producers emit those internal URLs** — the processor fetches the exact URL the telemetry advertises; there is no bundled offline copy.

**Q11.** It **passes the telemetry through unchanged**. The processor only rewrites families listed in `targets`; anything else is out of scope. That is correct because dropping telemetry merely for lacking a known schema mapping would cause silent data loss — passthrough preserves the data (still tagged with its original schema URL) so another processor/backend can handle it.

**Q12.** Two differing non-empty schema URLs are genuinely incompatible: the merged resource can't truthfully claim to follow *both* convention versions, and silently picking one could mislabel the other operand's attributes. So `Merge` treats it as an error rather than guessing. The returned resource is `Empty()` (no attributes, empty schema URL), paired with a non-nil `cannot merge resource due to conflicting Schema URL` error.

**Q13.** Root cause: a dependency upgrade bumped the `semconv` version bundled in one component, so two resources being merged (typically `resource.Default()` and your custom resource, or two libraries' resources) now advertise *different* schema URLs, and `resource.Merge` rejects the combination. Two fixes: (a) **align the semconv versions** — import the same `go.opentelemetry.io/otel/semconv/vX.Y.Z` everywhere so all resources share one schema URL; or (b) **construct your resource with the matching schema URL explicitly** (or without a schema URL on one side, since merging empty-with-nonempty is allowed) so there is no conflict. (Upgrading the whole SDK/semconv set together is the durable version of fix (a).)

**Q14.** The processor cannot build the translation for that schema, so it logs an error and the affected telemetry is **not converted** — depending on the component version it is passed through with its original schema URL (or the batch is refused); it is not silently "successfully translated." The operational consequence is mixed-version data reaching your backend. Catch it in production by alerting on the Collector's own internal metrics/logs — the processor's error logs plus the pipeline's `otelcol_processor_*` / refused-vs-accepted counters — rather than waiting to notice split attribute names downstream.

</details>