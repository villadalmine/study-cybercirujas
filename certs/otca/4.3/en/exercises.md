# OTCA Domain 4 · Topic 4.3 — Error Handling

**Guided lab exercises (production-grade)**

> These exercises are for OTCA Domain 4, *Maintaining and Debugging Observability Pipelines*. "Error handling" here means the failure semantics of the **telemetry export path**: how the OpenTelemetry Protocol (OTLP) classifies failures, how the Collector's `exporterhelper` retries and queues, how backpressure propagates upstream, and how you record and observe drops. The final exercise covers the *other* meaning of error handling — recording application errors as telemetry.
>
> **Reference sources**
> - OTLP failure & partial-success semantics — https://opentelemetry.io/docs/specs/otlp/#failures
> - `exporterhelper` (queue + retry) — https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
> - `file_storage` extension (persistent queue) — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/storage/filestorage
> - `memory_limiter` processor — https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
> - Collector internal telemetry — https://opentelemetry.io/docs/collector/internal-telemetry/
> - Exception semantic conventions — https://opentelemetry.io/docs/specs/semconv/exceptions/

### Lab prerequisites

- A Linux host with Docker (examples use `--network host`, which requires Linux).
- The Collector Contrib image: `otel/opentelemetry-collector-contrib:latest`.
- A load generator: `telemetrygen` (shipped as a contrib image, no local build needed).

```bash
# Pull once
docker pull otel/opentelemetry-collector-contrib:latest
docker pull ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest

# Helper alias used throughout (10 traces over gRPC to a local Collector)
gen() { docker run --rm --network host \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-endpoint localhost:4317 --otlp-insecure --traces "${1:-10}"; }
```

> Counter metrics scraped from `:8888/metrics` may carry a `_total` suffix depending on your Collector version (e.g. `otelcol_exporter_send_failed_spans` vs `..._total`). Grep on the stem shown in each exercise.

---

## Exercise 1 — Retryable failures and exponential backoff

**Goal:** observe what the Collector does when the downstream backend is unreachable (a *retryable* transport error) and how `retry_on_failure` governs backoff and eventual drop.

1. Create `ex1.yaml`. The `otlp` exporter points at port `4999`, where **nothing is listening**, so every export gets `connection refused` (mapped to gRPC `UNAVAILABLE`, a retryable code). `debug` proves data reaches the pipeline.

    ```yaml
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    exporters:
      debug:
        verbosity: normal
      otlp:
        endpoint: localhost:4999
        tls:
          insecure: true
        # retry_on_failure is ON by default; shown here explicitly with tight values
        retry_on_failure:
          enabled: true
          initial_interval: 2s
          max_interval: 6s
          max_elapsed_time: 20s
    service:
      telemetry:
        metrics:
          level: detailed
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [debug, otlp]
    ```

2. Start the Collector in the foreground so you can read its logs:

    ```bash
    docker run --rm --name otc --network host \
      -v "$(pwd)/ex1.yaml:/etc/otelcol-contrib/config.yaml" \
      otel/opentelemetry-collector-contrib:latest
    ```

3. In a second terminal, send traces and watch the first terminal:

    ```bash
    gen 10
    ```

4. Read the retry log lines. You will see repeated warnings with a growing `interval`, then a final drop after ~20s:

    ```text
    warn  internal/retry_sender.go  Exporting failed. Will retry the request after interval.
      {"kind":"exporter","data_type":"traces","name":"otlp",
       "error":"rpc error: code = Unavailable desc = ... connection refused",
       "interval":"2.31s"}
    warn  ... "interval":"3.7s"}
    warn  ... "interval":"5.9s"}
    error internal/queue_sender.go  Exporting failed. Dropping data.
      {"kind":"exporter","data_type":"traces","name":"otlp",
       "error":"no more retries left: rpc error: code = Unavailable ...",
       "dropped_items":20}
    ```

5. In a third terminal, scrape the self-observability metrics:

    ```bash
    curl -s localhost:8888/metrics | grep -E 'otelcol_exporter_(sent|send_failed)_spans'
    ```

    ```text
    otelcol_exporter_send_failed_spans{exporter="otlp",...} 20
    otelcol_exporter_sent_spans{exporter="otlp",...} 0
    otelcol_exporter_sent_spans{exporter="debug",...} 20
    ```

**Comprehension check**

- **Q1.1** Why is `connection refused` treated as *retryable* while a `400 Bad Request` would not be?
- **Q1.2** With `initial_interval: 2s`, `max_interval: 6s`, `max_elapsed_time: 20s`, why do the intervals grow but cap at ~6s, and what event terminates the retry loop?
- **Q1.3** `debug` reports 20 sent spans but `otlp` reports 20 *failed*. Why did the failure of one exporter not stop the other from succeeding?
- **Q1.4** A colleague sets `max_elapsed_time: 0` "to be safe." What is the production risk of that value?

---

## Exercise 2 — The sending queue and backpressure

**Goal:** understand that retries happen *behind a queue*, and what the queue does when it fills.

1. Create `ex2.yaml`. The backend is still dead, but now retries never give up (`max_elapsed_time: 0`) and the queue is deliberately tiny so it saturates:

    ```yaml
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    exporters:
      otlp:
        endpoint: localhost:4999
        tls:
          insecure: true
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_elapsed_time: 0        # retry forever -> items stay in the queue
        sending_queue:
          enabled: true
          num_consumers: 1
          queue_size: 2              # deliberately tiny
    service:
      telemetry:
        metrics:
          level: detailed
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [otlp]
    ```

2. Start it (same `docker run` as Exercise 1, swapping the file), then flood it faster than the (stuck) single consumer can drain:

    ```bash
    for i in 1 2 3 4 5; do gen 5 & done; wait
    ```

3. Watch for enqueue-failure logs and scrape the queue metrics:

    ```bash
    curl -s localhost:8888/metrics | grep -E 'otelcol_exporter_(queue_size|queue_capacity|enqueue_failed_spans)'
    ```

    ```text
    otelcol_exporter_queue_size{exporter="otlp",...} 2
    otelcol_exporter_queue_capacity{exporter="otlp",...} 2
    otelcol_exporter_enqueue_failed_spans{exporter="otlp",...} 55
    ```

    Collector log when the queue is full:

    ```text
    error exporterhelper/queue_sender.go  Exporting failed. Rejecting data.
      {"kind":"exporter","data_type":"traces","name":"otlp",
       "error":"sending queue is full","dropped_items":5}
    ```

**Comprehension check**

- **Q2.1** Data is being dropped, yet `otelcol_exporter_send_failed_spans` may stay at 0 while `otelcol_exporter_enqueue_failed_spans` climbs. What is the difference between these two drop counters?
- **Q2.2** The queue is full because the single consumer is blocked retrying a dead backend forever. Name **two** distinct configuration changes that would relieve this, and the trade-off of each.
- **Q2.3** When the sending queue rejects data, the OTLP *receiver* returns an error to the upstream client. Is that error retryable or permanent, and what is the desired client behavior?
- **Q2.4** Why does a persistent flood plus `max_elapsed_time: 0` create a worse failure mode than `max_elapsed_time: 300s`?

---

## Exercise 3 — Persistent queue (surviving restarts)

**Goal:** make the sending queue durable with the `file_storage` extension so buffered telemetry survives a Collector restart.

1. Prepare a writable host directory for the queue's disk backing:

    ```bash
    mkdir -p otc-storage && chmod 777 otc-storage
    ```

2. Create `ex3.yaml`. Note the `storage:` reference in `sending_queue` and the extension in `service.extensions`:

    ```yaml
    extensions:
      file_storage/queue:
        directory: /storage
        timeout: 1s
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    exporters:
      otlp:
        endpoint: localhost:4999      # still down for now
        tls:
          insecure: true
        retry_on_failure:
          enabled: true
          max_elapsed_time: 0
        sending_queue:
          enabled: true
          queue_size: 1000
          storage: file_storage/queue   # <-- persistent, disk-backed queue
    service:
      extensions: [file_storage/queue]
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [otlp]
    ```

3. Start the Collector with the storage volume mounted:

    ```bash
    docker run --rm --name otc --network host \
      -v "$(pwd)/ex3.yaml:/etc/otelcol-contrib/config.yaml" \
      -v "$(pwd)/otc-storage:/storage" \
      otel/opentelemetry-collector-contrib:latest
    ```

4. Send traces while the backend is down, confirm the queue has data on disk, then **kill the Collector** (Ctrl-C):

    ```bash
    gen 10
    ls -la otc-storage/     # a bbolt DB file is present
    ```

5. Bring up a real backend on port `4999` (a second Collector that just prints), then restart the first Collector against the *same* storage volume:

    ```bash
    # Terminal A: a backend that accepts OTLP on 4999 and prints
    cat > sink.yaml <<'EOF'
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4999
    exporters:
      debug:
        verbosity: normal
    service:
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [debug]
    EOF
    docker run --rm --network host \
      -v "$(pwd)/sink.yaml:/etc/otelcol-contrib/config.yaml" \
      otel/opentelemetry-collector-contrib:latest
    ```

    ```bash
    # Terminal B: restart the ORIGINAL collector; it re-reads the persisted queue
    docker run --rm --name otc --network host \
      -v "$(pwd)/ex3.yaml:/etc/otelcol-contrib/config.yaml" \
      -v "$(pwd)/otc-storage:/storage" \
      otel/opentelemetry-collector-contrib:latest
    ```

6. Observe in **Terminal A** that the 10 traces you sent *before the crash* are now delivered — they were replayed from disk.

**Comprehension check**

- **Q3.1** Repeat this exercise mentally *without* the `storage:` reference. What happens to the 10 buffered traces when the Collector is killed, and why?
- **Q3.2** The persisted data lives in a bbolt file inside the mounted volume. What must be true of that path for the durability guarantee to hold in Kubernetes?
- **Q3.3** A persistent queue with `queue_size: 1000` still has a limit. Give one scenario where even the persistent queue drops data, and how you would detect it.
- **Q3.4** Why does the persistent queue protect against Collector restarts but **not** against the host's disk being lost?

---

## Exercise 4 — Permanent errors vs. partial success

**Goal:** distinguish a *permanent* (non-retryable) failure from a *retryable* one, and understand OTLP **partial success**. Retrying a permanent error wastes resources and never succeeds.

1. Start a mock backend that answers every OTLP/HTTP POST with `400 Bad Request` (a permanent error):

    ```bash
    python3 - <<'EOF'
    from http.server import BaseHTTPRequestHandler, HTTPServer
    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            self.send_response(400)
            self.send_header('Content-Length', '0')
            self.end_headers()
        def log_message(self, *a): pass
    print("mock OTLP/HTTP backend returning 400 on :4318")
    HTTPServer(('0.0.0.0', 4318), H).serve_forever()
    EOF
    ```

2. Create `ex4.yaml` using the **HTTP** exporter pointed at the mock, with retry enabled:

    ```yaml
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    exporters:
      otlphttp:
        endpoint: http://localhost:4318
        retry_on_failure:
          enabled: true
          initial_interval: 2s
          max_elapsed_time: 20s
    service:
      telemetry:
        metrics:
          level: detailed
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [otlphttp]
    ```

3. Start the Collector (mount `ex4.yaml`) and send traces:

    ```bash
    gen 10
    ```

4. Read the Collector log. Unlike Exercise 1, there is **no retry loop** — the batch is dropped immediately:

    ```text
    error exporterhelper/common.go  Exporting failed. Rejecting data.
      Try enabling sending_queue to survive temporary failures.
      {"kind":"exporter","data_type":"traces","name":"otlphttp",
       "error":"not retryable error: Permanent error: rpc error: code = ...
                error exporting items, request to http://localhost:4318/v1/traces
                responded with HTTP Status Code 400",
       "dropped_items":10}
    ```

5. Confirm via metrics that these count as send failures, and that zero retries were attempted (the drop is immediate):

    ```bash
    curl -s localhost:8888/metrics | grep -E 'otelcol_exporter_send_failed_spans'
    ```

6. **Reasoning step (partial success):** now consider a backend that returns HTTP `200` but with an OTLP body of `{"partialSuccess":{"rejectedSpans":"3","errorMessage":"3 spans rejected: missing service.name"}}`. Read the OTLP spec section on partial success and predict the Collector's behavior before checking the answer.

**Comprehension check**

- **Q4.1** Why does OTLP forbid the client from retrying a `400`/`INVALID_ARGUMENT`, even though the data was genuinely not delivered?
- **Q4.2** List the HTTP status codes OTLP defines as retryable, and the gRPC status codes it defines as retryable. Which one code is *conditionally* retryable, and on what signal?
- **Q4.3** In **partial success**, the server returns `200 OK` *and* a `rejectedSpans` count. Should the client retry the rejected spans? What is it expected to do instead?
- **Q4.4** A throttling backend returns `429` with a `Retry-After: 30` header (or gRPC `RESOURCE_EXHAUSTED` + `RetryInfo`). How must a compliant client treat that header/field, and why is ignoring it dangerous?

---

## Exercise 5 — Upstream backpressure with `memory_limiter`

**Goal:** see how a Collector under memory pressure *refuses* data and pushes backpressure to its clients instead of being OOM-killed.

1. Create `ex5.yaml`. `memory_limiter` is the **first** processor; limits are set absurdly low to trigger refusal quickly:

    ```yaml
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 20            # hard limit (tiny, for the demo)
        spike_limit_mib: 5       # soft limit = 20 - 5 = 15 MiB
      batch: {}
    exporters:
      debug:
        verbosity: normal
    service:
      telemetry:
        metrics:
          level: detailed
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]   # memory_limiter FIRST
          exporters: [debug]
    ```

2. Start it, then hammer it hard enough to cross the soft limit:

    ```bash
    for i in $(seq 1 8); do gen 20000 & done; wait
    ```

3. Watch for refusal logs and scrape the refusal counter:

    ```text
    warn  memorylimiter/memorylimiter.go  Memory usage is above soft limit.
      Refusing data.  {"cur_mem_mib": 16}
    ```

    ```bash
    curl -s localhost:8888/metrics | grep -E 'otelcol_processor_refused_spans'
    ```

    ```text
    otelcol_processor_refused_spans{processor="memory_limiter",...} 43120
    ```

4. On the **client side**, `telemetrygen` logs export errors — the receiver answered with a retryable error, so a well-behaved client backs off and retries:

    ```text
    traces  failed to export ... rpc error: code = Unavailable
            desc = data refused due to high memory usage
    ```

**Comprehension check**

- **Q5.1** Why must `memory_limiter` be the *first* processor in the pipeline? What breaks if you put `batch` before it?
- **Q5.2** Explain the two thresholds: what happens between the soft limit (`limit_mib - spike_limit_mib`) and the hard limit, and what happens at/above the hard limit?
- **Q5.3** When `memory_limiter` refuses data, the OTLP receiver returns a *retryable* error to the client. Trace the full chain of what a compliant SDK client does next. Why is "refuse and let the client retry" better than silently dropping?
- **Q5.4** `memory_limiter` protects one Collector from OOM but can create a retry storm across many clients. Which two other mechanisms in this topic complement it to absorb that pressure instead of bouncing it back?

---

## Exercise 6 — Recording application errors as telemetry

**Goal:** the producer side of error handling. Instrumented code must *record* failures so the pipeline has something to carry: set span **status** to `ERROR` and attach an **exception event** following semantic conventions.

1. Study this Python instrumentation (the pattern is identical across languages). It records an exception and marks the span as failed:

    ```python
    from opentelemetry import trace
    from opentelemetry.trace import Status, StatusCode

    tracer = trace.get_tracer("checkout")

    def charge(order):
        with tracer.start_as_current_span("charge_card") as span:
            try:
                do_charge(order)                 # raises on failure
            except PaymentDeclined as exc:
                span.record_exception(exc)        # -> "exception" event
                span.set_status(Status(StatusCode.ERROR, "payment declined"))
                raise
    ```

2. Predict the resulting span before running anything: it will carry `status.code = ERROR` and one event named `exception` with these attributes:

    ```text
    span "charge_card"
      status:  ERROR  ("payment declined")
      event "exception"
        exception.type:       PaymentDeclined
        exception.message:    card 4111... declined by issuer
        exception.stacktrace: Traceback (most recent call last): ...
    ```

3. Contrast with the *default*: a span whose code path threw but where you forgot `set_status`. Its status stays `UNSET` — downstream error-rate dashboards will **undercount** the failure.

**Comprehension check**

- **Q6.1** What is the difference between `span.record_exception()` and `span.set_status(ERROR)`? Why do you usually need both, and what does each one feed?
- **Q6.2** The three canonical span status codes are `UNSET`, `OK`, `ERROR`. Why does the specification say instrumentation should *rarely* set `OK`, and leave successful spans `UNSET`?
- **Q6.3** Name the standard attributes carried by an `exception` event, and why using these exact keys (rather than custom ones) matters for a backend.
- **Q6.4** This is a *different* layer of "error handling" than Exercises 1–5. In one sentence, distinguish an application error recorded on a span from a pipeline export error handled by `exporterhelper`.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** `connection refused` is a *transport-level, transient* condition — the target may simply be restarting or briefly unreachable — so a retry can plausibly succeed. It maps to gRPC `UNAVAILABLE`, which OTLP lists as retryable. A `400 Bad Request` / `INVALID_ARGUMENT` means the *payload itself* is unacceptable (malformed, wrong schema, too large, missing required fields). Resending identical bytes will fail identically forever, so OTLP classifies it as permanent and the client must not retry.

**A1.2** `exporterhelper` uses exponential backoff: each interval ≈ previous × `multiplier` (default 1.5) plus jitter (`randomization_factor`, default 0.5), clamped to `max_interval` — hence intervals grow 2s → ~3s → ~6s and then stop growing. The loop terminates when the cumulative retry time exceeds `max_elapsed_time` (20s here); at that point the item is dropped, logged as `Dropping data`, and `otelcol_exporter_send_failed_spans` is incremented.

**A1.3** Each exporter in a pipeline is driven independently through its own `exporterhelper` (its own queue/retry state). A fan-out to `[debug, otlp]` sends the same batch to both; `debug` writes to stdout and succeeds immediately, while `otlp` fails and retries on its own. One exporter's failure does not roll back or block another's success.

**A1.4** `max_elapsed_time: 0` means *retry forever*. With a persistently unreachable backend, items are never released; they pile up behind the sending queue until it fills, at which point the Collector starts rejecting new data at the receiver (Exercise 2). It converts a bounded, observable drop into an unbounded backlog and cascading backpressure. Use a finite value unless you pair `0` with a **persistent** queue and capacity planning.

### Exercise 2

**A2.1** `enqueue_failed_spans` counts data rejected **at the front door** — the item never entered the queue because the queue was full, so it was dropped before any export attempt. `send_failed_spans` counts data that *was* dequeued and handed to the exporter but failed to send after exhausting retries. Full queue ⇒ `enqueue_failed` rises; dead backend with a draining queue ⇒ `send_failed` rises.

**A2.2** Any two of: (a) increase `num_consumers` — more parallel senders drain the queue faster, at the cost of more concurrent load/connections on the backend; (b) increase `queue_size` — absorb longer outages, at the cost of more memory (or disk, if persistent); (c) set a finite `max_elapsed_time` — stop wedging a consumer on a hopeless request so it can move to the next item, at the cost of dropping data sooner during real outages; (d) enable a persistent queue to trade RAM pressure for disk.

**A2.3** When the sending queue is full, the receiver returns a **retryable** error to the upstream client (e.g. gRPC `UNAVAILABLE` / HTTP `503`). The desired behavior is that the client backs off and retries later — backpressure is propagated toward the source rather than data being silently discarded at the edge.

**A2.4** With `max_elapsed_time: 300s`, stuck items are eventually released (dropped) and the single consumer frees up to process the next batch, so the queue keeps cycling. With `max_elapsed_time: 0`, the consumer is pinned forever on the first unreachable request; the queue can never drain, fills permanently, and *every* subsequent batch is refused at the receiver — a total, self-inflicted outage rather than partial loss.

### Exercise 3

**A3.1** Without `storage:`, the sending queue is **in-memory only**. Killing the process discards RAM, so all 10 buffered traces are lost with no record — the queue starts empty on restart. Persistence is what lets buffered items outlive the process.

**A3.2** The `directory` must be backed by durable, node-independent storage that is re-attached to the *same* Collector instance after a restart — i.e. a `PersistentVolumeClaim`, not an `emptyDir` (which is deleted with the pod) and not the container's ephemeral layer. It must also be writable by the Collector's UID and, since bbolt takes a file lock, mounted `ReadWriteOnce` to a single replica.

**A3.3** If the backend is down long enough (or throughput high enough) that buffered items exceed `queue_size: 1000`, new items are rejected at enqueue — persistence bounds durability, not capacity. Detect it via `otelcol_exporter_enqueue_failed_spans` climbing and `otelcol_exporter_queue_size` sitting pinned at `otelcol_exporter_queue_capacity`.

**A3.4** The persistent queue's guarantee is only as strong as the disk it writes to. A restart re-reads that disk, so buffered data survives. But if the volume itself is destroyed (node loss with an `emptyDir`, deleted PVC, disk failure), the bbolt file is gone and the buffered telemetry is unrecoverable — durability is scoped to the storage medium's own durability.

### Exercise 4

**A4.1** A `400`/`INVALID_ARGUMENT` reports that the *request content* is unacceptable — malformed proto, schema violation, missing required fields, or oversize. Nothing about resending the identical bytes changes the outcome, so retrying only burns CPU, network, and quota while guaranteeing the same rejection. OTLP marks it permanent so clients fail fast and surface a real bug/config error instead of hiding it behind endless retries.

**A4.2** Retryable **HTTP**: `429 Too Many Requests`, `502 Bad Gateway`, `503 Service Unavailable`, `504 Gateway Timeout`. Retryable **gRPC**: `CANCELLED`, `DEADLINE_EXCEEDED`, `ABORTED`, `OUT_OF_RANGE`, `UNAVAILABLE`, `DATA_LOSS`. The conditionally-retryable code is gRPC `RESOURCE_EXHAUSTED`: retry it **only** when the server signals recovery is possible by returning a `RetryInfo` in the status; otherwise treat it as permanent.

**A4.3** No — partial success means the server *definitively* rejected those `rejectedSpans` (e.g. invalid data); they are non-retryable by definition. The rest were accepted. The client must **not** resend the rejected items; it should log/emit a warning (surfacing `errorMessage`) so an operator can fix the source data. A `200` with `rejectedSpans: 0` and a non-empty message is a pure warning.

**A4.4** The client must **honor the delay** — wait at least `Retry-After` seconds (HTTP) or the `RetryInfo.retry_delay` (gRPC) before the next attempt. Ignoring it and retrying immediately amplifies load on an already-overwhelmed backend, turning throttling into a self-reinforcing overload (retry storm) that can keep the backend down and get the client rate-limited or banned.

### Exercise 5

**A5.1** `memory_limiter` must run first so it can refuse data at the earliest point, before other processors allocate memory holding/copying it. If `batch` runs first, batches accumulate telemetry in memory *ahead of* the limiter's protection, so the very growth the limiter exists to prevent happens before it can act — defeating the guard and risking OOM.

**A5.2** Between the soft limit (`limit_mib − spike_limit_mib`) and the hard limit, the processor enters a "refusing" state: it forces garbage collection and rejects incoming data (returning errors upstream) to bring memory back down. At/above the hard limit (`limit_mib`) it hard-refuses all data. The spike headroom exists because memory can jump between 1s check intervals; refusing *before* the hard ceiling leaves room to absorb that spike without an OOM kill.

**A5.3** The chain: `memory_limiter` refuses the batch → the OTLP receiver translates that into a retryable response (gRPC `UNAVAILABLE` / HTTP `503`) → the client's exporter sees a retryable error → it keeps the data in its own queue and retries with backoff later. It is better than silently dropping because the data is preserved at the source and delivered once pressure clears, and the failure is visible/observable rather than lost — backpressure is a signal, a silent drop is data loss.

**A5.4** A **persistent sending queue** on the clients (and/or an intermediary Collector) absorbs the refused data on disk instead of bouncing it, and **finite retry with exponential backoff + jitter** spreads the retries out so thousands of clients don't resend in lockstep. Together they turn "refuse and retry immediately" into "buffer durably and retry gradually," preventing the retry storm.

### Exercise 6

**A6.1** `record_exception()` attaches an **event** named `exception` to the span, capturing type/message/stacktrace — it is diagnostic detail about *what* went wrong. `set_status(ERROR)` marks the **span's outcome** as failed, which is what error-rate metrics, sampling decisions, and red/error highlighting key off. You usually need both: the event gives a human the stack trace; the status makes the failure count in aggregates. Recording an exception does **not** automatically set the status.

**A6.2** The convention is that spans are successful unless proven otherwise, so leaving a healthy span `UNSET` is the norm and backends interpret `UNSET` as "not an error." `OK` is reserved for cases where an application *explicitly* wants to override any inference and assert success (e.g. a 4xx that is expected/handled and should not count as an error). Routinely setting `OK` adds no information and can prevent a backend or later instrumentation from correctly flagging a failure.

**A6.3** The `exception` event carries `exception.type`, `exception.message`, `exception.stacktrace`, and optionally `exception.escaped` (whether the exception propagated out of the span's scope). Using these exact semantic-convention keys means any conforming backend can group by exception type, render the stack trace, and build error dashboards without per-language or per-app custom parsing — interoperability is the whole point of semantic conventions.

**A6.4** An application error recorded on a span (status `ERROR` + `exception` event) is telemetry describing that *the observed workload* failed and is *content* to be delivered; a pipeline export error handled by `exporterhelper` is a failure of *delivering telemetry itself*, handled by retry/queue/backpressure — the payload versus the transport of that payload.

</details>