# OTCA 3.5 — Transforming Data

> **Domain 3 · The OpenTelemetry Collector — Topic 3.5 (exam weight ≈ 5.2)**
>
> The Collector's value is not that it *moves* telemetry, but that it *reshapes* it in flight: enriching resources, normalizing attribute keys, dropping noise, masking PII, aggregating metric labels, and even deriving new signals from existing ones. This topic is where you learn to do that deterministically, with the processors and the **OpenTelemetry Transformation Language (OTTL)**.
>
> These are hands-on labs. You will run a real Collector, push crafted OTLP payloads at it, and read the `debug` exporter output to *prove* each transformation happened. Do not skip the observation steps — reading the transformed output is the whole point.

---

## Objectives

By the end you will be able to:

- Order processors correctly in a pipeline and explain why order changes the result.
- Use the **attributes** processor (`insert`/`update`/`upsert`/`delete`/`hash`/`extract`) and the **resource** processor.
- Write **OTTL** statements in the **transform** processor across `resource`, `span`, `metric`, `datapoint`, and `log` contexts.
- Drop telemetry with the **filter** processor using OTTL conditions.
- Mask sensitive values with the **redaction** processor.
- Rename and aggregate metric labels with the **metricstransform** processor.
- Derive metrics from traces with the **spanmetrics** connector.

**Reference distribution:** OpenTelemetry Collector *Contrib* (`otelcol-contrib`), because `transform`, `filter`, `redaction`, `metricstransform`, and the `spanmetrics` connector ship only in Contrib, not in the Core distribution.

Sources:
- Collector overview — https://opentelemetry.io/docs/collector/
- Transform processor — https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/transformprocessor/README.md
- OTTL grammar & functions — https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/README.md and https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/ottlfuncs/README.md

---

## Lab 0 — Setup and the observation harness

You need a running Collector and a way to see what comes out the other end. The `debug` exporter (the successor to the old `logging` exporter) prints decoded telemetry to stdout.

1. Download the Contrib Collector binary for your platform from the releases page (https://github.com/open-telemetry/opentelemetry-collector-contrib/releases) and confirm it runs:

   ```bash
   otelcol-contrib --version
   # otelcol-contrib version 0.109.0   (any recent 0.10x is fine)
   ```

2. Create `base.yaml`, the harness you will extend in every exercise. It accepts OTLP over gRPC (4317) and HTTP (4318) and echoes everything to the console with full detail:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   exporters:
     debug:
       verbosity: detailed        # prints resource/scope/attributes, not just counts

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: []
         exporters: [debug]
   ```

3. Start it:

   ```bash
   otelcol-contrib --config ./base.yaml
   ```

   Leave this terminal open — it is your output window.

4. In a second terminal, save this raw OTLP/HTTP JSON span as `span.json`. It deliberately contains a health-check route, a PII e-mail, and a credit-card number — the raw material for later exercises:

   ```json
   {
     "resourceSpans": [{
       "resource": {
         "attributes": [
           {"key": "service.name", "value": {"stringValue": "checkout"}},
           {"key": "host.name", "value": {"stringValue": "node-7"}}
         ]
       },
       "scopeSpans": [{
         "scope": {"name": "manual-test"},
         "spans": [{
           "traceId": "5b8efff798038103d269b633813fc60c",
           "spanId": "eee19b7ec3c1b174",
           "name": "GET /user/12345/profile",
           "kind": 2,
           "startTimeUnixNano": "1700000000000000000",
           "endTimeUnixNano":   "1700000000100000000",
           "attributes": [
             {"key": "http.request.method", "value": {"stringValue": "GET"}},
             {"key": "http.route",          "value": {"stringValue": "/health"}},
             {"key": "user.email",          "value": {"stringValue": "alice@example.com"}},
             {"key": "credit_card",         "value": {"stringValue": "4716123456789012"}}
           ]
         }]
       }]
     }]
   }
   ```

5. Send it and confirm the round-trip:

   ```bash
   curl -sS -X POST http://localhost:4318/v1/traces \
     -H "Content-Type: application/json" \
     -d @span.json
   # {"partialSuccess":{}}   <- empty partialSuccess means fully accepted
   ```

   The Collector terminal should print the span with all four attributes, e.g.:

   ```
   Span #0
       Trace ID       : 5b8efff798038103d269b633813fc60c
       ID             : eee19b7ec3c1b174
       Name           : GET /user/12345/profile
       Kind           : Server
       Attributes:
            -> http.request.method: Str(GET)
            -> http.route: Str(/health)
            -> user.email: Str(alice@example.com)
            -> credit_card: Str(4716123456789012)
   ```

**Checkpoint questions — Lab 0**

- **Q0.1** Why does this lab use `otelcol-contrib` rather than the Core `otelcol` binary?
- **Q0.2** What does an empty `{"partialSuccess":{}}` in the OTLP/HTTP response body tell you, and what would a non-empty `rejectedSpans` count mean?
- **Q0.3** In `verbosity: detailed`, the field prints `Str(...)` next to each attribute. Why does the value type matter when you later write OTTL conditions that compare an attribute to `"/health"`?

---

## Lab 1 — The attributes and resource processors

The attributes processor edits **signal-level** attributes (span, metric datapoint, or log attributes). The resource processor edits **resource-level** attributes (the `service.name`, `host.name` block that identifies *what produced* the telemetry). Confusing the two scopes is the single most common mistake.

1. Create `01-attributes.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   processors:
     resource:
       attributes:
         - key: deployment.environment
           value: production
           action: insert           # only if absent
         - key: host.name
           action: delete            # strip a high-cardinality identifier

     attributes:
       actions:
         - key: team
           value: payments
           action: insert            # add if missing
         - key: http.request.method
           value: UNKNOWN
           action: update            # change ONLY if it already exists
         - key: http.status_code
           value: 200
           action: upsert            # insert-or-update
         - key: user.email
           action: hash              # irreversible one-way hash of the value
         - key: user_id
           from_attribute: http.route
           pattern: ^/user/(?P<user_id>\d+)/.*$   # (extract shown in transform lab too)
           action: extract

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [resource, attributes]
         exporters: [debug]
   ```

2. Restart the Collector with this config and re-send `span.json`:

   ```bash
   otelcol-contrib --config ./01-attributes.yaml
   # (other terminal)
   curl -sS -X POST http://localhost:4318/v1/traces -H "Content-Type: application/json" -d @span.json
   ```

3. In the output, verify each action. You should now see (abbreviated):

   ```
   Resource attributes:
        -> service.name: Str(checkout)
        -> deployment.environment: Str(production)     # inserted; host.name is gone
   ...
   Span #0
       Attributes:
            -> http.request.method: Str(GET)           # update kept GET (it existed)
            -> http.route: Str(/health)
            -> user.email: Str(2bd806c9...)            # hashed, no longer readable
            -> credit_card: Str(4716123456789012)
            -> team: Str(payments)                     # inserted
            -> http.status_code: Int(200)              # upserted (was absent)
   ```

4. Now send a second span **without** `http.request.method` (delete that attribute from a copy of `span.json`) and observe that `update` does **not** create it — proving `update` ≠ `upsert`.

**Checkpoint questions — Lab 1**

- **Q1.1** For each action, state whether it acts when the key is absent, present, or both: `insert`, `update`, `upsert`, `delete`.
- **Q1.2** The `host.name` deletion is on the **resource** processor and `team` is on the **attributes** processor. Why could you not swap them — what would happen if you put `key: host.name / action: delete` under the attributes processor?
- **Q1.3** Why is `hash` on `user.email` preferable to `delete` when your dashboards still need to count *distinct users* but must not expose the address?
- **Q1.4** The `extract` action populated `user_id` from a regex named capture group. Given `http.route` was `/health` (not `/user/12345/...`), did `user_id` get created for our span? Why or why not?

---

## Lab 2 — The transform processor and OTTL

The attributes processor is declarative and limited. **OTTL** is a small expression language that gives you conditionals, functions, and multiple **contexts**. In the transform processor you group statements by `context` — `resource`, `scope`, `span`, `spanevent`, `metric`, `datapoint`, or `log` — and the Collector runs each statement against every matching item.

Key vocabulary:
- **Editor** functions mutate telemetry and return nothing: `set`, `delete_key`, `keep_keys`, `replace_pattern`, `limit`, `truncate_all`, `merge_maps`.
- **Converter** functions compute and return a value: `SHA256`, `Concat`, `Split`, `IsMatch`, `Substring`, `Hour`, `ConvertCase`.
- Every statement may end with a `where <condition>` guard.
- `error_mode: ignore | silent | propagate` controls what happens when a statement errors on a record (e.g. a missing key).

1. Create `02-transform.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   processors:
     transform:
       error_mode: ignore
       trace_statements:
         - context: resource
           statements:
             # Keep only the resource keys we care about, drop the rest.
             - keep_keys(attributes, ["service.name", "deployment.environment"])
         - context: span
           statements:
             # 1) Normalize a high-cardinality name into a route template.
             - replace_pattern(name, "/user/[0-9]+/", "/user/{id}/")
             # 2) Derive a boolean-ish attribute only for health checks.
             - set(attributes["is_synthetic"], true) where attributes["http.route"] == "/health"
             # 3) Irreversibly hash PII with an explicit algorithm.
             - set(attributes["user.email"], SHA256(attributes["user.email"])) where attributes["user.email"] != nil
             # 4) Mark the span as an error if it took too long (fabricated rule).
             - set(status.code, STATUS_CODE_ERROR) where (end_time_unix_nano - start_time_unix_nano) > 90000000
             # 5) Defensive hygiene: cap attribute count and value length.
             - limit(attributes, 128, ["service.name"])
             - truncate_all(attributes, 4096)

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [transform]
         exporters: [debug]
   ```

2. Restart and send `span.json`. Verify:
   - `Name` became `GET /user/{id}/profile`.
   - `is_synthetic: Bool(true)` was added (route is `/health`).
   - `user.email` is now a 64-hex-char SHA-256 digest.
   - Our span lasted `100ms` (100000000 ns) > 90ms, so `Status.Code` is `Error`.

   ```
   Span #0
       Name           : GET /user/{id}/profile
       Status code    : Error
       Attributes:
            -> http.route: Str(/health)
            -> user.email: Str(2bd806c9f...e3b0c44)   # SHA256 digest
            -> is_synthetic: Bool(true)
   ```

3. Experiment with `error_mode`. Add a statement that references a key present in only some spans, e.g. `set(attributes["x"], Substring(attributes["missing"], 0, 3))`. With `error_mode: ignore`, the bad record is passed through untouched and processing continues; switch to `propagate` and observe the Collector logging the statement error for that record.

**Checkpoint questions — Lab 2**

- **Q2.1** Which of these are editors and which are converters: `set`, `SHA256`, `keep_keys`, `IsMatch`, `truncate_all`? What is the practical consequence of that distinction — can you write `keep_keys(...) == true`?
- **Q2.2** The `keep_keys` statement is in the `resource` context and `replace_pattern(name, ...)` is in the `span` context. What happens if you move `keep_keys(attributes, [...])` into the `span` context by mistake — which attributes does it then filter?
- **Q2.3** Explain, using the `set(status.code, ...) where duration > 90ms` example, why `where` guards matter for `error_mode`. If `end_time_unix_nano` were missing, how would `ignore` vs `propagate` differ?
- **Q2.4** Both Lab 1 and Lab 2 hashed `user.email`. Why might a security reviewer prefer the transform-processor `SHA256(...)` form over the attributes-processor `hash` action?

---

## Lab 3 — Dropping data with the filter processor

Transforming includes *removing*. The filter processor evaluates OTTL **conditions** (not statements); when a condition is true, the record is **dropped** from the pipeline. This is how you shed health-check noise, debug logs, or a chatty metric before it costs you money at the backend.

1. Create `03-filter.yaml`. It drops health-check spans and debug-level logs:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   processors:
     filter/drop_noise:
       error_mode: ignore
       traces:
         span:
           - 'attributes["http.route"] == "/health"'
           - 'IsMatch(name, ".*(healthz|readyz|livez).*")'
       logs:
         log_record:
           - 'severity_number < SEVERITY_NUMBER_INFO'   # drop TRACE/DEBUG
       metrics:
         datapoint:
           - 'attributes["state"] == "idle"'            # drop idle CPU datapoints

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [filter/drop_noise]
         exporters: [debug]
   ```

2. Restart and send `span.json`. Because `http.route == "/health"`, the span is dropped — the Collector terminal should print **nothing** for this request (or only a `{"partialSuccess":{}}` HTTP ack, with no decoded span).

3. Prove the negative case. Edit a copy of `span.json`, change `http.route` to `/checkout`, and re-send. Now the span *does* appear in the output, confirming the filter is selective and not dropping everything.

**Checkpoint questions — Lab 3**

- **Q3.1** In the filter processor, when a condition evaluates to **true**, is the record kept or dropped? Contrast that with a `where` clause in the transform processor.
- **Q3.2** The two `traces.span` conditions are OR-combined. If you needed "drop only when route is `/health` **and** method is `GET`", how would you express that in one OTTL condition?
- **Q3.3** The metrics rule uses `datapoint` context, not `metric` context. Why does dropping at datapoint granularity matter for a gauge like `system.cpu.time{state=idle|user|system}` — what would `metric`-context filtering on `name == "system.cpu.time"` do instead?
- **Q3.4** You place `filter/drop_noise` first in the pipeline, before `transform`. Give one cost reason and one correctness reason this ordering is usually right.

---

## Lab 4 — Masking sensitive values with the redaction processor

Hashing changes a value; redaction *masks* it while keeping the key, and can also enforce an allow-list so unexpected keys never leak. This is the compliance-grade tool for PANs, tokens, and secrets.

1. Create `04-redaction.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   processors:
     redaction:
       allow_all_keys: false          # anything not allowed/ignored is deleted
       allowed_keys:
         - http.request.method
         - http.route
         - credit_card                # allowed to exist, but its VALUE is inspected
       ignored_keys:
         - http.status_code           # never inspected, always kept
       blocked_values:                # regexes matched against allowed values
         - '4[0-9]{12}(?:[0-9]{3})?'  # Visa PAN
         - '5[1-5][0-9]{14}'          # MasterCard PAN
       summary: debug                 # add redaction.* meta-attributes

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [redaction]
         exporters: [debug]
   ```

2. Restart and send `span.json`. Verify:
   - `user.email` is **gone** (not in `allowed_keys`, `allow_all_keys: false`).
   - `credit_card` is present but **masked** (its value matched a blocked pattern).
   - Meta-attributes appear thanks to `summary: debug`.

   ```
   Span #0
       Attributes:
            -> http.request.method: Str(GET)
            -> http.route: Str(/health)
            -> credit_card: Str(****)
            -> redaction.masked.count: Int(1)
            -> redaction.masked.keys: Str(credit_card)
            -> redaction.allowed.count: Int(3)
   ```

3. Change the `credit_card` value in a copy of `span.json` to `not-a-card` and re-send. The key stays and the value is **not** masked, because it did not match any `blocked_values` regex — proving redaction masks by *value*, not by *key name*.

**Checkpoint questions — Lab 4**

- **Q4.1** With `allow_all_keys: false`, what happens to a key that is neither in `allowed_keys` nor `ignored_keys`? Which of our span's original attributes did that rule remove?
- **Q4.2** What is the difference between `ignored_keys` and `allowed_keys` — specifically, is an `ignored_keys` value checked against `blocked_values`?
- **Q4.3** `credit_card` was masked but `user.email` was removed entirely. If compliance required the *email* to be masked to `****` (kept, not deleted) rather than dropped, what two changes to this config achieve that?
- **Q4.4** Why is `summary: debug` operationally useful in a real pipeline, and why might you set it to `info` or omit it in production?

---

## Lab 5 — Reshaping metrics with the metricstransform processor

OTTL can edit metric datapoints, but **renaming metrics** and **aggregating away labels** (to cut cardinality) is the specialty of the metricstransform processor.

1. Save this metric as `metric.json` — a `system.cpu.time` sum split by `cpu` and `state`:

   ```json
   {
     "resourceMetrics": [{
       "resource": { "attributes": [{"key":"service.name","value":{"stringValue":"node-exporter"}}] },
       "scopeMetrics": [{
         "scope": {"name": "manual-test"},
         "metrics": [{
           "name": "system.cpu.time",
           "sum": {
             "aggregationTemporality": 2,
             "isMonotonic": true,
             "dataPoints": [
               {"asDouble": 10, "timeUnixNano":"1700000000000000000", "attributes":[{"key":"cpu","value":{"stringValue":"0"}},{"key":"state","value":{"stringValue":"user"}}]},
               {"asDouble": 20, "timeUnixNano":"1700000000000000000", "attributes":[{"key":"cpu","value":{"stringValue":"1"}},{"key":"state","value":{"stringValue":"user"}}]},
               {"asDouble":  5, "timeUnixNano":"1700000000000000000", "attributes":[{"key":"cpu","value":{"stringValue":"0"}},{"key":"state","value":{"stringValue":"system"}}]}
             ]
           }
         }]
       }]
     }]
   }
   ```

2. Create `05-metricstransform.yaml` — rename the metric and collapse the per-`cpu` dimension by summing:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   processors:
     metricstransform:
       transforms:
         - include: system.cpu.time
           action: update
           new_name: system.cpu.time.seconds        # rename
         - include: system.cpu.time.seconds
           action: update
           operations:
             - action: aggregate_labels
               label_set: [state]                    # keep 'state', drop 'cpu'
               aggregation_type: sum

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       metrics:
         receivers: [otlp]
         processors: [metricstransform]
         exporters: [debug]
   ```

3. Restart and send:

   ```bash
   curl -sS -X POST http://localhost:4318/v1/metrics -H "Content-Type: application/json" -d @metric.json
   ```

   You started with 3 datapoints across 2 `cpu` values; after aggregating away `cpu` you should see **2** datapoints keyed only by `state`:

   ```
   Metric #0
        Name: system.cpu.time.seconds
        DataPoints
        NumberDataPoint  Value: 30.0   Attributes: state=user     # 10 + 20
        NumberDataPoint  Value:  5.0   Attributes: state=system
   ```

**Checkpoint questions — Lab 5**

- **Q5.1** Why does the second transform block use `include: system.cpu.time.seconds` and not the original name? What does this tell you about how sequential transforms chain?
- **Q5.2** `aggregate_labels` used `aggregation_type: sum`. For a metric that was a gauge of temperature per rack, why would `sum` be wrong, and which aggregation type would you pick?
- **Q5.3** How does dropping the `cpu` label reduce backend cost, and what information is irreversibly lost by doing so?
- **Q5.4** metricstransform and the OTTL transform processor can both touch metric attributes. Name one thing metricstransform does that OTTL (`datapoint` context) cannot do as cleanly.

---

## Lab 6 — Deriving new signals: the spanmetrics connector

The most powerful "transformation" turns one signal *type* into another. A **connector** is an exporter on one pipeline and a receiver on another. The `spanmetrics` connector consumes spans and **produces** request-count and latency-histogram metrics (the R.E.D. method) without any app changes.

1. Create `06-spanmetrics.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   connectors:
     spanmetrics:
       histogram:
         explicit:
           buckets: [5ms, 10ms, 50ms, 100ms, 250ms, 1s]
       dimensions:
         - name: http.route
         - name: http.request.method
           default: GET
       metrics_flush_interval: 5s

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       traces:                       # spans go IN to the connector
         receivers: [otlp]
         exporters: [spanmetrics]
       metrics:                      # derived metrics come OUT of the connector
         receivers: [spanmetrics]
         exporters: [debug]
   ```

2. Restart and send `span.json` a few times within the flush interval:

   ```bash
   for i in 1 2 3; do
     curl -sS -X POST http://localhost:4318/v1/traces -H "Content-Type: application/json" -d @span.json
   done
   ```

3. Within ~5 s the metrics pipeline prints derived metrics — a monotonic call counter and a latency histogram, dimensioned by the span attributes you listed:

   ```
   Metric #0
        Name: calls               # (a.k.a. traces.span.metrics.calls)
        NumberDataPoint  Value: 3.0
             -> http.route: Str(/user/{id}/profile-ish)   # from span name/route
             -> http.request.method: Str(GET)
             -> span.kind: Str(SPAN_KIND_SERVER)
   Metric #1
        Name: duration            # histogram, buckets from config
        HistogramDataPoint  Count: 3  Sum: 300  ...
   ```

**Checkpoint questions — Lab 6**

- **Q6.1** In the `service.pipelines` block, `spanmetrics` appears as an `exporters` entry under `traces` and a `receivers` entry under `metrics`. Explain in one sentence how that single component bridges two pipelines.
- **Q6.2** You listed `http.route` and `http.request.method` as `dimensions`. What is the cardinality risk of adding `user.email` as a dimension, and how does that connect back to Lab 4?
- **Q6.3** If you removed the `metrics` pipeline entirely but kept `spanmetrics` under `traces` exporters, what would happen to the generated metrics?
- **Q6.4** A teammate says "spanmetrics is a processor." Correct them: what is the defining architectural difference between a **processor** and a **connector**?

---

## Synthesis — a production-ordered pipeline

Combine what you built into one pipeline and reason about the order. Processors run **top-to-bottom** in the `processors:` list.

```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors:
        - memory_limiter        # 1. shed load first, protect the process
        - filter/drop_noise     # 2. drop what you'll never keep — cheapest to do early
        - redaction             # 3. mask PII before it can be copied downstream
        - transform             # 4. enrich/normalize the survivors
        - resource
        - attributes
        - batch                 # 5. batch LAST, just before export
      exporters: [debug, spanmetrics]
```

**Checkpoint questions — Synthesis**

- **S.1** Give the reasoning for two of these placements: why `memory_limiter` first, and why `batch` last.
- **S.2** If you moved `redaction` to run *after* `spanmetrics` had already exported, what compliance failure could occur?
- **S.3** A metric appears with the *old* name at your backend even though metricstransform renames it. Name two ordering/pipeline mistakes that could explain it.

---

<details>
<summary><strong>Answers</strong></summary>

**Lab 0**

- **A0.1** `transform`, `filter`, `redaction`, `metricstransform`, and the `spanmetrics` connector are all part of the *Contrib* distribution. The Core `otelcol` binary ships only a minimal, stable component set (basic receivers/exporters, `batch`, `memory_limiter`), so it cannot load these configs at all — it fails at startup with an "unknown type" error.
- **A0.2** An empty `partialSuccess` means the Collector accepted **all** items in the request. A non-empty response with `rejectedSpans: N` and an `errorMessage` means the receiver refused N spans (e.g. malformed, or a downstream component permanently errored) — the client should not retry those. This is the OTLP mechanism for partial acceptance.
- **A0.3** OTTL and the processors are **type-aware**. The attribute value is a *string* (`Str(...)`), so `attributes["http.route"] == "/health"` compares string to string and matches. If the value were an `Int` or `Bool`, that comparison would be false (or error), and you would need a converter. Reading the printed type tells you which comparisons and functions are valid.

**Lab 1**

- **A1.1** `insert`: acts only when the key is **absent**. `update`: acts only when the key is **present**. `upsert`: acts in **both** cases (insert-or-update). `delete`: acts only when **present** (removes it).
- **A1.2** `host.name` is a **resource** attribute — it lives in the resource block, not on the span. The attributes processor operates on **span/datapoint/log** attributes, so `action: delete` on `host.name` there would find nothing on the span and do nothing; the resource-level `host.name` would survive. Scope determines which map the processor can even see.
- **A1.3** `hash` is a deterministic one-way function: the same e-mail always maps to the same digest, so distinct-user counts and joins still work, but the original address cannot be recovered. `delete` would remove the value entirely and make per-user counting impossible.
- **A1.4** No. The `extract` regex required a `/user/<digits>/...` shape, but our `http.route` was `/health`, which does not match, so no `user_id` capture group fired and no attribute was created. `extract` only writes the named groups that actually matched.

**Lab 2**

- **A2.1** Editors: `set`, `keep_keys`, `truncate_all` (they mutate and return nothing). Converters: `SHA256`, `IsMatch` (they return a value). Consequence: you cannot write `keep_keys(...) == true` — an editor has no return value to compare. Converters are what you use inside `set(...)` or a `where`/filter condition.
- **A2.2** In the `span` context, `keep_keys(attributes, [...])` filters the **span's** attribute map, not the resource's. So it would delete every span attribute not in the list (dropping `http.route`, `user.email`, etc.) and leave the resource attributes untouched — the opposite of what the resource-context statement intended.
- **A2.3** The `where` guard means the `set` only runs on spans that satisfy the condition, so unrelated spans are never touched. If `end_time_unix_nano` were missing, evaluating `end - start` errors on that record: with `error_mode: ignore` the record passes through unchanged and processing continues; with `propagate` the error is surfaced (logged / returned) and can fail the batch. `ignore` favors resilience; `propagate` favors catching config bugs.
- **A2.4** The transform form is explicit about the algorithm (`SHA256`) and the condition (`where ... != nil`), and it lives in versioned OTTL you can review and test. The attributes-processor `hash` action hides the algorithm choice behind a keyword. For auditability, an explicit, named cryptographic function is easier to certify.

**Lab 3**

- **A3.1** In the filter processor, a condition that is **true drops** the record. That is the inverse of a transform `where` guard, where a true condition means "apply this mutation." Same OTTL boolean expression, opposite effect — a classic exam trap.
- **A3.2** Combine with `and` in a single condition: `'attributes["http.route"] == "/health" and attributes["http.request.method"] == "GET"'`. Two separate list entries are OR-combined, so they cannot express AND.
- **A3.3** `datapoint` context evaluates the condition per datapoint, so only the `state=idle` timeseries is dropped and `user`/`system` survive. `metric`-context filtering on `name == "system.cpu.time"` matches the **whole metric** and would drop *all* of its datapoints — you would lose `user` and `system` too. Granularity of the context determines what is removed.
- **A3.4** Cost: dropping early means the expensive `transform`/enrichment and export never run on data you were going to discard — you save CPU and egress. Correctness: filtering before enrichment ensures you never emit derived attributes or spanmetrics for records that should not exist at all.

**Lab 4**

- **A4.1** With `allow_all_keys: false`, any key not in `allowed_keys` and not in `ignored_keys` is **deleted**. In our span that removed `user.email` (it was neither allowed nor ignored).
- **A4.2** `allowed_keys` are kept **and their values are inspected** against `blocked_values`. `ignored_keys` are kept but **never inspected** — they bypass value redaction entirely. So a value under an ignored key is *not* checked against `blocked_values`; use `ignored_keys` only for values you know are safe.
- **A4.3** (1) Add `user.email` to `allowed_keys` so it is kept rather than deleted; (2) add a regex to `blocked_values` that matches an e-mail (e.g. `'[^@\s]+@[^@\s]+\.[^@\s]+'`) so its value is masked to `****`.
- **A4.4** `summary: debug` emits `redaction.masked.count`, `redaction.masked.keys`, etc., which let you verify the processor is actually catching secrets and alert if masking counts spike or drop to zero. In production you might lower it to `info` or omit it to avoid adding attributes (and cardinality) to every record once you trust the config.

**Lab 5**

- **A5.1** metricstransform applies transforms **in order**, and each sees the output of the previous one. After the first block renames the metric, its name is `system.cpu.time.seconds`, so the second block must `include` the *new* name to match it. Referencing the old name would match nothing.
- **A5.2** Temperature is a gauge; summing per-rack temperatures produces a meaningless total. You would use `mean` (average) — or keep the label and not aggregate at all. `aggregate_labels` requires an aggregation that is semantically valid for the metric type.
- **A5.3** Cost: each unique label-value combination is a separate timeseries billed/stored at the backend; dropping `cpu` collapses N per-core series into one, cutting cardinality by roughly the core count. Loss: you can no longer break the metric down per CPU core — that dimension is gone permanently for data transformed here.
- **A5.4** metricstransform can **aggregate datapoints across a label** (sum/mean the datapoints that share the surviving label set) and **rename the metric itself**. OTTL's `datapoint` context edits attributes on existing datapoints but does not merge datapoints together, and renaming the metric is done in `metric` context — metricstransform bundles both cleanly in one component.

**Lab 6**

- **A6.1** A connector is simultaneously an exporter (end of the `traces` pipeline) and a receiver (start of the `metrics` pipeline); spans flow *into* it and derived metrics flow *out*, so it bridges the two pipeline types through one component instance.
- **A6.2** `user.email` is effectively unique per user, so making it a metric dimension creates one timeseries per user — an unbounded cardinality explosion that can overwhelm the backend. That is exactly why Lab 4 masked/removed such fields: high-cardinality PII must not become a metric label.
- **A6.3** The connector would still generate metrics internally, but with no `metrics` pipeline consuming them there is nowhere for them to go — they are effectively dropped (and you'd typically get a config error or a dead-end warning, since the connector's output side is unused).
- **A6.4** A **processor** transforms telemetry *within a single pipeline of one signal type* and passes the same signal type along. A **connector** joins **two pipelines**, consuming one signal type and emitting another (or the same type into a different pipeline). Bridging pipelines is the connector's defining trait; a processor never leaves its pipeline.

**Synthesis**

- **S.1** `memory_limiter` first so that under load the Collector refuses/limits data before spending CPU on transformation, protecting itself from OOM. `batch` last so batching groups the *final* shape of the data right before export, maximizing throughput and not re-batching after each mutation.
- **S.2** If `redaction` runs after `spanmetrics` has already exported, the derived metrics (and any exemplars) may carry unmasked PII/secrets out to the metrics backend before redaction touched the traces — the secret leaks through the *metrics* path. Masking must happen upstream of every exporter/connector that could copy the value.
- **S.3** (1) The metricstransform processor is placed **after** the exporter/connector that emits the metric, or is not in that metric pipeline at all, so the rename never runs before export. (2) There are **two pipelines** and the rename is only in one, while the metric reaches the backend through the other (unmodified) pipeline. Either way, the transform is not on the path the exported metric actually travels.

</details>