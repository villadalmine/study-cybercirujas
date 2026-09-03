# 704.4 — Tracing

**LPI DevOps Tools Engineer — Exam 701-100, v2.0.0**
**Weight: 3.33**

---

## 1. The Architectural Problem

### 1.1 Why metrics and logs stop working at a certain scale

A monolith fails in one place, so a stack trace is a complete causal explanation. A distributed system does not fail in one place — it fails *between* places. Once a single user action fans out across a dozen processes, three languages, a message broker and two managed databases, the three classic telemetry signals degrade in specific, predictable ways:

- **Metrics** are pre-aggregated. `http_request_duration_seconds{service="checkout"}` tells you the p99 is 4.2 s. It cannot tell you *which* 1% of requests, *why* they were slow, or *which downstream hop* consumed the time. Aggregation is lossy by construction, and the loss is exactly the information you need during an incident.
- **Logs** are per-process and unordered across processes. You can grep `checkout`, you can grep `payments`, but stitching the two together requires a correlation identifier that someone has to propagate — and if you are going to propagate an identifier anyway, you have re-invented tracing badly.
- **Neither answers the causality question**: *for this specific request, what happened, in what order, on which machines, and where did the latency actually go?*

Distributed tracing is the signal designed for that question. The unit of analysis is not the process, it is the **request**.

### 1.2 The three production failure modes tracing is built for

| Failure mode | What metrics show | What logs show | What a trace shows |
|---|---|---|---|
| **Tail latency** (p99 is 4 s, p50 is 40 ms) | A number, no attribution | Nothing — slow requests usually succeed and log nothing unusual | The 3.9 s spent in a single N+1 query loop inside `inventory`, 6 hops deep |
| **Cascading dependency failure** | Errors in 7 services at once; no ordering | 7 uncorrelated error streams | One trace with a single root cause span and six downstream `ERROR` spans that are consequences |
| **Unknown topology** ("who calls this service?") | Nothing | Nothing reliable | A service graph derived from `CLIENT`/`SERVER` span pairs |

### 1.3 The cardinality argument

This is the deepest architectural reason to run tracing rather than "more metrics". A Prometheus time series is a fixed label set; adding `user_id`, `tenant_id`, `order_id` or `request_id` as labels multiplies the series count and destroys the TSDB. Cardinality is the hard ceiling of the metrics model.

A span has **no such ceiling**. Span attributes are stored per-event, not per-series. `user.id`, `tenant.id`, `db.query.parameter` and `order.id` are free to attach. This inverts the usual guidance:

> **Rule of thumb:** if the dimension is unbounded, it belongs on a span, not on a metric label. Derive the low-cardinality metric *from* the spans (`spanmetrics` connector), and keep the high-cardinality detail in the trace.

### 1.4 The cost problem, and why sampling is a first-class design decision

100% trace retention for a system serving 50 k req/s at an average of 20 spans per request is 1 M spans/s. At ~500 bytes/span serialized that is ~500 MB/s ingested, ~43 TB/day. This is not a storage problem you solve with a bigger disk; it is an architecture problem you solve with **sampling policy**, and sampling policy is the single most consequential decision in a tracing platform. Section 4 covers it in depth.

---

## 2. The Data Model

### 2.1 Trace, span, context

```
Trace  60d0d0c9d5b7a1e1b8a2c3d4e5f60718   (128-bit, 32 hex chars)
│
├─ Span  a1b2c3d4e5f60718   SERVER   frontend        GET /checkout            0 ms ────────────────── 412 ms
│  │
│  ├─ Span  b2c3d4e5f6071829  CLIENT   frontend        POST /api/cart          12 ms ──── 61 ms
│  │  └─ Span  c3d4e5f60718293a  SERVER  cart          POST /api/cart          14 ms ─── 58 ms
│  │     └─ Span  d4e5f60718293a4b  CLIENT cart         SELECT carts           18 ms ── 55 ms
│  │
│  ├─ Span  e5f60718293a4b5c  CLIENT   frontend        POST /api/payment       65 ms ─────────────── 405 ms
│  │  └─ Span  f60718293a4b5c6d  SERVER  payments      POST /api/payment       67 ms ────────────── 402 ms
│  │     ├─ Span  0718293a4b5c6d7e CLIENT payments     acquirer.example.com    70 ms ───────────── 398 ms  ⚠ 328 ms
│  │     └─ Span  18293a4b5c6d7e8f PRODUCER payments   ledger.events publish  399 ms ─ 401 ms
│  │
│  └─ Span  293a4b5c6d7e8f90  INTERNAL frontend        render.template        406 ms ─ 411 ms
```

A **span** is the atomic record. Its required fields:

| Field | Type | Notes |
|---|---|---|
| `trace_id` | 16 bytes / 32 hex | Constant for every span in the request. All-zero is invalid. |
| `span_id` | 8 bytes / 16 hex | Unique within the trace. All-zero is invalid. |
| `parent_span_id` | 8 bytes / 16 hex | Empty ⇒ this is the **root span**. |
| `name` | string | **Low cardinality.** `GET /users/{id}`, never `GET /users/8412`. |
| `kind` | enum | `INTERNAL`, `SERVER`, `CLIENT`, `PRODUCER`, `CONSUMER` |
| `start_time_unix_nano` / `end_time_unix_nano` | uint64 | Wall clock. Skew between hosts is a real operational hazard — see §6.5. |
| `status` | `UNSET` \| `OK` \| `ERROR` | Only set `OK` when the application explicitly judges success. |
| `attributes` | key/value | Semantic conventions apply. |
| `events` | timestamped records | Exceptions, cache misses, GC pauses. |
| `links` | span refs | Cross-trace causality (batch consumers, fan-in). |
| `resource` | key/value | Immutable identity of the *emitter*: `service.name`, `k8s.pod.name`, `host.name`. |

**Span kind matters operationally.** `CLIENT`/`SERVER` pairs are what a service-graph generator uses to derive topology; `PRODUCER`/`CONSUMER` mark asynchronous boundaries where wall-clock nesting no longer implies blocking. Getting `kind` wrong produces a topology map that is silently wrong.

### 2.2 Context propagation — W3C Trace Context

Propagation is the entire mechanism by which a trace stays one trace. The interoperable standard is **W3C Trace Context** (a W3C Recommendation), which defines two HTTP headers.

```
traceparent: 00-60d0d0c9d5b7a1e1b8a2c3d4e5f60718-e5f60718293a4b5c-01
             ^^ ^------------------------------^ ^--------------^ ^^
             |  trace-id (16 bytes, hex)         parent-id        trace-flags
             version                             (the caller's    bit 0 = sampled
                                                  span-id)
```

```
tracestate: congo=t61rcWkgMzE,rojo=00f067aa0ba902b7
```

- `traceparent` is **required** and mutated at every hop: the receiver puts *its own* span-id into `parent-id` before calling the next service.
- `tracestate` is vendor-specific, ordered (most recent first), max 32 entries. Used for per-vendor sampling state (e.g. `ot=th:8` for OpenTelemetry consistent sampling threshold).
- `trace-flags` bit 0 (`01`) is the **sampled** flag. This is the wire signal that makes head-based sampling coherent across a whole request.
- **`baggage`** (a separate W3C spec) carries arbitrary user key/values across the whole trace: `baggage: tenant.tier=platinum,deploy.ring=canary`. Baggage is *not* automatically copied onto spans, and it crosses trust boundaries — never put secrets or PII in it.

### 2.3 Propagation format comparison

| Format | Headers | Trace-ID width | Status | When you still need it |
|---|---|---|---|---|
| **W3C Trace Context** | `traceparent`, `tracestate` | 128-bit | Standard; OTel default | Always. This is the target state. |
| **B3 multi** | `X-B3-TraceId`, `X-B3-SpanId`, `X-B3-ParentSpanId`, `X-B3-Sampled`, `X-B3-Flags` | 64 or 128-bit | Legacy (Zipkin) | Istio/Envoy meshes, older Spring Cloud Sleuth |
| **B3 single** | `b3: {trace}-{span}-{sampled}-{parent}` | 64 or 128-bit | Legacy | Header-budget-constrained proxies |
| **Jaeger** | `uber-trace-id: {trace}:{span}:{parent}:{flags}` | 64 or 128-bit | Legacy | Pre-OTel Jaeger client SDKs still in production |
| **AWS X-Ray** | `X-Amzn-Trace-Id: Root=1-5759e988-...;Parent=...;Sampled=1` | X-Ray format | Vendor | ALB / API Gateway / Lambda front doors |
| **OT Trace** | `ot-tracer-traceid`, … | 64-bit | Deprecated | LightStep legacy |

**Migration pattern:** configure the SDK to *extract* several formats and *inject* several, so a mixed fleet keeps traces whole during rollout.

```bash
export OTEL_PROPAGATORS=tracecontext,baggage,b3multi,jaeger
```

The first propagator that successfully extracts wins; all listed propagators inject.

### 2.4 Semantic conventions

Attribute names are a stable API. Backends build UIs, RED metrics and service graphs on them. OpenTelemetry semantic conventions went through a major HTTP rename that is still visible in production fleets:

| Concept | Legacy (pre-1.21) | Stable (current) |
|---|---|---|
| HTTP method | `http.method` | `http.request.method` |
| Status code | `http.status_code` | `http.response.status_code` |
| Full URL | `http.url` | `url.full` |
| Route template | `http.route` | `http.route` (unchanged) |
| Peer host | `net.peer.name` | `server.address` |
| Peer port | `net.peer.port` | `server.port` |
| DB statement | `db.statement` | `db.query.text` |
| DB system | `db.system` | `db.system.name` |

During migration, many SDKs accept `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup` to emit **both** sets, so dashboards and alerts can be cut over without a flag day.

---

## 3. Architecture: SDK → Collector → Backend

### 3.1 Why the OpenTelemetry Collector is non-optional in production

Exporting straight from the application SDK to the storage backend works in a demo and fails in production for five reasons:

1. **Backend coupling.** Changing Jaeger → Tempo means redeploying every service.
2. **Credential sprawl.** Every pod needs backend credentials.
3. **No central policy.** Redaction, tail sampling, attribute normalisation and rate limiting have to be implemented N times in N languages.
4. **No enrichment.** The application does not know its own `k8s.node.name`, cloud region or instance type.
5. **Backpressure.** SDK export queues are small; when the backend degrades, applications start dropping spans or, worse, blocking.

The Collector is a vendor-neutral pipeline binary that solves all five.

```
┌──────────────┐   OTLP    ┌──────────────────┐  OTLP+LB  ┌──────────────────┐  OTLP  ┌─────────┐
│ app + SDK    │──────────▶│ Collector AGENT  │──────────▶│ Collector GATEWAY│───────▶│ Jaeger  │
│ (in-process) │  gRPC     │ DaemonSet        │ routing_  │ Deployment (HPA) │        │ Tempo   │
│              │  :4317    │ - k8sattributes  │ key=      │ - tail_sampling  │        │ Zipkin  │
└──────────────┘           │ - resourcedetect │ traceID   │ - spanmetrics    │        └─────────┘
                           │ - batch          │           │ - redaction      │
                           └──────────────────┘           └──────────────────┘
```

The **two-tier** split exists for one hard technical reason: **tail-based sampling requires every span of a trace to arrive at the same collector instance.** A DaemonSet agent cannot satisfy that (spans of one trace originate on many nodes). The agent tier therefore uses the `loadbalancing` exporter with `routing_key: traceID` to hash-route consistently into a stateful gateway tier.

### 3.2 Collector pipeline component types

| Type | Role | Production-relevant examples |
|---|---|---|
| **Receivers** | Ingest | `otlp` (gRPC 4317 / HTTP 4318), `jaeger`, `zipkin`, `kafka`, `filelog` |
| **Processors** | Transform, ordered | `memory_limiter` (must be first), `k8sattributes`, `resourcedetection`, `tail_sampling`, `transform`, `filter`, `batch` (must be last) |
| **Exporters** | Emit | `otlp`, `otlphttp`, `loadbalancing`, `prometheus`, `debug`, `file` |
| **Connectors** | Pipeline-to-pipeline; consume one signal, produce another | `spanmetrics` (traces→metrics), `servicegraph` (traces→metrics), `forward` |
| **Extensions** | Non-pipeline capability | `health_check`, `pprof`, `zpages`, `basicauth`, `oauth2client`, `file_storage` |

> **Processor order is semantics, not style.** `memory_limiter` first (it must be able to refuse before anything allocates), `batch` last (batching before enrichment wastes work and breaks `k8sattributes` connection-based association). Putting `batch` before `tail_sampling` is a correctness bug, not a performance one.

### 3.3 Backend comparison

| | **Jaeger v2** | **Grafana Tempo** | **Zipkin** | **OpenSearch/Elastic APM** |
|---|---|---|---|---|
| Governance | CNCF (graduated) | Grafana Labs (AGPLv3) | OpenZipkin | Elastic / OpenSearch |
| Built on | OpenTelemetry Collector | Standalone (Cortex-lineage) | Standalone JVM | Elasticsearch |
| Native ingest | OTLP | OTLP, Jaeger, Zipkin | Zipkin v1/v2, OTLP via collector | OTLP |
| Storage | Cassandra, Elasticsearch/OpenSearch, ClickHouse, Badger, memory | **Object storage only** (S3/GCS/Azure) | Cassandra, ES, MySQL, memory | Elasticsearch |
| Index | Full attribute index | **Trace-ID only**, plus optional TraceQL block scan | Full index | Full index |
| Query language | UI filters + JSON API | **TraceQL** | UI filters | KQL / Lucene |
| Cost at scale | Index cost dominates; expensive | **Cheapest** — no index to maintain | Index cost dominates | Most expensive |
| Search latency | Fast, indexed | Slower for wide searches (block scan) | Fast | Fast |
| Metrics from spans | SPM (via `spanmetrics`) | Built-in `metrics_generator` | No | Yes |
| Best for | Full-fidelity search, mixed sampling | Very high volume, "store everything, search by ID" | Legacy estates | Teams already all-in on Elastic |

**Decision heuristic:** if your dominant workflow is *"I have a trace ID from a log line, show me the trace"*, Tempo's economics are unbeatable. If it is *"find me all traces where `tenant.id=acme` returned 503 last Tuesday"*, you need an index — Jaeger on Elasticsearch or ClickHouse.

---

## 4. Sampling

### 4.1 Strategy comparison

| Strategy | Decision point | Sees full trace? | Coherent across services? | Catches all errors? | Cost model |
|---|---|---|---|---|---|
| **AlwaysOn** | Root | n/a | Yes | Yes | Unbounded |
| **AlwaysOff** | Root | n/a | Yes | No | Zero |
| **TraceIdRatioBased** | Root, hash of trace-id | No | Only if every service uses the same ratio | No | Linear, predictable |
| **ParentBased(root=ratio)** | Root decides, children obey `trace-flags` | No | **Yes** | No | Linear, predictable |
| **Rate limiting** (spans/s) | Root | No | Weakly | No | Hard-capped |
| **Jaeger adaptive/remote** | Root, per-operation, server-driven | No | Yes | Approximately | Self-tuning |
| **Tail-based** | Gateway, after `decision_wait` | **Yes** | Yes | **Yes** | Buffer memory + full ingest to gateway |

**The trade-off in one sentence:** head sampling is cheap and decides *before* it knows whether the request was interesting; tail sampling knows everything and costs you full-fidelity ingest and a stateful, memory-hungry gateway tier.

### 4.2 Head sampling — the correct default

`parentbased_traceidratio` is the only head sampler that produces *complete* traces. A naïve independent `traceidratio` at each service yields fragments: service A samples, service B does not, and you get a two-span stub.

```bash
export OTEL_TRACES_SAMPLER=parentbased_traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.05      # 5% of root requests, whole trace or nothing
```

The decision is deterministic on the trace-id hash, so **every SDK in every language reaches the same verdict for the same trace-id** — which is what makes it safe even before `trace-flags` propagation is fully working.

### 4.3 Tail sampling — the production policy set

The realistic production policy is a **union**: keep everything interesting, plus a statistical baseline so your latency histograms are not survivorship-biased.

- All traces with an `ERROR` status → 100%
- All traces slower than the SLO threshold → 100%
- Platinum-tier tenants → 50%
- Everything else → 2% baseline

Two operational constraints govern `tail_sampling`:

1. **`decision_wait` is a latency/completeness trade-off.** Too short and you decide before slow spans arrive, systematically discarding exactly the slow traces you wanted. Set it above your p99.9 request duration.
2. **`num_traces × avg spans × span size` is resident memory.** 200 000 traces × 20 spans × 500 B ≈ 2 GB before overhead. Size the gateway accordingly and always pair with `memory_limiter`.

---

## 5. Complete Infrastructure Manifests

Everything below is deployed into an `observability` namespace and is self-consistent: agent tier → gateway tier → Tempo, plus an instrumented application.

### 5.1 Namespace and RBAC for `k8sattributes`

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    app.kubernetes.io/part-of: telemetry-platform
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-collector
subjects:
  - kind: ServiceAccount
    name: otel-collector
    namespace: observability
```

### 5.2 Agent tier — DaemonSet + ConfigMap

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-agent-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
            max_recv_msg_size_mib: 8
            keepalive:
              server_parameters:
                max_connection_age: 30s
                max_connection_age_grace: 5s
          http:
            endpoint: 0.0.0.0:4318
      zipkin:
        endpoint: 0.0.0.0:9411
      jaeger:
        protocols:
          thrift_http:
            endpoint: 0.0.0.0:14268
          grpc:
            endpoint: 0.0.0.0:14250

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20

      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        filter:
          node_from_env_var: KUBE_NODE_NAME
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.deployment.name
            - k8s.statefulset.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.pod.start_time
            - k8s.node.name
            - k8s.container.name
            - container.image.name
            - container.image.tag
          labels:
            - tag_name: service.version
              key: app.kubernetes.io/version
              from: pod
            - tag_name: deploy.ring
              key: deploy.example.com/ring
              from: pod
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
          - sources:
              - from: resource_attribute
                name: k8s.pod.uid
          - sources:
              - from: connection

      resourcedetection/env:
        detectors: [env, system]
        timeout: 5s
        override: false

      transform/redact:
        error_mode: ignore
        trace_statements:
          - context: span
            statements:
              - replace_pattern(attributes["url.full"], "(token|api_key)=[^&]*", "$$1=REDACTED")
              - delete_key(attributes, "http.request.header.authorization")
              - delete_key(attributes, "db.query.parameter.password")

      batch:
        send_batch_size: 8192
        send_batch_max_size: 16384
        timeout: 2s

    exporters:
      loadbalancing:
        routing_key: traceID
        protocol:
          otlp:
            timeout: 10s
            tls:
              insecure: true
            sending_queue:
              enabled: true
              num_consumers: 10
              queue_size: 5000
            retry_on_failure:
              enabled: true
              initial_interval: 5s
              max_interval: 30s
              max_elapsed_time: 300s
        resolver:
          k8s:
            service: otel-gateway-headless.observability
            ports:
              - 4317

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      pprof:
        endpoint: 127.0.0.1:1777
      zpages:
        endpoint: 127.0.0.1:55679

    service:
      extensions: [health_check, pprof, zpages]
      telemetry:
        logs:
          level: info
          encoding: json
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
      pipelines:
        traces:
          receivers: [otlp, zipkin, jaeger]
          processors:
            - memory_limiter
            - k8sattributes
            - resourcedetection/env
            - transform/redact
            - batch
          exporters: [loadbalancing]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-agent
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-agent
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-agent
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-agent
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8888"
    spec:
      serviceAccountName: otel-collector
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.115.1
          args: ["--config=/conf/config.yaml"]
          env:
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: GOMEMLIMIT
              value: "800MiB"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "k8s.cluster.name=prod-eu-1,deployment.environment=production"
          ports:
            - name: otlp-grpc
              containerPort: 4317
              hostPort: 4317
              protocol: TCP
            - name: otlp-http
              containerPort: 4318
              hostPort: 4318
              protocol: TCP
            - name: zipkin
              containerPort: 9411
              protocol: TCP
            - name: metrics
              containerPort: 8888
              protocol: TCP
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              memory: 1Gi
          livenessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 5
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /conf
      volumes:
        - name: config
          configMap:
            name: otel-agent-config
            items:
              - key: config.yaml
                path: config.yaml
```

> **Note on `GOMEMLIMIT`:** without it, the Go runtime happily grows past the container limit and the kernel OOM-kills the collector before `memory_limiter` ever refuses a batch. Set it to ~80% of the memory limit. This single line prevents the most common collector outage.

### 5.3 Gateway tier — tail sampling, span metrics, service graph

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-gateway-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
            max_recv_msg_size_mib: 16
          http:
            endpoint: 0.0.0.0:4318

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 75
        spike_limit_percentage: 15

      tail_sampling:
        decision_wait: 30s
        num_traces: 200000
        expected_new_traces_per_sec: 4000
        policies:
          - name: keep-all-errors
            type: status_code
            status_code:
              status_codes: [ERROR]

          - name: keep-http-5xx
            type: numeric_attribute
            numeric_attribute:
              key: http.response.status_code
              min_value: 500
              max_value: 599

          - name: keep-slow-requests
            type: latency
            latency:
              threshold_ms: 1500

          - name: keep-explicitly-marked
            type: boolean_attribute
            boolean_attribute:
              key: sampling.priority.force
              value: true

          - name: platinum-tenants-half
            type: and
            and:
              and_sub_policy:
                - name: is-platinum
                  type: string_attribute
                  string_attribute:
                    key: tenant.tier
                    values: [platinum]
                    enabled_regex_matching: false
                - name: half
                  type: probabilistic
                  probabilistic:
                    sampling_percentage: 50

          - name: drop-health-checks
            type: and
            and:
              and_sub_policy:
                - name: is-healthz
                  type: string_attribute
                  string_attribute:
                    key: http.route
                    values: ["/healthz", "/readyz", "/metrics"]
                - name: none
                  type: probabilistic
                  probabilistic:
                    sampling_percentage: 0

          - name: statistical-baseline
            type: probabilistic
            probabilistic:
              sampling_percentage: 2

      batch:
        send_batch_size: 8192
        send_batch_max_size: 16384
        timeout: 5s

    connectors:
      spanmetrics:
        histogram:
          explicit:
            buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2s, 5s, 10s, 30s]
        dimensions:
          - name: http.request.method
          - name: http.response.status_code
          - name: http.route
          - name: deployment.environment
          - name: k8s.namespace.name
        exclude_dimensions: ["span.kind"]
        exemplars:
          enabled: true
        dimensions_cache_size: 100000
        metrics_flush_interval: 15s
        metrics_expiration: 5m
        namespace: traces.span.metrics

      servicegraph:
        latency_histogram_buckets: [1ms, 5ms, 10ms, 50ms, 100ms, 500ms, 1s, 5s, 10s]
        dimensions: [k8s.cluster.name, k8s.namespace.name]
        store:
          ttl: 5s
          max_items: 200000
        cache_loop: 1m
        store_expiration_loop: 2s

    exporters:
      otlp/tempo:
        endpoint: tempo.observability.svc.cluster.local:4317
        tls:
          insecure: true
        sending_queue:
          enabled: true
          num_consumers: 20
          queue_size: 10000
          storage: file_storage/queue
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 60s
          max_elapsed_time: 600s

      prometheus:
        endpoint: 0.0.0.0:8889
        enable_open_metrics: true
        resource_to_telemetry_conversion:
          enabled: true

      debug:
        verbosity: basic
        sampling_initial: 5
        sampling_thereafter: 500

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      pprof:
        endpoint: 127.0.0.1:1777
      zpages:
        endpoint: 0.0.0.0:55679
      file_storage/queue:
        directory: /var/lib/otelcol/queue
        timeout: 10s

    service:
      extensions: [health_check, pprof, zpages, file_storage/queue]
      telemetry:
        logs:
          level: info
          encoding: json
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, tail_sampling, batch]
          exporters: [otlp/tempo, spanmetrics, servicegraph]

        metrics/derived:
          receivers: [spanmetrics, servicegraph]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
---
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway-headless
  namespace: observability
spec:
  clusterIP: None
  publishNotReadyAddresses: false
  selector:
    app.kubernetes.io/name: otel-gateway
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-gateway
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: otel-gateway
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
    - name: metrics
      port: 8888
      targetPort: 8888
    - name: prom-derived
      port: 8889
      targetPort: 8889
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: otel-gateway
  namespace: observability
spec:
  serviceName: otel-gateway-headless
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-gateway
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8888"
    spec:
      serviceAccountName: otel-collector
      terminationGracePeriodSeconds: 60
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: otel-gateway
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.115.1
          args: ["--config=/conf/config.yaml"]
          env:
            - name: GOMEMLIMIT
              value: "6GiB"
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: otlp-http
              containerPort: 4318
            - name: metrics
              containerPort: 8888
            - name: prom-derived
              containerPort: 8889
            - name: zpages
              containerPort: 55679
          resources:
            requests:
              cpu: "2"
              memory: 6Gi
            limits:
              memory: 8Gi
          livenessProbe:
            httpGet:
              path: /
              port: 13133
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /
              port: 13133
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /conf
            - name: queue
              mountPath: /var/lib/otelcol/queue
      volumes:
        - name: config
          configMap:
            name: otel-gateway-config
  volumeClaimTemplates:
    - metadata:
        name: queue
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 20Gi
```

> **Why a `StatefulSet` and not a `Deployment`:** the `loadbalancing` exporter's k8s resolver hashes trace-IDs onto the current endpoint set. Stable identities plus `Parallel` pod management minimise the reshuffling window during rollouts — every reshuffle splits in-flight traces across two gateways and corrupts tail-sampling decisions for `decision_wait` seconds. The PVC backs the persistent sending queue so a restart does not drop buffered spans.

### 5.4 Backend — Grafana Tempo (monolithic, S3)

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  namespace: observability
data:
  tempo.yaml: |
    server:
      http_listen_port: 3200
      grpc_listen_port: 9095
      log_level: info

    distributor:
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318
        jaeger:
          protocols:
            grpc:
              endpoint: 0.0.0.0:14250
            thrift_http:
              endpoint: 0.0.0.0:14268
        zipkin:
          endpoint: 0.0.0.0:9411
      log_received_spans:
        enabled: false

    ingester:
      max_block_duration: 5m
      max_block_bytes: 524288000
      complete_block_timeout: 15m

    compactor:
      compaction:
        block_retention: 720h
        compacted_block_retention: 1h
        compaction_window: 1h
        max_compaction_objects: 6000000

    metrics_generator:
      registry:
        external_labels:
          source: tempo
          cluster: prod-eu-1
      storage:
        path: /var/tempo/generator/wal
        remote_write:
          - url: http://prometheus.observability.svc.cluster.local:9090/api/v1/write
            send_exemplars: true
      traces_storage:
        path: /var/tempo/generator/traces
      processor:
        service_graphs:
          max_items: 20000
          wait: 10s
        span_metrics:
          histogram_buckets: [0.005, 0.01, 0.05, 0.1, 0.5, 1, 2.5, 5, 10]

    querier:
      max_concurrent_queries: 20
      search:
        query_timeout: 60s

    query_frontend:
      max_outstanding_per_tenant: 2000
      search:
        concurrent_jobs: 1000
        max_duration: 168h

    storage:
      trace:
        backend: s3
        wal:
          path: /var/tempo/wal
        local:
          path: /var/tempo/blocks
        s3:
          bucket: tempo-traces-prod-eu-1
          endpoint: s3.eu-central-1.amazonaws.com
          region: eu-central-1
          insecure: false
        pool:
          max_workers: 100
          queue_depth: 10000
        block:
          version: vParquet4

    overrides:
      defaults:
        metrics_generator:
          processors: [service-graphs, span-metrics, local-blocks]
        ingestion:
          rate_limit_bytes: 50000000
          burst_size_bytes: 100000000
          max_traces_per_user: 200000
        global:
          max_bytes_per_trace: 50000000
---
apiVersion: v1
kind: Service
metadata:
  name: tempo
  namespace: observability
spec:
  selector:
    app.kubernetes.io/name: tempo
  ports:
    - name: http
      port: 3200
      targetPort: 3200
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: tempo
  namespace: observability
spec:
  serviceName: tempo
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: tempo
  template:
    metadata:
      labels:
        app.kubernetes.io/name: tempo
    spec:
      serviceAccountName: tempo
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
      containers:
        - name: tempo
          image: grafana/tempo:2.6.1
          args:
            - "-config.file=/etc/tempo/tempo.yaml"
            - "-target=all"
          env:
            - name: AWS_REGION
              value: eu-central-1
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: tempo-s3
                  key: access_key_id
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: tempo-s3
                  key: secret_access_key
          ports:
            - containerPort: 3200
            - containerPort: 4317
            - containerPort: 4318
          resources:
            requests:
              cpu: "1"
              memory: 4Gi
            limits:
              memory: 8Gi
          readinessProbe:
            httpGet:
              path: /ready
              port: 3200
            initialDelaySeconds: 20
          volumeMounts:
            - name: config
              mountPath: /etc/tempo
            - name: data
              mountPath: /var/tempo
      volumes:
        - name: config
          configMap:
            name: tempo-config
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 100Gi
```

### 5.5 Alternative backend — Jaeger v2 with Elasticsearch

Jaeger v2 is itself an OpenTelemetry Collector distribution: the same `receivers`/`processors`/`exporters`/`extensions` grammar, plus Jaeger-specific storage and query extensions.

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: jaeger-config
  namespace: observability
data:
  jaeger.yaml: |
    service:
      extensions: [jaeger_storage, jaeger_query, healthcheckv2]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [jaeger_storage_exporter]
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

    extensions:
      healthcheckv2:
        use_v2: true
        http:
          endpoint: 0.0.0.0:13133

      jaeger_query:
        storage:
          traces: es_main
        base_path: /
        http:
          endpoint: 0.0.0.0:16686
        grpc:
          endpoint: 0.0.0.0:16685

      jaeger_storage:
        backends:
          es_main:
            elasticsearch:
              server_urls:
                - https://elasticsearch.observability.svc.cluster.local:9200
              indices:
                index_prefix: jaeger
                spans:
                  date_layout: "2006-01-02"
                  rollover_frequency: day
                  shards: 5
                  replicas: 1
              bulk:
                size: 5000000
                workers: 10
                flush_interval: 200ms
              tls:
                insecure_skip_verify: false
              auth:
                basic:
                  username: jaeger
                  password_file: /etc/jaeger/es-password

    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        send_batch_size: 5000
        timeout: 5s

    exporters:
      jaeger_storage_exporter:
        trace_storage: es_main
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: observability
spec:
  selector:
    app.kubernetes.io/name: jaeger
  ports:
    - name: ui
      port: 16686
      targetPort: 16686
    - name: otlp-grpc
      port: 4317
    - name: otlp-http
      port: 4318
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: observability
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: jaeger
  template:
    metadata:
      labels:
        app.kubernetes.io/name: jaeger
    spec:
      containers:
        - name: jaeger
          image: jaegertracing/jaeger:2.1.0
          args: ["--config", "/etc/jaeger/jaeger.yaml"]
          ports:
            - containerPort: 16686
            - containerPort: 4317
            - containerPort: 4318
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
            limits:
              memory: 4Gi
          readinessProbe:
            httpGet:
              path: /status
              port: 13133
          volumeMounts:
            - name: config
              mountPath: /etc/jaeger
            - name: es-credentials
              mountPath: /etc/jaeger/es-password
              subPath: es-password
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: jaeger-config
        - name: es-credentials
          secret:
            secretName: jaeger-es
```

**Jaeger port reference (still exam-relevant):**

| Port | Protocol | Purpose |
|---|---|---|
| 4317 | gRPC | OTLP — the modern ingest path |
| 4318 | HTTP | OTLP/HTTP, path `/v1/traces` |
| 16686 | HTTP | Query API + web UI |
| 16685 | gRPC | Query gRPC API |
| 14268 | HTTP | Legacy Jaeger Thrift collector |
| 14250 | gRPC | Legacy Jaeger model.proto collector |
| 9411 | HTTP | Zipkin-compatible ingest |
| 13133 | HTTP | Health check |
| 5778 | HTTP | Remote sampling configuration |

The Jaeger v1 **agent** (UDP 6831/6832) is gone in v2 — its role is served by an OTel Collector DaemonSet.

### 5.6 Instrumented application — zero-code injection via the OpenTelemetry Operator

```yaml
---
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: default-instrumentation
  namespace: shop
spec:
  exporter:
    endpoint: http://$(NODE_IP):4318
  propagators:
    - tracecontext
    - baggage
    - b3multi
  sampler:
    type: parentbased_traceidratio
    argument: "0.05"
  resource:
    addK8sUIDAttributes: true
    resourceAttributes:
      deployment.environment: production
  env:
    - name: OTEL_EXPORTER_OTLP_PROTOCOL
      value: http/protobuf
    - name: OTEL_SEMCONV_STABILITY_OPT_IN
      value: http/dup
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:0.50b0
    env:
      - name: OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED
        value: "true"
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.10.0
    env:
      - name: OTEL_INSTRUMENTATION_JDBC_ENABLED
        value: "true"
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.53.0
  go:
    image: ghcr.io/open-telemetry/opentelemetry-go-instrumentation/autoinstrumentation-go:v0.19.0-alpha
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/version: "3.4.1"
spec:
  replicas: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
        app.kubernetes.io/version: "3.4.1"
      annotations:
        instrumentation.opentelemetry.io/inject-python: "default-instrumentation"
    spec:
      containers:
        - name: checkout
          image: registry.example.com/shop/checkout:3.4.1
          ports:
            - containerPort: 8080
          env:
            - name: NODE_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: OTEL_SERVICE_NAME
              value: checkout
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=shop,service.version=3.4.1"
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              memory: 512Mi
```

### 5.7 Manual instrumentation where it matters

Auto-instrumentation gives you the boundaries (HTTP in, HTTP out, DB, queue). It cannot tell you which *business* step was slow. Add manual spans at decision points only.

**Python:**

```python
from opentelemetry import trace, baggage, context
from opentelemetry.trace import SpanKind, Status, StatusCode
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

resource = Resource.create({
    "service.name": "checkout",
    "service.version": "3.4.1",
    "service.namespace": "shop",
    "deployment.environment": "production",
})

provider = TracerProvider(
    resource=resource,
    sampler=ParentBased(root=TraceIdRatioBased(0.05)),
)
provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(endpoint="http://otel-agent:4317", insecure=True),
        max_queue_size=8192,
        max_export_batch_size=1024,
        schedule_delay_millis=2000,
        export_timeout_millis=30000,
    )
)
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("shop.checkout", "3.4.1")


def submit_order(order):
    with tracer.start_as_current_span(
        "checkout.submit_order",
        kind=SpanKind.INTERNAL,
        attributes={
            "order.id": order.id,               # high cardinality: fine on a span
            "order.item_count": len(order.items),
            "order.total_cents": order.total_cents,
            "tenant.id": order.tenant_id,
        },
    ) as span:
        ctx = baggage.set_baggage("tenant.tier", order.tenant_tier)
        token = context.attach(ctx)
        try:
            reserve_inventory(order)
            span.add_event("inventory.reserved",
                           attributes={"warehouse.id": order.warehouse_id})
            charge = authorize_payment(order)
            span.set_attribute("payment.authorization_code", charge.auth_code)
            span.set_status(Status(StatusCode.OK))
            return charge
        except PaymentDeclined as exc:
            # A declined card is a business outcome, NOT a system error.
            span.set_attribute("payment.decline_reason", exc.reason)
            span.add_event("payment.declined", attributes={"reason": exc.reason})
            raise
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            raise
        finally:
            context.detach(token)
```

> **The `ERROR` status discipline:** mark a span `ERROR` only when *your service* failed. A `404`, a validation rejection or a declined card is a correct outcome. Teams that mark every non-2xx as `ERROR` destroy their own tail-sampling policy: the "keep all errors" rule then keeps 30% of traffic and the sampling budget evaporates.

**Go — propagation across an asynchronous Kafka boundary**, which is where auto-instrumentation most often breaks the trace:

```go
package orders

import (
	"context"

	"github.com/segmentio/kafka-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("shop/orders")

// kafkaCarrier adapts kafka-go headers to the TextMapCarrier interface so that
// the W3C traceparent survives the queue hop.
type kafkaCarrier struct{ msg *kafka.Message }

func (c kafkaCarrier) Get(key string) string {
	for _, h := range c.msg.Headers {
		if h.Key == key {
			return string(h.Value)
		}
	}
	return ""
}

func (c kafkaCarrier) Set(key, value string) {
	for i, h := range c.msg.Headers {
		if h.Key == key {
			c.msg.Headers[i].Value = []byte(value)
			return
		}
	}
	c.msg.Headers = append(c.msg.Headers, kafka.Header{Key: key, Value: []byte(value)})
}

func (c kafkaCarrier) Keys() []string {
	keys := make([]string, 0, len(c.msg.Headers))
	for _, h := range c.msg.Headers {
		keys = append(keys, h.Key)
	}
	return keys
}

func Publish(ctx context.Context, w *kafka.Writer, topic string, payload []byte) error {
	ctx, span := tracer.Start(ctx, topic+" publish",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "kafka"),
			attribute.String("messaging.destination.name", topic),
			attribute.Int("messaging.message.body.size", len(payload)),
		),
	)
	defer span.End()

	msg := kafka.Message{Topic: topic, Value: payload}
	otel.GetTextMapPropagator().Inject(ctx, kafkaCarrier{msg: &msg})
	return w.WriteMessages(ctx, msg)
}

func Consume(ctx context.Context, msg kafka.Message, handle func(context.Context, []byte) error) error {
	// Extract restores the producer's context; WithLinks is the alternative when
	// one consumer span aggregates a batch from many producers.
	parent := otel.GetTextMapPropagator().Extract(ctx, kafkaCarrier{msg: &msg})

	ctx, span := tracer.Start(parent, msg.Topic+" process",
		trace.WithSpanKind(trace.SpanKindConsumer),
		trace.WithAttributes(
			attribute.String("messaging.system", "kafka"),
			attribute.String("messaging.destination.name", msg.Topic),
			attribute.Int("messaging.kafka.partition", msg.Partition),
			attribute.Int64("messaging.kafka.offset", msg.Offset),
		),
	)
	defer span.End()

	return handle(ctx, msg.Value)
}

var _ propagation.TextMapCarrier = kafkaCarrier{}
```

### 5.8 SDK environment variable reference

| Variable | Effect | Typical production value |
|---|---|---|
| `OTEL_SERVICE_NAME` | Sets `service.name` (mandatory identity) | `checkout` |
| `OTEL_RESOURCE_ATTRIBUTES` | Extra resource K/V, comma-separated | `service.version=3.4.1,deployment.environment=production` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Base endpoint **including scheme** | `http://otel-agent:4318` |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | Signal-specific; for HTTP must include `/v1/traces` | `http://otel-agent:4318/v1/traces` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` \| `http/protobuf` \| `http/json` | `http/protobuf` |
| `OTEL_EXPORTER_OTLP_HEADERS` | Auth headers | `api-key=...` |
| `OTEL_TRACES_SAMPLER` | Sampler name | `parentbased_traceidratio` |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler argument | `0.05` |
| `OTEL_PROPAGATORS` | Extract/inject formats | `tracecontext,baggage,b3multi` |
| `OTEL_BSP_MAX_QUEUE_SIZE` | Batch processor queue | `8192` |
| `OTEL_BSP_SCHEDULE_DELAY` | Export interval (ms) | `2000` |
| `OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT` | Cap per span | `128` |
| `OTEL_SDK_DISABLED` | Kill switch | `false` |

> **The endpoint gotcha, in exam terms:** with `OTEL_EXPORTER_OTLP_ENDPOINT` the SDK appends `/v1/traces` for HTTP; with `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` it does **not**. Half of "no traces are arriving" incidents are this one rule plus a missing `http://` scheme.

---

## 6. Verification and Failure Diagnosis

### 6.1 Bring-up: prove the pipeline before blaming the application

```console
$ podman run --rm -d --name otelcol \
    -p 4317:4317 -p 4318:4318 -p 8888:8888 -p 55679:55679 \
    -v "$PWD/config.yaml:/etc/otelcol/config.yaml:Z" \
    otel/opentelemetry-collector-contrib:0.115.1 \
    --config=/etc/otelcol/config.yaml
6f3a1d9c04b7e2f18a5c3d9e7b21c4a806f5e93d1b7c2a4e6f80d5b3c1a9e742

$ podman exec otelcol /otelcol-contrib validate --config=file:/etc/otelcol/config.yaml
$ echo $?
0
```

A non-zero exit prints the offending path — this is the fastest config-syntax check and belongs in CI:

```console
$ podman run --rm -v "$PWD/broken.yaml:/c.yaml:Z" \
    otel/opentelemetry-collector-contrib:0.115.1 validate --config=file:/c.yaml
Error: failed to get config: cannot unmarshal the configuration: decoding failed due to the
following error(s):

error decoding 'processors': unknown type: "tail_sampling_v2" for id: "tail_sampling_v2"
(valid values: [attributes batch cumulativetodelta deltatorate filter groupbyattrs
groupbytrace k8sattributes memory_limiter metricstransform probabilistic_sampler
redaction remotetap resource resourcedetection routing span tail_sampling transform])
$ echo $?
1
```

Confirm the listeners are actually bound:

```console
$ ss -lntp | grep -E '4317|4318|8888'
LISTEN 0  4096  *:4317  *:*  users:(("otelcol-contrib",pid=1,fd=12))
LISTEN 0  4096  *:4318  *:*  users:(("otelcol-contrib",pid=1,fd=14))
LISTEN 0  4096  *:8888  *:*  users:(("otelcol-contrib",pid=1,fd=9))
```

### 6.2 Inject a synthetic span end-to-end

**Raw OTLP/HTTP with JSON** — no SDK, no application, no ambiguity:

```console
$ cat > /tmp/span.json <<'EOF'
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "smoke-test"}},
        {"key": "deployment.environment", "value": {"stringValue": "production"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "manual-smoke", "version": "1.0.0"},
      "spans": [{
        "traceId": "5b8efff798038103d269b633813fc60c",
        "spanId": "eee19b7ec3c1b174",
        "name": "GET /healthz",
        "kind": 2,
        "startTimeUnixNano": "1756900000000000000",
        "endTimeUnixNano": "1756900000123000000",
        "attributes": [
          {"key": "http.request.method", "value": {"stringValue": "GET"}},
          {"key": "http.route", "value": {"stringValue": "/healthz"}},
          {"key": "http.response.status_code", "value": {"intValue": "200"}}
        ],
        "status": {"code": 1}
      }]
    }]
  }]
}
EOF

$ curl -sS -i -X POST http://localhost:4318/v1/traces \
    -H 'Content-Type: application/json' \
    --data-binary @/tmp/span.json
HTTP/1.1 200 OK
Content-Type: application/json
Date: Wed, 03 Sep 2026 09:41:07 GMT
Content-Length: 21

{"partialSuccess":{}}
```

`{"partialSuccess":{}}` with HTTP 200 is full acceptance. A populated `partialSuccess.rejectedSpans` means the collector took some and dropped some — always read the body, never just the status code.

**With `otel-cli`**, for scripted CI smoke tests:

```console
$ export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
$ otel-cli span --service smoke-test --name "deploy.verify" \
    --attrs "ci.pipeline=release,ci.build=4711" \
    --kind internal --verbose
trace_id: 4f1a2b3c5d6e7f8091a2b3c4d5e6f708
 span_id: 91a2b3c4d5e6f708
 endpoint: localhost:4317 (grpc)
 status: sent
```

### 6.3 Read the collector's own telemetry — the single most useful diagnostic

```console
$ curl -s http://localhost:8888/metrics | grep -E '^otelcol_(receiver|processor|exporter)' | sort
otelcol_exporter_queue_capacity{exporter="otlp/tempo"} 10000
otelcol_exporter_queue_size{exporter="otlp/tempo"} 47
otelcol_exporter_send_failed_spans_total{exporter="otlp/tempo"} 0
otelcol_exporter_sent_spans_total{exporter="otlp/tempo"} 1284933
otelcol_processor_batch_batch_send_size_bucket{le="10000",processor="batch"} 3122
otelcol_processor_batch_timeout_trigger_send_total{processor="batch"} 1877
otelcol_processor_refused_spans_total{processor="memory_limiter"} 0
otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc"} 1284933
otelcol_receiver_refused_spans_total{receiver="otlp",transport="grpc"} 0
```

**The four numbers that explain almost every incident:**

| Metric | Healthy | What a non-zero / rising value means |
|---|---|---|
| `otelcol_receiver_refused_spans_total` | 0 | Collector is rejecting ingest — almost always `memory_limiter` back-pressure |
| `otelcol_processor_refused_spans_total{processor="memory_limiter"}` | 0 | Memory ceiling hit; raise limits or scale out |
| `otelcol_exporter_send_failed_spans_total` | 0 | Backend unreachable, TLS failure, auth failure, or quota rejection |
| `otelcol_exporter_queue_size` vs `_capacity` | < 50% | Sustained near-capacity ⇒ backend is slower than ingest; drops are imminent |

A **healthy** pipeline satisfies `receiver_accepted ≈ exporter_sent` (allowing for sampling drops, which you should account for separately via `tail_sampling` metrics).

### 6.4 zPages — live in-process introspection

```console
$ curl -s "http://localhost:55679/debug/tracez" | head -30
TraceZ Summary
Span Name                                    Running    Latency Samples             Errors
                                                        [0,10us) [10us,100us) ...
exporter/otlp/tempo/traces                         0           0            4  ...       0
processor/tail_sampling/TraceData                  3          12          188  ...       0
receiver/otlp/TraceDataReceived                    1           0          871  ...       0

$ curl -s "http://localhost:55679/debug/pipelinez"
```

`tracez` is the collector tracing *itself*: it shows which internal stage has running (stuck) operations and where latency accumulates. This is how you distinguish "the exporter is slow" from "the receiver is not getting anything".

### 6.5 Querying the backend

**Tempo — fetch by trace ID:**

```console
$ kubectl -n observability port-forward svc/tempo 3200:3200 >/dev/null 2>&1 &
$ curl -s "http://localhost:3200/api/traces/5b8efff798038103d269b633813fc60c" \
    | jq '.batches[].scopeSpans[].spans[] | {name, spanId, parentSpanId, kind}'
{
  "name": "GET /checkout",
  "spanId": "a1b2c3d4e5f60718",
  "parentSpanId": "",
  "kind": "SPAN_KIND_SERVER"
}
{
  "name": "POST /api/payment",
  "spanId": "e5f60718293a4b5c",
  "parentSpanId": "a1b2c3d4e5f60718",
  "kind": "SPAN_KIND_CLIENT"
}
```

**Tempo — TraceQL:**

```console
$ curl -sG "http://localhost:3200/api/search" \
    --data-urlencode 'q={ resource.service.name = "checkout" && span.http.response.status_code >= 500 } | select(span.http.route)' \
    --data-urlencode 'limit=5' \
    --data-urlencode 'start=1756896000' \
    --data-urlencode 'end=1756899600' | jq '.traces[] | {traceID, rootServiceName, durationMs}'
{
  "traceID": "60d0d0c9d5b7a1e1b8a2c3d4e5f60718",
  "rootServiceName": "frontend",
  "durationMs": 4127
}
{
  "traceID": "71e1e1dae6c8b2f2c9b3d4e5f6071829",
  "rootServiceName": "frontend",
  "durationMs": 3980
}
```

Useful TraceQL idioms:

```traceql
{ duration > 2s && resource.service.name = "payments" }
{ span.db.system.name = "postgresql" && span.db.query.text =~ ".*ORDER BY.*" }
{ status = error } && { resource.k8s.namespace.name = "shop" }
{ resource.service.name = "checkout" } >> { resource.service.name = "acquirer" }   # descendant
count() by (resource.service.name) | select(span.http.route)
```

**Jaeger — query API:**

```console
$ curl -s "http://localhost:16686/api/services" | jq -r '.data[]'
frontend
cart
checkout
payments
inventory
jaeger-all-in-one

$ curl -s "http://localhost:16686/api/traces?service=checkout&operation=POST%20%2Fapi%2Fpayment&limit=2&lookback=1h&minDuration=1500ms" \
    | jq '.data[] | {traceID, spanCount: (.spans | length), duration: (.spans[0].duration)}'
{
  "traceID": "60d0d0c9d5b7a1e1b8a2c3d4e5f60718",
  "spanCount": 14,
  "duration": 4127311
}

$ curl -s "http://localhost:16686/api/dependencies?endTs=$(date +%s000)&lookback=3600000" \
    | jq -r '.data[] | "\(.parent) -> \(.child)  (\(.callCount))"'
frontend -> cart  (18422)
frontend -> checkout  (9130)
checkout -> payments  (9128)
payments -> inventory  (9128)
```

### 6.6 Verifying propagation on the wire

This is the definitive test for "why is my trace split in two":

```console
$ kubectl -n shop exec -it deploy/frontend -- \
    curl -sv http://checkout.shop.svc.cluster.local:8080/api/order \
      -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
      -o /dev/null 2>&1 | grep -i -E 'traceparent|tracestate|b3|uber'
> traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
< traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-2f1a9b3c4d5e6f70-01
```

The response's `traceparent` keeps the same `trace-id` and carries a *new* `parent-id` — propagation works. If the outbound request from `checkout` to `payments` carries a **different trace-id**, context was lost inside `checkout`.

Inspect what a service actually emits, without a backend:

```console
$ kubectl -n shop exec -it deploy/checkout -- \
    env | grep -E '^OTEL_'
OTEL_SERVICE_NAME=checkout
OTEL_EXPORTER_OTLP_ENDPOINT=http://10.42.3.17:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.05
OTEL_PROPAGATORS=tracecontext,baggage,b3multi
OTEL_RESOURCE_ATTRIBUTES=service.namespace=shop,service.version=3.4.1,k8s.pod.uid=8c1b...
```

### 6.7 Failure catalogue

| Symptom | Root cause | Diagnosis | Fix |
|---|---|---|---|
| **Zero traces anywhere** | Wrong port/protocol pairing | SDK logs `connection refused` on 4317 while collector serves only 4318 | Match `OTEL_EXPORTER_OTLP_PROTOCOL` to the port: `grpc`→4317, `http/protobuf`→4318 |
| **Zero traces, no SDK error** | `OTEL_SDK_DISABLED=true`, or sampler is `always_off` | `env \| grep OTEL_` inside the pod | Correct the env |
| **HTTP 404 from collector** | `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` missing `/v1/traces` | `curl -i` shows `404 Not Found` | Append the path, or switch to the base `OTEL_EXPORTER_OTLP_ENDPOINT` variable |
| **`no such host` / `unsupported scheme`** | Endpoint given without `http://` | SDK log: `parse "otel-agent:4318": first path segment in URL cannot contain colon` | Always include the scheme |
| **Traces split into fragments; each service has its own trace-id** | Propagator mismatch (service A injects W3C, B extracts B3 only) | `curl -v` header comparison (§6.6) | Set `OTEL_PROPAGATORS` to a superset on every service during migration |
| **Trace stops at a specific hop** | Reverse proxy / WAF strips unknown headers | Compare headers before and after the proxy | Allow-list `traceparent`, `tracestate`, `baggage`, `b3` on the proxy |
| **Trace restarts after a queue** | Context not carried in message headers | Consumer span has empty `parentSpanId` | Inject/extract on message headers (§5.7) |
| **Trace restarts after a thread pool / `asyncio.create_task`** | Context is thread/task-local and not copied | Root spans appearing mid-request | Use the SDK's context-aware executor wrapper, or `context.attach()` explicitly |
| **Only ~5% of traces, and each is incomplete** | Independent `traceidratio` per service instead of `parentbased_*` | Sampling ratios differ across services | Standardise on `parentbased_traceidratio` with an identical argument |
| **Slow traces are exactly the ones missing** | `tail_sampling.decision_wait` shorter than p99 latency | `otelcol_processor_tail_sampling_sampling_trace_dropped_too_early` > 0 | Raise `decision_wait` above p99.9 |
| **Tail sampling keeps random fragments** | Spans of one trace hitting different gateway replicas | Gateway replicas each hold partial traces | Use `loadbalancing` exporter with `routing_key: traceID` in front of the gateway tier |
| **Spans with negative or impossible durations; child starts before parent** | Clock skew across nodes | `chronyc tracking` shows offsets in the tens of ms | Enforce NTP/chrony; Jaeger's UI applies clock-skew adjustment, do not rely on it |
| **Collector OOM-killed repeatedly** | `GOMEMLIMIT` unset, or `tail_sampling.num_traces` too high | `kubectl describe pod` → `Reason: OOMKilled`, exit code 137 | Set `GOMEMLIMIT` to ~80% of limit; add `memory_limiter`; reduce `num_traces` |
| **`refused_spans` climbing under load** | `memory_limiter` doing its job | `otelcol_processor_refused_spans_total` > 0 | Scale out gateway replicas; SDK retries will cover the gap |
| **`send_failed_spans` climbing** | Backend down / TLS / auth | Collector log: `Exporting failed. Will retry ... rpc error: code = Unavailable` | Fix backend; enable `sending_queue.storage` so a restart is not a data-loss event |
| **gRPC through Ingress fails, HTTP works** | L7 proxy defaults to HTTP/1.1 | `502` or `UNAVAILABLE` on 4317 only | `nginx.ingress.kubernetes.io/backend-protocol: "GRPC"`, ensure HTTP/2 end to end |
| **Prometheus series explosion after enabling `spanmetrics`** | High-cardinality dimension (raw URL, user id) | `prometheus_tsdb_head_series` jumps by millions | Use `http.route`, never `url.full`; prune `dimensions`; set `dimensions_cache_size` |
| **Everything is `ERROR`, sampling budget blown** | 4xx marked as span error | `tail_sampling` keeps ~40% of traffic | Only set `StatusCode.ERROR` for server-side failures |
| **Trace ID is all zeros** | Invalid/absent context; span created outside a provider | `00000000000000000000000000000000` in logs | Verify `TracerProvider` is registered before the first span |
| **Traces in Grafana but "trace not found" from a log link** | Log's trace ID emitted by a *different* environment/tenant, or trace was sampled out | Search the raw ID in Tempo directly | Log the sampled flag too; consider `local-blocks` / higher baseline sampling |

### 6.8 Correlating the three signals

The payoff of tracing is not the flame graph — it is **navigation**. Wire the identifiers so that any signal jumps to the other two.

**Logs → traces:** inject `trace_id` and `span_id` into every log line.

```console
$ kubectl -n shop logs deploy/checkout --tail=1 | jq .
{
  "ts": "2026-09-03T09:41:07.512Z",
  "level": "error",
  "logger": "shop.checkout",
  "msg": "payment authorization timed out",
  "trace_id": "60d0d0c9d5b7a1e1b8a2c3d4e5f60718",
  "span_id": "0718293a4b5c6d7e",
  "trace_flags": "01",
  "service.name": "checkout"
}
```

**Metrics → traces:** exemplars. The `spanmetrics` connector attaches a trace ID to histogram buckets, so a p99 spike in Grafana is one click from an example trace that produced it.

```console
$ curl -s http://localhost:8889/metrics | grep -A0 'traces_span_metrics_duration_bucket' | head -2
traces_span_metrics_duration_milliseconds_bucket{service_name="payments",span_name="POST /api/payment",http_route="/api/payment",le="2000"} 4821 # {trace_id="60d0d0c9d5b7a1e1b8a2c3d4e5f60718",span_id="f60718293a4b5c6d"} 1873.4 1756899667.512
```

Prometheus must be started with `--enable-feature=exemplar-storage`, and the Grafana Tempo datasource needs `tracesToLogs` / `tracesToMetrics` configured for the links to render.

**Grafana datasource wiring:**

```yaml
apiVersion: 1
datasources:
  - name: Tempo
    type: tempo
    uid: tempo
    access: proxy
    url: http://tempo.observability.svc.cluster.local:3200
    jsonData:
      httpMethod: GET
      tracesToLogsV2:
        datasourceUid: loki
        spanStartTimeShift: '-5m'
        spanEndTimeShift: '5m'
        filterByTraceID: true
        filterBySpanID: false
        tags:
          - key: service.name
            value: service_name
      tracesToMetrics:
        datasourceUid: prometheus
        spanStartTimeShift: '-2m'
        spanEndTimeShift: '2m'
        tags:
          - key: service.name
            value: service_name
        queries:
          - name: 'Request rate'
            query: 'sum(rate(traces_span_metrics_calls_total{$$__tags}[5m]))'
      serviceMap:
        datasourceUid: prometheus
      nodeGraph:
        enabled: true
      lokiSearch:
        datasourceUid: loki
```

### 6.9 A verification checklist you can run on any cluster

```bash
#!/usr/bin/env bash
# verify-tracing.sh — end-to-end health check of the tracing pipeline.
set -euo pipefail

NS=observability
FAIL=0

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [ OK ] %s\n' "$name"
  else
    printf '  [FAIL] %s\n' "$name"
    FAIL=1
  fi
}

echo "== 1. Collector pods are ready =="
kubectl -n "$NS" get pods -l app.kubernetes.io/name=otel-agent \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'

echo "== 2. Config validates =="
check "agent config" kubectl -n "$NS" exec ds/otel-agent -- \
  /otelcol-contrib validate --config=file:/conf/config.yaml

echo "== 3. Receivers accepting spans =="
ACCEPTED=$(kubectl -n "$NS" exec ds/otel-agent -- \
  wget -qO- http://localhost:8888/metrics |
  awk '/^otelcol_receiver_accepted_spans_total/ {s+=$2} END {print s+0}')
echo "  accepted spans: ${ACCEPTED}"
[ "${ACCEPTED}" -gt 0 ] || { echo "  [FAIL] no spans accepted"; FAIL=1; }

echo "== 4. No refusals, no export failures =="
for m in otelcol_receiver_refused_spans_total \
         otelcol_processor_refused_spans_total \
         otelcol_exporter_send_failed_spans_total; do
  V=$(kubectl -n "$NS" exec ds/otel-agent -- wget -qO- http://localhost:8888/metrics |
      awk -v pat="^${m}" '$0 ~ pat {s+=$2} END {print s+0}')
  printf '  %-45s %s\n' "$m" "$V"
  [ "$V" = "0" ] || FAIL=1
done

echo "== 5. Backend round-trip =="
TRACE_ID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
NOW_NS=$(( $(date +%s) * 1000000000 ))
kubectl -n "$NS" exec deploy/otel-gateway -- sh -c "cat > /tmp/s.json <<EOF
{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"verify-script\"}}]},
\"scopeSpans\":[{\"spans\":[{\"traceId\":\"${TRACE_ID}\",\"spanId\":\"$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')\",
\"name\":\"verify\",\"kind\":1,\"startTimeUnixNano\":\"${NOW_NS}\",\"endTimeUnixNano\":\"$((NOW_NS + 1000000))\",
\"status\":{\"code\":2}}]}]}]}
EOF
wget -qO- --post-file=/tmp/s.json --header='Content-Type: application/json' \
  http://localhost:4318/v1/traces"

sleep 10
check "trace ${TRACE_ID} retrievable from Tempo" \
  kubectl -n "$NS" exec deploy/otel-gateway -- \
  wget -qO- "http://tempo:3200/api/traces/${TRACE_ID}"

exit "$FAIL"
```

```console
$ ./verify-tracing.sh
== 1. Collector pods are ready ==
otel-agent-4zk7p	Running
otel-agent-8mq2r	Running
otel-agent-bt9wl	Running
== 2. Config validates ==
  [ OK ] agent config
== 3. Receivers accepting spans ==
  accepted spans: 1284933
== 4. No refusals, no export failures ==
  otelcol_receiver_refused_spans_total          0
  otelcol_processor_refused_spans_total         0
  otelcol_exporter_send_failed_spans_total      0
== 5. Backend round-trip ==
{"partialSuccess":{}}
  [ OK ] trace 9c4e1a7b3f8d2065e1a7b3f8d2065e1a retrievable from Tempo
$ echo $?
0
```

---

## 7. Exam Summary

**The concepts that carry the weight of this objective:**

- **Trace / span / span context** — a trace is a DAG of spans sharing a `trace_id`; each span has a unique `span_id` and a `parent_span_id` (empty on the root).
- **W3C Trace Context** — `traceparent: {version}-{trace-id}-{parent-id}-{trace-flags}` plus `tracestate`. `trace-flags` bit 0 is the sampled flag. `baggage` is a separate header for user-defined key/values.
- **OpenTelemetry** is the CNCF standard for the *generation and transport* of traces (and metrics and logs); it is not a storage backend. **OTLP** is its wire protocol: gRPC on 4317, HTTP on 4318 (`/v1/traces`).
- **Jaeger** and **Zipkin** are backends; **Grafana Tempo** is a backend optimised for object storage and trace-ID lookup, queried with **TraceQL**.
- **The Collector** decouples applications from backends and is where central policy lives: enrichment (`k8sattributes`), redaction (`transform`), sampling (`tail_sampling`), batching (`batch`), and memory protection (`memory_limiter`).
- **Head sampling** decides at the root, cheaply, blind to the outcome. **Tail sampling** decides at the gateway after the trace is complete — it can keep all errors and all slow requests, but requires trace-affine routing and significant memory.
- **Instrumentation** is auto (agent/operator injection) for framework boundaries and manual for business-meaningful operations. Auto-instrumentation reliably breaks at asynchronous boundaries — queues, thread pools, background tasks — where context must be injected and extracted explicitly.
- **Span names must be low cardinality; span attributes may be high cardinality.** This is the inverse of the metrics rule and the single most common design mistake.

---

## 8. References

**Exam objectives**
- LPI DevOps Tools Engineer, Exam 701 objectives — https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI DevOps Tools Engineer certification overview — https://www.lpi.org/our-certifications/devops-overview/

**Standards**
- W3C Trace Context (Recommendation) — https://www.w3.org/TR/trace-context/
- W3C Baggage — https://www.w3.org/TR/baggage/
- OpenTelemetry Protocol (OTLP) specification — https://opentelemetry.io/docs/specs/otlp/
- OpenTelemetry Tracing API/SDK specification — https://opentelemetry.io/docs/specs/otel/trace/api/
- OpenTelemetry Semantic Conventions — https://opentelemetry.io/docs/specs/semconv/
- OpenTelemetry SDK environment variables — https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/

**OpenTelemetry**
- Documentation home — https://opentelemetry.io/docs/
- Collector configuration — https://opentelemetry.io/docs/collector/configuration/
- Collector deployment patterns (agent / gateway) — https://opentelemetry.io/docs/collector/deployment/
- Collector troubleshooting — https://opentelemetry.io/docs/collector/troubleshooting/
- Sampling concepts — https://opentelemetry.io/docs/concepts/sampling/
- Contrib components (`tail_sampling`, `k8sattributes`, `loadbalancing`, `spanmetrics`, `servicegraph`) — https://github.com/open-telemetry/opentelemetry-collector-contrib
- OpenTelemetry Operator — https://github.com/open-telemetry/opentelemetry-operator
- Zero-code instrumentation — https://opentelemetry.io/docs/zero-code/

**Backends**
- Jaeger documentation — https://www.jaegertracing.io/docs/
- Jaeger v2 architecture — https://www.jaegertracing.io/docs/latest/architecture/
- Jaeger deployment and storage backends — https://www.jaegertracing.io/docs/latest/deployment/
- Zipkin — https://zipkin.io/ and API — https://zipkin.io/zipkin-api/
- Grafana Tempo — https://grafana.com/docs/tempo/latest/
- TraceQL language reference — https://grafana.com/docs/tempo/latest/traceql/
- Tempo metrics-generator — https://grafana.com/docs/tempo/latest/metrics-generator/

**Ecosystem**
- CNCF Observability Landscape — https://landscape.cncf.io/
- Prometheus exemplars — https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- Envoy tracing (mesh-level propagation) — https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/observability/tracing
- Istio distributed tracing — https://istio.io/latest/docs/tasks/observability/distributed-tracing/