# 4.3 Error Handling

> **Domain 4 — Maintaining and Debugging OpenTelemetry** · Exam weight: **2.5%**
> OpenTelemetry Certified Associate (OTCA)

---

## 1. Motivation — the "do no harm" contract

The defining architectural constraint of a telemetry pipeline is asymmetric: the observability system exists to report on the health of the target system, so **it must never become the reason the target system fails.** A tracing SDK that throws an unhandled exception on a malformed span, an exporter that blocks the request thread while a backend is down, or a Collector that runs the node out of memory during a traffic spike — each of these turns your diagnostics layer into the outage.

OpenTelemetry codifies this in its **Error Handling specification**. Two principles drive every design decision below:

1. **The API and SDK must not throw runtime exceptions into user code.** Errors are handled internally and surfaced through a *self-diagnostics* channel (an error handler + internal logs), never propagated to the instrumented call site. Fail-fast crashing is permitted *only* at initialization time, never during steady-state operation.
2. **Data loss is preferable to backpressure that harms the application.** When the pipeline cannot keep up, the last-resort behavior is to drop telemetry — but it must drop it *observably* (counters increment), never silently.

Error handling in OpenTelemetry is therefore not one feature; it is a set of behaviors layered across five boundaries. This is the mental model you must carry into production and into the exam:

| Layer | Boundary | Failure it absorbs | Primary mechanism |
|---|---|---|---|
| **API** | app ↔ instrumentation | Bug in instrumentation, uninitialized SDK | No-op implementation, never throws |
| **SDK self-diagnostics** | SDK internals ↔ operator | Export errors, config problems | Global **Error Handler** + internal logger (`OTEL_LOG_LEVEL`) |
| **Signal/data model** | code ↔ trace data | Business/runtime errors in the traced operation | `Span.SetStatus(Error)` + `Span.RecordException()` |
| **SDK export** | SDK ↔ network | Backend transient unavailability | `BatchSpanProcessor` queue + OTLP retry/backoff |
| **Collector pipeline** | receiver → processor → exporter | Backend outage, memory pressure, poison data | `retry_on_failure`, `sending_queue`, `memory_limiter`, permanent-vs-transient error classification |

The rest of this topic walks each layer with production-grade configuration.

---

## 2. Layer 1–2: API safety and the SDK Error Handler

### 2.1 The API never throws

By spec, calling the API before an SDK is installed returns **no-op** implementations. A `Tracer` from the global provider with no SDK produces non-recording spans; every method is a safe stub. This is why instrumentation libraries can call the API unconditionally without guarding against "is OpenTelemetry configured?" — the failure mode of an unconfigured system is *silence*, not a crash.

### 2.2 The Global Error Handler (self-diagnostics)

When the SDK itself hits a problem it cannot surface to the caller — the classic case being an **exporter that failed to ship a batch** — it routes the error to a configurable handler rather than throwing. In Go:

```go
package main

import (
	"go.opentelemetry.io/otel"
)

// Custom handler: count SDK-internal errors so they become a metric,
// and rate-limit logging so a dead backend doesn't flood stderr.
func init() {
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		sdkInternalErrors.Add(1) // your own metric
		limitedLog.Printf("otel-sdk: %v", err)
	}))
}
```

The equivalent knobs across languages:

| Language | Error surface | Verbosity control |
|---|---|---|
| Go | `otel.SetErrorHandler()` | — |
| Java | `io.opentelemetry` via `java.util.logging` | JUL level on the OTel logger |
| Python | `logging` module, logger `opentelemetry` | standard `logging` level |
| Node.js | `diag` API — `diag.setLogger()` | `DiagLogLevel` / `OTEL_LOG_LEVEL` |
| .NET | `EventSource` `OpenTelemetry-*` | `OTEL_LOG_LEVEL` |

The universal environment variable is **`OTEL_LOG_LEVEL`** (`error` | `warn` | `info` | `debug`). In production you keep it at `error` or `warn`; you raise it to `debug` only while diagnosing, because a chatty exporter failure at `debug` can itself become a load problem.

```console
$ OTEL_LOG_LEVEL=debug OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317 ./app
opentelemetry: exporter connecting to http://collector:4317
opentelemetry: batch span processor started (max_queue=2048, batch=512)
opentelemetry: exporter export failed: rpc error: code = Unavailable desc = connection refused; retrying in 5s
opentelemetry: exporter export failed: rpc error: code = Unavailable desc = connection refused; retrying in 7.5s
opentelemetry: batch span processor dropped 512 spans: queue full
```

That last line is the ground truth of the "do no harm" contract: rather than block the application waiting for a dead Collector, the SDK **drops spans and increments a drop counter**. The application never sees an error.

---

## 3. Layer 3: signal-level error handling — Status and RecordException

This is where *your* code participates. A span's outcome is expressed through two independent facilities that are frequently — and incorrectly — assumed to be one.

### 3.1 Span Status

The status data model has exactly three codes:

| StatusCode | Meaning | Who sets it |
|---|---|---|
| `Unset` | Default. Outcome unknown / normal. | Nobody — this is the initial value |
| `Error` | The operation failed. | Instrumentation, on a known failure |
| `Ok` | Explicitly *not* an error; overrides a backend's heuristic. | The application, deliberately, and rarely |

Spec rule that trips people up: instrumentation **SHOULD NOT** set `Ok`. Leaving a successful span `Unset` is correct — it lets backends and sampling apply their own semantics. `Ok` is a hard override reserved for the application author who wants to say "I know this looks like a 4xx but for my business it is success." Only `Error` carries a free-text `description`.

### 3.2 RecordException

`RecordException` attaches a span **event** named `exception` carrying the semantic-convention attributes:

| Attribute | Example |
|---|---|
| `exception.type` | `java.net.SocketTimeoutException` |
| `exception.message` | `Read timed out` |
| `exception.stacktrace` | full multi-line stack |
| `exception.escaped` | `true` if the exception propagated out of the span's scope |

### 3.3 The gotcha: they are orthogonal

**`RecordException` does not set the status to `Error`.** Recording the exception adds diagnostic detail; it does *not* mark the span as failed. You must call both, in this order of intent:

```python
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode

tracer = trace.get_tracer("checkout")

with tracer.start_as_current_span("charge_card") as span:
    try:
        gateway.charge(order)
    except PaymentError as exc:
        span.record_exception(exc)                       # detail: what & where
        span.set_status(Status(StatusCode.ERROR,          # verdict: it failed
                               "payment gateway declined"))
        raise
```

Idiomatic shortcuts exist — Python's `start_as_current_span(..., record_exception=True, set_status_on_exception=True)` (both default `True`) does both automatically for exceptions that escape the `with` block. But when you catch-and-handle without re-raising, the auto-behavior does not fire and you are back to the manual two-call pattern above.

| Pattern | `exception` event? | Status set to `Error`? |
|---|---|---|
| `record_exception()` only | ✅ | ❌ (stays `Unset`) |
| `set_status(Error)` only | ❌ | ✅ |
| exception escapes `with` (auto) | ✅ | ✅ |
| caught + handled, no manual calls | ❌ | ❌ |

A span with a recorded exception but `Unset` status is a real, common production defect: the trace *looks* fine in the error-rate panel while the exception detail sits invisibly in the events.

---

## 4. Layer 5: Collector pipeline error handling

The Collector is where error handling becomes an infrastructure discipline, because it sits between many producers and one (fragile) backend.

### 4.1 Permanent vs. transient errors

Every consumer in a pipeline returns an error up the chain. The Collector classifies them into two buckets, and the distinction decides whether data is **retried or dropped**:

| Class | Constructed by | Examples | Behavior |
|---|---|---|---|
| **Permanent** | `consumererror.NewPermanent(err)` | 400 Bad Request, malformed/poison payload, schema rejection, 401/403 | **Dropped immediately.** Retrying a malformed batch will never succeed and only wastes the queue. |
| **Transient (non-permanent)** | any plain `error` | `Unavailable`, `DeadlineExceeded`, 429, 502/503/504, connection refused | **Retried** by `retry_on_failure` with backoff. |

This is why a Collector pointed at a backend returning `400` will show data *dropped* with no retry storm, whereas a backend that is simply *down* triggers exponential backoff and queue growth.

### 4.2 retry_on_failure and sending_queue

Both are provided by `exporterhelper`, so any OTLP/OTLP-HTTP/most exporters expose them with identical semantics.

- **`retry_on_failure`** — exponential backoff for transient errors. After `max_elapsed_time` the item is given up on (dropped).
- **`sending_queue`** — decouples the receive/process path from the (slow) network. Producers enqueue; `num_consumers` workers drain the queue to the exporter. When the queue is **full**, `enqueue` fails → this is the backpressure signal that propagates back toward the receiver.

| Setting | Default | Production meaning |
|---|---|---|
| `retry_on_failure.enabled` | `true` | Absorb transient backend blips |
| `retry_on_failure.initial_interval` | `5s` | First backoff |
| `retry_on_failure.max_interval` | `30s` | Backoff ceiling |
| `retry_on_failure.max_elapsed_time` | `300s` | Total retry budget before **drop** |
| `sending_queue.enabled` | `true` | Decouple ingest from egress |
| `sending_queue.num_consumers` | `10` | Egress parallelism |
| `sending_queue.queue_size` | `1000` | Buffer depth before backpressure/drop |
| `sending_queue.storage` | *(unset → in-memory)* | Set to a storage extension for a **persistent** queue |

**Trade-off — in-memory vs. persistent queue:**

| | In-memory queue (default) | Persistent queue (`file_storage`) |
|---|---|---|
| Durability across restart/OOM/crash | ❌ entire queue lost | ✅ survives restart |
| Latency / throughput | highest | lower (disk write per item) |
| Operational cost | none | PVC / disk + I/O |
| When to use | ephemeral, best-effort telemetry | billing/audit signals, unreliable backend link |

### 4.3 Backpressure with `memory_limiter`

`retry_on_failure` + `sending_queue` handle a *downstream* problem (backend down). `memory_limiter` handles the *upstream* problem: producers sending faster than the Collector can egress. Placed **first** in the pipeline, it periodically checks heap usage; above the soft limit it **refuses data** (returns errors that propagate back to receivers, which then reject the client with a retryable status). This converts "run the node out of memory and get OOM-killed" into "push backpressure onto the sender," which is exactly the "do no harm" contract applied to the Collector itself.

> Order matters: `memory_limiter` must be the **first** processor; `batch` typically after it. A `batch` before `memory_limiter` would accumulate memory the limiter is trying to bound.

### 4.4 Complete production Collector manifest

```yaml
# otelcol-config.yaml — production error-handling configuration
extensions:
  # Persistent queue backing store — survives Collector restarts/OOM.
  file_storage/queue:
    directory: /var/lib/otelcol/sending-queue
    timeout: 10s
    compaction:
      on_start: true
      directory: /var/lib/otelcol/compaction
  # Live in-process debugging surface.
  zpages:
    endpoint: 0.0.0.0:55679
  health_check:
    endpoint: 0.0.0.0:13133

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # FIRST processor: bounds heap, applies backpressure to receivers.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80        # hard limit — refuse data above this
    spike_limit_percentage: 25  # headroom for bursts between checks
  batch:
    timeout: 5s
    send_batch_size: 8192
    send_batch_max_size: 16384

exporters:
  otlp/backend:
    endpoint: tempo-gateway.observability.svc:4317
    tls:
      insecure: false
    # Transient backend outages: back off, don't hammer, give up after 5 min.
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    # Durable buffer: 10 workers, 5000 slots, persisted to disk.
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
      storage: file_storage/queue
  # Last-resort visibility into what is flowing (or failing).
  debug:
    verbosity: normal
    sampling_initial: 5
    sampling_thereafter: 200

service:
  extensions: [file_storage/queue, zpages, health_check]
  telemetry:
    logs:
      level: info
    metrics:
      # Expose otelcol_* internal metrics for scraping.
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, batch]
      exporters:  [otlp/backend, debug]
```

### 4.5 Kubernetes: the persistent queue needs durable storage

A persistent `sending_queue` is only durable if its directory survives Pod restarts. That means a `StatefulSet` (or a Deployment with a bound PVC) — not an `emptyDir`.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: otelcol
  namespace: observability
spec:
  serviceName: otelcol
  replicas: 1
  selector:
    matchLabels: { app: otelcol }
  template:
    metadata:
      labels: { app: otelcol }
    spec:
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.111.0
          args: ["--config=/conf/otelcol-config.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: metrics,   containerPort: 8888 }
            - { name: zpages,    containerPort: 55679 }
          livenessProbe:
            httpGet: { path: /, port: 13133 }
          volumeMounts:
            - { name: config, mountPath: /conf }
            - { name: queue,  mountPath: /var/lib/otelcol }  # persistent queue
      volumes:
        - name: config
          configMap: { name: otelcol-config }
  volumeClaimTemplates:
    - metadata: { name: queue }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests: { storage: 10Gi }
```

---

## 5. Verification and failure diagnosis

### 5.1 Validate before you ship

```console
$ otelcol-contrib validate --config=otelcol-config.yaml
$ echo $?
0
```

An invalid config fails fast at startup (permitted by the spec — this is init time, not runtime):

```console
$ otelcol-contrib validate --config=broken.yaml
Error: invalid configuration: exporters::otlp/backend: sending_queue.storage
references storage "file_storage/queue" which is not configured in service::extensions
$ echo $?
1
```

### 5.2 The internal telemetry metrics — your first stop

Scrape `:8888/metrics`. These `otelcol_*` counters are the definitive account of what the pipeline dropped, retried, and shipped:

```console
$ curl -s http://otelcol:8888/metrics | grep -E 'exporter_(send_failed|sent|queue|enqueue)'
otelcol_exporter_sent_spans{exporter="otlp/backend"}          1.482940e+06
otelcol_exporter_send_failed_spans{exporter="otlp/backend"}   3.072000e+03
otelcol_exporter_enqueue_failed_spans{exporter="otlp/backend"} 5.120000e+02
otelcol_exporter_queue_size{exporter="otlp/backend"}          4.998000e+03
otelcol_exporter_queue_capacity{exporter="otlp/backend"}      5.000000e+03
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 1.024000e+03
```

Read this like a doctor reads a chart:

| Signal | What it means | Root cause to check |
|---|---|---|
| `exporter_queue_size` ≈ `queue_capacity` | Queue **saturated** | Backend slow/down; egress can't drain |
| `exporter_enqueue_failed_spans` rising | Queue full → **producers backpressured/dropped** | Same as above; queue too small |
| `exporter_send_failed_spans` rising | Exporter giving up after retry budget | Backend outage exceeding `max_elapsed_time`, or permanent errors (400/401) |
| `receiver_refused_spans` rising | `memory_limiter` refusing data | Ingest > egress; Collector under memory pressure — scale out or raise limits |

The diagnostic flow is causal: `queue_size` maxes out → `enqueue_failed` climbs → `receiver_refused` climbs → clients get retryable errors. Trace it back to the exporter and you find the backend.

### 5.3 zpages — live pipeline state without a backend

```console
$ curl -s http://otelcol:55679/debug/tracez | head
$ curl -s http://otelcol:55679/debug/pipelinez
```

`/debug/tracez` groups the Collector's own spans by latency bucket and by **error status**, letting you see failing internal operations in real time. `/debug/pipelinez` shows the receiver→processor→exporter wiring as loaded — the fastest way to confirm `memory_limiter` is actually first.

### 5.4 The debug exporter — is data even arriving?

When you cannot tell whether the problem is "no data produced" or "data produced but not exported," add the `debug` exporter with `verbosity: detailed` and read stderr:

```console
$ kubectl logs -n observability otelcol-0 | tail
2026-08-11T14:22:07.114Z  info  TracesExporter  {"kind": "exporter",
  "data_type": "traces", "name": "debug", "resource spans": 1, "spans": 3}
2026-08-11T14:22:07.115Z  info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
ScopeSpans #0
Span #0
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Name           : charge_card
    Status code    : STATUS_CODE_ERROR
    Status message : payment gateway declined
Events:
    -> exception: exception.type=PaymentError, exception.message="declined"
```

This single output confirms the whole chain end-to-end: the span carries `STATUS_CODE_ERROR` **and** the `exception` event — the correct two-part error signal from §3.3.

### 5.5 Failure playbook

| Symptom | Likely cause | Confirm with | Fix |
|---|---|---|---|
| App fine, but no traces in backend | Backend down; queue draining/dropping | `exporter_send_failed_spans`, SDK `debug` logs | Restore backend; retry/queue absorbs the gap |
| Traces missing under load only | Queue too small / ingest > egress | `enqueue_failed` + `receiver_refused` rising | ↑ `queue_size`, ↑ `num_consumers`, scale replicas |
| Collector OOM-killed | No `memory_limiter` or limit too high | container OOM events, no `receiver_refused` | Add/tune `memory_limiter` as first processor |
| Queue lost every restart | In-memory queue | `sending_queue.storage` unset | Add `file_storage` + persistent volume |
| Retry storm on bad data | Backend `400` treated as transient | steady `send_failed`, no recovery | Backend should return `NewPermanent`; fix payload |
| Error rate dashboard looks clean but exceptions exist | `record_exception` without `set_status(Error)` | `debug` exporter shows `Status code: UNSET` | Set span status on failure (§3.3) |

---

## 6. References

- **OpenTelemetry Specification — Error Handling:** https://opentelemetry.io/docs/specs/otel/error-handling/
- **Trace API — Span Status & Record Exception:** https://opentelemetry.io/docs/specs/otel/trace/api/#set-status
- **Semantic Conventions — Exceptions on spans:** https://opentelemetry.io/docs/specs/semconv/exceptions/exceptions-spans/
- **SDK configuration & environment variables (`OTEL_LOG_LEVEL`, `OTEL_BSP_*`):** https://opentelemetry.io/docs/languages/sdk-configuration/general/
- **Collector — `exporterhelper` (`retry_on_failure`, `sending_queue`):** https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
- **Collector — `memory_limiter` processor:** https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
- **Collector — `file_storage` extension (persistent queue):** https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/extension/storage/filestorage/README.md
- **Collector — Internal telemetry & metrics:** https://opentelemetry.io/docs/collector/internal-telemetry/
- **Collector — `zpages` extension:** https://github.com/open-telemetry/opentelemetry-collector/blob/main/extension/zpagesextension/README.md
- **Collector — `debug` exporter:** https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/debugexporter/README.md
- **OTCA Curriculum (CNCF):** https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf