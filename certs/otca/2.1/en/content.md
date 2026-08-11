# Topic 2.1 — The OpenTelemetry Data Model

> Exam weight: 6.58 · Domain 2 (OpenTelemetry Fundamentals) · Level: Production / Platform Architect

---

## 1. Motivation: the architectural problem the data model solves

Before OpenTelemetry, an SRE running a polyglot platform inherited a **combinatorial integration problem**. Each signal had its own wire format, its own agent, and its own identity scheme:

- Traces spoke Jaeger Thrift, Zipkin JSON v2, or a proprietary APM protocol.
- Metrics spoke Prometheus exposition text, StatsD/DogStatsD UDP, or Graphite line protocol.
- Logs spoke syslog RFC 5424, GELF, or raw JSON lines shipped by Fluentd/Filebeat.

The consequence was not merely "three agents instead of one." The deeper failure was **loss of correlation**. A span in Jaeger and a log line in Elasticsearch describing the *same request* had no shared, machine-comparable identity. On-call engineers pivoted between tools by copy-pasting timestamps and guessing. The `service.name` in one system was `service` in another and `app` in a third; a `500` was `http.status_code` here and `http_status` there. Cardinality decisions, retention, and cost were made independently per pillar, so the same failure was over-sampled in one store and dropped in another.

The **OpenTelemetry data model** is the answer to that problem. It is a *specification-level* contract — deliberately decoupled from any SDK, language, or backend — that defines:

1. **A single logical structure for all signals** (traces, metrics, logs) rooted in a shared `Resource` and `InstrumentationScope`.
2. **A shared identity and correlation scheme** — the same `trace_id`/`span_id` that identify a span are embedded in metric exemplars and log records, so the three signals point at each other by construction, not by timestamp heuristics.
3. **A typed, self-describing attribute system** (`AnyValue`) plus **Semantic Conventions** that fix attribute *names and meanings* across the ecosystem.
4. **A concrete wire encoding — OTLP** (OpenTelemetry Protocol) — that serializes that logical model over Protobuf, on gRPC or HTTP.

The design principle to internalize for the exam: **the data model is transport-agnostic and backend-agnostic.** OTLP is *one* encoding of the model. A Prometheus remote-write export is a *lossy projection* of the metrics part of the same model. The model is the source of truth; every exporter is a translation from it.

```
                     ┌──────────────────────────────────────────┐
                     │              Resource                      │
                     │  service.name, service.namespace,          │
                     │  service.instance.id, host.*, k8s.*, ...   │
                     └──────────────────────────────────────────┘
                                       │ (shared by every signal)
        ┌──────────────────────────────┼──────────────────────────────┐
        ▼                               ▼                              ▼
  InstrumentationScope           InstrumentationScope           InstrumentationScope
  (name+version+schema_url)      (name+version+schema_url)       (name+version+schema_url)
        │                               │                              │
        ▼                               ▼                              ▼
   ┌─────────┐                     ┌─────────┐                    ┌─────────┐
   │  Spans  │  trace_id/span_id   │ Metrics │  exemplar.trace_id │  Logs   │
   │         │ ◄──────────────────►│ (points)│ ◄─────────────────►│ Records │
   └─────────┘   correlation       └─────────┘   correlation      └─────────┘
```

---

## 2. The layered structure of the model

Every signal shares the same three-tier envelope. Learn this shape once and it applies to all three OTLP messages:

```
Resource<Signal>          # 1 Resource + its schema_url
  └── Scope<Signal>       # 1 InstrumentationScope + its schema_url
        └── <Signal item> # Span | Metric | LogRecord
```

| OTLP top-level message | Middle tier | Leaf item |
|---|---|---|
| `ResourceSpans`   | `ScopeSpans`   | `Span`      |
| `ResourceMetrics` | `ScopeMetrics` | `Metric`    |
| `ResourceLogs`    | `ScopeLogs`    | `LogRecord` |

### 2.1 Resource

A **Resource** is an immutable set of attributes describing the entity that produced the telemetry — the *who/where*. It is attached once and shared by every span, metric, and log emitted by that process. The single most important attribute is `service.name`; without it, backends bucket telemetry under `unknown_service` and correlation collapses.

Resource attributes are populated by **Resource Detectors** (SDK components that read the environment: container ID, K8s downward API, cloud metadata endpoints, `OTEL_RESOURCE_ATTRIBUTES`).

### 2.2 InstrumentationScope

Formerly `InstrumentationLibrary` (renamed in the stable spec). It identifies the *emitter of a given instrument* — typically the instrumentation library or a named tracer/meter/logger:

```
InstrumentationScope {
  name        = "io.opentelemetry.okhttp-3.0"   // required, logical name
  version     = "1.32.0"
  schema_url  = "https://opentelemetry.io/schemas/1.27.0"
  attributes  = [ ... ]                          // scope-level attributes
}
```

### 2.3 Attributes and the `AnyValue` type

Attributes are key–value pairs. The value is an `AnyValue` — a typed union. This is what makes OTLP self-describing on the wire.

| `AnyValue` variant | Backing type | Notes |
|---|---|---|
| `string_value`  | UTF-8 string        | most common |
| `bool_value`    | boolean             | |
| `int_value`     | signed 64-bit int   | integers are **int64**, not doubles |
| `double_value`  | IEEE-754 double     | |
| `bytes_value`   | raw bytes           | |
| `array_value`   | `ArrayValue` (list of `AnyValue`) | homogeneous by convention |
| `kvlist_value`  | `KeyValueList` (nested map) | for structured attributes |

**Production rule:** attribute *keys* should come from Semantic Conventions when one exists (`http.request.method`, not `verb`). Attributes are the primary driver of **cardinality** and therefore of index and storage cost — never put unbounded values (user IDs, full URLs with query strings, request UUIDs) into metric attributes.

---

## 3. Signal 1 — Traces

### 3.1 The Span

A **Span** is a single operation with a start and end. The fields defined by the model:

| Field | Type / size | Meaning |
|---|---|---|
| `trace_id`        | 16 bytes (128-bit) | identifies the whole trace; all-zero is invalid |
| `span_id`         | 8 bytes (64-bit)   | identifies this span; all-zero is invalid |
| `parent_span_id`  | 8 bytes            | empty ⇒ this is a root span |
| `trace_state`     | string (W3C `tracestate`) | vendor propagation state |
| `name`            | string             | low-cardinality operation name |
| `kind`            | enum               | see below |
| `start_time_unix_nano` / `end_time_unix_nano` | fixed64 | wall-clock, nanoseconds since Unix epoch |
| `attributes`      | repeated KeyValue  | span-scoped dimensions |
| `events`          | repeated Event     | timestamped points inside the span |
| `links`           | repeated Link      | references to *other* spans/traces |
| `status`          | Status             | `Unset` / `Ok` / `Error` + message |
| `dropped_*_count` | uint32             | count of attributes/events/links dropped by limits |
| `flags`           | uint32             | trace flags (incl. sampled bit) |

**SpanKind** (drives topology and the RED/latency semantics a backend infers):

| Enum value | Numeric | When to use |
|---|---|---|
| `SPAN_KIND_UNSPECIFIED` | 0 | default; treated as INTERNAL |
| `SPAN_KIND_INTERNAL`    | 1 | internal operation, no remote boundary |
| `SPAN_KIND_SERVER`      | 2 | inbound RPC/HTTP handler (server side) |
| `SPAN_KIND_CLIENT`      | 3 | outbound synchronous call (client side) |
| `SPAN_KIND_PRODUCER`    | 4 | async message send (producer) |
| `SPAN_KIND_CONSUMER`    | 5 | async message receive/process |

**Status codes:**

| Status | Numeric | Set by |
|---|---|---|
| `STATUS_CODE_UNSET` | 0 | default — the operation completed without an explicit error verdict |
| `STATUS_CODE_OK`    | 1 | *only* set explicitly by application code that asserts success |
| `STATUS_CODE_ERROR` | 2 | error; `message` carries a description |

> Exam trap: an HTTP `4xx` does **not** automatically become `STATUS_CODE_ERROR`. For a `SERVER` span, `4xx` is left `Unset` (the server behaved correctly); for a `CLIENT` span, `4xx`/`5xx` is `Error`. Instrumentation, not the transport code, decides.

### 3.2 SpanContext and W3C propagation

The `SpanContext` — the *propagatable, immutable* subset — is `{ trace_id, span_id, trace_flags, trace_state }`. It is what crosses a process boundary. The default text-map propagator is **W3C Trace Context**, carried in two HTTP headers:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  └───────────── trace_id ────────┘ └── parent_id ─┘ └ flags
             └ version (00)
tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

`trace_flags` is an 8-bit field; **bit 0 is the `sampled` flag** (`01` = sampled). The remaining bits are reserved.

### 3.3 A complete OTLP/JSON trace payload

This is a full, syntactically valid `ExportTraceServiceRequest` as accepted by an OTLP/HTTP endpoint at `POST /v1/traces`. Note the nesting `resourceSpans → scopeSpans → spans` and the byte fields encoded as hex strings in JSON:

```json
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name",        "value": { "stringValue": "checkout" } },
          { "key": "service.namespace",   "value": { "stringValue": "shop" } },
          { "key": "service.version",     "value": { "stringValue": "2.4.1" } },
          { "key": "service.instance.id", "value": { "stringValue": "checkout-7c9f-abc12" } },
          { "key": "deployment.environment", "value": { "stringValue": "production" } },
          { "key": "k8s.pod.name",        "value": { "stringValue": "checkout-7c9f-abc12" } }
        ],
        "droppedAttributesCount": 0
      },
      "schemaUrl": "https://opentelemetry.io/schemas/1.27.0",
      "scopeSpans": [
        {
          "scope": {
            "name": "io.opentelemetry.instrumentation.http",
            "version": "2.9.0"
          },
          "schemaUrl": "https://opentelemetry.io/schemas/1.27.0",
          "spans": [
            {
              "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
              "spanId": "00f067aa0ba902b7",
              "parentSpanId": "",
              "name": "POST /api/checkout",
              "kind": 2,
              "startTimeUnixNano": "1723291200000000000",
              "endTimeUnixNano":   "1723291200145000000",
              "attributes": [
                { "key": "http.request.method", "value": { "stringValue": "POST" } },
                { "key": "url.path",            "value": { "stringValue": "/api/checkout" } },
                { "key": "http.response.status_code", "value": { "intValue": "200" } },
                { "key": "server.address",      "value": { "stringValue": "checkout.shop.svc" } },
                { "key": "network.protocol.version", "value": { "stringValue": "1.1" } }
              ],
              "events": [
                {
                  "timeUnixNano": "1723291200030000000",
                  "name": "cache.miss",
                  "attributes": [
                    { "key": "cache.key", "value": { "stringValue": "cart:abc12" } }
                  ]
                }
              ],
              "links": [
                {
                  "traceId": "8a3c60f7d188f8fa79d48a391a778fa6",
                  "spanId":  "b7ad6b7169203331",
                  "attributes": [
                    { "key": "link.type", "value": { "stringValue": "batch.parent" } }
                  ]
                }
              ],
              "status": { "code": 0 },
              "flags": 1
            }
          ]
        }
      ]
    }
  ]
}
```

---

## 4. Signal 2 — Metrics

Metrics are where the model is richest and where most production incidents originate, because **temporality** and **aggregation** are subtle.

### 4.1 The Metric envelope and the five point types

A `Metric` has `name`, `description`, `unit` (UCUM string, e.g. `ms`, `By`, `1`) and exactly one `data` oneof:

| Point type | Monotonic? | Carries temporality? | Typical instrument |
|---|---|---|---|
| `Gauge`               | n/a       | no (implicit instantaneous) | observable gauge (temperature, queue depth) |
| `Sum`                 | configurable | yes | Counter (monotonic), UpDownCounter (non-monotonic) |
| `Histogram`           | n/a       | yes | explicit-bucket Histogram |
| `ExponentialHistogram`| n/a       | yes | base-2 exponential Histogram |
| `Summary`             | n/a       | no  | **legacy** — Prometheus quantiles; do not emit from OTel SDKs |

### 4.2 Temporality: Delta vs Cumulative

Every `Sum`, `Histogram`, and `ExponentialHistogram` carries an `aggregation_temporality`:

| Enum | Numeric | Meaning |
|---|---|---|
| `AGGREGATION_TEMPORALITY_UNSPECIFIED` | 0 | invalid |
| `AGGREGATION_TEMPORALITY_DELTA`       | 1 | value covers `(start, end]` — resets each interval |
| `AGGREGATION_TEMPORALITY_CUMULATIVE`  | 2 | value is the running total since `start_time_unix_nano` |

This is the single most exam-relevant *and* production-relevant decision in the metrics model:

| Dimension | Delta | Cumulative |
|---|---|---|
| Point meaning | change during the interval | total since start |
| Restart handling | trivially correct (new interval, new value) | needs reset detection (counter goes backwards ⇒ reset) |
| Backend fit | StatsD-style, AWS CloudWatch EMF, many SaaS | **Prometheus** (its native model) |
| Memory in SDK | must retain last-collection state briefly | must retain running totals for lifetime |
| Reaggregation across dimensions | simple addition | simple addition |
| Time alignment | sensitive to collection interval jitter | robust to jitter (rate computed at query time) |
| Loss of one datapoint | permanently loses that interval's delta | self-heals on next scrape (total is absolute) |
| Horizontal scaling / ephemeral pods | **preferred** — no long-lived series across pod churn | reset storms when pods churn |

**Rule of thumb for platforms:** if the final backend is Prometheus, keep **Cumulative** end-to-end. If the backend is delta-native (or you run highly ephemeral serverless workloads), emit **Delta**, or convert with the Collector's `cumulativetodelta` / `deltatocumulative` processor. Never let the two mix silently for the same series — that is the classic "rate spikes to infinity after a deploy" incident.

### 4.3 Histogram vs ExponentialHistogram

| Property | Explicit `Histogram` | `ExponentialHistogram` |
|---|---|---|
| Bucket boundaries | fixed, hand-picked `explicit_bounds` | derived from `scale`, auto-covering the range |
| Config burden | high — wrong bounds ⇒ useless percentiles | low — self-adjusting resolution |
| Wire size | proportional to bucket count you defined | compact; boundaries are implicit |
| Relative error | non-uniform (coarse where you guessed wrong) | bounded and uniform in log space |
| Mergeability across services | only if bounds match exactly | always mergeable (rescaled to min scale) |
| Best for | known, stable latency ranges | unknown/wide dynamic range (P99 tail hunting) |

The exponential histogram encodes buckets as `base = 2^(2^-scale)`. Bucket index `i` covers `(base^i, base^(i+1)]`. A `zero_count` and `zero_threshold` handle values at/near zero; `positive` and `negative` `Buckets` each carry an `offset` and a `bucket_counts` array. Higher `scale` ⇒ finer resolution ⇒ more buckets.

### 4.4 Exemplars — the metrics→traces bridge

An **Exemplar** is a raw measurement attached to an aggregated point that carries `trace_id`, `span_id`, `time_unix_nano`, the value, and `filtered_attributes`. This is *the* mechanism that lets you click a spike on a latency histogram and jump to an exemplar trace of a request that landed in that bucket. It is the metrics-side half of cross-signal correlation.

### 4.5 A complete OTLP/JSON metrics payload

```json
{
  "resourceMetrics": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "checkout" } }
        ]
      },
      "scopeMetrics": [
        {
          "scope": { "name": "io.opentelemetry.instrumentation.http", "version": "2.9.0" },
          "metrics": [
            {
              "name": "http.server.request.duration",
              "description": "Duration of inbound HTTP requests",
              "unit": "s",
              "histogram": {
                "aggregationTemporality": 2,
                "dataPoints": [
                  {
                    "startTimeUnixNano": "1723291140000000000",
                    "timeUnixNano":      "1723291200000000000",
                    "count": "1050",
                    "sum": 84.2,
                    "min": 0.002,
                    "max": 1.911,
                    "bucketCounts": ["500","300","180","60","10"],
                    "explicitBounds": [0.005, 0.01, 0.025, 0.1],
                    "attributes": [
                      { "key": "http.request.method", "value": { "stringValue": "POST" } },
                      { "key": "http.route", "value": { "stringValue": "/api/checkout" } },
                      { "key": "http.response.status_code", "value": { "intValue": "200" } }
                    ],
                    "exemplars": [
                      {
                        "timeUnixNano": "1723291195000000000",
                        "asDouble": 1.911,
                        "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
                        "spanId":  "00f067aa0ba902b7",
                        "filteredAttributes": [
                          { "key": "customer.tier", "value": { "stringValue": "premium" } }
                        ]
                      }
                    ]
                  }
                ]
              }
            },
            {
              "name": "http.server.active_requests",
              "unit": "{request}",
              "sum": {
                "aggregationTemporality": 2,
                "isMonotonic": false,
                "dataPoints": [
                  {
                    "startTimeUnixNano": "1723291140000000000",
                    "timeUnixNano":      "1723291200000000000",
                    "asInt": "7",
                    "attributes": [
                      { "key": "http.request.method", "value": { "stringValue": "POST" } }
                    ]
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  ]
}
```

> Note `explicit_bounds` has *N* entries and `bucket_counts` has *N+1* (the last bucket is `(+Inf]`). A mismatch of ±1 here is the most common malformed-histogram bug.

---

## 5. Signal 3 — Logs

OpenTelemetry did not invent a new log format from scratch; it defined a **LogRecord data model** into which existing log formats (syslog, JSON, log4j) are mapped. This is why logs were the last signal to stabilize.

### 5.1 The LogRecord

| Field | Type | Meaning |
|---|---|---|
| `time_unix_nano`          | fixed64 | when the event *occurred* (may be 0/unknown) |
| `observed_time_unix_nano` | fixed64 | when the collector/SDK *observed* it (always set) |
| `severity_number`         | enum (1–24) | normalized severity |
| `severity_text`           | string  | original level string (`"WARN"`, `"error"`) |
| `body`                    | `AnyValue` | the message — string *or* structured map |
| `attributes`              | KeyValue | structured fields (`http.request.method`, `db.statement`) |
| `trace_id` / `span_id`    | bytes   | **correlation to the emitting span** |
| `flags`                   | uint32  | log record flags (incl. trace flags) |
| `dropped_attributes_count`| uint32  | limit-dropped attributes |

**SeverityNumber** is normalized into six bands of four steps each — the key to comparing levels across heterogeneous sources:

| Band | Range | Example texts |
|---|---|---|
| TRACE | 1–4   | `TRACE`, `TRACE2` |
| DEBUG | 5–8   | `DEBUG`, `FINE` |
| INFO  | 9–12  | `INFO`, `NOTICE` |
| WARN  | 13–16 | `WARN`, `WARNING` |
| ERROR | 17–20 | `ERROR`, `SEVERE` |
| FATAL | 21–24 | `FATAL`, `CRITICAL`, `EMERGENCY` |

Because a log carrying the same `trace_id`/`span_id` as a span is *by construction* the same request, "show me all logs for this failed trace" becomes an exact index lookup instead of a timestamp-window guess. This is the correlation payoff the whole model exists to enable.

### 5.2 A complete OTLP/JSON logs payload

```json
{
  "resourceLogs": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "checkout" } }
        ]
      },
      "scopeLogs": [
        {
          "scope": { "name": "checkout.payments", "version": "2.4.1" },
          "logRecords": [
            {
              "timeUnixNano":         "1723291200140000000",
              "observedTimeUnixNano": "1723291200140500000",
              "severityNumber": 17,
              "severityText": "ERROR",
              "body": { "stringValue": "payment authorization declined by gateway" },
              "attributes": [
                { "key": "payment.gateway",  "value": { "stringValue": "stripe" } },
                { "key": "payment.decline_code", "value": { "stringValue": "insufficient_funds" } },
                { "key": "http.response.status_code", "value": { "intValue": "402" } }
              ],
              "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
              "spanId":  "00f067aa0ba902b7",
              "flags": 1
            }
          ]
        }
      ]
    }
  ]
}
```

---

## 6. OTLP transport: the encoding of the model

| Variant | Default port | Path(s) | Encoding | Notes |
|---|---|---|---|---|
| **OTLP/gRPC**       | `4317` | gRPC service methods | Protobuf (binary) | streaming-friendly, HTTP/2, best throughput |
| **OTLP/HTTP** (protobuf) | `4318` | `/v1/traces`, `/v1/metrics`, `/v1/logs` | Protobuf in body, `Content-Type: application/x-protobuf` | firewall/proxy-friendly |
| **OTLP/HTTP** (JSON) | `4318` | same paths | JSON, `Content-Type: application/json` | human-debuggable; byte fields hex-encoded |

Trade-off: gRPC gives the best density and native streaming but needs HTTP/2 end-to-end (many corporate proxies still break it); OTLP/HTTP-JSON is the least efficient but the only variant you can hand-craft with `curl` for debugging. All three carry the **identical logical model** — choosing one never changes the data, only the bytes on the wire.

---

## 7. Infrastructure: end-to-end pipeline manifests

### 7.1 Collector configuration exercising every signal

```yaml
# otelcol-config.yaml — validates all three signals of the data model
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # Guarantee service.name exists — the model's most critical Resource attribute
  resource:
    attributes:
      - key: service.name
        value: checkout
        action: insert            # insert = only if absent
      - key: deployment.environment
        value: production
        action: upsert
  # Enrich with K8s Resource attributes (semantic conventions k8s.*)
  k8sattributes:
    extract:
      metadata:
        - k8s.pod.name
        - k8s.namespace.name
        - k8s.node.name
  # Normalize temporality so a Prometheus backend never sees deltas
  cumulativetodelta: {}
  batch:
    timeout: 5s
    send_batch_size: 1024

exporters:
  debug:
    verbosity: detailed           # prints the decoded data model to stdout
  otlphttp/backend:
    endpoint: https://otel-gateway.observability.svc:4318
    tls:
      insecure: false

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [k8sattributes, resource, batch]
      exporters:  [debug, otlphttp/backend]
    metrics:
      receivers:  [otlp]
      processors: [k8sattributes, resource, batch]
      exporters:  [debug, otlphttp/backend]
    logs:
      receivers:  [otlp]
      processors: [k8sattributes, resource, batch]
      exporters:  [debug, otlphttp/backend]
  telemetry:
    logs:
      level: info
    metrics:
      level: detailed
      address: 0.0.0.0:8888
```

### 7.2 Kubernetes: OpenTelemetry Collector as a sidecar/deployment CR

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: gateway
  namespace: observability
spec:
  mode: deployment
  replicas: 2
  image: otel/opentelemetry-collector-contrib:0.109.0
  ports:
    - name: otlp-grpc
      port: 4317
    - name: otlp-http
      port: 4318
  config:
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    processors:
      batch: {}
    exporters:
      debug: { verbosity: detailed }
    service:
      pipelines:
        traces:  { receivers: [otlp], processors: [batch], exporters: [debug] }
        metrics: { receivers: [otlp], processors: [batch], exporters: [debug] }
        logs:    { receivers: [otlp], processors: [batch], exporters: [debug] }
```

### 7.3 SDK-side Resource configuration via environment

```yaml
# workload.env — how a service declares its Resource identity to the SDK
OTEL_SERVICE_NAME: checkout
OTEL_RESOURCE_ATTRIBUTES: "service.namespace=shop,service.version=2.4.1,deployment.environment=production"
OTEL_EXPORTER_OTLP_ENDPOINT: "http://gateway-collector.observability.svc:4318"
OTEL_EXPORTER_OTLP_PROTOCOL: "http/protobuf"
OTEL_METRICS_EXEMPLAR_FILTER: "trace_based"     # attach exemplars only for sampled spans
OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: "cumulative"
```

---

## 8. CLI: generating, sending, and decoding the model

### 8.1 Validate a collector config before shipping it

```console
$ otelcol-contrib validate --config otelcol-config.yaml
$ echo "exit=$?"
exit=0
```

A structural error surfaces immediately and non-zero:

```console
$ otelcol-contrib validate --config broken.yaml
Error: invalid configuration: service::pipelines::traces: references processor "resouce" which is not configured
$ echo "exit=$?"
exit=1
```

### 8.2 Generate real OTLP data with `telemetrygen`

```console
$ telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 \
    --traces 3 --child-spans 2 --service checkout
2026-08-10T14:03:11.204Z  info  traces/worker.go:99   traces generated  {"worker": 0, "traces": 3}
2026-08-10T14:03:11.205Z  info  traces/traces.go:78   stopping the exporter
```

```console
$ telemetrygen metrics --otlp-insecure --otlp-endpoint localhost:4317 \
    --metrics 5 --metric-type Histogram --service checkout
2026-08-10T14:03:40.881Z  info  metrics/worker.go:82  metrics generated  {"worker": 0, "metrics": 5}
```

### 8.3 Hand-craft an OTLP/HTTP-JSON trace with `curl`

```console
$ curl -sS -X POST http://localhost:4318/v1/traces \
    -H 'Content-Type: application/json' \
    --data-binary @trace.json -w '\nHTTP %{http_code}\n'

{"partialSuccess":{}}
HTTP 200
```

A `200` with an empty `partialSuccess` means every item was accepted. A partial rejection reports the count and reason inline:

```console
$ curl -sS -X POST http://localhost:4318/v1/traces \
    -H 'Content-Type: application/json' --data-binary @bad-trace.json

{"partialSuccess":{"rejectedSpans":"1","errorMessage":"span has an invalid trace_id (all zeroes)"}}
```

### 8.4 Read the decoded data model from the debug exporter

With the `debug` exporter at `verbosity: detailed`, the collector prints the reconstructed logical model — Resource, Scope, and each item — so you can confirm what actually arrived on the wire:

```console
$ kubectl -n observability logs deploy/gateway-collector | sed -n '/ResourceSpans/,/^$/p'
2026-08-10T14:03:11.310Z  info  Traces  {"resource spans": 1, "spans": 3}
ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
     -> service.namespace: Str(shop)
     -> telemetry.sdk.language: Str(go)
ScopeSpans #0
ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.27.0
InstrumentationScope telemetrygen 
Span #0
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Parent ID      : 
    ID             : 00f067aa0ba902b7
    Name           : POST /api/checkout
    Kind           : Server
    Start time     : 2026-08-10 14:03:11.2 +0000 UTC
    End time       : 2026-08-10 14:03:11.345 +0000 UTC
    Status code    : Unset
    Attributes:
         -> http.request.method: Str(POST)
         -> http.response.status_code: Int(200)
```

---

## 9. Verification and failure diagnosis

The failure modes below are ranked by how often they occur in production and how invisible they are to naive checks (a `200` from the endpoint proves *transport*, not *model correctness*).

| Symptom | Root cause in the data model | Diagnosis | Fix |
|---|---|---|---|
| Everything lands under `unknown_service` | `Resource` is missing `service.name` | `debug` exporter shows no `service.name` attribute | set `OTEL_SERVICE_NAME` or `resource` processor `insert` |
| Logs won't correlate to traces | `LogRecord.trace_id`/`span_id` empty | inspect a log record's byte fields — all zero | ensure log appender runs inside an active span context; enable trace-context log injection |
| Rate query spikes to ∞ after every deploy | temporality mismatch: delta series treated as cumulative (or a cumulative counter reset on pod restart) | check `aggregationTemporality` (1 vs 2) on the metric | pin one temporality end-to-end; use `deltatocumulative`/`cumulativetodelta`; enable reset detection |
| Percentiles are meaningless | explicit `Histogram` bounds don't cover the real latency range, or `bucket_counts` length ≠ `explicit_bounds`+1 | print the point; compare lengths | fix bounds, or switch to `ExponentialHistogram` |
| Backend index/cost explodes | high-cardinality value put in an **attribute** (request UUID, raw URL with query) | list distinct attribute values per key | move the value to a span attribute or drop it via `attributes`/`transform` processor |
| gRPC exporter fails behind proxy, HTTP works | OTLP/gRPC needs HTTP/2 end-to-end | test both `4317` and `4318` | switch `OTEL_EXPORTER_OTLP_PROTOCOL` to `http/protobuf` |
| `partialSuccess.rejectedSpans > 0` | invalid `trace_id`/`span_id` (all-zero), wrong byte length, or negative timestamps | read the `errorMessage` in the response | fix the emitting instrumentation; never fabricate IDs |
| Attributes silently missing | SDK attribute/event limits hit | check `dropped_attributes_count` / `dropped_events_count` > 0 | raise `OTEL_ATTRIBUTE_COUNT_LIMIT` or reduce emitted attributes |
| Metrics arrive but never update in Prometheus | Summary/Gauge where a Sum was expected, or `start_time_unix_nano` = 0 | inspect the point `data` oneof and start time | emit the correct instrument; always set a valid start time |

### Diagnostic drill — confirm cross-signal correlation is real

```console
# 1. Send a trace and capture its trace_id
$ telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 1 --service checkout
# 2. Confirm the same trace_id appears on the metric exemplar
$ kubectl -n observability logs deploy/gateway-collector | grep -A1 "Exemplar"
Exemplar #0
     -> Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736
# 3. Confirm a log record carries the identical trace_id
$ kubectl -n observability logs deploy/gateway-collector | grep -A2 "LogRecord" | grep "Trace ID"
     -> Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736
```

Three signals, one `trace_id` — that identity is the entire point of the data model, and this drill is how you *prove* it end-to-end rather than assume it.

### Inspect the Collector's own health metrics

```console
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver_accepted|exporter_sent|processor_dropped)'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 3
otelcol_exporter_sent_spans{exporter="otlphttp/backend"} 3
otelcol_processor_dropped_metric_points{processor="batch"} 0
```

`accepted` should equal `sent` minus anything intentionally dropped; a persistent gap is data loss inside the pipeline.

---

## 10. References

- OpenTelemetry — Data Model (Traces): https://opentelemetry.io/docs/specs/otel/trace/api/
- OpenTelemetry — Trace Data Model / SDK: https://opentelemetry.io/docs/specs/otel/trace/sdk/
- OpenTelemetry — Metrics Data Model: https://opentelemetry.io/docs/specs/otel/metrics/data-model/
- OpenTelemetry — Logs Data Model: https://opentelemetry.io/docs/specs/otel/logs/data-model/
- OpenTelemetry — Common (AnyValue, KeyValue, InstrumentationScope): https://opentelemetry.io/docs/specs/otel/common/
- OpenTelemetry — Resource Data Model: https://opentelemetry.io/docs/specs/otel/resource/sdk/
- OpenTelemetry Protocol (OTLP) Specification: https://opentelemetry.io/docs/specs/otlp/
- OTLP Protobuf definitions (proto files): https://github.com/open-telemetry/opentelemetry-proto
- OpenTelemetry Semantic Conventions: https://opentelemetry.io/docs/specs/semconv/
- W3C Trace Context Recommendation: https://www.w3.org/TR/trace-context/
- OpenTelemetry Collector — Configuration: https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry Operator (OpenTelemetryCollector CR): https://github.com/open-telemetry/opentelemetry-operator
- `telemetrygen` load generator: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
- OTCA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf