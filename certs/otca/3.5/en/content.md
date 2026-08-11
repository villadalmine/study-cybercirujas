# 3.5 Transforming Data

> **Domain 3 — The OpenTelemetry Collector.** This topic covers how telemetry is reshaped *inside the pipeline*, after it is received and before it is exported: attribute manipulation, normalization, redaction, enrichment, aggregation and structural rewriting. The instruments are the Collector's transformation processors — `transform` (OTTL), `attributes`, `resource`, `metricstransform`, `redaction`, `groupbyattrs` — and their governing language, **OTTL**.

---

## 1. The production problem: telemetry is never shaped the way you need it

An SRE inherits telemetry from three uncooperative sources at once:

1. **Instrumentation you don't control.** Third-party libraries, sidecars, legacy exporters and cloud agents each emit their own attribute keys (`http.status`, `http_status_code`, `status`), their own resource identity, and their own severity encodings. Backends need *one* schema.
2. **Data that is too expensive to store as-is.** Trace attributes carrying full URLs explode metric cardinality when they later become dimensions; a `user.id` attribute on a span multiplies index cost; a `http.url` with query strings is unbounded. Cost is a function of *shape*, and shape is fixed at the Collector.
3. **Data that is unsafe or non-compliant to forward.** Credit-card numbers in log bodies, bearer tokens in `http.request.header.authorization`, PII in span attributes. These must never reach the vendor, and the redaction must happen *before* the export queue, on infrastructure you own.

The architectural insight OTCA tests: **the Collector is the one place in the observability plane where you can normalize, reduce and sanitize telemetry from all sources uniformly, without touching application code or backend configuration.** Transformation at the Collector is a control point — a single deployment governs schema, cost and compliance for every service behind it.

### The pipeline contract

Transformation happens in the `processors` stage of a pipeline. Order is explicit and significant:

```
receivers → [ processor_1 → processor_2 → … → processor_n ] → exporters
```

Processors run **in the exact order listed in the pipeline's `processors:` array**, not the order they are defined in the top-level `processors:` block. A `transform` that rewrites `http.route` before a `filter` that drops `/health` routes behaves differently if you swap them. This ordering is the single most common source of "my config is correct but the data is wrong" incidents.

---

## 2. The transformation toolbox — comparative analysis

There are two families. **Action-based processors** (`attributes`, `resource`, `metricstransform`) take a declarative list of typed operations. **OTTL processors** (`transform`, `filter`) take statements written in the OpenTelemetry Transformation Language — a small, typed expression language that is strictly more powerful but has a real CPU cost per statement.

| Processor | Signal(s) | Model | Strength | Weakness | When to reach for it |
|---|---|---|---|---|---|
| `attributes` | traces, logs, metrics (datapoint attrs) | Action list (`insert/update/upsert/delete/hash/extract/convert/from_attribute`) | Fast, declarative, regex `extract` | Only touches attributes, no cross-signal logic | Simple key rename/hash/delete on attributes |
| `resource` | all | Action list (same actions, on Resource) | Rewrites resource identity uniformly | Resource-scope only | Fix `service.name`, drop noisy resource attrs |
| `transform` | traces, logs, metrics | **OTTL** statements | Conditional logic, math, parsing, cross-scope reads, any field | Highest per-record CPU cost; easy to write a slow regex | Anything conditional, structural, or field-level beyond attributes |
| `filter` | traces, logs, metrics | **OTTL** boolean conditions | Drops whole records by predicate | Drop-only (see [Filtering Data]) | Remove `/health`, drop debug logs, cut cardinality by dropping |
| `metricstransform` | metrics | Action list (rename metric/label, aggregate) | Renames metrics, aggregates away labels | Metrics only; being superseded by OTTL | Rename metrics, sum-away a label dimension |
| `redaction` | traces, logs, metrics | Allow-list keys + blocked-value regexes | Compliance-grade masking, allow-list model | Regex cost on every value | PII/secret masking with an allow-list posture |
| `groupbyattrs` | traces, logs, metrics | Re-partitions records by attribute set | Moves record attrs up to resource; compacts payload | Structural only, no value edits | Normalize where an attribute "belongs" (record vs resource) |

**Rule of thumb tested by OTCA:** prefer the *narrowest* tool. If a rename can be done by `attributes`, don't reach for `transform` — the action-based processors are cheaper and their intent is self-documenting. Escalate to OTTL only when you need a condition, a computed value, parsing, or access to a field that is not an attribute (`status.code`, `severity_number`, `body`, `name`).

### Editors vs. Converters — the OTTL distinction you must internalize

OTTL functions split into two categories, and confusing them is the classic beginner error:

- **Editors** mutate telemetry in place and **return nothing**. They are the *verb* of a statement: `set`, `delete_key`, `keep_keys`, `limit`, `truncate_all`, `replace_pattern`, `merge_maps`. An editor is a complete statement on its own.
- **Converters** compute and **return a value**. They are never a statement by themselves — they are arguments *to* an editor: `SHA256(...)`, `Concat(...)`, `ParseJSON(...)`, `Int(...)`, `IsMatch(...)`, `Truncate...`, `UUID()`.

```
set(attributes["user.hash"], SHA256(attributes["user.id"]))
│    └─────────── target ──┘  └──────── Converter ───────┘
└─ Editor (the statement)
```

Converters are capitalized by convention; editors are lower_snake_case. A statement is: **`editor(args...) [where <boolean condition>]`**.

---

## 3. OTTL — the language, precisely

### 3.1 Contexts

OTTL evaluates statements within a **context** — the telemetry "level" the statement operates on. The context determines which paths are addressable and how many times a statement runs.

| Signal | Contexts (outer → inner) | A statement in this context runs once per… |
|---|---|---|
| Traces | `resource` → `scope` → `span` → `spanevent` | resource / scope / **span** / span event |
| Metrics | `resource` → `scope` → `metric` → `datapoint` | resource / scope / metric / **datapoint** |
| Logs | `resource` → `scope` → `log` | resource / scope / **log record** |

Inner contexts can **read** outer ones (`span` can read `resource.attributes["k8s.pod.name"]`) but not vice versa without a coarser context. Choosing the coarsest context that still exposes the field you need is a performance decision: a statement in `datapoint` context runs once per datapoint (potentially thousands per metric), while the same effect in `metric` context runs once per metric.

### 3.2 Paths (selected, by context)

```
# span context
name, kind, trace_id, span_id, parent_span_id, trace_state,
start_time_unix_nano, end_time_unix_nano,
attributes["k"], dropped_attributes_count,
status.code, status.message, events, links,
resource.attributes["k"], instrumentation_scope.name

# log context
time_unix_nano, observed_time_unix_nano,
severity_number, severity_text, body,
attributes["k"], trace_id, span_id, flags

# datapoint context
metric.name, metric.type, metric.unit,
attributes["k"], time_unix_nano, start_time_unix_nano,
value_double, value_int, count, sum, exemplars, flags
```

### 3.3 Operators & conditions

`==` `!=` `<` `<=` `>` `>=`, boolean `and` / `or` / `not`, arithmetic `+ - * /`, map/slice indexing `attributes["a"]["b"]`, `slice[0]`. The `where` clause gates the editor; if the condition is false, the editor does not run for that record.

```
set(status.code, STATUS_CODE_ERROR) where attributes["http.response.status_code"] >= 500
```

---

## 4. Complete production manifest

The following is a full, syntactically valid `otelcol-contrib` configuration for a gateway Collector that normalizes, enriches, reduces cardinality, and redacts secrets across all three signals. It is uncut and deployable.

```yaml
# collector-gateway.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # 1) ALWAYS FIRST — sheds load before it reaches the heap-heavy processors.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25

  # 2) Enrich with k8s identity (from the downward API / API server).
  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.deployment.name
        - k8s.node.name
      labels:
        - tag_name: app.version
          key: app.kubernetes.io/version
          from: pod
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.ip

  # 3) Detect cloud/host resource identity.
  resourcedetection:
    detectors: [env, system]
    system:
      hostname_sources: [os]

  # 4) Action-based resource normalization (cheap, declarative).
  resource:
    attributes:
      - key: deployment.environment
        value: production
        action: upsert
      - key: telemetry.sdk.language      # noisy, drop it
        action: delete

  # 5) Attribute-level normalization on records (traces/logs).
  attributes/normalize:
    actions:
      # Unify divergent status-code keys emitted by different libraries.
      - key: http.response.status_code
        from_attribute: http.status_code
        action: upsert
      - key: http.status_code
        action: delete
      # Hash a high-cardinality / PII dimension instead of storing it raw.
      - key: enduser.id
        action: hash

  # 6) OTTL — the conditional / structural work the action processors can't do.
  transform/shape:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          # Strip query strings so http.url is bounded.
          - replace_pattern(attributes["url.full"], "\\?.*$", "")
          # Derive a low-cardinality route bucket for metrics later.
          - set(attributes["http.route.class"], "5xx")
              where attributes["http.response.status_code"] >= 500
          - set(attributes["http.route.class"], "4xx")
              where attributes["http.response.status_code"] >= 400
              and attributes["http.response.status_code"] < 500
          # Mark server errors as span-level errors.
          - set(status.code, STATUS_CODE_ERROR)
              where attributes["http.response.status_code"] >= 500
          # Bound blast radius: cap and truncate attributes.
          - limit(attributes, 128, ["service.name", "http.route"])
          - truncate_all(attributes, 4096)
    log_statements:
      - context: log
        statements:
          # Promote a numeric level field into OTel severity.
          - set(severity_number, SEVERITY_NUMBER_ERROR)
              where IsMatch(body, "(?i)\\b(error|fatal|panic)\\b")
          # Parse a JSON body into structured attributes.
          - merge_maps(attributes, ParseJSON(body), "upsert")
              where IsMatch(body, "^\\s*\\{")
    metric_statements:
      - context: datapoint
        statements:
          # Copy a resource attr down so it survives metric aggregation.
          - set(attributes["k8s.namespace.name"],
                resource.attributes["k8s.namespace.name"])

  # 7) Compliance-grade redaction — allow-list posture, blocked patterns.
  redaction:
    allow_all_keys: false
    allowed_keys:
      - http.method
      - http.route
      - http.response.status_code
      - service.name
      - k8s.namespace.name
      - deployment.environment
    blocked_values:
      - "4[0-9]{12}(?:[0-9]{3})?"        # Visa PAN
      - "5[1-5][0-9]{14}"                # Mastercard PAN
      - "(?i)bearer\\s+[a-z0-9._\\-]+"    # bearer tokens
    summary: info

  # 8) ALWAYS NEAR LAST — batch for export efficiency.
  batch:
    send_batch_size: 8192
    send_batch_max_size: 10000
    timeout: 5s

exporters:
  otlphttp/backend:
    endpoint: https://otel-backend.internal:4318
    tls:
      insecure: false
  debug:
    verbosity: detailed
    sampling_initial: 5
    sampling_thereafter: 200

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  zpages:
    endpoint: 0.0.0.0:55679

service:
  extensions: [health_check, zpages]
  telemetry:
    metrics:
      level: detailed
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, resourcedetection,
                   resource, attributes/normalize, transform/shape,
                   redaction, batch]
      exporters: [otlphttp/backend]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, resource,
                   transform/shape, redaction, batch]
      exporters: [otlphttp/backend]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, resource,
                   transform/shape, batch]
      exporters: [otlphttp/backend]
```

**The ordering law demonstrated above:** `memory_limiter` first (protect the process), enrichment before transformation (you can only normalize attributes that exist), `transform` before `redaction` (shape first, then sanitize the shaped result), `batch` last (never batch before you've dropped/reduced — you'd waste memory batching data you're about to discard, and `memory_limiter` must see pressure before the batcher hoards).

### Kubernetes deployment fragment

For `k8sattributes` to enrich, the Collector's ServiceAccount needs read access to pods:

```yaml
# rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector-k8sattributes
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector-k8sattributes
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-collector-k8sattributes
subjects:
  - kind: ServiceAccount
    name: otel-collector
    namespace: observability
```

---

## 5. CLI workflow and real terminal output

### 5.1 Validate the config before deploying

```console
$ otelcol-contrib validate --config=collector-gateway.yaml
$ echo $?
0
```

`validate` is silent on success (exit 0) and loud on failure. A misplaced converter used as a statement:

```console
$ otelcol-contrib validate --config=broken.yaml
Error: invalid configuration: processors::transform/shape: unable to parse OTTL
statement "SHA256(attributes[\"user.id\"])": editor names must start with a
lowercase letter but got "SHA256"
2026/08/11 14:03:11 collector server run finished with error: invalid configuration
$ echo $?
1
```

That error is OTTL telling you a **converter** was used where an **editor** (a full statement) is required — you meant `set(attributes["user.id"], SHA256(attributes["user.id"]))`.

### 5.2 Drive synthetic telemetry through the pipeline

```console
$ otelcol-contrib --config=collector-gateway.yaml &
2026-08-11T14:05:02.114Z  info  service@v0.112.0/service.go:135  Setting up own telemetry...
2026-08-11T14:05:02.121Z  info  service@v0.112.0/service.go:207  Starting otelcol-contrib...  {"Version": "0.112.0"}
2026-08-11T14:05:02.121Z  info  extensions/extensions.go:39  Starting extensions...
2026-08-11T14:05:02.122Z  info  otlpreceiver@v0.112.0/otlp.go:169  Starting GRPC server  {"endpoint": "0.0.0.0:4317"}
2026-08-11T14:05:02.122Z  info  service@v0.112.0/service.go:230  Everything is ready. Begin running and processing data.

$ telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 \
    --traces 1 --span-duration 250ms \
    --telemetry-attributes 'http.status_code="503"' \
    --telemetry-attributes 'enduser.id="alice@corp.io"'
2026-08-11T14:05:31.902Z  info  traces/traces.go:58  generation of traces isn't being throttled
2026-08-11T14:05:31.905Z  info  traces/worker.go:96  traces generated  {"worker": 0, "traces": 1}
2026-08-11T14:05:31.905Z  info  traces/traces.go:74  stop the batch span processor
```

### 5.3 Observe the transformed result via the `debug` exporter

```console
2026-08-11T14:05:31.921Z  info  Traces  {"kind": "exporter", "data_type": "traces", "name": "debug", "resource spans": 1, "spans": 1}
2026-08-11T14:05:31.921Z  info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(telemetrygen)
     -> deployment.environment: Str(production)
     -> k8s.namespace.name: Str(observability)
ScopeSpans #0
Span #0
    Name           : okey-dokey-0
    Kind           : Server
    Status code    : Error
    Status message :
Attributes:
     -> http.response.status_code: Int(503)
     -> http.route.class: Str(5xx)
     -> enduser.id: Str(b94d27b9934d3e08a52e52d7da7dabfa...)
```

Confirm the transformations landed: `http.status_code` (503) was unified into `http.response.status_code`; `http.route.class=5xx` was derived; the span `Status code` was flipped to `Error` by the OTTL `where >= 500` statement; `deployment.environment=production` was upserted onto the resource; and `enduser.id` was replaced by its SHA-256 hash — the raw email never left the Collector.

---

## 6. Verification and failure diagnosis

### 6.1 `error_mode` — the single most important safety knob

Every OTTL processor takes `error_mode`, which decides what happens when a statement errors at runtime (e.g. `ParseJSON` on a non-JSON body, indexing a missing key):

| `error_mode` | Behaviour on statement error | Use it when |
|---|---|---|
| `propagate` | The whole batch is rejected and returned as an error to the previous component | You want fail-fast in staging; a bad statement should page you |
| `ignore` | Log the error, skip **that statement**, continue the batch | Production default — one malformed record must not drop the batch |
| `silent` | Skip the statement, no log | High-volume paths where expected errors would flood logs |

The production trap: `propagate` on a `transform` that parses a free-form `body` will drop *entire batches* the moment one log line isn't JSON. Guard converters with a `where IsMatch(...)` predicate **and** run `error_mode: ignore`.

### 6.2 Self-observability — prove the processor is doing work

The Collector exports its own metrics on `:8888`. Scrape them to verify throughput and refusals:

```console
$ curl -s localhost:8888/metrics | grep -E 'otelcol_processor|otelcol_receiver_accepted'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 1
otelcol_processor_incoming_items{processor="transform/shape",otel_signal="traces"} 1
otelcol_processor_outgoing_items{processor="transform/shape",otel_signal="traces"} 1
otelcol_processor_incoming_items{processor="redaction",otel_signal="traces"} 1
otelcol_processor_outgoing_items{processor="redaction",otel_signal="traces"} 1
```

For the `memory_limiter`, watch refusals — non-zero means you are shedding load and must scale out or raise limits:

```console
$ curl -s localhost:8888/metrics | grep refused
otelcol_processor_refused_spans{processor="memory_limiter"} 0
```

### 6.3 zPages — inspect the live pipeline

```console
$ curl -s localhost:55679/debug/pipelinez | head -20
Pipeline: traces
  Processors: memory_limiter, k8sattributes, resourcedetection,
              resource, attributes/normalize, transform/shape,
              redaction, batch
  MutatesData: true
```

`MutatesData: true` confirms the pipeline holds mutating processors — the Collector must therefore give each pipeline its own copy of the data (fan-out cost). This is why routing the *same* receiver into two pipelines that both transform doubles memory.

### 6.4 Diagnostic decision table

| Symptom | Likely cause | Verification |
|---|---|---|
| Attribute rename didn't happen | Source key absent when `attributes` ran; or wrong processor order | Add a `debug` exporter *before* the transform; compare |
| Whole batches vanishing | `error_mode: propagate` + a converter erroring on malformed input | Grep Collector logs for `failed to execute statement`; switch to `ignore` + `where` guard |
| OTTL statement never fires | `where` condition false; type mismatch (`Int` vs `Str` compare) | Log `attributes["k"]` type with `debug`; wrap with `Int(...)`/`String(...)` |
| High CPU after adding transform | Expensive regex (`replace_pattern`) or `datapoint`-context statement over a huge series | Check `otelcol_process_cpu_seconds`; move to `metric`/`resource` context; anchor regexes |
| Redacted value still leaks | `allow_all_keys: true`, or the key is allow-listed but the *value* pattern isn't blocked | Set `summary: info`; read the redaction summary attributes on records |
| `service.name` shows `unknown_service` | `resource`/`resourcedetection` ran after export, or detector disabled | Confirm processor is in the pipeline `processors:` array, not just declared |
| Config valid but data unchanged | Processor declared under `processors:` but omitted from the pipeline array | `pipelinez` zPage lists the *actual* active chain |

---

## 7. Design guidance (Platform Architect notes)

- **Transform at the gateway, not the agent.** Node-local agent Collectors should do minimal work (batch, memory_limiter) and forward; centralize normalization/redaction at a horizontally scaled gateway tier so policy lives in one place. Redaction *must* be gateway-side so raw PII never crosses the network to the vendor.
- **Prefer coarse contexts.** A `set` you can do in `resource` context should not live in `datapoint` context — the CPU delta is multiplicative in series count.
- **Cut cardinality by dropping the attribute, not just hashing.** Hashing preserves cardinality (each distinct value → distinct hash); if the goal is cost, `delete` or bucket into a class (`http.route.class`) instead.
- **Guard every converter with a predicate.** `merge_maps(attributes, ParseJSON(body), "upsert") where IsMatch(body, "^\\s*\\{")` — never call a parser unconditionally on free-form input.
- **`metricstransform` is legacy for renames/aggregation; new work should use OTTL `transform`** for uniformity, but `metricstransform`'s label-aggregation (`combine`/`sum` across a dropped label) still has no clean OTTL equivalent for scalar aggregation — know both exist.

---

## Referencias

- OpenTelemetry Collector — Transforming telemetry (Processors overview): https://opentelemetry.io/docs/collector/transforming-telemetry/
- OTTL — OpenTelemetry Transformation Language: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/README.md
- OTTL Functions (editors & converters reference): https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/ottlfuncs/README.md
- OTTL Contexts (span/log/metric/datapoint paths): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/pkg/ottl/contexts
- Transform processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/transformprocessor/README.md
- Attributes processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/attributesprocessor/README.md
- Resource processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/resourceprocessor/README.md
- Filter processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/filterprocessor/README.md
- Redaction processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/redactionprocessor/README.md
- Metrics Transform processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/metricstransformprocessor/README.md
- Memory Limiter processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/memorylimiterprocessor/README.md
- k8sattributes processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/k8sattributesprocessor/README.md
- Collector internal telemetry / self-observability: https://opentelemetry.io/docs/collector/internal-telemetry/
- OTCA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf