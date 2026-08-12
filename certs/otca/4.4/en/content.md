# 4.4 Schema Management

> OTCA Domain 4 — *Maintaining and Debugging Observability Pipelines*. Exam weight: 2.5.
> Scope: OpenTelemetry **Telemetry Schemas**, the `schema_url` field, schema files, schema-driven transformation, and the operational tooling (Collector `schemaprocessor`, Weaver) that lets a heterogeneous fleet converge on one vocabulary.

---

## 1. The production problem: semantic convention drift

Semantic conventions are the shared vocabulary that makes telemetry *portable*: `http.request.method`, `server.address`, `db.system.name`. Backends, dashboards, alert rules, and SLO queries are hard-coded against these attribute and metric names. The problem is that the vocabulary **evolves**, and it does so faster than you can redeploy a fleet.

Real, breaking renames that shipped in the OpenTelemetry HTTP conventions:

| Old name (≤ semconv 1.20) | New name (stable semconv ≥ 1.23) |
|---|---|
| `http.method` | `http.request.method` |
| `http.status_code` | `http.response.status_code` |
| `net.peer.name` | `server.address` |
| `net.peer.port` | `server.port` |
| `http.url` | `url.full` |

Now picture the failure mode at scale:

- Team A upgrades its Java auto-instrumentation and starts emitting `http.request.method`. Team B is still on the old agent emitting `http.method`.
- The central dashboard groups by `http.method`. Team A's traffic silently **disappears** from the panel — no error, no gap, just a smaller number. This is worse than a hard break: an alert keyed on `http.status_code >= 500` stops matching Team A entirely and goes **quiet** during an incident.
- You cannot force a synchronized fleet-wide upgrade, and you cannot rewrite every dashboard for every intermediate version.

You need two things, and OpenTelemetry provides exactly two mechanisms:

1. **Self-description** — every telemetry stream carries a `schema_url` declaring *which convention version it was produced against*. Telemetry stops being ambiguous.
2. **A machine-readable delta** — a **Telemetry Schema file** that encodes the changes between versions, so a processor can *transform* telemetry from the producer's version to the consumer's expected version automatically.

Schema management is the discipline of emitting (1) correctly and operating (2) reliably.

---

## 2. Anatomy of a Telemetry Schema

### 2.1 The Schema URL

A **Schema URL** uniquely identifies a schema version. It is an opaque identifier whose **last path segment is a semantic version**:

```
https://opentelemetry.io/schemas/1.26.0
                                  ^^^^^^ version
https://opentelemetry.io/schemas/  ← "schema family" (everything but the version)
```

- Two URLs belong to the **same schema family** iff everything except the final version segment is identical. Transformation is only defined *within* a family.
- By convention the URL **should be resolvable**: an HTTP `GET` returns the schema file for that family (the OTel one does). This lets a Collector fetch deltas it has never seen.

### 2.2 Where `schema_url` lives in the wire format (OTLP)

`schema_url` is attached at **two granularities**, at the Resource level and the InstrumentationScope level. From `trace.proto`:

```proto
message ResourceSpans {
  Resource resource      = 1;
  repeated ScopeSpans scope_spans = 2;
  string schema_url      = 3;   // applies to resource.attributes
}
message ScopeSpans {
  InstrumentationScope scope = 1;
  repeated Span spans        = 2;
  string schema_url          = 3;   // applies to the scope's spans/attributes
}
```

The same shape exists for `ResourceMetrics/ScopeMetrics` and `ResourceLogs/ScopeLogs`. The scope-level URL is the one that matters for signal attributes, because an instrumentation library declares the semconv version *it* was compiled against — independent of the resource's version.

### 2.3 The Schema File (file format 1.1.0)

A single YAML document describes an entire family:

- `file_format` — version of the **file format itself** (currently `1.1.0`), not of your schema.
- `schema_url` — the family's URL. Its version **must equal the highest version listed** under `versions`.
- `versions` — a map `version → { section → changes }`. A version's `changes` describe *what happened at that version* relative to the previous one. Attribute maps are written **old → new**.

Sections and the change types each accepts:

| Section | Change types | Purpose |
|---|---|---|
| `all` | `rename_attributes` | Rename an attribute *everywhere* (resource, spans, events, metric datapoints, logs) |
| `resources` | `rename_attributes` | Rename resource attributes only |
| `spans` | `rename_attributes` (opt. `apply_to_spans`) | Rename span attributes, optionally scoped to named spans |
| `span_events` | `rename_events`, `rename_attributes` (opt. `apply_to_events`, `apply_to_spans`) | Rename events and their attributes |
| `metrics` | `rename_metrics`, `rename_attributes` (opt. `apply_to_metrics`), `split` | Rename metric *streams*, their attributes, or split one metric into many |
| `logs` | `rename_attributes` | Rename log record attributes |

**Transformation direction.** To move telemetry from version `X` to target `Y > X`, apply the changes of every version in `(X, Y]` in ascending order, using each `attribute_map` forward (old→new). To move *backward* (`Y → X`), apply the same changes in descending order **inverted**. This is why the deltas must be lossless renames/splits, not arbitrary logic.

---

## 3. Trade-offs

### 3.1 Where do you perform the transformation?

| Location | Latency to correct vocab | Blast radius on rollback | Cardinality/cost control | Multi-consumer flexibility | Verdict |
|---|---|---|---|---|---|
| **At the SDK / producer** (just emit new names) | Immediate, but requires redeploying every producer | Must redeploy to undo | None (already emitted) | One vocabulary for all consumers | Ideal *eventually*; impossible to coordinate across a fleet at once |
| **At the Collector (`schemaprocessor`)** | Central, config-only, no app redeploy | Flip config + restart | Normalizes before fan-out → fewer distinct streams downstream | One canonical version per pipeline | **Recommended control point** for mixed fleets |
| **At the backend / query time** | Zero producer coordination | Just edit queries | Storage still holds mixed names (high cardinality) | Per-team, but every query must know the mapping | Fragile; the drift lives forever in storage |

The Collector is the natural convergence point: producers stay on whatever version they ship with, and the pipeline emits a single canonical `schema_url` to storage.

### 3.2 Resource-level vs Scope-level `schema_url`

| Aspect | Resource `schema_url` | Scope `schema_url` |
|---|---|---|
| Describes | `resource.attributes` (e.g. `service.*`, `k8s.*`) | The instrumentation library's signal attributes |
| Set by | Your app's `Resource` construction | The library, via its tracer/meter creation |
| Typical churn | Low (resource conventions are stable) | High (one lib can differ from another in the same process) |
| Merge hazard | `Resource.Merge` conflicts if URLs differ | N/A — each scope is independent |

**Key insight:** a single process legitimately emits **multiple** scope schema URLs (different libraries, different versions). Never assume one URL per process.

---

## 4. Complete manifests

### 4.1 A production schema file (family `https://myco.example.com/schemas`)

```yaml
# https://myco.example.com/schemas/1.3.0  (served verbatim at this URL)
file_format: 1.1.0
schema_url: https://myco.example.com/schemas/1.3.0

versions:
  # -------- 1.3.0: the HTTP rename lands + a paging-metric split --------
  1.3.0:
    all:
      changes:
        # Applies to resources, spans, events, metric datapoints, and logs.
        - rename_attributes:
            attribute_map:
              net.peer.name: server.address
              net.peer.port: server.port

    spans:
      changes:
        - rename_attributes:
            attribute_map:
              http.method: http.request.method
              http.status_code: http.response.status_code
              http.url: url.full
            # Optional: restrict the rename to specific span names.
            # apply_to_spans:
            #   - "HTTP GET"
            #   - "HTTP POST"

    span_events:
      changes:
        - rename_events:
            name_map:
              exception.stacktrace: exception
        - rename_attributes:
            attribute_map:
              message.uncompressed_size: message.uncompressed.size

    metrics:
      changes:
        - rename_metrics:
            http.server.duration: http.server.request.duration
        - rename_attributes:
            apply_to_metrics:
              - http.server.request.duration
            attribute_map:
              http.method: http.request.method
        - split:
            # Split one bidirectional metric into two directional metrics.
            apply_to_metric: system.paging.operations
            by_attribute: direction         # this attribute is REMOVED from outputs
            metrics_from_attributes:
              system.paging.operations.in: in
              system.paging.operations.out: out

    logs:
      changes:
        - rename_attributes:
            attribute_map:
              log.severity: severity.text

  # -------- 1.2.0: earlier delta, kept for backward transforms --------
  1.2.0:
    resources:
      changes:
        - rename_attributes:
            attribute_map:
              service.instance: service.instance.id

  # -------- 1.1.0: family baseline (no changes recorded) --------
  1.1.0:
```

### 4.2 Collector pipeline with the `schemaprocessor`

> Stability: the `schemaprocessor` is in **development/alpha** in `opentelemetry-collector-contrib`. Pin your Collector version and test transforms before relying on them in an alerting path.

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # Converts any incoming telemetry whose schema_url is in a known family
  # to the target version of that family. Streams already at target are no-ops.
  schema:
    # Warm the cache at startup so the first request isn't blocked on a fetch.
    prefetch:
      - https://myco.example.com/schemas/1.3.0
      - https://opentelemetry.io/schemas/1.26.0
    # One target per family. Everything in that family is normalized to this version.
    targets:
      - https://myco.example.com/schemas/1.3.0
      - https://opentelemetry.io/schemas/1.26.0

  batch:
    send_batch_size: 8192
    timeout: 5s

exporters:
  debug:
    verbosity: detailed          # prints Resource/Scope SchemaURL — see §6
  otlp/backend:
    endpoint: tempo:4317
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [schema, batch]   # schema BEFORE batch/export
      exporters:  [debug, otlp/backend]
    metrics:
      receivers:  [otlp]
      processors: [schema, batch]
      exporters:  [otlp/backend]
  telemetry:
    logs:
      level: info
```

### 4.3 Emitting `schema_url` from the SDK (Go)

```go
import (
    "go.opentelemetry.io/otel/sdk/resource"
    "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.26.0" // package pins the version
)

// Resource carries the RESOURCE-level schema_url.
res, err := resource.New(ctx,
    resource.WithSchemaURL(semconv.SchemaURL), // "https://opentelemetry.io/schemas/1.26.0"
    resource.WithAttributes(
        semconv.ServiceName("checkout"),
        semconv.ServiceVersion("2.4.1"),
    ),
)
if err != nil {
    log.Fatalf("resource: %v", err) // includes ErrSchemaURLConflict on merge collisions
}

tp := trace.NewTracerProvider(trace.WithResource(res) /* + exporter */)

// Tracer carries the SCOPE-level schema_url — independent of the resource's.
tracer := tp.Tracer(
    "github.com/myco/checkout",
    trace.WithInstrumentationVersion("2.4.1"),
    trace.WithSchemaURL(semconv.SchemaURL),
)
```

Python equivalent for the resource:

```python
from opentelemetry.sdk.resources import Resource
from opentelemetry.semconv.resource import ResourceAttributes
from opentelemetry.semconv import SCHEMA_URL   # e.g. https://opentelemetry.io/schemas/1.26.0

resource = Resource.create(
    attributes={ResourceAttributes.SERVICE_NAME: "checkout"},
    schema_url=SCHEMA_URL,
)
```

---

## 5. CLI commands and real terminal output

**Fetch and inspect a live schema file** (proves the URL is resolvable):

```console
$ curl -sS https://opentelemetry.io/schemas/1.26.0 | head -n 6
file_format: 1.1.0
schema_url: https://opentelemetry.io/schemas/1.26.0
versions:
  1.26.0:
  1.25.0:
    spans:

$ curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' https://opentelemetry.io/schemas/1.26.0
200 text/yaml
```

**Generate spans with a known `schema_url` and watch the Collector transform them.** `telemetrygen` stamps the OTLP `schema_url` on its output:

```console
$ telemetrygen traces \
    --otlp-endpoint localhost:4317 --otlp-insecure \
    --otlp-attributes 'http.method="GET"' \
    --traces 1
2026-08-11T14:02:11.874Z  info  traces/worker.go:110  traces generated  {"worker": 0, "traces": 1}
```

**Collector `debug` exporter — the `schema_url` is printed at both levels** (this is your ground truth on the wire):

```console
$ docker logs otel-collector 2>&1 | sed -n '/ResourceSpans #0/,/Attributes:/p'
ResourceSpans #0
Resource SchemaURL: https://opentelemetry.io/schemas/1.26.0
Resource attributes:
     -> service.name: Str(telemetrygen)
ScopeSpans #0
ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.26.0
InstrumentationScope telemetrygen
Span #0
    Trace ID       : 5b8aa5a2d2c872e8321cf37308d69df9
    Name           : okey-dokey-0
    Attributes:
         -> http.request.method: Str(GET)   # <-- was http.method on the wire; schemaprocessor renamed it
```

**Diff two semantic-convention registry versions with Weaver** (the source of truth from which schema deltas are authored):

```console
$ weaver registry diff \
    --registry https://github.com/open-telemetry/semantic-conventions/archive/refs/tags/v1.26.0.zip \
    --baseline-registry https://github.com/open-telemetry/semantic-conventions/archive/refs/tags/v1.23.0.zip \
    --diff-format markdown
Resolved registry (baseline): 1.23.0
Resolved registry (current):  1.26.0
Attributes renamed:
  - http.method            -> http.request.method
  - http.status_code       -> http.response.status_code
  - net.peer.name          -> server.address
Metrics renamed:
  - http.server.duration   -> http.server.request.duration
Diff written to: registry_diff.md
```

**Validate a registry / catch breaking policy violations before publishing:**

```console
$ weaver registry check --registry ./semconv-registry
✔ Registry `./semconv-registry` loaded (312 attributes, 41 metrics)
✔ No parsing errors
✔ Policy checks passed (0 violations)
```

---

## 6. Verification and failure diagnosis

| Symptom | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| `schemaprocessor` is a **no-op**; names never change | Producer emits **empty** `schema_url` | `debug` exporter shows `Resource SchemaURL:` blank | Set `WithSchemaURL(semconv.SchemaURL)` in the SDK — transformation is undefined without a source version |
| Only *some* attributes renamed | Rename declared under `spans`/`metrics` but you needed `all` (or vice-versa) | Read which section the change sits in; check `apply_to_*` filters | Move the change to the correct section or widen `apply_to_*` |
| Collector logs `schema version X not in family` / no transform | Producer's `schema_url` family ≠ any `targets` family | Compare the URL prefix (everything but the version) to `targets` | Add the correct family to `targets`; families never cross-transform |
| Startup stalls / first requests time out | Schema fetch on the hot path; registry unreachable | Network egress from Collector; missing `prefetch` | Add `prefetch:`; run an internal mirror of schema URLs for air-gapped clusters |
| Collector refuses to load schema file | `file_format` ≠ supported version, or `schema_url` version ≠ highest `versions` key | `weaver` / parse the YAML; check the two invariants | Set `file_format: 1.1.0`; make `schema_url`'s version equal the max version listed |
| Go: `resource.New` returns error, resulting resource has **empty** schema URL | `Resource.Merge` of two resources with **different non-empty** schema URLs → `ErrSchemaURLConflict` | Log shows the conflict; merged schema URL is dropped | Align both resources to one `schema_url`, or merge only same-version resources |
| A `split` metric loses data / double counts | The `by_attribute` value has cases not covered in `metrics_from_attributes` | Compare distinct attribute values vs. the map keys | Cover every value; the split **drops** the `by_attribute` dimension from outputs |

**Golden verification loop:**

1. `curl` each schema URL you rely on → expect `200` + valid YAML (`file_format`, `schema_url`, `versions`).
2. Emit one signal with a *known* old attribute name via `telemetrygen`.
3. Read the Collector `debug` output → confirm the attribute name is the **target** version's name and both `SchemaURL` lines equal your target.
4. Assert in the backend that the canonical name is the *only* one present (no split-brain vocabulary).

---

## Referencias

- Telemetry Schemas — specification: https://opentelemetry.io/docs/specs/otel/schemas/
- Schema file format v1.1.0: https://opentelemetry.io/docs/specs/otel/schemas/file_format_v1.1.0/
- Published OpenTelemetry schema files: https://opentelemetry.io/schemas/
- OTLP trace proto (`schema_url` fields): https://github.com/open-telemetry/opentelemetry-proto/blob/main/opentelemetry/proto/trace/v1/trace.proto
- Collector `schemaprocessor`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/schemaprocessor
- Semantic Conventions (versioning & schema URLs): https://opentelemetry.io/docs/specs/semconv/
- Semantic Conventions repository & CHANGELOG: https://github.com/open-telemetry/semantic-conventions
- OpenTelemetry Weaver (registry resolve / diff / check): https://github.com/open-telemetry/weaver
- Go SDK `resource` (schema URL & merge conflict): https://pkg.go.dev/go.opentelemetry.io/otel/sdk/resource
- `telemetrygen` utility: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
- OTCA curriculum: https://github.com/cncf/curriculum