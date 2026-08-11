# Topic 1.2 — Semantic Conventions

> **Exam weight: 4.5** · Domain 1 (Fundamentals of Observability / OpenTelemetry)
> Profile: SRE / Platform Architect — production-grade depth.

Semantic conventions are the single most under-appreciated part of the OpenTelemetry specification and, in practice, the difference between telemetry that *federates* across a fleet and telemetry that is a per-team dialect nobody can query. This chapter treats them as a contract, not a style guide.

---

## 1. Motivation and the production architecture problem

### 1.1 The problem semantic conventions actually solve

OpenTelemetry decouples three things that used to be welded together in a single vendor agent:

1. **Instrumentation** — the code that *produces* signals (traces, metrics, logs).
2. **Transport** — OTLP over gRPC/HTTP.
3. **Analysis** — the backend that stores and queries the data (Tempo, Jaeger, Prometheus, a SaaS, etc.).

Decoupling the wire format (OTLP) is necessary but **not sufficient**. OTLP guarantees the *shape* of a span — it has a name, a start time, a kind, and a bag of key/value attributes. It says nothing about *what the keys are called or what the values mean*. Two teams instrumenting the same HTTP framework can both emit perfectly valid OTLP and still be mutually unreadable:

```text
Team A span attributes          Team B span attributes
------------------------        --------------------------------
method:  "GET"                  http.verb:        "get"
status:  200                    response.code:    "200"
path:    "/orders/42"           endpoint:         "/orders/{id}"
host:    "api.shop"             upstream.host:    "api.shop:443"
```

Every backend dashboard, alert, SLO query, and trace-to-metric correlation now has to know both dialects. Cardinality explodes, `PromQL`/`TraceQL`/`LogQL` queries fork per team, and cross-service traces break at the boundary because the parent and child describe the same HTTP call with different vocabularies.

**Semantic conventions are the shared vocabulary.** They are a versioned registry of attribute names, their value types, their allowed values (enums), their units, and their *requirement level*, published by the OpenTelemetry project. When every producer emits `http.request.method`, a single dashboard, a single alert, and a single SLO query work across the entire fleet — regardless of language, framework, or vendor.

### 1.2 Why this is an *architectural* concern, not a naming nicety

In a platform of any size the payoff compounds:

- **Portability of analysis.** Backend-agnostic dashboards ship as code because the field names are fixed. You can swap Jaeger for Tempo without rewriting queries.
- **Correlation across signals.** Exemplars link a metric bucket to a trace, and a trace to logs, *only* if `service.name`, `trace_id`, and `service.instance.id` mean the same thing everywhere. Correlation is a join, and a join needs a shared key.
- **Cost control.** Cardinality is a billing line item in every metrics backend. Conventions prescribe *low-cardinality* attributes for metric dimensions (`http.route`, not `url.path`) — the single most effective lever against a runaway time-series count.
- **Auto-instrumentation is only useful if it is uniform.** The value of zero-code instrumentation (Java agent, eBPF, OTel Operator auto-inject) collapses if every library invents its own keys. Conventions are what let a Java agent and a Go SDK produce a span that a backend renders identically.
- **Governance at scale.** A registry you can lint against (see Weaver, §4) turns "please use the right names" from a code-review plea into a CI gate.

### 1.3 The four surfaces conventions cover

Semantic conventions apply to four distinct planes. Confusing them is a common exam trap.

| Plane | What it describes | Carried on | Canonical examples |
|---|---|---|---|
| **Resource** | The *entity* producing telemetry (immutable for the process lifetime) | `Resource` (attached once per SDK/exporter) | `service.name`, `service.version`, `service.instance.id`, `k8s.pod.name`, `cloud.region`, `host.arch` |
| **Trace / Span** | A single operation | Span attributes + span name + span kind | `http.request.method`, `db.query.text`, `messaging.system` |
| **Metric** | A measurement over time | Instrument name + unit + attributes | `http.server.request.duration` (unit `s`), `http.route` dimension |
| **Log** | A log record | LogRecord attributes / fields | `exception.type`, `code.function.name`, `log.file.path` |

A `Resource` is *attached to* spans, metrics, and logs — it is not a signal itself. That is why `service.name` is set once and shows up on every signal a process emits.

---

## 2. The rules of the registry (and technical trade-off comparisons)

### 2.1 Attribute naming rules

The spec is precise, and the exam tests it:

- **Namespaces are dot-separated**, forming a hierarchy: `http.request.method`, `db.collection.name`. The dotted prefix is the namespace; the last segment is the leaf.
- **Segments use `snake_case`** (lowercase, `_` between words *inside* a segment): `service.instance.id`, `http.request.method_original`.
- **Lowercase only.** No camelCase, no PascalCase.
- **Never reuse a name across incompatible types.** A name binds to exactly one type for all time.
- **`.` is a namespace separator, never part of a leaf name.** Prometheus exporters replace `.` with `_` on export (`http_server_request_duration_seconds`); that is an export-time transformation, not the source name.
- **Enumerations** (like `http.request.method`) have a fixed member set but usually `allow_custom_values: true`, so an unknown method (`QUERY`) is passed through in `http.request.method_original` while `http.request.method` is set to `_OTHER`.

### 2.2 Requirement levels

Every attribute in the registry carries a **requirement level**. This is a normative field, not a suggestion.

| Level | Meaning for an instrumentation author | Meaning for a backend/consumer |
|---|---|---|
| **Required** | MUST be emitted, always. Absence is a spec violation. | Safe to assume present. |
| **Conditionally Required** | MUST be emitted *when the stated condition holds* (e.g. `http.route` when a route exists; `error.type` when the request failed). | Present iff the condition held; absence is meaningful. |
| **Recommended** | SHOULD be emitted unless there is a reason not to (cost, privacy). | May be absent even in a correct implementation. |
| **Opt-In** | Emitted *only* when the operator explicitly turns it on (usually high-cost or sensitive, e.g. full `db.query.text` with parameters). | Present only under explicit configuration. |

**Design consequence:** metric dimensions must be built from `Required`/`Conditionally Required`, *low-cardinality* attributes only. `url.path` is `Recommended` on a span but must **never** become a metric dimension — it is unbounded cardinality.

### 2.3 Stability levels

Conventions themselves move through a lifecycle. This governs whether you can build durable dashboards on them.

| Stability | Guarantee | Operational stance |
|---|---|---|
| **Stable** | Backwards-compatibility guaranteed; will not be renamed or retyped. | Safe to hard-code in dashboards, alerts, SLOs. |
| **Development** (formerly *Experimental*) | May change or be renamed in any release. | Use behind a feature flag; expect churn; pin a schema URL. |
| **Deprecated** | Superseded; kept for migration only, will be removed. | Migrate off; use dual-emit during transition. |

The best-known real-world event: the **HTTP semantic conventions stabilized in semconv v1.23.0** (2023), which *renamed* almost every HTTP attribute. `http.method` → `http.request.method`, `http.status_code` → `http.response.status_code`, `http.url` → `url.full`, and the entire `net.*` family collapsed into `network.*`, `server.*`, `client.*`, `url.*`. This break is the canonical case study for §3's migration mechanics.

### 2.4 HTTP conventions: old (deprecated) vs new (stable)

This table is worth memorizing; the rename is a favorite exam subject.

| Concept | Old (deprecated, ≤ 1.20) | New (stable, ≥ 1.23) |
|---|---|---|
| Request method | `http.method` | `http.request.method` |
| Response status | `http.status_code` | `http.response.status_code` |
| Full URL | `http.url` | `url.full` |
| Path | `http.target` (path+query) | `url.path` + `url.query` |
| Scheme | `http.scheme` | `url.scheme` |
| Route (low-card) | `http.route` | `http.route` *(unchanged)* |
| Protocol version | `http.flavor` | `network.protocol.version` |
| User agent | `http.user_agent` | `user_agent.original` |
| Server host/port | `net.host.name` / `net.host.port` | `server.address` / `server.port` |
| Client peer | `net.peer.name` / `net.peer.port` | `client.address` / `network.peer.address` |
| Server metric | `http.server.duration` (unit `ms`) | `http.server.request.duration` (unit `s`, histogram) |

Note the **metric changed both its name and its unit** (`ms` → `s`) *and* its type expectation (explicit-bucket histogram with a recommended bucket boundary set). A migration that only renames attributes but forgets the metric unit change will silently produce dashboards off by 1000×.

### 2.5 Migration strategy trade-offs

When conventions break (HTTP, and later DB and messaging), you have three architectural options for the transition. Choosing correctly is an SRE decision.

| Strategy | Where it runs | Pros | Cons | Use when |
|---|---|---|---|---|
| **SDK dual-emit** (`OTEL_SEMCONV_STABILITY_OPT_IN=http/dup`) | In-process, at the instrumentation | Both old + new emitted; backend can migrate dashboards at its own pace; no data loss | ~2× attribute volume on affected spans; only for domains the SDK supports; requires app redeploy | You control app deploys and want a clean, staged cutover |
| **Collector `transform` (OTTL)** | Central, in the Collector pipeline | No app redeploy; one policy for the whole fleet; can add/rename/drop keys | You must maintain the OTTL rules; runs on every span (CPU); easy to forget a key | You cannot redeploy every service, or you have polyglot/legacy producers |
| **Collector `schema` processor** | Central, driven by telemetry-schema files | Declarative, version-to-version translation defined by the OTel project's own schema files | Only covers transformations expressed in the published schema; less flexible than OTTL | You want spec-sanctioned, version-pinned translation without hand-writing rules |

The mature pattern is **hybrid**: turn on `http/dup` in newly deployed services, and run a Collector `transform` (or `schema`) stage to normalize the long tail of legacy producers to the new names — so the backend only ever sees one vocabulary.

---

## 3. Complete manifests and infrastructure

### 3.1 Setting the Resource (env-var contract)

The Resource is where `service.name` and friends live. The spec defines environment variables the SDK reads at startup — this is the portable, language-agnostic way to set it.

```bash
# service.name is REQUIRED. If unset, SDKs fall back to "unknown_service" (+ process name),
# which is a fleet-wide anti-pattern — everything collapses into one bucket.
export OTEL_SERVICE_NAME="checkout"

# Additional Resource attributes as a W3C Baggage-style comma list.
# OTEL_SERVICE_NAME wins over any service.name here if both are set.
export OTEL_RESOURCE_ATTRIBUTES="service.namespace=shop,service.version=1.4.2,deployment.environment.name=prod"

# Standard exporter wiring (OTLP/gRPC to a local Collector).
export OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector.observability.svc:4317"
export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
```

`service.instance.id` should be **unique per running instance** (it is what disambiguates two pods of the same Deployment). In Kubernetes, derive it from the pod UID rather than the hostname.

### 3.2 Kubernetes: injecting Resource attributes the correct way

The pattern below feeds pod identity into the SDK via the Downward API. This is the production-correct way to populate `service.instance.id`, `k8s.pod.name`, etc., without relying on best-effort detection.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
spec:
  replicas: 3
  selector:
    matchLabels: { app: checkout }
  template:
    metadata:
      labels:
        app: checkout
        app.kubernetes.io/name: checkout
        app.kubernetes.io/version: "1.4.2"
    spec:
      containers:
        - name: checkout
          image: registry.example.com/shop/checkout:1.4.2
          env:
            - name: OTEL_SERVICE_NAME
              value: "checkout"
            # Pod UID is the stable, unique per-instance identifier.
            - name: K8S_POD_UID
              valueFrom:
                fieldRef: { fieldPath: metadata.uid }
            - name: K8S_POD_NAME
              valueFrom:
                fieldRef: { fieldPath: metadata.name }
            - name: K8S_NAMESPACE
              valueFrom:
                fieldRef: { fieldPath: metadata.namespace }
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef: { fieldPath: spec.nodeName }
            # Compose the Resource. service.instance.id MUST be unique per instance.
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: >-
                service.namespace=shop,
                service.version=1.4.2,
                deployment.environment.name=prod,
                service.instance.id=$(K8S_POD_UID),
                k8s.namespace.name=$(K8S_NAMESPACE),
                k8s.pod.name=$(K8S_POD_NAME),
                k8s.node.name=$(K8S_NODE_NAME)
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://$(K8S_NODE_NAME):4317"   # DaemonSet Collector on the node
```

> **Gotcha:** attribute values injected via `OTEL_RESOURCE_ATTRIBUTES` are only expanded because they reference *other* env vars declared earlier in the same list; Kubernetes performs `$(VAR)` substitution left-to-right, so `K8S_POD_UID` must be declared **before** the line that uses it.

### 3.3 Collector: resource detection (fill in what the app cannot know)

The app knows `service.*`; it does not reliably know the cloud/host it runs on. The `resourcedetection` processor enriches the Resource with `cloud.*`, `host.*`, `k8s.*` from the platform metadata endpoints.

```yaml
processors:
  resourcedetection:
    detectors: [env, system, ec2, eks]
    timeout: 2s
    override: false          # do NOT clobber attributes the SDK already set
    system:
      resource_attributes:
        host.name:   { enabled: true }
        host.id:     { enabled: true }
        os.type:     { enabled: true }
    ec2:
      resource_attributes:
        cloud.region:            { enabled: true }
        cloud.availability_zone: { enabled: true }
        host.type:               { enabled: true }

  # k8sattributes decorates telemetry with pod/namespace metadata by matching source IP.
  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.pod.uid
        - k8s.deployment.name
        - k8s.node.name
      labels:
        - tag_name: service.version
          key: app.kubernetes.io/version
          from: pod
```

`override: false` is the load-bearing setting: the SDK's `service.name` must always win over a detector's guess.

### 3.4 Collector: HTTP semconv migration with OTTL `transform`

This normalizes legacy producers (old `http.*`/`net.*` names) to the stable v1.23+ vocabulary so the backend sees one dialect. It is the concrete implementation of the "Collector transform" row in §2.5.

```yaml
processors:
  transform/http_semconv_migration:
    error_mode: ignore          # a missing key must not drop the span
    trace_statements:
      - context: span
        statements:
          # Rename request method.
          - set(attributes["http.request.method"], attributes["http.method"]) where attributes["http.method"] != nil
          # Rename response status (already an Int, no cast needed).
          - set(attributes["http.response.status_code"], attributes["http.status_code"]) where attributes["http.status_code"] != nil
          # Full URL and scheme.
          - set(attributes["url.full"], attributes["http.url"]) where attributes["http.url"] != nil
          - set(attributes["url.scheme"], attributes["http.scheme"]) where attributes["http.scheme"] != nil
          # Protocol version and user agent.
          - set(attributes["network.protocol.version"], attributes["http.flavor"]) where attributes["http.flavor"] != nil
          - set(attributes["user_agent.original"], attributes["http.user_agent"]) where attributes["http.user_agent"] != nil
          # net.* -> server.* / network.*
          - set(attributes["server.address"], attributes["net.host.name"]) where attributes["net.host.name"] != nil
          - set(attributes["server.port"], attributes["net.host.port"]) where attributes["net.host.port"] != nil
          # Drop the deprecated keys once copied, to avoid double storage.
          - delete_key(attributes, "http.method")
          - delete_key(attributes, "http.status_code")
          - delete_key(attributes, "http.url")
          - delete_key(attributes, "http.scheme")
          - delete_key(attributes, "http.flavor")
          - delete_key(attributes, "http.user_agent")
          - delete_key(attributes, "net.host.name")
          - delete_key(attributes, "net.host.port")

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [k8sattributes, resourcedetection, transform/http_semconv_migration, batch]
      exporters: [otlp/tempo]
```

### 3.5 Collector: the spec-driven alternative — `schema` processor

Instead of hand-writing OTTL, the `schema` processor uses OpenTelemetry **telemetry schema** files (the same `1.x.y` schemas published at `opentelemetry.io/schemas/…`) to translate signals to a target version. It reads the `schema_url` on incoming data and applies the recorded transformations.

```yaml
processors:
  schema:
    # Translate everything to these target schema versions.
    targets:
      - https://opentelemetry.io/schemas/1.27.0

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [schema, batch]
      exporters: [otlp/tempo]
```

This is declarative and version-pinned: the transformation set is whatever the OTel project recorded in the schema file between the producer's version and `1.27.0`. It cannot express arbitrary rules the way OTTL can, but it never drifts from the official rename history.

### 3.6 A semantic-convention *model* file (the registry source of truth)

Conventions are themselves defined as YAML in `open-telemetry/semantic-conventions`. Platform teams extend the registry with their **own** company namespace (e.g. `com.shop.*`) using the same schema, then generate/lint against it with Weaver (§4). A minimal custom group:

```yaml
groups:
  - id: registry.shop.checkout
    type: attribute_group
    display_name: Shop Checkout Attributes
    brief: >
      Company-specific attributes for the checkout domain. All names are
      namespaced under `shop.` to avoid collision with upstream conventions.
    attributes:
      - id: shop.cart.id
        type: string
        stability: stable
        requirement_level: required
        brief: Opaque identifier of the shopping cart.
        examples: ["cart_9f8b3c"]
      - id: shop.payment.provider
        type:
          allow_custom_values: true
          members:
            - id: stripe
              value: "stripe"
              stability: stable
            - id: adyen
              value: "adyen"
              stability: stable
        stability: stable
        requirement_level:
          conditionally_required: "when a payment was attempted"
        brief: The payment gateway used for this transaction.
      - id: shop.cart.total_minor
        type: int
        stability: development
        requirement_level: recommended
        brief: Cart total in the minor currency unit (cents).
        note: Pair with `shop.currency` for interpretation.
```

The `stability`, `requirement_level`, and typed `members` here are exactly the machine-readable fields §2.2/§2.3 described — this file is what turns governance into a CI check.

---

## 4. CLI and real terminal output

### 4.1 Validating the registry with OpenTelemetry Weaver

`weaver` is the official tool for resolving, checking, generating from, and live-checking semantic-convention registries. It is how you enforce conventions in CI.

**Lint a registry (structural + policy checks):**

```console
$ weaver registry check -r model/
✔ Loaded 1 registry (model/) — 214 groups, 1180 attributes
✔ Semantic Convention Registry resolution
✔ Attribute name format (snake_case, dotted namespaces)
✔ No duplicate attribute ids
✔ Every attribute declares `stability`
✖ Policy violation: attribute `shop.cartId` is not snake_case (did you mean `shop.cart_id`?)
✖ Policy violation: group `registry.shop.checkout` attribute `shop.payment.provider`
    has requirement_level `conditionally_required` but no condition text
2 error(s), 0 warning(s)
exit status 1
```

**Resolve the registry to a single flattened, dereferenced document** (what tooling and code-gen consume):

```console
$ weaver registry resolve -r model/ --format json -o resolved.json
✔ Resolved registry written to resolved.json (1180 attributes, 96 metrics, 41 spans)
```

**Live-check real telemetry against the registry** (does the running system actually emit conforming data?):

```console
$ weaver registry live-check -r model/ --input otlp://0.0.0.0:4317
Listening for OTLP on 0.0.0.0:4317 …
── span "GET /products/:id" (scope: otelhttp 0.54.0) ──────────────
  ✔ http.request.method = "GET"           [stable, required]  OK
  ✔ http.route          = "/products/:id" [stable, cond-req]  OK
  ✔ http.response.status_code = 200        [stable, cond-req] OK
  ⚠ http.method         = "GET"           DEPRECATED → use http.request.method
  ✖ url.full            MISSING           [recommended]  (advisory)
  ✖ cart.id             = "cart_9f8b3c"   UNKNOWN attribute — not in registry
Summary: 3 conforming, 1 deprecated, 1 unknown, 1 advisory
```

`weaver registry live-check` is the production feedback loop: it tells you *empirically* whether instrumentation matches the contract, catching the deprecated `http.method` a service is still emitting.

### 4.2 Seeing conventions on the wire via the Collector `debug` exporter

The fastest way to inspect emitted attributes is a Collector with the `debug` exporter at `detailed` verbosity.

```yaml
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

```console
$ otelcol-contrib --config debug.yaml
2026-08-10T14:22:01.334Z  info  service@v0.121.0  Everything is ready. Begin running and processing data.
2026-08-10T14:22:07.902Z  info  Traces  {"resource spans": 1, "spans": 1}
2026-08-10T14:22:07.902Z  info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
     -> service.namespace: Str(shop)
     -> service.version: Str(1.4.2)
     -> service.instance.id: Str(2f1c9a44-...-pod-uid)
     -> deployment.environment.name: Str(prod)
     -> k8s.pod.name: Str(checkout-7d9f-abc12)
     -> telemetry.sdk.name: Str(opentelemetry)
     -> telemetry.sdk.language: Str(go)
     -> telemetry.sdk.version: Str(1.34.0)
ScopeSpans #0
ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.27.0
InstrumentationScope go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp 0.54.0
Span #0
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Parent ID      : 00f067aa0ba902b7
    ID             : 00f067aa0ba90200
    Name           : GET /products/:id
    Kind           : Server
    Start time     : 2026-08-10 14:22:07.81 +0000 UTC
    Status code    : Unset
    Attributes:
         -> http.request.method: Str(GET)
         -> url.path: Str(/products/42)
         -> url.scheme: Str(https)
         -> url.query: Str(ref=home)
         -> server.address: Str(checkout.shop.svc)
         -> server.port: Int(443)
         -> http.route: Str(/products/:id)
         -> http.response.status_code: Int(200)
         -> network.protocol.version: Str(1.1)
         -> user_agent.original: Str(curl/8.6.0)
```

Read this output like a checklist: `Name` is the low-cardinality `{method} {http.route}` span name (`GET /products/:id`, **not** `/products/42`); `Kind: Server`; the `ScopeSpans SchemaURL` pins the semconv version; and every attribute uses the stable v1.23+ names. The **absence** of any `http.method`/`http.url`/`net.*` key confirms the producer is on new conventions.

### 4.3 Confirming the metric name/unit convention

```console
$ curl -s http://checkout:9464/metrics | grep http_server_request_duration
# HELP http_server_request_duration_seconds Duration of inbound HTTP requests.
# TYPE http_server_request_duration_seconds histogram
http_server_request_duration_seconds_bucket{http_request_method="GET",http_route="/products/:id",http_response_status_code="200",le="0.005"} 812
http_server_request_duration_seconds_bucket{http_request_method="GET",http_route="/products/:id",http_response_status_code="200",le="0.01"}  1190
http_server_request_duration_seconds_sum{http_request_method="GET",http_route="/products/:id",http_response_status_code="200"} 6.42
http_server_request_duration_seconds_count{http_request_method="GET",http_route="/products/:id",http_response_status_code="200"} 2043
```

Two convention facts are visible here:
- The OTel name `http.server.request.duration` (unit `s`) exports to Prometheus as `http_server_request_duration_seconds` — dots → underscores, unit suffix appended.
- The dimensions are `http_route` (bounded), **not** `url_path`. That is the low-cardinality rule (§2.2) enforced by the convention.

### 4.4 The migration opt-in in action

```console
# Legacy default: old attribute names only.
$ OTEL_SEMCONV_STABILITY_OPT_IN= ./checkout
   -> http.method: Str(GET)
   -> http.status_code: Int(200)

# Dual emit: both old AND new, for a staged backend cutover.
$ OTEL_SEMCONV_STABILITY_OPT_IN=http/dup ./checkout
   -> http.method: Str(GET)
   -> http.request.method: Str(GET)
   -> http.status_code: Int(200)
   -> http.response.status_code: Int(200)

# New only: stable v1.23+ names, old names gone.
$ OTEL_SEMCONV_STABILITY_OPT_IN=http ./checkout
   -> http.request.method: Str(GET)
   -> http.response.status_code: Int(200)
```

Domains have independent tokens (`http`, `http/dup`; `database`, `database/dup`) and the variable accepts a comma-separated list: `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup,database/dup`.

---

## 5. Verification and failure-diagnosis guide

### 5.1 A verification ladder (cheapest check first)

| Question | How to answer | Cost |
|---|---|---|
| Do attribute names follow the format rules? | `weaver registry check -r model/` | free, CI |
| Does the running system emit conforming data? | `weaver registry live-check --input otlp://…` | one collector, live |
| What is actually on the wire *right now*? | Collector `debug` exporter, `verbosity: detailed` | free, live |
| Is `service.name` set fleet-wide (not `unknown_service`)? | Query the backend for `service.name="unknown_service*"` | free |
| Is a metric dimension high-cardinality? | Count series per metric in Prometheus/backend | free |
| Which semconv version is a producer on? | Inspect `ScopeSpans SchemaURL` in debug output | free |

### 5.2 Failure catalogue

**Symptom: everything shows up as `unknown_service` (or `unknown_service:java`).**
`service.name` was never set. The SDK's default kicked in. Fix: set `OTEL_SERVICE_NAME` (or `service.name` via `OTEL_RESOURCE_ATTRIBUTES`). Diagnose:

```console
$ curl -s $BACKEND/api/services | jq -r '.[].name' | grep unknown
unknown_service:java
```

**Symptom: two pods of the same Deployment collapse into one instance in the backend.**
`service.instance.id` is missing or identical (e.g. hard-coded, or all pods share a hostname behind a headless service). Fix: derive it from the pod UID (§3.2). It is what disambiguates replicas.

**Symptom: metric cardinality is exploding / metrics backend is OOM-ing.**
A high-cardinality attribute leaked into a metric dimension — almost always `url.path`/`url.full` (raw path with IDs) used where `http.route` (templated) belongs. Diagnose the offending series count:

```console
$ curl -s 'http://prometheus:9090/api/v1/query?query=count(count%20by(url_path)(http_server_request_duration_seconds_count))'
{"status":"success","data":{"result":[{"value":[1.7e9,"48213"]}]}}
```

48 213 distinct `url_path` values is the smoking gun. Fix: drop `url.path` from the metric view (it should never have been a dimension); ensure the router set `http.route`. In the Collector, `transform` on the metrics pipeline can strip it:
`delete_key(attributes, "url.path")`.

**Symptom: cross-service traces break at the HTTP boundary; parent and child disagree on the operation.**
Producer and consumer are on different semconv versions (one emits `http.method`, the other `http.request.method`), so backend queries that filter on one name miss half the spans. Diagnose by checking `ScopeSpans SchemaURL` on each side. Fix: normalize with `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup` during transition, plus a Collector `transform`/`schema` stage (§3.4/§3.5) so the backend only ever sees one dialect.

**Symptom: HTTP latency dashboards read 1000× too high (or low) after an upgrade.**
The metric moved from `http.server.duration` (unit `ms`) to `http.server.request.duration` (unit `s`) and a panel still assumes milliseconds. This is the unit-change trap from §2.4. Fix: update the query to the seconds-based metric and divide/scale panels accordingly; verify with the `_sum/_count` ratio against a known request.

**Symptom: `weaver registry check` passes but real telemetry still has bad names.**
`check` validates the *model*, not the *emitted data*. A clean model does not prove instrumentation obeys it. Use `weaver registry live-check` (§4.1) or the `debug` exporter to verify what is actually produced. This is the direct analogue of "the citation resolves ≠ the citation says what is claimed": *the convention exists* and *the code emits it* are different rungs.

**Symptom: sensitive data (query parameters, full SQL with values) appears in spans.**
An `Opt-In` attribute (e.g. full `db.query.text` with parameter values, or `url.query` containing tokens) was emitted where it should require explicit enablement. Fix: confirm the attribute's requirement level is `Opt-In` and that it is only enabled deliberately; scrub with a Collector `transform`/`redaction` processor otherwise.

### 5.3 Golden signals of a conformant fleet

A production platform is "conforming" when all of the following hold, and each is machine-checkable:

1. Zero services report `service.name` starting with `unknown_service`.
2. Every metric dimension is drawn from a `Required`/`Conditionally Required`, low-cardinality attribute; `weaver registry live-check` reports **0 unknown** attributes on metrics.
3. Every `ScopeSpans`/`ScopeMetrics` carries a `SchemaURL`, and the fleet is within one minor semconv version of a single target.
4. No `Deprecated` attributes appear in live-check output (or they are knowingly present only during a dual-emit window with an end date).
5. Custom company attributes all live under a reserved namespace (e.g. `shop.*` / `com.shop.*`) and pass `weaver registry check` in CI.

---

## 6. References

- OpenTelemetry Semantic Conventions (specification home): https://opentelemetry.io/docs/specs/semconv/
- General attribute naming rules: https://opentelemetry.io/docs/specs/semconv/general/naming/
- Attribute requirement levels: https://opentelemetry.io/docs/specs/semconv/general/attribute-requirement-level/
- Resource semantic conventions (`service.*`, `telemetry.sdk.*`): https://opentelemetry.io/docs/specs/semconv/resource/
- HTTP semantic conventions (spans & metrics): https://opentelemetry.io/docs/specs/semconv/http/
- Database semantic conventions: https://opentelemetry.io/docs/specs/semconv/database/
- General metrics semantic conventions & naming: https://opentelemetry.io/docs/specs/semconv/general/metrics/
- Stability & migration (`OTEL_SEMCONV_STABILITY_OPT_IN`): https://opentelemetry.io/docs/specs/semconv/non-normative/http-migration/
- SDK environment variables (`OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`): https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- Telemetry Schemas (schema URLs, version transformations): https://opentelemetry.io/docs/specs/otel/schemas/
- `semantic-conventions` source registry (YAML model): https://github.com/open-telemetry/semantic-conventions
- OpenTelemetry Weaver (registry check / resolve / generate / live-check): https://github.com/open-telemetry/weaver
- Collector `resourcedetection` processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/resourcedetectionprocessor
- Collector `k8sattributes` processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/k8sattributesprocessor
- Collector `transform` processor & OTTL: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/transformprocessor
- Collector `schema` processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/schemaprocessor
- UCUM (unit codes used by metric conventions): https://ucum.org/
- OTCA certification & curriculum: https://training.linuxfoundation.org/certification/opentelemetry-certified-associate-otca/ · https://github.com/cncf/curriculum