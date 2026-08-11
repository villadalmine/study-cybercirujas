# 4.2 Debugging Pipelines

*OTCA — Domain 4: Maintaining and Debugging OpenTelemetry Telemetry Pipelines*

---

## 1. Motivation and the Production Architecture Problem

A telemetry pipeline is the one system in your stack that fails **silently and self-referentially**. When your payment service breaks, telemetry tells you. When your *telemetry* breaks, nothing tells you — you discover it during the next incident, when the dashboards are flat and the traces are gone precisely for the window you need to investigate. This is the defining operational hazard of observability: the instrument that measures everything else has no external instrument measuring it.

The OpenTelemetry data path is a multi-hop chain, and every hop is a place where data can be dropped without an error propagating back to the origin:

```
Application SDK ──OTLP──▶ Collector (agent/DaemonSet) ──OTLP──▶ Collector (gateway/Deployment) ──▶ Backend
   │  receiver → [memory_limiter → batch → attributes/filter/sampling] → exporter (sending_queue)
```

Each stage has independent, asynchronous failure modes:

- The **SDK** buffers spans in a `BatchSpanProcessor` and drops on overflow — the app never blocks, so a full buffer is invisible to request latency.
- The **receiver** can `refuse` data (returns a retryable error) when downstream backpressure propagates up.
- The **memory_limiter processor** deliberately refuses data to protect the process from OOM.
- The **exporter's `sending_queue`** drops the *oldest* enqueued items when it fills, so under load you lose data and the process keeps running "healthily."

The architectural problem is that **backpressure and data loss are decoupled from the request path by design** — the pipeline is asynchronous so the application is never slowed by telemetry. That same decoupling means loss is invisible unless you instrument the pipeline itself. Debugging an OpenTelemetry pipeline is therefore not "read a stack trace"; it is a disciplined **traversal of the chain**, answering at each hop: *is data arriving here, is it leaving here, and if not, which counter says why.*

The Collector exposes exactly this: its own **internal telemetry** (metrics, logs, traces about itself), plus purpose-built diagnostic components — the `debug` exporter, the `zpages`, `pprof`, and `health_check` extensions. Mastering the pipeline means knowing which of these answers which question, at what cost.

---

## 2. Technical Comparison — The Diagnostic Toolbox

There is no single "debug" button. Each tool observes a different layer at a different cost. Choosing wrong wastes an incident window.

| Tool | Layer observed | What it answers | Overhead / risk | Production-safe? |
|---|---|---|---|---|
| **Collector internal metrics** (`:8888/metrics`) | Whole pipeline, aggregate | *How much* accepted / refused / sent / failed / queued, per component | Negligible (counters) | ✅ Always on |
| **`debug` exporter** | One pipeline branch, per-record | *What* the actual payload looks like (attributes, resource, span names) | High at `detailed` — logs every record; can flood disk & CPU | ⚠️ Sampled only |
| **`zpages` extension** | Live in-process state | Recent/running/errored spans (`tracez`), effective pipeline wiring (`pipelinez`) | Low (in-memory ring buffers) | ✅ Bind to localhost |
| **`pprof` extension** | Runtime (Go) | CPU/heap/goroutine profiles — *why* the Collector is slow or leaking | Low unless profiling actively | ✅ Bind to localhost |
| **`health_check` extension** | Process liveness | Is the Collector up and serving? | Negligible | ✅ Use for k8s probes |
| **SDK console/stdout exporter** | Application, pre-network | Is the *app* even producing telemetry? | Console I/O per span | ⚠️ Dev / narrow scope |
| **`telemetrygen`** | Synthetic injection | Isolate the pipeline from the app (send known-good data) | N/A (test tool) | Test/staging |

### 2.1 Debug exporter verbosity trade-offs

The `debug` exporter (the renamed successor to the old `logging` exporter, deprecated since Collector v0.86.0) has three verbosity levels. The choice is a signal-vs-flood trade-off:

| `verbosity` | Output | Use when | Cost |
|---|---|---|---|
| `basic` | One summary line per batch: counts only | Confirming data *flows* through a branch | Minimal |
| `normal` (default) | Compact one-line-per-record with key fields | Spot-checking identifiers/service names | Moderate |
| `detailed` | Full resource + scope + attributes + body | Inspecting *why* a record is malformed or mis-attributed | **Severe** — can saturate stdout and disk |

Always pair `detailed` with sampling (`sampling_initial`, `sampling_thereafter`) so you inspect a few records, not the firehose.

### 2.2 `service.telemetry` levels (the Collector's own metrics)

| `metrics.level` | Emits | When to raise it |
|---|---|---|
| `none` | Nothing | Never in production — you go blind |
| `basic` | Process + top-level throughput counters | Minimum viable |
| `normal` (default) | Per-component accepted/refused/sent/failed | Standard production baseline |
| `detailed` | Adds queue sizes, batch-size histograms, RPC-level metrics | Actively debugging drops/latency |

---

## 3. Complete Manifests — A Debuggable Collector

The following is a **complete, syntactically valid** `otelcol-contrib` configuration wired for diagnosis: internal telemetry exposed on Prometheus, all four diagnostic extensions enabled, `memory_limiter` first, a `debug` exporter fanned out alongside the real backend, and a `sending_queue` with explicit capacity so drops are observable.

```yaml
# otel-collector-config.yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: /health/status
  zpages:
    endpoint: localhost:55679
  pprof:
    endpoint: localhost:1777
    block_profile_fraction: 0   # raise to 3 only while chasing a specific mutex/block stall
    mutex_profile_fraction: 0

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # ORDER MATTERS: memory_limiter must be first so it can refuse before
  # the batch processor accumulates unbounded data in memory.
  memory_limiter:
    check_interval: 1s
    limit_mib: 1500
    spike_limit_mib: 400
  batch:
    send_batch_size: 8192
    send_batch_max_size: 10000
    timeout: 5s

exporters:
  debug:
    verbosity: detailed
    sampling_initial: 5       # log the first 5 records...
    sampling_thereafter: 500  # ...then 1 in every 500
  otlp/backend:
    endpoint: otel-gateway.observability.svc.cluster.local:4317
    tls:
      insecure: false
      ca_file: /etc/otel/certs/ca.crt
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000        # explicit so queue_size/queue_capacity are meaningful
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s

service:
  extensions: [health_check, zpages, pprof]
  telemetry:
    logs:
      level: info            # flip to debug during an incident
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
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [debug, otlp/backend]   # fan-out: debug + real backend
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/backend]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/backend]
```

### 3.1 Kubernetes deployment with probes wired to `health_check`

The `health_check` extension is only useful if the orchestrator actually consults it. This Deployment binds liveness/readiness to it and scrapes the self-metrics port:

```yaml
# otel-collector-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
spec:
  replicas: 2
  selector:
    matchLabels: { app: otel-collector }
  template:
    metadata:
      labels: { app: otel-collector }
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8888"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.108.0
          args: ["--config=/conf/otel-collector-config.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: metrics,   containerPort: 8888 }
            - { name: health,    containerPort: 13133 }
          resources:
            requests: { cpu: "200m", memory: "512Mi" }
            limits:   { cpu: "1",    memory: "2Gi" }   # keep limit_mib < this
          livenessProbe:
            httpGet: { path: /health/status, port: 13133 }
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet: { path: /health/status, port: 13133 }
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - { name: config, mountPath: /conf }
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
```

> **Sizing rule:** keep `memory_limiter.limit_mib` (1500) comfortably below the container `memory.limit` (2Gi). If the hard limit is reached first, the kernel OOM-kills the process before the limiter can apply backpressure — you lose the graceful degradation the limiter exists to provide.

### 3.2 A pipeline deliberately wired to drop (for teaching the symptom)

To *see* a drop, undersize the queue and point the exporter at a dead endpoint:

```yaml
exporters:
  otlp/backend:
    endpoint: 127.0.0.1:9999   # nothing listening → every send fails
    tls: { insecure: true }
    sending_queue:
      enabled: true
      queue_size: 100          # tiny → fills instantly under load
    retry_on_failure:
      enabled: true
      max_elapsed_time: 10s    # after this, items are dropped
```

---

## 4. CLI Commands and Real Terminal Output

### 4.1 Confirm the Collector started and registered its diagnostics

```console
$ kubectl -n observability logs deploy/otel-collector | head -n 20
2026-08-11T14:20:03.112Z  info  service@v0.108.0/service.go:135  Setting up own telemetry...
2026-08-11T14:20:03.113Z  info  telemetry/telemetry.go:96  Serving metrics  {"address": "0.0.0.0:8888", "metrics level": "Detailed"}
2026-08-11T14:20:03.115Z  info  service@v0.108.0/service.go:207  Starting otelcol-contrib...  {"Version": "0.108.0", "NumCPU": 8}
2026-08-11T14:20:03.116Z  info  extensions/extensions.go:39  Starting extensions...
2026-08-11T14:20:03.116Z  info  healthcheckextension@v0.108.0/healthcheckextension.go:35  Starting health_check extension  {"config": {"Endpoint":"0.0.0.0:13133"}}
2026-08-11T14:20:03.117Z  info  zpagesextension@v0.108.0/zpagesextension.go:56  Registered zPages span processor on tracer provider
2026-08-11T14:20:03.117Z  info  zpagesextension@v0.108.0/zpagesextension.go:69  Serving zPages  {"address": "localhost:55679"}
2026-08-11T14:20:03.118Z  info  pprofextension@v0.108.0/pprofextension.go:60  Starting net/http/pprof server  {"config": {"TCPAddr":{"Endpoint":"localhost:1777"}}}
2026-08-11T14:20:03.120Z  info  service@v0.108.0/service.go:230  Everything is ready. Begin running and processing data.
```

### 4.2 Health check

```console
$ kubectl -n observability port-forward deploy/otel-collector 13133:13133 &
$ curl -s localhost:13133/health/status | jq
{
  "status": "Server available",
  "upSince": "2026-08-11T14:20:03.115Z",
  "uptime": "15m3.204s"
}
```

### 4.3 The core diagnostic: read the internal counters

The single most important debugging skill is reading `:8888/metrics` and comparing **accepted vs refused** (ingress) and **sent vs send_failed** (egress).

```console
$ kubectl -n observability port-forward deploy/otel-collector 8888:8888 &
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|exporter|processor)_' | grep spans
# HELP otelcol_receiver_accepted_spans Number of spans successfully pushed into the pipeline.
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 148203
# HELP otelcol_receiver_refused_spans Number of spans that could not be pushed into the pipeline.
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 5120
# HELP otelcol_exporter_sent_spans Number of spans successfully sent to destination.
otelcol_exporter_sent_spans{exporter="otlp/backend"} 138900
# HELP otelcol_exporter_send_failed_spans Number of spans in failed attempts to send.
otelcol_exporter_send_failed_spans{exporter="otlp/backend"} 9303
# HELP otelcol_exporter_queue_size Current size of the retry queue (in batches).
otelcol_exporter_queue_size{exporter="otlp/backend"} 4998
otelcol_exporter_queue_capacity{exporter="otlp/backend"} 5000
```

Reading this: `refused > 0` at the receiver means backpressure is reaching ingress. `send_failed > 0` with `queue_size` pinned at `queue_capacity` is the textbook signature of **a saturated queue against a failing backend** — the exporter can't drain, the queue fills, backpressure climbs the chain, the receiver starts refusing, and the SDK's `BatchSpanProcessor` begins dropping. One glance at four counters localizes the fault to egress.

> **Note on metric names:** the `otelcol_*` Prometheus names are version-dependent. Historic versions used `otelcol_processor_dropped_spans`; recent Collectors emit `..._refused_spans` / `..._send_failed_spans`, and the internal telemetry is migrating onto the OpenTelemetry metrics SDK. Always confirm against the version you run — `grep HELP` on the live endpoint is authoritative.

### 4.4 See the actual payload with the `debug` exporter

```console
$ kubectl -n observability logs deploy/otel-collector | grep -A25 'TracesExporter'
2026-08-11T14:23:11.482Z  info  TracesExporter  {"kind":"exporter","data_type":"traces","name":"debug","resource spans":1,"spans":2}
2026-08-11T14:23:11.482Z  info  ResourceSpans #0
Resource SchemaURL: https://opentelemetry.io/schemas/1.21.0
Resource attributes:
     -> service.name: Str(cartservice)
     -> service.namespace: Str(shop)
     -> telemetry.sdk.language: Str(go)
     -> k8s.pod.name: Str(cartservice-7d9f-abcde)
ScopeSpans #0
InstrumentationScope go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp 0.53.0
Span #0
    Trace ID       : 5b8efff798038103d269b633813fc60c
    Parent ID      :
    ID             : eee19b7ec3c1b174
    Name           : GET /cart
    Kind           : Server
    Start time     : 2026-08-11 14:23:11.400 +0000 UTC
    End time       : 2026-08-11 14:23:11.481 +0000 UTC
    Status code    : Ok
Attributes:
     -> http.request.method: Str(GET)
     -> http.response.status_code: Int(200)
     -> url.path: Str(/cart)
```

An empty `Parent ID` on what should be a child span is the visual signature of **broken context propagation** — the traces will render as disconnected fragments in the backend.

### 4.5 Inspect live pipeline state with zpages

```console
$ kubectl -n observability port-forward deploy/otel-collector 55679:55679 &
$ curl -s localhost:55679/debug/servicez | head
Pipelines
  traces: otlp -> [memory_limiter, batch] -> [debug, otlp/backend]
  metrics: otlp -> [memory_limiter, batch] -> [otlp/backend]

$ curl -s "localhost:55679/debug/tracez?ztype=1&tracename=exporter/otlp/backend"
# tracez shows spans bucketed by latency and by error — a non-empty
# "errors" bucket for the exporter span is a direct pointer to failing sends.
```

`pipelinez`/`servicez` confirm the **effective** wiring — invaluable when a config didn't reload or a component silently dropped from a pipeline. `tracez` shows the Collector's own operation spans bucketed by latency and error.

### 4.6 Isolate the pipeline from the application with `telemetrygen`

When you can't tell whether the app or the pipeline is at fault, inject known-good telemetry and watch the counters move:

```console
$ telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 50 --rate 10
2026-08-11T14:35:22.101Z  info  traces/worker.go:99   generation of traces isn't finite, generating until stop condition
2026-08-11T14:35:27.104Z  info  traces/worker.go:120  traces generated  {"worker": 0, "traces": 50}
2026-08-11T14:35:27.104Z  info  traces/traces.go:124  stop the batch span processor

$ curl -s localhost:8888/metrics | grep otelcol_receiver_accepted_spans
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 148253   # +50 → receiver is healthy
```

If `accepted` climbs but `sent` doesn't, the fault is downstream of ingress (processor or exporter). If `accepted` doesn't move, the fault is the network/endpoint/TLS between generator and receiver — and by extension, the same path the app uses.

### 4.7 SDK-side: is the application even producing spans?

Before blaming the Collector, prove the app emits. Redirect the SDK to a console exporter and raise its log level:

```console
$ export OTEL_TRACES_EXPORTER=console
$ export OTEL_LOG_LEVEL=debug
$ export OTEL_SERVICE_NAME=cartservice
$ ./cartservice
{"Name":"GET /cart","SpanContext":{"TraceID":"5b8efff7...","SpanID":"eee19b7e..."},"Parent":{"TraceID":"00000000...","remote":false},"Kind":2,"StartTime":"...","Attributes":[{"Key":"http.request.method","Value":"GET"}]}
```

If nothing prints, the problem is instrumentation, not the pipeline — no debugging of the Collector will help.

### 4.8 Profile a leaking/slow Collector with pprof

```console
$ go tool pprof -top http://localhost:1777/debug/pprof/heap
Showing nodes accounting for 812MB, 96.4% of 842MB total
      flat  flat%   sum%        cum   cum%
   410MB   48.7%  48.7%      410MB  48.7%  batchprocessor.(*batchTraces).add
   180MB   21.4%  70.1%      180MB  21.4%  collector/exporter/exporterhelper.(*queueSender)
```

A heap dominated by the batch processor or the queue sender points at an accumulation problem — usually a downstream backend too slow to drain, holding data in memory until `memory_limiter` intervenes.

---

## 5. Verification and Failure Diagnosis

### 5.1 The traversal method (memorize this)

Debugging a pipeline is a **linear walk of the chain**; at each hop ask the same two questions and consult one counter:

| # | Hop | "Is data arriving?" | "Is data leaving?" | Tool |
|---|---|---|---|---|
| 1 | App SDK | — | Console exporter prints spans | `OTEL_TRACES_EXPORTER=console` |
| 2 | App → Collector | `receiver_accepted_*` climbs | — | `:8888/metrics` + `telemetrygen` |
| 3 | Receiver → processors | accepted > 0 | `receiver_refused_*` == 0 | internal metrics |
| 4 | memory_limiter | logs: no "Refusing data" | — | Collector logs |
| 5 | Processors → exporter | — | `exporter_enqueue_failed_*` == 0 | internal metrics + zpages `servicez` |
| 6 | Exporter → backend | `exporter_sent_*` climbs | `exporter_send_failed_*` == 0, `queue_size` < capacity | internal metrics + `debug` exporter |

Find the first hop where "arriving" is true but "leaving" is false — that is your fault domain.

### 5.2 Failure-mode catalogue

| Symptom (what you see) | Signature (the evidence) | Root cause | Fix |
|---|---|---|---|
| Backend missing recent data, Collector "healthy" | `exporter_send_failed_spans` rising, `queue_size == queue_capacity` | Backend down/slow; queue full, dropping oldest | Fix backend; raise `queue_size`/`num_consumers`; alert on `queue_size / queue_capacity` |
| Data loss during traffic spikes | Logs: `Memory usage is above soft limit. Refusing data.`; `receiver_refused_*` climbs | `memory_limiter` protecting the process | Raise `limit_mib` (and container limit); add a batching gateway; scale replicas |
| Traces render as disconnected fragments | `debug` shows child spans with empty `Parent ID` | Broken context propagation (missing headers, unsupported propagator, thread/async boundary) | Ensure W3C `traceparent` propagation; configure matching propagators end-to-end |
| No data at all, app looks fine | `receiver_accepted_* == 0`, no receiver logs | Wrong endpoint or protocol: gRPC `:4317` vs HTTP `:4318`, or TLS mismatch | Align `OTEL_EXPORTER_OTLP_PROTOCOL`/endpoint; verify TLS/`insecure` |
| Metrics backend cost/latency exploding | `otelcol_processor_batch_batch_send_size` huge; high-cardinality label sets in payload (`debug detailed`) | Cardinality explosion (unbounded label values like user IDs) | Drop/aggregate via `attributes`/`transform`/`filter` processor; fix instrumentation |
| Fewer traces than expected, no errors | Steady ratio of spans present; consistent with a sampling arg | Head/tail sampling dropping by design | Confirm `OTEL_TRACES_SAMPLER` / tail-sampling policy is intended |
| Collector RSS climbs then OOM-killed | `otelcol_process_memory_rss` rising; pprof heap in batch/queue | Backend can't drain; data accumulates faster than limiter frees | Fix egress; lower `send_batch_size`/`timeout`; ensure `limit_mib` < container limit |
| Config edit had no effect | `servicez`/`pipelinez` shows old wiring | Config not reloaded / restart didn't pick up ConfigMap | Restart/roll the Collector; verify mounted config; check startup logs |

### 5.3 Alerting on the pipeline itself (so it's not silent next time)

The whole motivation from §1 collapses to a handful of PromQL alerts on the Collector's own metrics:

```promql
# Egress failing
rate(otelcol_exporter_send_failed_spans[5m]) > 0

# Ingress backpressure — data refused at the door
rate(otelcol_receiver_refused_spans[5m]) > 0

# Queue near saturation (drops imminent)
otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.8

# The Collector is missing entirely
up{job="otel-collector"} == 0
```

### 5.4 Quick verification checklist

1. `curl :13133/health/status` → `Server available`.
2. `grep "Everything is ready"` in startup logs; confirm no component errors.
3. `curl :8888/metrics` → `receiver_accepted_*` increasing while traffic flows.
4. `receiver_refused_* == 0` and `exporter_send_failed_* == 0`.
5. `exporter_queue_size` well below `queue_capacity`.
6. `curl :55679/debug/servicez` → pipeline wiring matches intent.
7. Inject with `telemetrygen`; confirm counters move end-to-end.
8. `debug` exporter at `detailed` (sampled) → attributes and `Parent ID` correct.

---

## References

- OpenTelemetry — Collector Troubleshooting: https://opentelemetry.io/docs/collector/troubleshooting/
- OpenTelemetry — Collector Internal Telemetry (`service.telemetry`, self-metrics): https://opentelemetry.io/docs/collector/internal-telemetry/
- OpenTelemetry — Collector Configuration (receivers, processors, exporters, extensions): https://opentelemetry.io/docs/collector/configuration/
- Collector `debug` exporter (verbosity, sampling): https://github.com/open-telemetry/opentelemetry-collector/tree/main/exporter/debugexporter
- Collector `zpages` extension: https://github.com/open-telemetry/opentelemetry-collector/tree/main/extension/zpagesextension
- Collector `pprof` extension: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/pprofextension
- Collector `health_check` extension: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/healthcheckextension
- Collector `memory_limiter` processor: https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/memorylimiterprocessor
- Collector `batch` processor: https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/batchprocessor
- Exporter helper (`sending_queue`, `retry_on_failure`): https://github.com/open-telemetry/opentelemetry-collector/tree/main/exporter/exporterhelper
- `telemetrygen` load/diagnostic generator: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
- OpenTelemetry SDK environment variables (`OTEL_LOG_LEVEL`, `OTEL_TRACES_EXPORTER`, samplers): https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- OpenTelemetry Context Propagation (W3C `traceparent`): https://opentelemetry.io/docs/concepts/context-propagation/
- CNCF — OTCA Curriculum: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf