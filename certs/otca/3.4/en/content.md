# 3.4 Pipelines — OpenTelemetry Collector Data Pipelines

> **Domain 3 — The OpenTelemetry Collector.** A pipeline is the Collector's unit of composition: the ordered path a single signal type travels from ingestion to egress, expressed as `receivers → processors → exporters` and wired together by the `service::pipelines` block. Everything else in the Collector — connectors, fan-out cloning, backpressure, self-telemetry — exists to make that path correct and observable under production load.

---

## 1. Motivation and the production architectural problem

### 1.1 What a pipeline actually is

The Collector binary is inert. It contains a registry of **components** (receivers, processors, exporters, connectors, extensions), but none of them do anything until the `service::pipelines` section *builds a graph* connecting them. A pipeline is one node-chain in that graph, scoped to exactly one signal type:

```
traces:   otlp ──► memory_limiter ──► batch ──► otlp/backend
metrics:  prometheus ──► memory_limiter ──► batch ──► prometheusremotewrite
logs:     filelog ──► k8sattributes ──► batch ──► loki
```

Internally (since the v0.61 pipelines refactor lives in `service/internal/graph`) the whole `service` is compiled into a single **directed acyclic graph** (DAG). Each pipeline contributes receiver nodes, a linear chain of processor nodes, a fan-out node, and exporter nodes. Connectors add edges *between* pipelines. The graph is validated for cycles and signal-type compatibility at startup, then data flows through it as synchronous Go function calls.

### 1.2 The problem pipelines solve

Without a Collector, every application SDK exports directly to every backend. That couples your fleet to backend topology (each service needs backend endpoints, credentials, retry logic), makes cross-cutting policy — sampling, PII redaction, tenant routing — impossible to enforce centrally, and turns a backend migration into a fleet-wide redeploy.

The pipeline model inverts this. Applications speak OTLP to a **local decision point**; the Collector owns:

| Concern | Where it lives in the pipeline |
|---|---|
| Protocol translation (Jaeger/Zipkin/Prometheus → OTLP internal) | receivers |
| Enrichment (k8s metadata, resource detection) | processors |
| Reduction (sampling, filtering, batching) | processors / connectors |
| Reliability (queue, retry, persistent buffer) | exporter helper |
| Backpressure toward sources | synchronous return path |
| Egress fan-out and backend abstraction | exporters |

The key architectural insight the exam tests: **a pipeline is per-signal and synchronous by default**. Data ownership, mutation, and error propagation all follow from that synchronous chain. Get the order wrong and you either leak memory (batch before memory_limiter) or silently double-count data (mis-wired connectors).

---

## 2. Anatomy and technical comparisons

### 2.1 The five component roles

| Role | Interface it satisfies | Cardinality in a pipeline | Ordered? |
|---|---|---|---|
| **Receiver** | `consumer.Traces/Metrics/Logs` (push) or scraper | 1..N (fan-in) | No |
| **Processor** | `consumer.Traces/...` (chained) | 0..N | **Yes — order is semantic** |
| **Exporter** | terminal `consumer` | 1..N (fan-out) | No |
| **Connector** | exporter of pipeline A + receiver of pipeline B | bridges pipelines | edge |
| **Extension** | not in a pipeline | global | — |

Receivers and exporters are **unordered sets**; processors are an **ordered list** and the order changes behaviour. This asymmetry is the single most common source of production incidents.

### 2.2 Named pipelines and component sharing

A pipeline is keyed `type[/name]`: `traces`, `traces/tail`, `metrics/internal`. Two rules govern instance sharing:

- **Same component ID in multiple pipelines → one shared instance.** An `otlp` receiver listed in both `traces` and `traces/tail` is instantiated **once** and fans out to both. This is why you cannot bind two `otlp` receivers to the same port without distinct names (`otlp` vs `otlp/2`) and distinct `endpoint` configs.
- **`type` vs `type/name` are different instances.** `batch` and `batch/logs` are two independent processors with independent buffers.

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

service:
  pipelines:
    traces:
      receivers:  [otlp]           # ┐ same otlp instance
      processors: [memory_limiter, batch]
      exporters:  [otlp/jaeger]
    traces/sampled:
      receivers:  [otlp]           # ┘ fans out from the one receiver
      processors: [memory_limiter, tail_sampling, batch]
      exporters:  [otlp/coldstore]
```

### 2.3 Processor ordering trade-offs

| Ordering decision | Correct choice | Why |
|---|---|---|
| `memory_limiter` position | **First** | It must be able to *refuse* data (return error → backpressure) before any downstream processor allocates memory doing work. |
| `batch` position | **Last processor, before exporters** | Batching after sampling/filtering means you batch only the data you keep, maximizing compression and minimizing outbound RPCs. Batching before `memory_limiter` would accumulate memory the limiter can no longer bound. |
| sampling (`tail_sampling`, `probabilistic_sampler`) | Before `batch` | Drop first, batch the survivors. |
| enrichment (`k8sattributes`, `resourcedetection`) | Early, before sampling if sampling depends on those attributes | OTTL/attribute-based sampling needs the attributes present. |
| `transform` / `filter` (OTTL) | After enrichment, before batch | Operate on the final attribute set. |

> **Canonical order:** `memory_limiter → resourcedetection/k8sattributes → transform/filter → sampling → batch`.

### 2.4 Deployment topology comparison

| Dimension | **Agent** (DaemonSet / sidecar) | **Gateway** (Deployment, N replicas) |
|---|---|---|
| Locality | One per node/pod, `localhost` hop | Centralized service, network hop |
| Enrichment | Node/pod-local metadata (`k8sattributes`, host resource) | Loses node locality; needs metadata forwarded |
| Batching efficiency | Small (per-node volume) | Large (aggregated) — better compression |
| Tail sampling | **Impossible** (a trace is split across nodes) | **Required tier** — but needs trace-affinity routing |
| Backpressure blast radius | Contained to one node | Shared; a slow backend stalls the fleet |
| Credentials | Fan-out of secrets to every node | Held by a small gateway tier |

Production reference architecture is **two-tier**: agents do node-local enrichment and light batching, then use the **`loadbalancing` exporter keyed on `traceID`** to route all spans of a trace to the *same* gateway replica, where `tail_sampling` can see the complete trace.

### 2.5 Connectors vs processors vs exporters

A **connector** is the only component that crosses pipeline boundaries and may change signal type. It is simultaneously the *exporter* of an upstream pipeline and the *receiver* of a downstream one.

| Need | Use |
|---|---|
| Transform data in place, same signal | processor |
| Send data out of the Collector | exporter |
| Derive a *new signal* from an existing one (traces → RED metrics) | **connector** (`spanmetrics`) |
| Route to different pipelines by attribute | **connector** (`routing`) |
| Merge multiple pipelines into one | **connector** (`forward`) |
| Count telemetry into metrics | **connector** (`count`) |

---

## 3. Complete manifests and infrastructure (unabridged)

### 3.1 Full gateway config with all production controls

`collector-gateway.yaml`:

```yaml
# OpenTelemetry Collector — gateway tier, production profile
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: /healthz
  pprof:
    endpoint: 0.0.0.0:1777
  zpages:
    endpoint: 0.0.0.0:55679
  file_storage/queue:
    directory: /var/lib/otelcol/queue
    timeout: 10s
    compaction:
      on_start: true
      directory: /var/lib/otelcol/queue
      max_transaction_size: 65536

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        max_recv_msg_size_mib: 16
      http:
        endpoint: 0.0.0.0:4318

processors:
  # MUST be first: bounds memory before any work is done.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25
  resourcedetection:
    detectors: [env, system]
    system:
      hostname_sources: [os]
    timeout: 5s
    override: false
  # Tail sampling: keep all errors + slow traces, 10% of the rest.
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    expected_new_traces_per_sec: 2000
    policies:
      - name: errors-policy
        type: status_code
        status_code:
          status_codes: [ERROR]
      - name: slow-policy
        type: latency
        latency:
          threshold_ms: 500
      - name: probabilistic-policy
        type: probabilistic
        probabilistic:
          sampling_percentage: 10
  batch:
    send_batch_size: 8192
    send_batch_max_size: 10000
    timeout: 5s

connectors:
  # Derive RED metrics from the trace stream.
  spanmetrics:
    histogram:
      explicit:
        buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2s, 5s]
    dimensions:
      - name: http.method
      - name: http.status_code
    exemplars:
      enabled: true

exporters:
  otlp/jaeger:
    endpoint: jaeger-collector.observability.svc:4317
    tls:
      insecure: false
      ca_file: /etc/otel/certs/ca.crt
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
      storage: file_storage/queue      # persistent — survives restart
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    timeout: 10s
  prometheusremotewrite:
    endpoint: https://mimir.observability.svc/api/v1/push
    tls:
      ca_file: /etc/otel/certs/ca.crt
    resource_to_telemetry_conversion:
      enabled: true
  debug:
    verbosity: normal
    sampling_initial: 5
    sampling_thereafter: 200

service:
  extensions: [health_check, pprof, zpages, file_storage/queue]
  telemetry:
    logs:
      level: info
      encoding: json
    metrics:
      level: detailed
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, resourcedetection, tail_sampling, batch]
      exporters:  [otlp/jaeger, spanmetrics]     # fan-out: backend + connector
    metrics:
      receivers:  [otlp, spanmetrics]            # fan-in: apps + derived RED metrics
      processors: [memory_limiter, batch]
      exporters:  [prometheusremotewrite]
```

Two things to internalize from this manifest:

1. The `traces` pipeline **fans out** to `otlp/jaeger` *and* the `spanmetrics` connector. Because `tail_sampling` sets `MutatesData: true`, the fan-out node **clones pdata** for all-but-one downstream consumer (§4.2). The connector then feeds `metrics`, which **fans in** the derived RED metrics alongside application `otlp` metrics.
2. `sending_queue.storage: file_storage/queue` upgrades the in-memory queue to a WAL-backed persistent queue. On restart, un-acked batches are replayed instead of dropped — the difference between "at-least-once to the backend boundary" and "best effort."

### 3.2 Kubernetes: ConfigMap + Deployment (raw)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-gateway-config
  namespace: observability
data:
  collector.yaml: |
    # (contents of collector-gateway.yaml above)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-gateway
  namespace: observability
  labels: { app.kubernetes.io/name: otel-gateway }
spec:
  replicas: 3
  selector:
    matchLabels: { app.kubernetes.io/name: otel-gateway }
  template:
    metadata:
      labels: { app.kubernetes.io/name: otel-gateway }
    spec:
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.111.0
          args: ["--config=/conf/collector.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: metrics,   containerPort: 8888 }
            - { name: zpages,    containerPort: 55679 }
          env:
            # memory_limiter limit_percentage reads this cgroup limit.
            - name: GOMEMLIMIT
              value: "1600MiB"
          resources:
            requests: { cpu: "500m", memory: "1Gi" }
            limits:   { memory: "2Gi" }
          livenessProbe:
            httpGet: { path: /healthz, port: 13133 }
            initialDelaySeconds: 10
          readinessProbe:
            httpGet: { path: /healthz, port: 13133 }
          volumeMounts:
            - { name: config, mountPath: /conf }
            - { name: queue,  mountPath: /var/lib/otelcol/queue }
      volumes:
        - name: config
          configMap: { name: otel-gateway-config }
        - name: queue
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway
  namespace: observability
spec:
  selector: { app.kubernetes.io/name: otel-gateway }
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: 4317 }
    - { name: otlp-http, port: 4318, targetPort: 4318 }
```

### 3.3 Agent tier with trace-affinity routing to the gateway

The agent must guarantee that all spans of a trace land on the **same** gateway replica, or tail sampling breaks. That is the `loadbalancing` exporter's job:

```yaml
# agent (DaemonSet) — routes by traceID to gateway replicas
exporters:
  loadbalancing:
    routing_key: traceID          # hash traceID → stable replica
    protocol:
      otlp:
        tls:
          insecure: true
    resolver:
      k8s:
        service: otel-gateway.observability
        ports: [4317]

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, k8sattributes, batch]
      exporters:  [loadbalancing]
```

---

## 4. Internal mechanics and CLI verification

### 4.1 Validate before you deploy

The Collector ships a `validate` subcommand that compiles the graph without starting it — catches type mismatches, unknown components, and cycles offline:

```console
$ otelcol-contrib validate --config=collector-gateway.yaml
$ echo $?
0
```

A signal-type mismatch (e.g. wiring a `prometheus` receiver — metrics-only — into a `traces` pipeline) fails loudly:

```console
$ otelcol-contrib validate --config=broken.yaml
Error: invalid configuration: service::pipelines::traces: references receiver "prometheus" which is not configured
2024-... error   Collector failed to start   {"error": "invalid configuration"}
$ echo $?
1
```

A component not compiled into the distribution:

```console
$ otelcol-contrib validate --config=needs-custom.yaml
Error: failed to get config: cannot unmarshal the configuration:
  error decoding 'processors': unknown type: "redaction/enterprise"
  for id: "redaction/enterprise" (valid values: [attributes batch filter ...])
```

### 4.2 Data ownership, mutation, and fan-out cloning

The Collector's internal data model is **pdata** (`ptrace.Traces`, `pmetric.Metrics`, `plog.Logs`) — the in-memory OTLP representation. Each consumer declares a capability:

```go
func (p *tailSamplingProcessor) Capabilities() consumer.Capabilities {
    return consumer.Capabilities{MutatesData: true}
}
```

At a fan-out point the service inserts a `fanoutconsumer`. Its rule:

- If **all** downstream consumers are read-only (`MutatesData: false`) → they share the **same** pdata pointer. Zero copies.
- If **any** downstream mutates → the fan-out **clones** the pdata for every mutating consumer (and hands the original to at most one read-only consumer), preventing a data race where one exporter reads spans another processor is rewriting.

This is why adding a mutating processor to a fanned-out pipeline can quietly double your CPU and allocation rate. You confirm it from self-telemetry, not from logs.

### 4.3 Startup log — reading the compiled graph

```console
$ otelcol-contrib --config=collector-gateway.yaml
2024-06-10T12:00:01.114Z info    service@v0.111.0/service.go:135  Setting up own telemetry...
2024-06-10T12:00:01.115Z info    memorylimiter/memorylimiter.go:151  Using percentage memory limiter  {"total_memory_mib": 2000, "limit_percentage": 80, "spike_limit_percentage": 25}
2024-06-10T12:00:01.116Z info    memorylimiter/memorylimiter.go:75   Memory limiter configured  {"limit_mib": 1600, "spike_limit_mib": 500, "check_interval": 1}
2024-06-10T12:00:01.118Z info    tailsamplingprocessor@...  Sampling Policy Evaluation  {"policy": "errors-policy"}
2024-06-10T12:00:01.121Z info    service@v0.111.0/service.go:207  Starting otelcol-contrib...  {"Version": "0.111.0", "NumCPU": 8}
2024-06-10T12:00:01.121Z info    extensions/extensions.go:39  Starting extensions...
2024-06-10T12:00:01.122Z info    otlpreceiver@...  Starting GRPC server  {"endpoint": "0.0.0.0:4317"}
2024-06-10T12:00:01.122Z info    otlpreceiver@...  Starting HTTP server  {"endpoint": "0.0.0.0:4318"}
2024-06-10T12:00:01.123Z info    service@v0.111.0/service.go:230  Everything is ready. Begin running and processing data.
```

### 4.4 zpages — inspecting the live pipeline graph

The `zpages` extension exposes the *runtime* view of the compiled DAG:

```console
$ curl -s localhost:55679/debug/pipelinez | sed 's/<[^>]*>//g' | grep -A4 traces
Pipeline traces
  receivers:  otlp
  processors: memory_limiter, resourcedetection, tail_sampling, batch
  exporters:  otlp/jaeger, spanmetrics
  MutatesData: true
```

`/debug/servicez` lists extensions and the overall service; `/debug/tracez` shows the Collector's *own* internal spans (sampled by latency bucket) — invaluable when a processor is the bottleneck.

### 4.5 Self-telemetry — the numbers that matter

The Collector exports its own metrics on `:8888`. These are the pipeline's vital signs:

```console
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|processor|exporter)' | grep -v '#'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"}      1.284e+06
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"}       0
otelcol_processor_batch_batch_send_size_sum{processor="batch"}         1.109e+06
otelcol_processor_batch_batch_send_size_count{processor="batch"}       152
otelcol_processor_batch_timeout_trigger_send_total{processor="batch"}  38
otelcol_exporter_sent_spans{exporter="otlp/jaeger"}                    1.101e+06
otelcol_exporter_send_failed_spans{exporter="otlp/jaeger"}             0
otelcol_exporter_queue_size{exporter="otlp/jaeger"}                    83
otelcol_exporter_queue_capacity{exporter="otlp/jaeger"}               5000
otelcol_exporter_enqueue_failed_spans{exporter="otlp/jaeger"}          0
```

The invariant you audit against:

```
accepted − refused  ≈  Σ(sent + still-queued + dropped)
```

If `accepted ≫ sent` and `queue_size → queue_capacity`, the backend is the bottleneck and the queue is filling. If `enqueue_failed_spans` climbs, the queue is *full* and you are shedding data — that is data loss, and it should page.

---

## 5. Verification and failure diagnosis guide

### 5.1 Decision table — symptom to cause

| Symptom (from `:8888/metrics`) | Root cause | Fix |
|---|---|---|
| `receiver_refused_spans > 0`, logs show `data refused due to high memory usage` | `memory_limiter` hard limit hit; correctly shedding load | Raise memory limit / add replicas / reduce `send_batch_size`. This is backpressure working, not a bug. |
| `exporter_queue_size` pinned at `queue_capacity` | Backend slower than ingest | Increase `num_consumers`, scale backend, or enable persistent queue to ride out spikes. |
| `exporter_enqueue_failed_spans > 0` | Queue full → **dropping data** | Persistent `storage:` queue + backend capacity. Alert. |
| `exporter_send_failed_spans` rising, retry logs | Backend erroring/unreachable | Check `retry_on_failure`; verify TLS/endpoint; watch `max_elapsed_time` (after which data is dropped). |
| Spanmetrics/tail_sampling produce nothing | Connector/processor placed in wrong pipeline or signal-type mismatch | `validate`; confirm connector is exporter of one pipeline and receiver of another. |
| Memory OOMKilled despite `memory_limiter` | `batch` placed **before** `memory_limiter`, or `limit_percentage` above container limit | Reorder; align `limit_*` with cgroup / `GOMEMLIMIT`. |
| Tail sampling keeps *partial* traces | Spans of a trace hitting different gateway replicas | Front with `loadbalancing` exporter `routing_key: traceID`. |
| Metrics double-counted | Same connector wired into two pipelines, or receiver shared unintentionally | Audit `service::pipelines` for accidental fan-out. |

### 5.2 Backpressure — proving the chain end-to-end

Because the pipeline is synchronous up to the sending queue, an overloaded backend surfaces as a **retryable gRPC error at the client**. Verify it deliberately:

```console
# Backend down; queue will fill, then the receiver refuses, then the client sees it.
$ telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure --rate 20000 --duration 30s
...
2024-... traces_worker  rpc error: code = Unavailable desc = no more queue space, dropping data
```

Collector-side, at the same moment:

```console
$ curl -s localhost:8888/metrics | grep -E 'refused_spans|enqueue_failed'
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"}   45210
otelcol_exporter_enqueue_failed_spans{exporter="otlp/jaeger"}      45210
```

The equality of those two counters proves the backpressure path is intact: the Collector refused exactly what it could not enqueue, and the client was told to retry rather than the Collector silently absorbing (and losing) it.

### 5.3 The debug exporter — see the actual pdata

When you must confirm *what* is flowing (attributes present? resource enriched?), temporarily add the `debug` exporter (the modern replacement for the removed `logging` exporter):

```yaml
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      exporters: [otlp/jaeger, debug]   # tee to stdout
```

```console
$ otelcol-contrib --config=debug.yaml 2>&1 | head -20
2024-... info    Traces  {"resource spans": 1, "spans": 3}
2024-... info    ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
     -> k8s.pod.name: Str(checkout-7d9f-abc12)
     -> host.name: Str(node-3)
ScopeSpans #0
Span #0
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Name           : POST /cart/checkout
    Kind           : Server
    Status code    : Error
    Attributes:
         -> http.method: Str(POST)
         -> http.status_code: Int(500)
```

### 5.4 Health and profiling under load

```console
$ curl -s localhost:13133/healthz | jq
{ "status": "Server available", "upSince": "2024-06-10T12:00:01Z", "uptime": "4h12m" }

# CPU profile when a processor is suspected hot (pprof extension):
$ go tool pprof -top http://localhost:1777/debug/pprof/profile?seconds=30
      flat  flat%   sum%        cum   cum%
   1200ms 24.0%  24.0%     1800ms 36.0%  ...tailsamplingprocessor.(*policyEvaluator).Evaluate
    640ms 12.8%  36.8%      640ms 12.8%  runtime.memmove   # fan-out cloning cost
```

Seeing `runtime.memmove` high alongside a fan-out to a mutating processor confirms the clone cost from §4.2 — the remedy is to move the mutation off the fanned-out path or split pipelines.

---

## 6. References

- OpenTelemetry Collector — Configuration & pipelines: https://opentelemetry.io/docs/collector/configuration/
- Collector architecture (data pipelines, components): https://opentelemetry.io/docs/collector/architecture/
- Building a custom Collector / component registry (OCB): https://opentelemetry.io/docs/collector/custom-collector/
- Connectors (spanmetrics, routing, forward, count): https://opentelemetry.io/docs/collector/building/connector/
- Deployment patterns (agent vs gateway): https://opentelemetry.io/docs/collector/deployment/
- Internal telemetry & self-monitoring metrics: https://opentelemetry.io/docs/collector/internal-telemetry/
- Scaling the Collector (tail sampling, loadbalancing): https://opentelemetry.io/docs/collector/scaling/
- `memory_limiter` processor: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
- `batch` processor: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md
- Exporter helper (sending_queue, retry_on_failure): https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
- `tail_sampling` processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/tailsamplingprocessor/README.md
- `loadbalancing` exporter: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/loadbalancingexporter/README.md
- `spanmetrics` connector: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/spanmetricsconnector/README.md
- `zpages` extension: https://github.com/open-telemetry/opentelemetry-collector/blob/main/extension/zpagesextension/README.md
- OTCA certification & curriculum (CNCF/Linux Foundation): https://training.linuxfoundation.org/certification/opentelemetry-certified-associate-otca/
- OTCA curriculum repository: https://github.com/cncf/curriculum