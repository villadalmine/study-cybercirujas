# 3.1 Configuration — The OpenTelemetry Collector

> **Domain 3: The OpenTelemetry Collector · Exam weight ≈ 5.2%**
> Level: Principal Platform / SRE. Assumes you already know what a signal (trace, metric, log), the OTLP protocol, and a pipeline are.

---

## 1. Motivation: the configuration *is* the Collector

The Collector ships as a single static binary with **zero built-in behavior**. It has no default receivers listening, no default destination, no opinion about your topology. Every byte of what it does — what it ingests, how it transforms, where it writes, how much memory it defends, what it exposes for debugging — is declared in one YAML document. There is no imperative API and no admin console. **The configuration file is the entire runtime contract.**

This is a deliberate architectural decision and it creates the central production problem of this domain:

- **Fan-in / fan-out.** In a gateway topology one Collector deployment receives OTLP from hundreds of instrumented services and multiplexes it to N backends (Tempo, Prometheus-compatible TSDB, a vendor, an object store). That entire wiring — which source feeds which sink, with which transforms — lives in the `service::pipelines` block. A pipeline you *declared* but did not *wire* silently does nothing.
- **Backpressure and self-protection.** A Collector under a traffic spike with no `memory_limiter` will OOM and take the whole ingest tier down. Self-protection is not a flag; it is a processor you must place, in the right order, in every pipeline.
- **Config drift and multi-tenancy.** The same binary runs as a per-node **agent** (DaemonSet) and as a central **gateway** (Deployment). They are the same image with different config. Getting the two configs to disagree in the wrong way (agent batches, gateway also batches with a smaller window; agent has `memory_limiter`, gateway forgot it) is the most common production incident in this space.
- **Secrets and reproducibility.** Endpoints, tokens and TLS material cannot be hard-coded into an image you ship to every node. Configuration must be *composed at start* from a base file plus environment substitution plus overlays — and it must validate before it ever binds a port.

The exam and this material treat "Configuration" as: **the file schema, the six component classes, how pipelines wire them, how configs are delivered and merged, and how you prove a config is correct before and after it runs.**

---

## 2. Anatomy of a Collector configuration

A Collector config has exactly **six top-level keys**. Five *declare* components; the sixth (`service`) *activates and wires* them.

| Top-level key | Role | Activated by | Notes |
|---|---|---|---|
| `receivers` | Pull or accept telemetry in | Referenced in a pipeline | e.g. `otlp`, `prometheus`, `filelog`, `kubeletstats` |
| `processors` | Transform / batch / drop / protect | Referenced in a pipeline | **Order is significant** (see §2.2) |
| `exporters` | Emit telemetry out | Referenced in a pipeline | e.g. `otlp`, `otlphttp`, `debug`, `prometheusremotewrite` |
| `connectors` | Act as **exporter of one pipeline and receiver of another** | Referenced on both ends | e.g. `spanmetrics`, `forward`, `count`, `routing` |
| `extensions` | Cross-cutting capabilities, **not in any pipeline** | Listed in `service::extensions` | e.g. `health_check`, `pprof`, `zpages`, auth |
| `service` | Turns declarations into a running graph | — | Contains `extensions`, `pipelines`, `telemetry` |

### 2.1 The single most important rule of Collector config

> **Declaring a component does nothing. A component only runs if it is referenced under `service`.** A receiver not named in a pipeline never binds a port. An exporter not named in a pipeline never opens a connection. An extension not listed in `service::extensions` is inert dead config.

This is the #1 source of "my config is right but nothing happens" tickets. Validation *passes* on unused components — they are legal, just idle.

### 2.2 Component identity: `type` and `type/name`

Every component instance is keyed by its **type**, optionally suffixed with `/name` to create multiple instances of the same type:

```yaml
exporters:
  otlp:                 # instance id = "otlp"
    endpoint: tempo:4317
  otlp/metrics:         # instance id = "otlp/metrics" — a DIFFERENT instance
    endpoint: mimir:4317
```

`otlp` and `otlp/metrics` are two independent exporters. Pipelines reference them by their full id.

### 2.3 Pipelines: the wiring, and why processor order matters

A pipeline has a **signal type** (`traces`, `metrics`, or `logs`, optionally `/name`) and three ordered stages:

```yaml
service:
  pipelines:
    traces:
      receivers:  [otlp]                 # SET — order irrelevant, fan-in
      processors: [memory_limiter, batch] # LIST — order is the data flow order
      exporters:  [otlp, debug]           # SET — order irrelevant, fan-out
```

- **Receivers and exporters are sets**: multiple receivers fan-in, multiple exporters fan-out; order has no meaning.
- **Processors are an ordered list**: telemetry flows left-to-right, each processor sees the output of the previous one. The canonical ordering rule:

| Position | Processor | Why it goes there |
|---|---|---|
| **First** | `memory_limiter` | Must reject/back-pressure *before* any expensive work is done, so it protects the whole chain |
| Early | `k8sattributes`, `resourcedetection` | Enrich before you sample/filter on those attributes |
| Middle | `filter`, `transform`, `attributes`, tail sampling | Business logic operates on enriched data |
| **Last (before exporters)** | `batch` | Batch *after* all drops, so you never batch data you're about to discard |

Putting `batch` before `memory_limiter` defeats self-protection; putting `memory_limiter` last means the pipeline already allocated the buffers you were trying to bound.

### 2.4 A connector is an exporter *and* a receiver

Connectors bridge two pipelines. `spanmetrics`, for example, consumes spans and produces metrics:

```yaml
connectors:
  spanmetrics: {}

service:
  pipelines:
    traces:
      receivers:  [otlp]
      exporters:  [spanmetrics, otlp]   # spanmetrics acts as an EXPORTER here
    metrics/spanmetrics:
      receivers:  [spanmetrics]         # ...and as a RECEIVER here
      exporters:  [prometheusremotewrite]
```

The same instance id appears once as an exporter and once as a receiver. That is what makes it a connector rather than a processor.

---

## 3. Configuration delivery and composition

Config is loaded through **confmap providers**, addressed by a URI scheme. `--config` may be given multiple times; the maps are **deep-merged left-to-right, later wins**.

| Provider scheme | Source | Typical use | Trade-off |
|---|---|---|---|
| `file:` (default) | Local file | Base config in image/ConfigMap | Immutable per-pod; needs restart on change |
| `env:` | Environment variable holding **whole YAML** | Inject full config from a secret | Whole doc in one var; hard to diff |
| `yaml:` | Inline YAML literal on the CLI | Small overrides, tests | Great for `validate`; unwieldy for prod |
| `http:` / `https:` | Remote URL | Centralized config service | Adds a startup network dependency (fail-fast) |
| `s3:`, `gcs:`, etc. (contrib) | Object storage | Fleet config distribution | Requires cloud creds at boot |

Within any loaded YAML, **value substitution** uses the `env` provider inline:

```yaml
exporters:
  otlp:
    endpoint: ${env:BACKEND_ENDPOINT}          # required — fails if unset
    headers:
      authorization: "Bearer ${env:OTLP_TOKEN}"
  otlphttp:
    endpoint: ${env:OTLP_HTTP_ENDPOINT:-http://localhost:4318}  # default if unset
```

- `${env:VAR}` — substitute; **hard error at startup if `VAR` is unset** (a safety feature, not a bug).
- `${env:VAR:-default}` — use `default` when `VAR` is empty/unset.
- `$$` — a literal `$` (escape), needed for e.g. Prometheus relabel `$1` capture groups, which must be written `$$1`.

### 3.1 Merge semantics you must know

Given base + overlay:

```yaml
# base.yaml
exporters:
  otlp:
    endpoint: tempo:4317
    tls:
      insecure: true
```
```yaml
# overlay-prod.yaml
exporters:
  otlp:
    tls:
      insecure: false
      ca_file: /etc/otel/ca.pem
```

`otelcol --config base.yaml --config overlay-prod.yaml` yields `endpoint: tempo:4317` (kept) with `tls: {insecure: false, ca_file: /etc/otel/ca.pem}`. **Maps merge key-by-key; scalars and lists are *replaced wholesale*, not appended.** This last point traps everyone: an overlay `processors: [batch]` does **not** append to the base's `processors` list — it replaces it entirely.

---

## 4. Complete, production-grade manifests

### 4.1 A full gateway Collector config (nothing trimmed)

```yaml
# otelcol-gateway.yaml — central gateway: OTLP in, fan-out to traces+metrics backends
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317        # gateway must listen on all interfaces
        max_recv_msg_size_mib: 16
      http:
        endpoint: 0.0.0.0:4318

processors:
  # 1) SELF-PROTECTION FIRST — bounds heap before any allocation-heavy work
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80              # soft-limit at 80% of the cgroup limit
    spike_limit_percentage: 25        # hard drop headroom for bursts

  # 2) Enrichment / normalization
  resourcedetection:
    detectors: [env, system]
    timeout: 5s
    override: false

  # 3) BATCH LAST — never batch data you might still drop
  batch:
    timeout: 5s
    send_batch_size: 8192
    send_batch_max_size: 16384

exporters:
  otlp/traces:
    endpoint: ${env:TEMPO_ENDPOINT}
    tls:
      insecure: false
      ca_file: /etc/otel/certs/ca.pem
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s

  prometheusremotewrite:
    endpoint: ${env:MIMIR_ENDPOINT}
    headers:
      X-Scope-OrgID: ${env:TENANT_ID}
    resource_to_telemetry_conversion:
      enabled: true

  debug:
    verbosity: normal                 # replaces the removed "logging" exporter

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  pprof:
    endpoint: 0.0.0.0:1777
  zpages:
    endpoint: 0.0.0.0:55679

service:
  extensions: [health_check, pprof, zpages]   # extensions are ONLY active if listed here
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters:  [otlp/traces, debug]
    metrics:
      receivers:  [otlp]
      processors: [memory_limiter, batch]
      exporters:  [prometheusremotewrite]
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
                port: 8888          # internal self-metrics scrape target
```

### 4.2 Kubernetes: ConfigMap + Deployment (gateway), secrets via env

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otelcol-gateway
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      batch:
        timeout: 5s
        send_batch_size: 8192
    exporters:
      otlp/traces:
        endpoint: ${env:TEMPO_ENDPOINT}
        tls: { insecure: false, ca_file: /etc/otel/certs/ca.pem }
    extensions:
      health_check: { endpoint: 0.0.0.0:13133 }
    service:
      extensions: [health_check]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/traces]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otelcol-gateway
  namespace: observability
spec:
  replicas: 3
  selector: { matchLabels: { app: otelcol-gateway } }
  template:
    metadata:
      labels: { app: otelcol-gateway }
    spec:
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.116.0
          args: ["--config=/etc/otel/config.yaml"]
          env:
            - name: TEMPO_ENDPOINT
              value: "tempo.observability.svc:4317"
            - name: GOMEMLIMIT              # let Go GC cooperate with memory_limiter
              value: "1600MiB"
          resources:
            requests: { cpu: "500m", memory: "1Gi" }
            limits:   { cpu: "2",    memory: "2Gi" }   # memory_limiter reads THIS via percentage
          ports:
            - { containerPort: 4317, name: otlp-grpc }
            - { containerPort: 4318, name: otlp-http }
            - { containerPort: 13133, name: health }
          livenessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 5
          readinessProbe:
            httpGet: { path: /, port: 13133 }
          volumeMounts:
            - { name: cfg, mountPath: /etc/otel }
      volumes:
        - name: cfg
          configMap: { name: otelcol-gateway }
```

> **Production note:** `limit_percentage` is a percentage of the **cgroup memory limit** the Collector reads at runtime — set `resources.limits.memory` and `GOMEMLIMIT` deliberately, or the percentage is computed against the wrong number.

### 4.3 The Operator way: `OpenTelemetryCollector` CRD (typed config)

When the [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator) is installed, you declare the *same* config inside a `v1beta1` CRD and the Operator renders the Deployment/DaemonSet, Service, ConfigMap and RBAC for you:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: gateway
  namespace: observability
spec:
  mode: deployment          # deployment | daemonset | statefulset | sidecar
  replicas: 3
  image: otel/opentelemetry-collector-contrib:0.116.0
  resources:
    limits: { cpu: "2", memory: 2Gi }
  config:                   # structured, schema-validated by the Operator's webhook
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      batch: {}
    exporters:
      debug: { verbosity: basic }
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
```

`mode: daemonset` reuses the identical schema to produce the per-node **agent**; `mode: sidecar` injects a Collector container into annotated pods. One schema, four topologies — the config *is* the deployment.

---

## 5. CLI commands and expected terminal output

### 5.1 Validate before you ever bind a port — `validate` is free and offline

```console
$ otelcol-contrib validate --config=otelcol-gateway.yaml
$ echo $?
0
```

Silence + exit `0` = the config parsed, every referenced component exists, and every component's own config unmarshalled. A malformed config fails loudly and **never starts a listener**:

```console
$ otelcol-contrib validate --config=broken.yaml
Error: invalid configuration: service::pipelines::traces: references exporter "otlp/traces" which is not configured
$ echo $?
1
```

```console
$ otelcol-contrib validate --config=broken2.yaml
Error: invalid configuration: exporters::otlp/traces: endpoint must be specified
```

```console
$ otelcol-contrib validate --config=broken3.yaml
Error: failed to get config: cannot resolve the configuration: environment variable "TEMPO_ENDPOINT" is not set
```

That last one is the point of `${env:...}` with no default — a missing secret is a **startup failure**, not a Collector that silently drops your data.

### 5.2 Discover what a build actually contains — `components`

Which receivers/processors/exporters exist depends on the distribution (`otelcol` core vs `otelcol-contrib` vs a custom OCB build). Never guess; ask the binary:

```console
$ otelcol-contrib components | head -n 20
buildinfo:
    command: otelcol-contrib
    description: OpenTelemetry Collector Contrib
    version: 0.116.0
receivers:
    - name: otlp
      stability:
        logs: beta
        metrics: stable
        traces: stable
    - name: filelog
    - name: kubeletstats
    - name: prometheus
processors:
    - name: batch
    - name: memory_limiter
    - name: k8sattributes
    - name: transform
exporters:
    - name: otlp
    - name: debug
    - name: prometheusremotewrite
```

If `components` doesn't list `spanmetrics`, no config will make it work — you need a different build.

### 5.3 Run with layered config and observe the merge

```console
$ otelcol-contrib --config=base.yaml \
    --config=overlay-prod.yaml \
    --config='yaml:service::telemetry::logs::level: debug'
2026-08-10T14:22:01.114Z  info  service@v0.116.0/service.go:164  Setting up own telemetry...
2026-08-10T14:22:01.116Z  info  memorylimiter/memorylimiter.go  Using percentage memory limiter  {"total_memory_mib": 2048, "limit_percentage": 80, "spike_limit_percentage": 25}
2026-08-10T14:22:01.121Z  info  service@v0.116.0/service.go  Starting otelcol-contrib...  {"Version": "0.116.0", "NumCPU": 4}
2026-08-10T14:22:01.122Z  info  extensions/extensions.go  Extension is starting...  {"kind": "extension", "name": "health_check"}
2026-08-10T14:22:01.123Z  info  otlpreceiver@v0.116.0  Starting GRPC server  {"endpoint": "0.0.0.0:4317"}
2026-08-10T14:22:01.123Z  info  otlpreceiver@v0.116.0  Starting HTTP server  {"endpoint": "0.0.0.0:4318"}
2026-08-10T14:22:01.124Z  info  service@v0.116.0/service.go  Everything is ready. Begin running and processing data.
```

The three `--config` flags are deep-merged; the inline `yaml:` override wins and flips log level to `debug`.

### 5.4 Toggle behavior with feature gates

```console
$ otelcol-contrib --config=otelcol-gateway.yaml \
    --feature-gates=+component.UseLocalHostAsDefaultHost,-some.other.gate
```

`+gate` enables, `-gate` disables. Feature gates are how the project rolls out breaking defaults (e.g. defaulting OTLP receiver endpoints to `localhost` instead of `0.0.0.0`) — read the log line at startup that reports which gates are active.

---

## 6. Verification and failure diagnosis

You verify a Collector at three altitudes: **config-time** (offline), **startup** (does it bind and report ready), and **runtime** (is data actually flowing and is it self-healthy).

### 6.1 The diagnostic surfaces you configure on purpose

| Extension / surface | Default endpoint | What it answers |
|---|---|---|
| `health_check` | `:13133/` | Is the Collector up and its pipelines started? (probe target) |
| **Internal metrics** (`service::telemetry::metrics`) | `:8888/metrics` | Accepted vs refused vs dropped counts, queue size, exporter failures |
| `zpages` | `:55679/debug/pipelinez` | Live per-pipeline processor/exporter view, in-flight spans |
| `pprof` | `:1777/debug/pprof/` | CPU/heap profiles when the Collector itself is the bottleneck |

### 6.2 Read the internal telemetry — this is where you find data loss

The self-metrics on `:8888` are the flight recorder. The key series:

```console
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|processor|exporter)_' | head
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 148213
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 0
otelcol_processor_dropped_spans{processor="memory_limiter"} 512
otelcol_exporter_sent_spans{exporter="otlp/traces"} 147701
otelcol_exporter_send_failed_spans{exporter="otlp/traces"} 0
otelcol_exporter_queue_size{exporter="otlp/traces"} 128
otelcol_exporter_queue_capacity{exporter="otlp/traces"} 5000
```

Reading it:
- `receiver_refused_*` > 0 → you are rejecting at ingest (auth, message size, or the receiver's own limit).
- `processor_dropped_spans{processor="memory_limiter"}` > 0 → **you are under memory pressure and shedding load**; raise limits/replicas or add backpressure upstream.
- `exporter_send_failed_*` climbing → backend is unreachable or rejecting; check `retry_on_failure` and the backend.
- `exporter_queue_size` approaching `exporter_queue_capacity` → the sink can't keep up; the queue is your last buffer before drops.

### 6.3 A field diagnosis playbook

**Symptom: config validates but no telemetry arrives at the backend.**
1. `curl -s localhost:8888/metrics | grep receiver_accepted` — is the receiver even seeing data? If `0`, the problem is upstream (client endpoint/TLS), not the Collector.
2. If accepted > 0 but `exporter_sent` is `0`, the pipeline probably doesn't reference that exporter. Re-read `service::pipelines` — **an exporter declared but not wired never sends.**
3. Add the `debug` exporter to the pipeline temporarily (`verbosity: detailed`) and watch spans print to stdout — this proves data reached the exporter stage.

**Symptom: Collector OOMKilled under load.**
1. Confirm `memory_limiter` is **first** in every pipeline's processor list.
2. Confirm `resources.limits.memory` is set and `GOMEMLIMIT` is aligned (~80% of the limit).
3. Watch `otelcol_processor_dropped_spans{processor="memory_limiter"}` — nonzero means it's working (shedding rather than crashing).

**Symptom: `references exporter "X" which is not configured`.**
A pipeline names a component id that has no declaration (typo, or the `/name` suffix mismatched). Ids are exact strings: `otlp/traces` ≠ `otlp`.

**Symptom: `environment variable "X" is not set`.**
A `${env:X}` with no `:-default` and no exported value. Fix the env, or give it a default if it's genuinely optional.

**Symptom: relabel/regex config rejected or mangled.**
A literal `$` inside embedded config (Prometheus `$1`, transform expressions) was consumed by confmap substitution. Escape it as `$$`.

### 6.4 Live pipeline inspection with zpages

```console
$ curl -s localhost:55679/debug/pipelinez
Pipeline: traces
  Receivers:  otlp
  Processors: memory_limiter -> resourcedetection -> batch
  Exporters:  otlp/traces, debug
  Spans received (last minute): 148213
  Spans exported (last minute): 147701
```

`pipelinez` shows the *actual assembled graph* the running process built from your merged config — the definitive answer to "is my config wired the way I think it is." When the file and the reality disagree, this page is where you see it.

---

## 7. References

- OpenTelemetry Collector — Configuration: https://opentelemetry.io/docs/collector/configuration/
- Configuration providers & environment variable substitution: https://opentelemetry.io/docs/collector/configuration/#environment-variables
- Data collection & pipeline concepts: https://opentelemetry.io/docs/collector/architecture/
- Connectors: https://opentelemetry.io/docs/collector/building/connector/
- Internal telemetry (`service::telemetry`, self-metrics): https://opentelemetry.io/docs/collector/internal-telemetry/
- `memory_limiter` processor: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
- `batch` processor: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md
- OTLP receiver: https://github.com/open-telemetry/opentelemetry-collector/blob/main/receiver/otlpreceiver/README.md
- `debug` exporter: https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/debugexporter/README.md
- Extensions (`health_check`, `pprof`, `zpages`): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension
- Feature gates: https://github.com/open-telemetry/opentelemetry-collector/blob/main/featuregate/README.md
- OpenTelemetry Operator — `OpenTelemetryCollector` CRD: https://github.com/open-telemetry/opentelemetry-operator
- OTCA certification & curriculum (CNCF/Linux Foundation): https://training.linuxfoundation.org/certification/opentelemetry-certified-associate-otca/
- OTCA curriculum repository: https://github.com/cncf/curriculum