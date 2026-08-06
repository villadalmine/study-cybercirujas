# 2.1 Observability Fundamentals: Traces, Metrics, Logs, and Events

> **CNPA — Cloud Native Platform Engineering Associate (exam version 2025-04-01)**
> Domain weight: 4.0 · Level: production / platform architecture

---

## 1. The architectural problem: why observability is a platform concern, not an application concern

### 1.1 The failure of the monolithic mental model

In a monolith, a request lives inside one process, one address space, one log file, one stack trace. When something breaks, the stack trace *is* the causal chain. Debugging is an act of reading.

A cloud native platform destroys every one of those assumptions:

| Monolith assumption | Cloud native reality |
|---|---|
| One process handles the request end-to-end | 8–40 processes across pods, nodes, and availability zones |
| The stack trace shows causality | Causality crosses network boundaries; no runtime carries it for you |
| The host is stable and nameable | Pods are ephemeral (median lifetime measured in hours), IPs are recycled, nodes are cattle |
| Logs live on disk until you rotate them | The container filesystem disappears with the pod; a `CrashLoopBackOff` erases its own evidence |
| One deploy = one version in production | Canary, blue/green, and progressive rollouts mean 2–3 versions serve traffic simultaneously |
| Errors are exceptions | Errors are *partial*: 0.4% of requests fail, only for one shard, only on one node's kernel version |

The concrete production consequence: **the interesting failures in a distributed system are ones nobody predicted**, so nobody built a dashboard for them. A dashboard answers a question you already knew to ask. A platform must let an engineer ask a question they invented ninety seconds ago, at 03:14, under load, without deploying code.

That capability is what "observability" means. The formal definition is borrowed from control theory (Kálmán, 1960): **a system is observable if its internal state can be inferred from its external outputs.** In platform terms: the telemetry a workload emits must be rich enough to reconstruct what it was doing, without attaching a debugger or shipping a new build.

### 1.2 Monitoring vs. observability — a real distinction, not marketing

| Axis | Monitoring | Observability |
|---|---|---|
| Question shape | "Is X within threshold?" | "Why is X out of threshold *for this subset*?" |
| Question timing | Defined **before** the incident | Invented **during** the incident |
| Failure class | Known-unknowns (disk fills, pod restarts) | Unknown-unknowns (p99 latency only for `tenant=acme` on `zone=us-east-1c` after the 14:02 rollout) |
| Data shape | Pre-aggregated, low cardinality | High cardinality, high dimensionality, per-event |
| Cost driver | Number of timeseries | Volume × retention × cardinality |
| Typical artifact | Alert rule, dashboard | Ad-hoc query, trace waterfall, exemplar drill-down |
| Outcome | Detection | Diagnosis |

Both are required. Monitoring pages you; observability tells you what to do about the page. A platform that ships only one of them either wakes people up with no path to resolution, or has a beautiful query engine nobody looks at because nothing ever alerts.

### 1.3 The platform-engineering framing

The reason observability lands in a *platform engineering* curriculum rather than an application one is the **N × M problem**:

- N application teams, each with its own language, framework, and opinion about logging.
- M telemetry backends (Prometheus, Loki, Tempo, Jaeger, an APM SaaS, a SIEM, a data lake).

If every team wires itself to every backend, you get N × M integrations, N × M credential rotations, and N × M migrations the day you change vendors. The platform's job is to collapse that into **N → 1 → M**: applications emit one vendor-neutral protocol (OTLP) to one platform-owned pipeline (the OpenTelemetry Collector), and the platform fans out to backends. Application teams never learn a backend's name. Changing vendors becomes a Collector config change, not 40 pull requests.

This is the same "golden path" logic as a paved CI template or a Backstage software template, applied to telemetry. Concretely, the platform owns:

1. **A wire protocol contract** — OTLP over gRPC (`:4317`) or HTTP/protobuf (`:4318`), plus Prometheus scraping for pull-based metrics.
2. **A semantic contract** — OpenTelemetry Semantic Conventions: `service.name`, `service.version`, `deployment.environment.name`, `http.request.method`, `k8s.pod.name`. Without an enforced naming contract, correlation is impossible: one team's `svc` is another's `service` is another's `app`.
3. **Enrichment nobody should hand-roll** — Kubernetes metadata, node identity, cloud region, trace/log correlation IDs.
4. **The economics** — sampling, filtering, aggregation, retention tiers, and the cardinality budget.
5. **A default SLO/alerting library** — burn-rate alerts that work out of the box for any HTTP service.

### 1.4 "Three pillars" is a useful lie

The classic framing is metrics + logs + traces as three pillars. It is pedagogically useful and architecturally misleading, because it encourages **three silos with three storage systems, three query languages, and no join key**. The failure mode is familiar: you see a latency spike in Grafana, you switch tabs to Loki, you eyeball timestamps, you guess.

The modern framing is: **there is one stream of events, and metrics/logs/traces are three projections of it, joined by shared context.** The join keys are:

- `trace_id` / `span_id` — put into log records by the SDK, and into metric **exemplars** by the instrumentation.
- **Resource attributes** — the identity of the emitting entity (`service.name`, `k8s.pod.uid`), attached identically to all three signals.
- **W3C Trace Context** — the `traceparent`/`tracestate` HTTP headers that carry the trace across process boundaries.

If those keys are present and consistent, the pillars are just indexes over the same reality, and an engineer can go latency-graph → exemplar → trace → span → the exact log lines of that span in three clicks. If they are absent, you own three expensive databases and a tab-switching ritual.

CNCF/OpenTelemetry now recognizes a fourth stable-ish signal, **continuous profiling** (which pod burned which CPU cycles, at function granularity), and Kubernetes contributes a fifth that is unique to the orchestrator: **Events**.

---

## 2. The signals: technical comparison and trade-offs

### 2.1 Signal-by-signal characterization

| Property | **Metrics** | **Logs** | **Traces** | **K8s Events** | **Profiles** |
|---|---|---|---|---|---|
| Unit of data | Numeric sample `(name, labels, value, ts)` | Timestamped record + attributes | Tree of spans sharing a `trace_id` | API object describing a state change | Stack-trace samples w/ weights |
| Aggregation | Pre-aggregated at write | Raw, aggregated at read | Raw per-request, sampled | Raw, coalesced by `count`/`series` | Aggregated over a window |
| Cardinality tolerance | **Very low** — cost is `O(unique label combos)` | High | High | Low (bounded by object count) | Medium |
| Cost per unit | Cheapest per query | Most expensive at volume | Expensive; mitigated by sampling | Negligible | Medium |
| Typical retention | 13 months (downsampled) | 7–30 days | 3–14 days | **1 hour in etcd** (must be exported) | 7–30 days |
| Query latency | Milliseconds | Seconds | Seconds | Milliseconds | Seconds |
| Answers | "Is it broken? How much? Trending?" | "What exactly happened in this process?" | "Where did the time go, across services?" | "What did the control plane decide?" | "Which code path burns CPU/RAM?" |
| Cannot answer | "Which user?" (cardinality) | "What is the p99 across the fleet?" (cost) | Anything not sampled | Anything about application internals | Request-level attribution |
| Push/pull | Pull (Prometheus) or push (OTLP) | Push | Push | Watch (API server) | Push/pull |
| Alerting suitability | **Primary** | Secondary (log-derived metrics) | Poor (sampled) | Good for infra causes | Not for alerting |

### 2.2 The cardinality economics — the single most important number in your budget

A Prometheus timeseries is uniquely identified by its metric name plus the full set of label key/value pairs. Cardinality is **multiplicative**:

```
series = metric_names × ∏(distinct values per label)
```

Worked example. A modest HTTP histogram:

```
http_server_request_duration_seconds_bucket{
  service, method, route, status_code, le
}
```

| Label | Distinct values | Running product |
|---|---:|---:|
| `service` | 40 | 40 |
| `method` | 5 | 200 |
| `route` | 25 | 5 000 |
| `status_code` | 8 | 40 000 |
| `le` (histogram buckets) | 12 + `_sum` + `_count` | ~560 000 |

560 000 series. At a conservative **~3 KiB of process memory per active series** (head chunks + inverted index + label pool), that is ~1.6 GiB of Prometheus RSS for a single metric family. Survivable.

Now a developer adds `user_id` "for debugging". With 50 000 monthly active users:

```
560 000 × 50 000 = 28 000 000 000 series
```

28 billion. Prometheus OOMs, the ingestion path back-pressures, and — this is the part people miss — **it stays broken after you revert the code**, because the churned series remain in the head block until the retention window rolls over and are replayed from the WAL on every restart.

**The rules that follow from this arithmetic:**

1. Metric labels must be drawn from a **bounded, enumerable set** known at design time. `route` is bounded (`/users/{id}`, not `/users/8f3a…`). `status_code` is bounded. `user_id`, `request_id`, `pod_ip`, `trace_id`, `session_id`, `email` are unbounded — **never** metric labels.
2. Unbounded dimensions belong on **logs and spans**, where cost is `O(volume)` and not `O(unique combinations)`.
3. The bridge between them is the **exemplar**: a metric sample may carry a pointer to one representative `trace_id`. You keep the cheap aggregate *and* one click to a concrete high-cardinality example. This is the correct answer to "but I need per-user latency."

### 2.3 Push vs. pull

| | **Pull (Prometheus scrape)** | **Push (OTLP / remote-write)** |
|---|---|---|
| Discovery | Server-side via Kubernetes SD; targets are discovered, not configured | Client-side; app must know an endpoint |
| Liveness signal | `up{}` is free and authoritative | Absence is ambiguous (crashed? misconfigured? network?) |
| Short-lived jobs | **Poor** — job may die between scrapes; needs Pushgateway | **Native fit** |
| Firewall/NAT direction | Requires inbound reachability to every pod | Outbound only — works across VPC/tenant boundaries |
| Back-pressure | Natural: server controls rate | Requires queues, retries, and drop policy in the client |
| Multi-tenancy | Server needs network path into tenant namespaces | Tenant pushes to a gateway; clean isolation |
| Cardinality control | Enforceable at scrape time via `metric_relabel_configs` | Enforceable at the Collector |
| Temporality | Cumulative by construction | Cumulative **or** delta — must be converted for Prometheus |

**Production stance:** pull for infrastructure and long-lived services (you get `up{}` and SD for free), push for batch jobs, serverless, mobile/edge clients, and any cross-boundary traffic. The Collector runs both: `prometheus` receiver on one side, `otlp` receiver on the other, unified pipeline downstream.

**Temporality trap:** OTel metrics default to *cumulative* for counters in most SDKs but several exporters and languages default to *delta*. Prometheus stores cumulative only. If you push delta sums into a `prometheusremotewrite` exporter without `cumulativetodelta`/`deltatocumulative` handling, `rate()` returns nonsense — usually flat zeros or sawtooth spikes. Set `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative` for Prometheus-backed platforms and make it a platform default, not a per-team decision.

### 2.4 Sampling strategies for traces

100% trace retention at scale is unaffordable and mostly worthless: 99.9% of traces are healthy and identical. The question is *which* traces to keep.

| Strategy | Decision point | Keeps the interesting traces? | Cost predictability | Operational complexity |
|---|---|---|---|---|
| **Head-based, probabilistic** (`parentbased_traceidratio`, e.g. 1%) | At the root span, before the request runs | **No** — a slow/failing trace is kept only by luck | Excellent (linear in traffic) | Trivial; SDK env var |
| **Head-based, rate-limiting** | Root span, token bucket | No | Excellent (hard ceiling) | Low |
| **Tail-based** (Collector `tail_sampling`) | After the whole trace is assembled | **Yes** — policy on latency, error status, attributes | Moderate (depends on error rate) | **High** — see below |
| **Remote/adaptive sampling** | Root span, ratio pushed from a control plane | Partially | Good | Medium |
| **Always-on + aggressive retention tiering** | Never sample; drop old data fast | Yes | Poor at scale | Medium |

**Why tail-based sampling is architecturally hard:** the decision requires every span of a trace to be in the *same* Collector process at the *same* time. In a horizontally scaled gateway behind a normal Service, spans of one trace land on random replicas, so every replica sees a fragment and the policy evaluates against incomplete data — silently. The fix is a two-tier topology: agents export via the **`loadbalancing` exporter with `routing_key: traceID`**, which hashes the trace ID and pins all spans of a trace to one gateway replica. Then, and only then, `tail_sampling` is correct.

Second cost: the gateway must **buffer every span for `decision_wait`** (typically 10–30 s) before deciding. Memory ≈ `spans_per_second × avg_span_bytes × decision_wait`. At 50 000 spans/s, 400 B/span, 15 s → ~300 MB steady-state buffer per replica, before Go GC headroom. Size the gateway accordingly and set `num_traces` explicitly.

### 2.5 Collector deployment topologies

| Topology | Placement | Strengths | Weaknesses | Use when |
|---|---|---|---|---|
| **No collector** (SDK → backend) | — | Fewest moving parts | N×M coupling; no enrichment; credentials in every app; no buffering | Prototypes only |
| **Sidecar** | One container per pod | Strong tenant isolation; localhost transport; per-workload config | Resource cost × pod count; N× config surface | Regulated multi-tenant; per-tenant credentials |
| **Agent (DaemonSet)** | One per node | Collects node-local files, kubelet stats, host metrics; `k8sattributes` works via node filter; low network hop | Node-scoped blast radius; cannot do tail sampling | **Always** — this is the baseline |
| **Gateway (Deployment)** | Central, scaled | Tail sampling, cross-cutting aggregation, egress credential boundary, backend fan-out, rate limiting | Extra hop; needs HPA + PDB | **Always at scale**, paired with agents |

**The reference production topology is agent + gateway.** Agents own *node-local reality* (files, kubelet, host metrics, pod metadata). Gateways own *global reality* (sampling decisions, egress, tenancy, backend credentials).

### 2.6 Log collection: how the bytes actually get out

| Approach | Mechanism | Pros | Cons |
|---|---|---|---|
| **stdout/stderr → node agent** (12-factor) | Container runtime writes `/var/log/pods/<ns>_<pod>_<uid>/<container>/N.log`; agent tails it | Standard, language-agnostic, survives app crash, kubelet handles rotation | Subject to CRI 16 KiB line splitting; rotation can lose data under extreme throughput |
| **Sidecar tailing a shared `emptyDir`** | App writes files; sidecar tails | Handles apps that insist on files; per-pod parsing | 2× resources; `emptyDir` fills the node disk; log lost if pod dies before flush |
| **App → OTLP directly** (`otlp` log exporter) | SDK pushes log records | Structured natively, `trace_id` correlation built-in, no parsing | Lost if the process dies before flush; couples app to endpoint |
| **App → backend SDK** (e.g. direct to a SaaS) | Vendor library | Simple day 1 | Vendor lock-in, credentials in app, no platform control |

**The CRI format you must know:**

```
2026-08-06T14:22:31.884211947Z stdout F {"level":"error","msg":"upstream timeout"}
└──────── RFC3339Nano ────────┘ └str─┘ │ └──────────── payload ────────────────┘
                                       └── F = full line, P = partial (continues)
```

The runtime reads container output in a **16 KiB buffer**. Any log line longer than that is emitted as multiple records tagged `P`, with the final fragment tagged `F`. A collector that does not reassemble `P` fragments will hand your JSON parser truncated documents, and you will see a steady trickle of "invalid JSON" for exactly your most interesting (largest) log lines — usually stack traces and request dumps. The OTel `filelog` receiver's `type: container` operator handles this; hand-rolled regex parsers usually do not.

Rotation is kubelet's job: `--container-log-max-size` (default `10Mi`) and `--container-log-max-files` (default `5`), i.e. ~50 MiB per container on disk. A container emitting 20 MB/s of debug logging will rotate through its entire history in under three seconds; if your agent is behind by more than that, the data is gone forever. This is why log volume is a platform quota, not a team preference.

### 2.7 Kubernetes Events — the signal people forget

A Kubernetes `Event` is a first-class API object recording a state transition observed by a controller: `Scheduled`, `Pulling`, `Failed`, `Killing`, `BackOff`, `FailedScheduling`, `Unhealthy`, `Preempted`, `NodeNotReady`, `SuccessfulRescale`.

They are the **causal narrative of the control plane**, and they answer questions no application signal can:

- Why did latency jump at 14:02? → `SuccessfulRescale` on the HPA, then 4× `FailedScheduling: 0/12 nodes are available: insufficient cpu`.
- Why is this pod restarting? → `Unhealthy: Liveness probe failed: HTTP probe failed with statuscode: 503`.
- Why did the node go quiet? → `NodeNotReady`, then `TaintManagerEviction`.

Two properties make them dangerous to rely on naively:

1. **They expire.** `kube-apiserver --event-ttl` defaults to **1 hour**. Events are stored in etcd and garbage-collected. An incident review the next morning has no events unless you exported them.
2. **They are lossy and deduplicated.** The client-side event recorder aggregates repeats (`count` in `core/v1`, `series.count` in `events.k8s.io/v1`) and rate-limits (default ~25 burst, refill 1 per 5 min per unique event key). Under a storm, events are *dropped*, not queued. Never treat event counts as exact.

Therefore: **exporting Events into your log/event store is mandatory platform work**, done with the OTel `k8sobjects` receiver (which supersedes the deprecated `k8s_events` receiver).

Note the vocabulary collision: "events" in the observability-theory sense means *wide, structured, per-request records* (canonical log lines, "one very wide event per request") — the substrate from which metrics and traces are derived. Kubernetes `Event` objects are a narrower, orchestrator-specific thing. Both matter; they are not the same noun.

### 2.8 Choosing what to measure: RED, USE, and the Four Golden Signals

| Framework | Applies to | Measures | Typical PromQL |
|---|---|---|---|
| **RED** | Request-driven **services** | **R**ate, **E**rrors, **D**uration | `sum(rate(http_server_request_duration_seconds_count[5m]))` |
| **USE** | **Resources** (CPU, disk, NIC, pool) | **U**tilization, **S**aturation, **E**rrors | `rate(node_cpu_seconds_total{mode!="idle"}[5m])`, `node_load1`, `node_network_receive_errs_total` |
| **Four Golden Signals** (Google SRE) | Anything user-facing | Latency, Traffic, Errors, Saturation | union of the above |

Practical rule: RED tells you the *user* is unhappy; USE tells you *which resource* made them unhappy. Alert on RED (symptoms, user-visible), diagnose with USE (causes). Alerting on causes produces pagers for conditions no user ever noticed.

---

## 3. Complete production manifests

Everything below is a coherent, deployable set. Namespace: `observability`.

### 3.1 Namespace and RBAC

The `k8sattributes` processor, `kubeletstats` receiver, and `k8sobjects` receiver each need explicit API permissions. Missing RBAC is the single most common cause of "my telemetry has no pod labels" — and it fails *silently degraded*, not loudly.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-agent
  namespace: observability
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-gateway
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-agent
rules:
  # k8sattributes processor: pod/namespace/node metadata enrichment
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  # kubeletstats receiver: /stats/summary on the local kubelet
  - apiGroups: [""]
    resources: ["nodes/stats", "nodes/proxy", "nodes/metrics"]
    verbs: ["get"]
  # prometheus receiver: service discovery of scrape targets
  - apiGroups: [""]
    resources: ["services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics", "/metrics/cadvisor"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-gateway
rules:
  # k8sobjects receiver: watch Kubernetes Events cluster-wide
  - apiGroups: [""]
    resources: ["events", "namespaces", "pods", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["events.k8s.io"]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets", "deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
  # loadbalancing exporter k8s resolver on the agent side targets this Service
  - apiGroups: [""]
    resources: ["endpoints", "services"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-agent
subjects:
  - kind: ServiceAccount
    name: otel-agent
    namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-gateway
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-gateway
subjects:
  - kind: ServiceAccount
    name: otel-gateway
    namespace: observability
```

### 3.2 Agent (DaemonSet) configuration

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
      # ---- Application telemetry pushed to the node-local agent -------------
      otlp:
        protocols:
          grpc:
            endpoint: ${env:MY_POD_IP}:4317
            max_recv_msg_size_mib: 16
            keepalive:
              server_parameters:
                max_connection_age: 120s
                max_connection_age_grace: 30s
          http:
            endpoint: ${env:MY_POD_IP}:4318

      # ---- Container stdout/stderr from the CRI log directory ---------------
      filelog:
        include:
          - /var/log/pods/*/*/*.log
        exclude:
          # Never tail your own logs: it is a guaranteed feedback loop.
          - /var/log/pods/observability_otel-agent-*/*/*.log
        start_at: end
        include_file_path: true
        include_file_name: false
        poll_interval: 200ms
        fingerprint_size: 1kb
        max_log_size: 4MiB
        retry_on_failure:
          enabled: true
          initial_interval: 1s
          max_interval: 30s
        operators:
          # Parses the CRI/containerd envelope AND reassembles P/F partial
          # lines split at the runtime's 16 KiB read boundary.
          - id: container-parser
            type: container
            format: containerd
            add_metadata_from_filepath: true
          # Best-effort structured parse; non-JSON lines pass through intact.
          - id: json-parser
            type: json_parser
            if: 'body matches "^\\s*\\{"'
            parse_from: body
            parse_to: attributes
            severity:
              parse_from: attributes.level
              mapping:
                debug: debug
                info: info
                warn: warn
                error: error
                fatal: fatal
            timestamp:
              parse_from: attributes.ts
              layout_type: gotime
              layout: "2006-01-02T15:04:05.999999999Z07:00"
              # A missing/invalid ts must not drop the record.
              on_error: send

      # ---- Node-level kubelet + cAdvisor metrics ---------------------------
      kubeletstats:
        collection_interval: 30s
        auth_type: serviceAccount
        endpoint: https://${env:K8S_NODE_NAME}:10250
        insecure_skip_verify: true
        metric_groups: [container, pod, node, volume]
        k8s_api_config:
          auth_type: serviceAccount

      # ---- Host (kernel) metrics -------------------------------------------
      hostmetrics:
        collection_interval: 30s
        root_path: /hostfs
        scrapers:
          cpu:
            metrics:
              system.cpu.utilization:
                enabled: true
          load: {}
          memory:
            metrics:
              system.memory.utilization:
                enabled: true
          disk: {}
          filesystem:
            exclude_mount_points:
              match_type: regexp
              mount_points:
                - /var/lib/kubelet/.*
                - /run/.*
            exclude_fs_types:
              match_type: strict
              fs_types: [tmpfs, devtmpfs, overlay, squashfs, autofs]
          network: {}
          processes: {}

      # ---- Prometheus scraping of node-local pods --------------------------
      prometheus:
        config:
          scrape_configs:
            - job_name: kubernetes-pods
              scrape_interval: 30s
              scrape_timeout: 10s
              kubernetes_sd_configs:
                - role: pod
                  selectors:
                    - role: pod
                      field: spec.nodeName=${env:K8S_NODE_NAME}
              relabel_configs:
                - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
                  action: keep
                  regex: "true"
                - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
                  action: replace
                  target_label: __metrics_path__
                  regex: (.+)
                - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
                  action: replace
                  target_label: __address__
                  regex: ([^:]+)(?::\d+)?;(\d+)
                  replacement: $$1:$$2
                - source_labels: [__meta_kubernetes_namespace]
                  target_label: k8s_namespace_name
                - source_labels: [__meta_kubernetes_pod_name]
                  target_label: k8s_pod_name
              metric_relabel_configs:
                # Platform-enforced cardinality guard: drop known offenders
                # before they ever reach storage.
                - source_labels: [__name__]
                  regex: "go_gc_heap_.*|go_memory_classes_.*"
                  action: drop

    processors:
      # MUST be the first processor in every pipeline. Under memory pressure it
      # refuses new data (back-pressure) instead of letting the process OOM.
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20

      # Node/cloud identity for every signal.
      resourcedetection:
        detectors: [env, system, k8snode]
        timeout: 5s
        override: false
        system:
          hostname_sources: [os]
        k8snode:
          auth_type: serviceAccount
          node_from_env_var: K8S_NODE_NAME

      # Pod identity for every signal. Requires the RBAC in 3.1.
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        # Watch only this node's pods: an O(cluster) watch on every node is a
        # classic API-server melt at 500+ nodes.
        filter:
          node_from_env_var: K8S_NODE_NAME
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.pod.start_time
            - k8s.deployment.name
            - k8s.statefulset.name
            - k8s.daemonset.name
            - k8s.job.name
            - k8s.cronjob.name
            - k8s.node.name
            - k8s.container.name
            - container.image.name
            - container.image.tag
          labels:
            - tag_name: service.namespace
              key: app.kubernetes.io/part-of
              from: pod
            - tag_name: app.team
              key: team
              from: pod
            - tag_name: deployment.environment.name
              key: environment
              from: namespace
          annotations:
            - tag_name: app.cost_center
              key: finops.example.com/cost-center
              from: namespace
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.uid
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
          - sources:
              - from: connection

      # Guarantee service.name exists. Telemetry without it is unattributable
      # and every backend will bucket it as "unknown_service".
      transform/ensure_service_name:
        error_mode: ignore
        trace_statements:
          - context: resource
            statements:
              - set(attributes["service.name"], attributes["k8s.deployment.name"])
                where attributes["service.name"] == nil
              - set(attributes["service.name"], "unknown_service")
                where attributes["service.name"] == nil
        log_statements:
          - context: resource
            statements:
              - set(attributes["service.name"], attributes["k8s.deployment.name"])
                where attributes["service.name"] == nil

      batch:
        timeout: 5s
        send_batch_size: 8192
        send_batch_max_size: 10000

    exporters:
      # Traces: hash on trace ID so every span of a trace reaches the SAME
      # gateway replica. This is the precondition for correct tail sampling.
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
              initial_interval: 1s
              max_interval: 30s
              max_elapsed_time: 300s
        resolver:
          k8s:
            service: otel-gateway.observability
            ports: [4317]

      # Metrics and logs need no trace affinity: plain round-robin.
      otlp/gateway:
        endpoint: otel-gateway.observability.svc.cluster.local:4317
        tls:
          insecure: true
        sending_queue:
          enabled: true
          num_consumers: 10
          queue_size: 10000
          # Survive gateway restarts: spill the queue to the node's disk.
          storage: file_storage/queue
        retry_on_failure:
          enabled: true
          initial_interval: 1s
          max_interval: 30s
          max_elapsed_time: 300s

    extensions:
      health_check:
        endpoint: ${env:MY_POD_IP}:13133
        path: /health/status
      pprof:
        endpoint: 127.0.0.1:1777
      zpages:
        endpoint: 127.0.0.1:55679
      file_storage/queue:
        directory: /var/lib/otelcol/queue
        timeout: 10s
        compaction:
          on_start: true
          directory: /var/lib/otelcol/queue
          max_transaction_size: 65536

    service:
      extensions: [health_check, pprof, zpages, file_storage/queue]
      telemetry:
        logs:
          level: info
          encoding: json
        metrics:
          # Modern form. The legacy `metrics: address: 0.0.0.0:8888` still
          # works in many builds but is deprecated.
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
      pipelines:
        traces:
          receivers: [otlp]
          processors:
            - memory_limiter
            - k8sattributes
            - resourcedetection
            - transform/ensure_service_name
            - batch
          exporters: [loadbalancing]
        metrics:
          receivers: [otlp, kubeletstats, hostmetrics, prometheus]
          processors:
            - memory_limiter
            - k8sattributes
            - resourcedetection
            - batch
          exporters: [otlp/gateway]
        logs:
          receivers: [otlp, filelog]
          processors:
            - memory_limiter
            - k8sattributes
            - resourcedetection
            - transform/ensure_service_name
            - batch
          exporters: [otlp/gateway]
```

### 3.3 Agent DaemonSet and Service

```yaml
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-agent
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-agent
    app.kubernetes.io/component: telemetry-agent
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-agent
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-agent
      annotations:
        # Force a rollout when the config changes; a ConfigMap edit alone does
        # not restart pods, and the Collector does not hot-reload by default.
        checksum/config: "REPLACED-BY-CI-WITH-SHA256-OF-CONFIGMAP"
    spec:
      serviceAccountName: otel-agent
      priorityClassName: system-node-critical
      hostNetwork: false
      dnsPolicy: ClusterFirst
      terminationGracePeriodSeconds: 45
      tolerations:
        - operator: Exists
      securityContext:
        runAsUser: 0
        runAsGroup: 0
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.128.0
          imagePullPolicy: IfNotPresent
          args: ["--config=/conf/config.yaml"]
          env:
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: MY_POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: K8S_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            # GOMEMLIMIT below the cgroup limit gives the Go GC room to work
            # before the kernel OOM-killer intervenes. Without it, a Collector
            # under burst load is killed rather than back-pressured.
            - name: GOMEMLIMIT
              value: "800MiB"
            - name: GOMAXPROCS
              value: "2"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.name=otel-agent,service.namespace=platform,k8s.cluster.name=prod-eu-1"
          ports:
            - name: otlp-grpc
              containerPort: 4317
              hostPort: 4317
              protocol: TCP
            - name: otlp-http
              containerPort: 4318
              hostPort: 4318
              protocol: TCP
            - name: metrics
              containerPort: 8888
              protocol: TCP
            - name: healthz
              containerPort: 13133
              protocol: TCP
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              # No CPU limit on purpose: throttling a telemetry agent during an
              # incident is how you lose the data about the incident.
              memory: 1Gi
          livenessProbe:
            httpGet:
              path: /health/status
              port: 13133
            initialDelaySeconds: 15
            periodSeconds: 20
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/status
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
              readOnly: true
            - name: varlogpods
              mountPath: /var/log/pods
              readOnly: true
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
            - name: hostfs
              mountPath: /hostfs
              readOnly: true
              mountPropagation: HostToContainer
            - name: queue
              mountPath: /var/lib/otelcol/queue
      volumes:
        - name: config
          configMap:
            name: otel-agent-config
            items:
              - key: config.yaml
                path: config.yaml
        - name: varlogpods
          hostPath:
            path: /var/log/pods
            type: DirectoryOrCreate
        - name: varlibdockercontainers
          hostPath:
            path: /var/lib/docker/containers
            type: DirectoryOrCreate
        - name: hostfs
          hostPath:
            path: /
            type: Directory
        - name: queue
          hostPath:
            path: /var/lib/otelcol/queue
            type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: otel-agent
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-agent
spec:
  # Headless + internalTrafficPolicy:Local keeps app→agent traffic on the node.
  clusterIP: None
  internalTrafficPolicy: Local
  selector:
    app.kubernetes.io/name: otel-agent
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
    - name: otlp-http
      port: 4318
      targetPort: 4318
      protocol: TCP
    - name: metrics
      port: 8888
      targetPort: 8888
      protocol: TCP
```

### 3.4 Gateway configuration — tail sampling, Events, and backend fan-out

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
            max_recv_msg_size_mib: 32
          http:
            endpoint: 0.0.0.0:4318

      # Kubernetes Events as a durable, queryable log stream.
      # Supersedes the deprecated `k8s_events` receiver.
      k8sobjects:
        auth_type: serviceAccount
        objects:
          - name: events
            mode: watch
            group: events.k8s.io
            exclude_watch_type: [DELETED]

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20

      # Keep every trace that is interesting; sample the boring ones at 2%.
      # Policies are OR'd: a trace is kept if ANY policy says sample.
      tail_sampling:
        decision_wait: 15s
        num_traces: 100000
        expected_new_traces_per_sec: 2000
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
              threshold_ms: 800
          - name: keep-flagged-tenants
            type: string_attribute
            string_attribute:
              key: tenant.tier
              values: ["platinum"]
              enabled_regex_matching: false
          - name: keep-explicit-debug
            type: boolean_attribute
            boolean_attribute:
              key: debug.force_sample
              value: true
          - name: baseline-sample
            type: probabilistic
            probabilistic:
              sampling_percentage: 2

      # Derive RED metrics from 100% of spans BEFORE sampling discards them.
      # This is why the connector sits upstream of the sampled export path.
      transform/normalize_events:
        error_mode: ignore
        log_statements:
          - context: log
            statements:
              - set(severity_text, "ERROR")
                where attributes["type"] == "Warning"
              - set(attributes["k8s.event.reason"], attributes["reason"])
                where attributes["reason"] != nil

      batch:
        timeout: 5s
        send_batch_size: 8192
        send_batch_max_size: 10000

    connectors:
      # Span -> RED metrics. Unsampled input, so the metrics are exact even
      # though the traces are sampled.
      spanmetrics:
        histogram:
          explicit:
            buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s]
        dimensions:
          - name: http.request.method
          - name: http.response.status_code
          - name: http.route
          - name: deployment.environment.name
        exclude_dimensions: [span.kind]
        # Exemplars are the metric -> trace bridge.
        exemplars:
          enabled: true
        metrics_flush_interval: 30s
        namespace: traces.span.metrics

    exporters:
      otlp/tempo:
        endpoint: tempo-distributor.tracing.svc.cluster.local:4317
        tls:
          insecure: true
        sending_queue:
          enabled: true
          num_consumers: 20
          queue_size: 20000
        retry_on_failure:
          enabled: true
          max_elapsed_time: 300s

      prometheusremotewrite:
        endpoint: http://prometheus.monitoring.svc.cluster.local:9090/api/v1/write
        target_info:
          enabled: true
        export_created_metric:
          enabled: false
        resource_to_telemetry_conversion:
          # DANGER: promoting ALL resource attributes to labels imports
          # k8s.pod.name (unbounded churn) into every series. Keep false and
          # select attributes explicitly upstream.
          enabled: false
        remote_write_queue:
          enabled: true
          queue_size: 100000
          num_consumers: 10

      otlphttp/loki:
        endpoint: http://loki-gateway.logging.svc.cluster.local/otlp
        tls:
          insecure: true
        sending_queue:
          enabled: true
          queue_size: 20000

      debug:
        verbosity: basic
        sampling_initial: 5
        sampling_thereafter: 500

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
        path: /health/status
      zpages:
        endpoint: 127.0.0.1:55679
      pprof:
        endpoint: 127.0.0.1:1777

    service:
      extensions: [health_check, zpages, pprof]
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
        # 1. Every span -> spanmetrics connector (no sampling upstream).
        traces/in:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [spanmetrics, forward/sampled]

        # 2. Sampled path -> trace store.
        traces/sampled:
          receivers: [forward/sampled]
          processors: [memory_limiter, tail_sampling, batch]
          exporters: [otlp/tempo]

        metrics:
          receivers: [otlp, spanmetrics]
          processors: [memory_limiter, batch]
          exporters: [prometheusremotewrite]

        logs:
          receivers: [otlp, k8sobjects]
          processors: [memory_limiter, transform/normalize_events, batch]
          exporters: [otlphttp/loki]

    connectors/forward:
      forward/sampled: {}
```

> **Note on the two-pipeline trace split:** `spanmetrics` must see *unsampled* spans or your RED metrics inherit the sampling error. The `forward` connector chains `traces/in` → `traces/sampled` so tail sampling applies only to what is stored, not to what is measured. If your Collector build does not expose `connectors/forward` at that key, declare `forward/sampled: {}` inside the top-level `connectors:` block alongside `spanmetrics`.

### 3.5 Gateway Deployment, Service, HPA, PDB

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-gateway
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-gateway
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-gateway
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-gateway
      annotations:
        checksum/config: "REPLACED-BY-CI-WITH-SHA256-OF-CONFIGMAP"
    spec:
      serviceAccountName: otel-gateway
      priorityClassName: system-cluster-critical
      terminationGracePeriodSeconds: 60
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: otel-gateway
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.128.0
          args: ["--config=/conf/config.yaml"]
          env:
            - name: GOMEMLIMIT
              value: "3400MiB"
            - name: K8S_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: metrics,   containerPort: 8888 }
            - { name: healthz,   containerPort: 13133 }
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              memory: 4Gi
          livenessProbe:
            httpGet: { path: /health/status, port: 13133 }
            initialDelaySeconds: 20
            periodSeconds: 20
          readinessProbe:
            httpGet: { path: /health/status, port: 13133 }
            initialDelaySeconds: 10
            periodSeconds: 10
          lifecycle:
            preStop:
              exec:
                # Drain: fail readiness first so the loadbalancing exporter's
                # k8s resolver removes this endpoint before we stop accepting.
                command: ["/bin/sh", "-c", "sleep 20"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /conf
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: otel-gateway-config
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
    - { name: otlp-grpc, port: 4317, targetPort: 4317, protocol: TCP }
    - { name: otlp-http, port: 4318, targetPort: 4318, protocol: TCP }
    - { name: metrics,   port: 8888, targetPort: 8888, protocol: TCP }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: otel-gateway
  namespace: observability
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-gateway
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: otel-gateway
  namespace: observability
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: otel-gateway
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 75
  behavior:
    scaleDown:
      # Scaling the gateway down reshuffles the loadbalancing exporter's hash
      # ring and briefly splits traces across replicas. Be conservative.
      stabilizationWindowSeconds: 600
      policies:
        - type: Pods
          value: 1
          periodSeconds: 180
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
```

### 3.6 An instrumented application

Two options. **Manual SDK** (explicit, no operator dependency):

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/part-of: storefront
spec:
  replicas: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
        team: payments
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9464"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: checkout
          image: registry.example.com/shop/checkout:1.24.3
          ports:
            - { name: http,    containerPort: 8080 }
            - { name: metrics, containerPort: 9464 }
          env:
            # ---- Identity: the single most important resource attribute ----
            - name: OTEL_SERVICE_NAME
              value: checkout
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: POD_UID
              valueFrom: { fieldRef: { fieldPath: metadata.uid } }
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: NODE_IP
              valueFrom: { fieldRef: { fieldPath: status.hostIP } }
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: >-
                service.namespace=storefront,
                service.version=1.24.3,
                deployment.environment.name=production,
                k8s.pod.name=$(POD_NAME),
                k8s.pod.uid=$(POD_UID),
                k8s.node.name=$(NODE_NAME),
                service.instance.id=$(POD_UID)

            # ---- Transport: to the node-local agent via hostIP ------------
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://$(NODE_IP):4317
            - name: OTEL_EXPORTER_OTLP_PROTOCOL
              value: grpc
            - name: OTEL_EXPORTER_OTLP_TIMEOUT
              value: "10000"

            # ---- Signals -------------------------------------------------
            - name: OTEL_TRACES_EXPORTER
              value: otlp
            - name: OTEL_LOGS_EXPORTER
              value: otlp
            # Metrics stay on the Prometheus pull path (see annotations above).
            - name: OTEL_METRICS_EXPORTER
              value: prometheus
            - name: OTEL_EXPORTER_PROMETHEUS_PORT
              value: "9464"

            # ---- Sampling: head-based ALL, tail sampling decides at the
            #      gateway. Sampling twice compounds the loss.
            - name: OTEL_TRACES_SAMPLER
              value: parentbased_always_on

            # ---- Context propagation contract -----------------------------
            - name: OTEL_PROPAGATORS
              value: tracecontext,baggage,b3multi

            # ---- Batching -------------------------------------------------
            - name: OTEL_BSP_MAX_QUEUE_SIZE
              value: "4096"
            - name: OTEL_BSP_SCHEDULE_DELAY
              value: "2000"
            - name: OTEL_BSP_MAX_EXPORT_BATCH_SIZE
              value: "512"
          resources:
            requests: { cpu: 250m, memory: 384Mi }
            limits:   { memory: 768Mi }
```

**Zero-code auto-instrumentation** via the OpenTelemetry Operator — the actual golden path, because application teams change nothing but one annotation:

```yaml
---
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: platform-default
  namespace: shop
spec:
  exporter:
    endpoint: http://otel-agent.observability.svc.cluster.local:4317
  propagators:
    - tracecontext
    - baggage
    - b3multi
  sampler:
    type: parentbased_always_on
  resource:
    addK8sUIDAttributes: true
    resourceAttributes:
      deployment.environment.name: production
  env:
    - name: OTEL_EXPORTER_OTLP_PROTOCOL
      value: grpc
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.20.1
    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits:   { memory: 256Mi }
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:0.58b0
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.62.0
  go:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-go:v0.24.0
```

Team-side opt-in is one line:

```yaml
      annotations:
        instrumentation.opentelemetry.io/inject-java: "platform-default"
```

### 3.7 Scrape configuration and platform alerting

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: otel-collectors
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames: [observability]
  selector:
    matchExpressions:
      - key: app.kubernetes.io/name
        operator: In
        values: [otel-agent, otel-gateway]
  podMetricsEndpoints:
    - port: metrics
      interval: 30s
      scrapeTimeout: 10s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: observability-pipeline
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    # ---- Meta-monitoring: who watches the watchmen ----------------------
    - name: otel-collector.health
      interval: 30s
      rules:
        - alert: OtelCollectorDroppingData
          expr: |
            sum by (job, pod, exporter) (
              rate(otelcol_exporter_send_failed_spans_total[5m])
              + rate(otelcol_exporter_send_failed_metric_points_total[5m])
              + rate(otelcol_exporter_send_failed_log_records_total[5m])
            ) > 0
          for: 10m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "Collector {{ $labels.pod }} is failing to export to {{ $labels.exporter }}"
            description: "{{ $value | printf \"%.1f\" }} items/s failing. Backend down, TLS expired, or quota exceeded."
            runbook_url: "https://runbooks.example.com/otel/export-failure"

        - alert: OtelCollectorRefusingData
          expr: |
            sum by (job, pod) (
              rate(otelcol_processor_refused_spans_total[5m])
              + rate(otelcol_processor_refused_metric_points_total[5m])
              + rate(otelcol_processor_refused_log_records_total[5m])
            ) > 0
          for: 5m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "memory_limiter on {{ $labels.pod }} is refusing data"
            description: "Back-pressure active. Scale the gateway or raise limits."

        - alert: OtelCollectorQueueNearFull
          expr: |
            (
              otelcol_exporter_queue_size
              / clamp_min(otelcol_exporter_queue_capacity, 1)
            ) > 0.8
          for: 10m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Export queue {{ $labels.exporter }} on {{ $labels.pod }} is {{ $value | humanizePercentage }} full"

        - alert: TelemetryPipelineSilent
          expr: |
            sum(rate(otelcol_receiver_accepted_spans_total[10m])) == 0
            and on() sum(up{job=~".*otel.*"}) > 0
          for: 15m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "Collectors are healthy but no spans are arriving"
            description: "Almost always broken instrumentation, not a broken pipeline."

    # ---- Cardinality guard ----------------------------------------------
    - name: prometheus.cardinality
      interval: 60s
      rules:
        - record: platform:series_by_metric_name:count
          expr: count by (__name__) ({__name__=~".+"})

        - alert: MetricCardinalityExplosion
          expr: platform:series_by_metric_name:count > 100000
          for: 15m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "Metric {{ $labels.__name__ }} has {{ $value }} series"
            description: "An unbounded label was almost certainly added. Drop it at the Collector via metric_relabel_configs before Prometheus OOMs."

        - alert: PrometheusHeadSeriesGrowth
          expr: |
            predict_linear(prometheus_tsdb_head_series[1h], 6 * 3600) > 12e6
          for: 30m
          labels:
            severity: warning
            team: platform

    # ---- Service SLO: multi-window multi-burn-rate error budget ----------
    - name: slo.checkout.availability
      interval: 30s
      rules:
        - record: slo:checkout_requests:rate5m
          expr: sum(rate(http_server_request_duration_seconds_count{service="checkout"}[5m]))
        - record: slo:checkout_errors:rate5m
          expr: sum(rate(http_server_request_duration_seconds_count{service="checkout",http_response_status_code=~"5.."}[5m]))
        - record: slo:checkout_error_ratio:rate5m
          expr: |
            slo:checkout_errors:rate5m / clamp_min(slo:checkout_requests:rate5m, 1e-9)
        - record: slo:checkout_error_ratio:rate1h
          expr: |
            sum(rate(http_server_request_duration_seconds_count{service="checkout",http_response_status_code=~"5.."}[1h]))
            / clamp_min(sum(rate(http_server_request_duration_seconds_count{service="checkout"}[1h])), 1e-9)
        - record: slo:checkout_error_ratio:rate6h
          expr: |
            sum(rate(http_server_request_duration_seconds_count{service="checkout",http_response_status_code=~"5.."}[6h]))
            / clamp_min(sum(rate(http_server_request_duration_seconds_count{service="checkout"}[6h])), 1e-9)

        # SLO = 99.9% => error budget = 0.001
        # Fast burn: 14.4x for 1h+5m windows => budget gone in ~2 days.
        - alert: CheckoutErrorBudgetBurnFast
          expr: |
            slo:checkout_error_ratio:rate1h  > (14.4 * 0.001)
            and
            slo:checkout_error_ratio:rate5m  > (14.4 * 0.001)
          for: 2m
          labels:
            severity: page
            team: payments
            slo: checkout-availability
          annotations:
            summary: "checkout is burning its error budget 14.4x too fast"
            runbook_url: "https://runbooks.example.com/slo/checkout"

        # Slow burn: 6x for 6h+30m windows.
        - alert: CheckoutErrorBudgetBurnSlow
          expr: |
            slo:checkout_error_ratio:rate6h > (6 * 0.001)
            and
            slo:checkout_error_ratio:rate5m > (6 * 0.001)
          for: 15m
          labels:
            severity: ticket
            team: payments
            slo: checkout-availability
```

---

## 4. Verification from the terminal

### 4.1 Is the pipeline alive?

```console
$ kubectl -n observability get pods -o wide
NAME                            READY   STATUS    RESTARTS   AGE     IP             NODE
otel-agent-4x9kd                1/1     Running   0          3h12m   10.42.3.17     ip-10-0-3-84
otel-agent-b7tql                1/1     Running   0          3h12m   10.42.1.44     ip-10-0-1-21
otel-agent-mz2v8                1/1     Running   0          3h12m   10.42.2.9      ip-10-0-2-56
otel-gateway-7d6c9f4b58-4hn2p   1/1     Running   0          52m     10.42.1.113    ip-10-0-1-21
otel-gateway-7d6c9f4b58-9klr7   1/1     Running   0          52m     10.42.2.87     ip-10-0-2-56
otel-gateway-7d6c9f4b58-w8qxs   1/1     Running   0          52m     10.42.3.201    ip-10-0-3-84

$ kubectl -n observability exec deploy/otel-gateway -c otelcol -- \
    wget -qO- http://127.0.0.1:13133/health/status
{"status":"Server available","upSince":"2026-08-06T11:14:02.331472Z","uptime":"52m18.9042s"}
```

### 4.2 The single most useful command: the Collector's own metrics

```console
$ kubectl -n observability port-forward deploy/otel-gateway 8888:8888 >/dev/null 2>&1 &
$ curl -s localhost:8888/metrics | grep -E '^otelcol_(receiver|processor|exporter)' | grep -v '^#'
otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc"} 4.8213e+07
otelcol_receiver_refused_spans_total{receiver="otlp",transport="grpc"} 0
otelcol_receiver_accepted_log_records_total{receiver="k8sobjects",transport=""} 91422
otelcol_receiver_accepted_metric_points_total{receiver="otlp",transport="grpc"} 2.19884e+08
otelcol_processor_batch_batch_send_size_sum{processor="batch"} 4.8213e+07
otelcol_processor_refused_spans_total{processor="memory_limiter"} 0
otelcol_processor_dropped_spans_total{processor="memory_limiter"} 0
otelcol_exporter_sent_spans_total{exporter="otlp/tempo"} 1.043921e+06
otelcol_exporter_send_failed_spans_total{exporter="otlp/tempo"} 0
otelcol_exporter_enqueue_failed_spans_total{exporter="otlp/tempo"} 0
otelcol_exporter_queue_size{exporter="otlp/tempo"} 61
otelcol_exporter_queue_capacity{exporter="otlp/tempo"} 20000
otelcol_exporter_sent_metric_points_total{exporter="prometheusremotewrite"} 2.19884e+08
otelcol_exporter_send_failed_metric_points_total{exporter="prometheusremotewrite"} 0
```

**Read this like a balance sheet — the invariant is `accepted = sent + refused + dropped + queued`:**

| Observation | Meaning |
|---|---|
| `receiver_accepted` climbing, `exporter_sent` flat | Data is stuck in the pipeline; look at `queue_size` and `send_failed` |
| `receiver_refused > 0` | The Collector is rejecting clients — `memory_limiter` back-pressure reaching the receiver |
| `processor_refused{processor="memory_limiter"} > 0` | Memory pressure; scale out or raise `limit_percentage` |
| `exporter_send_failed > 0` | Backend is rejecting or unreachable |
| `exporter_enqueue_failed > 0` | **Data is being lost.** The sending queue is full and retries are being discarded |
| `queue_size / queue_capacity > 0.8` sustained | Ingest rate exceeds export rate; the gap is your future data loss |
| `sent_spans` ≈ 2.2% of `accepted_spans` | Tail sampling is working (2% baseline + errors + slow) |

In the output above: 48.2 M spans accepted, 1.04 M exported → 2.16% retention. Consistent with the policy set. If you see 100% you have a sampling misconfiguration; if you see 0% your policies never match.

### 4.3 Following one request end to end

```console
$ kubectl -n shop port-forward svc/checkout 8080:8080 >/dev/null 2>&1 &
$ curl -si -X POST localhost:8080/api/v1/checkout \
    -H 'content-type: application/json' \
    -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
    -d '{"cart_id":"c-88213","currency":"EUR"}' | head -12
HTTP/1.1 201 Created
content-type: application/json
x-trace-id: 4bf92f3577b34da6a3ce929d0e0e4736
date: Thu, 06 Aug 2026 14:22:31 GMT
```

The `traceparent` header is W3C Trace Context:

```
00      -  4bf92f3577b34da6a3ce929d0e0e4736  -  00f067aa0ba902b7  -  01
version    trace-id (16 bytes / 32 hex)         parent span-id      flags
                                                (8 bytes/16 hex)    01 = sampled
```

Now find that exact trace's logs:

```console
$ kubectl -n shop logs deploy/checkout --tail=3 | jq -c '{ts,level,msg,trace_id,span_id}'
{"ts":"2026-08-06T14:22:31.884Z","level":"info","msg":"checkout started","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"a3f1c02d7e9b4415"}
{"ts":"2026-08-06T14:22:32.117Z","level":"warn","msg":"payment gateway retry 1/3","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"b1094ee2f8c33aa7"}
{"ts":"2026-08-06T14:22:32.902Z","level":"info","msg":"order committed","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"a3f1c02d7e9b4415"}
```

**If `trace_id` is absent from your logs, correlation is impossible and every incident becomes archaeology.** This is the single highest-leverage instrumentation check on a platform.

Confirm the trace landed in the backend:

```console
$ kubectl -n tracing port-forward svc/tempo-query-frontend 3200:3200 >/dev/null 2>&1 &
$ curl -s localhost:3200/api/traces/4bf92f3577b34da6a3ce929d0e0e4736 \
    | jq '[.batches[].scopeSpans[].spans[] | {name, kind, durMs: ((.endTimeUnixNano|tonumber - (.startTimeUnixNano|tonumber))/1e6)}]'
[
  {"name": "POST /api/v1/checkout",     "kind": 2, "durMs": 1018.4},
  {"name": "cart.load",                 "kind": 3, "durMs": 12.7},
  {"name": "inventory.reserve",         "kind": 3, "durMs": 41.9},
  {"name": "POST /v2/charges",          "kind": 3, "durMs": 883.1},
  {"name": "orders.insert",             "kind": 3, "durMs": 22.6}
]
```

883 ms of a 1018 ms request is one downstream call. That conclusion is unreachable from metrics alone — this is exactly the question traces exist to answer.

### 4.4 Inspecting the raw CRI log file on a node

```console
$ kubectl debug node/ip-10-0-1-21 -it --image=busybox:1.36 -- sh
Creating debugging pod node-debugger-ip-10-0-1-21-x7f2m with container debugger
/ # ls /host/var/log/pods/shop_checkout-6d4b7f9c85-2xk9v_9a1f0c3e-b8d2-4f11-9e77-3c5a1d0b7e42/
checkout

/ # tail -2 /host/var/log/pods/shop_checkout-*/checkout/0.log
2026-08-06T14:22:32.117884211Z stdout F {"ts":"2026-08-06T14:22:32.117Z","level":"warn","msg":"payment gateway retry 1/3","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736"}
2026-08-06T14:22:32.902441093Z stdout F {"ts":"2026-08-06T14:22:32.902Z","level":"info","msg":"order committed","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736"}
```

A truncation problem looks like this — note the `P` tags:

```console
/ # grep -c ' P ' /host/var/log/pods/shop_checkout-*/checkout/0.log
1842
/ # grep ' P ' /host/var/log/pods/shop_checkout-*/checkout/0.log | head -1 | cut -c1-140
2026-08-06T14:19:08.441209773Z stdout P {"ts":"2026-08-06T14:19:08.441Z","level":"error","msg":"unhandled exception","stack":"java.lang.NullPoi
```

1 842 partial lines means 1 842 log records that a naive parser will mangle. Verify your `filelog` receiver uses `type: container`, which reassembles them.

### 4.5 Kubernetes Events

```console
$ kubectl get events -n shop --sort-by='.lastTimestamp' \
    -o custom-columns='TIME:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,COUNT:.count,MESSAGE:.message'
TIME                   TYPE      REASON              OBJECT                       COUNT  MESSAGE
2026-08-06T14:01:12Z   Normal    SuccessfulRescale   checkout                     1      New size: 8; reason: cpu resource utilization above target
2026-08-06T14:01:14Z   Warning   FailedScheduling    checkout-6d4b7f9c85-l4m2p    6      0/12 nodes are available: 8 Insufficient cpu, 4 node(s) had untolerated taint {spot: true}
2026-08-06T14:03:41Z   Normal    TriggeredScaleUp    checkout-6d4b7f9c85-l4m2p    1      pod triggered scale-up: [{eks-spot-4xl 4->6 (max: 20)}]
2026-08-06T14:05:22Z   Normal    Scheduled           checkout-6d4b7f9c85-l4m2p    1      Successfully assigned shop/checkout-6d4b7f9c85-l4m2p to ip-10-0-4-93
2026-08-06T14:05:24Z   Normal    Pulling             checkout-6d4b7f9c85-l4m2p    1      Pulling image "registry.example.com/shop/checkout:1.24.3"
2026-08-06T14:06:58Z   Normal    Started             checkout-6d4b7f9c85-l4m2p    1      Started container checkout
2026-08-06T14:12:03Z   Warning   Unhealthy           checkout-6d4b7f9c85-2xk9v    9      Liveness probe failed: HTTP probe failed with statuscode: 503
2026-08-06T14:13:31Z   Normal    Killing             checkout-6d4b7f9c85-2xk9v    1      Container checkout failed liveness probe, will be restarted
```

That is a complete causal narrative — HPA scaled, scheduling failed for 4 minutes, cluster-autoscaler added nodes, a separate pod started failing liveness — and **all of it is gone in one hour** unless exported. Prove your export works:

```console
$ kubectl -n observability logs deploy/otel-gateway -c otelcol | grep -c k8sobjects
0
$ kubectl -n observability exec deploy/otel-gateway -c otelcol -- \
    wget -qO- http://127.0.0.1:8888/metrics | grep k8sobjects
otelcol_receiver_accepted_log_records_total{receiver="k8sobjects",transport=""} 91422
otelcol_receiver_refused_log_records_total{receiver="k8sobjects",transport=""} 0
```

Non-zero and climbing = Events are being persisted.

### 4.6 Cardinality forensics with `promtool` and the TSDB API

```console
$ kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 >/dev/null 2>&1 &

$ promtool query instant http://localhost:9090 \
    'topk(5, count by (__name__)({__name__=~".+"}))'
{__name__="http_server_request_duration_seconds_bucket"} => 1284410 @[1780583931.442]
{__name__="container_memory_working_set_bytes"}          => 214883  @[1780583931.442]
{__name__="kube_pod_container_status_ready"}             => 198221  @[1780583931.442]
{__name__="traces_span_metrics_duration_milliseconds_bucket"} => 141902 @[1780583931.442]
{__name__="node_cpu_seconds_total"}                      => 4608    @[1780583931.442]

$ curl -s 'localhost:9090/api/v1/status/tsdb' | jq '.data.seriesCountByLabelName[0:6]'
[
  {"name": "__name__",    "value": 2874},
  {"name": "instance",    "value": 4211},
  {"name": "job",         "value": 88},
  {"name": "pod",         "value": 61240},
  {"name": "cart_id",     "value": 984112},
  {"name": "namespace",   "value": 74}
]
```

`cart_id` with 984 112 distinct values is the smoking gun: an unbounded business identifier promoted to a metric label. Find the offending metric and confirm:

```console
$ promtool query instant http://localhost:9090 \
    'count by (__name__)({cart_id!=""})'
{__name__="http_server_request_duration_seconds_bucket"} => 1284410 @[1780583931.442]
```

**Immediate mitigation at the Collector** (takes effect on the next scrape; no application deploy required):

```yaml
    processors:
      transform/drop_high_cardinality:
        error_mode: ignore
        metric_statements:
          - context: datapoint
            statements:
              - delete_key(attributes, "cart_id")
              - delete_key(attributes, "user_id")
              - delete_key(attributes, "request_id")
              - delete_key(attributes, "session_id")
```

Then reclaim the storage, which does **not** happen automatically:

```console
$ curl -s -X POST -g \
    'localhost:9090/api/v1/admin/tsdb/delete_series?match[]={cart_id!=""}'
$ curl -s -X POST 'localhost:9090/api/v1/admin/tsdb/clean_tombstones'
```

> Requires Prometheus started with `--web.enable-admin-api`. Deleting series is irreversible.

### 4.7 `zpages` — live pipeline introspection

```console
$ kubectl -n observability port-forward deploy/otel-gateway 55679:55679 >/dev/null 2>&1 &
$ curl -s 'localhost:55679/debug/tracez' | sed -n '1,14p'
TraceZ Summary
Span Name                                   Running  Latency Samples          Errors
                                                     [0,10us) [10us,100us) ...
exporter/otlp/tempo/traces                        3        0           12          1
processor/tail_sampling/TracesProcessed           0        0            0          0
receiver/otlp/TraceDataReceived                  17        0          208          0

$ curl -s 'localhost:55679/debug/pipelinez' | head -20
Pipelines
Name              Receivers          Processors                        Exporters
traces/in         [otlp]             [memory_limiter batch]            [spanmetrics forward/sampled]
traces/sampled    [forward/sampled]  [memory_limiter tail_sampling ..] [otlp/tempo]
metrics           [otlp spanmetrics] [memory_limiter batch]            [prometheusremotewrite]
logs              [otlp k8sobjects]  [memory_limiter transform batch]  [otlphttp/loki]
```

---

## 5. Failure diagnosis guide

### 5.1 Symptom → cause → command

| Symptom | Most likely cause | Diagnostic command | Fix |
|---|---|---|---|
| Backend shows `unknown_service` / `unknown_service:java` | `service.name` never set | `kubectl exec <pod> -- env \| grep OTEL_` | Set `OTEL_SERVICE_NAME` or add the `transform/ensure_service_name` processor |
| Telemetry has no `k8s.pod.name`, `k8s.deployment.name` | `k8sattributes` RBAC missing, or `pod_association` cannot match | `kubectl auth can-i list pods --as=system:serviceaccount:observability:otel-agent` | Apply the ClusterRole in §3.1; verify `pod_association` includes `connection` |
| Traces are fragmented — each service appears as its own root trace | Context propagation broken: a hop drops `traceparent` (API gateway, message queue, thread pool, `curl` in a shell script) | Send a request with an explicit `traceparent`; check whether the downstream span shares the trace ID | Enable propagation on the offending client; queues need manual context injection into message headers |
| Trace waterfall shows negative durations or child spans starting before parents | **Clock skew** between nodes | `for n in $(kubectl get no -o name); do kubectl debug $n -it --image=busybox -- date -u; done` | Enforce NTP/chrony via a DaemonSet or node image; >1 s skew makes traces unreadable |
| Tail sampling keeps only fragments of traces | Gateway scaled horizontally **without** `loadbalancing` exporter | `grep -A3 routing_key` in the agent ConfigMap | Add `loadbalancing` with `routing_key: traceID`; verify with `otelcol_loadbalancer_num_backends` |
| Prometheus OOMKilled, restarts, replays WAL for 20 min | Cardinality explosion | `curl -s localhost:9090/api/v1/status/tsdb \| jq .data.seriesCountByLabelName` | Drop the label at the Collector (§4.6), then `delete_series` + `clean_tombstones` |
| Log lines arriving truncated / JSON parse errors on the biggest lines | CRI 16 KiB partial-line splitting (`P` tag) not reassembled | `grep -c ' P ' /var/log/pods/**/*.log` on a node | Use `filelog` operator `type: container`; do not hand-roll the regex |
| Logs missing entirely for a crashing pod | The agent lagged behind kubelet log rotation, or the pod's node is gone | `kubectl -n observability logs ds/otel-agent \| grep -i "file.*rotat\|deleted"` | Raise `--container-log-max-files`; reduce log volume; enable `retry_on_failure` + `file_storage` |
| `rate()` on a counter returns flat 0 or sawtooth | Delta temporality pushed into a cumulative store | Compare raw samples: `curl .../api/v1/query?query=<metric>` over consecutive scrapes | Set `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative`, or insert `deltatocumulative` |
| Collector pods OOMKilled | `memory_limiter` missing/misordered, or `GOMEMLIMIT` unset | `kubectl -n observability get pods` → `OOMKilled`; check processor order in the config | `memory_limiter` **first** in every pipeline; set `GOMEMLIMIT` to ~80–85% of the container limit |
| `otelcol_exporter_enqueue_failed_*` climbing | Sending queue full — backend slower than ingest | `curl :8888/metrics \| grep queue` | Scale the gateway/backend, raise `queue_size`, enable `file_storage` persistence |
| Everything looks healthy, but nothing appears in the backend | Pipeline points at the wrong exporter, or the signal type has no pipeline | `curl :55679/debug/pipelinez` | Confirm the receiver→processor→exporter wiring for that specific signal |
| Kubernetes Events absent after an incident review | Events expired (`--event-ttl`, default 1 h) and were never exported | `kubectl get events -A \| wc -l` (suspiciously small) | Add the `k8sobjects` receiver (§3.4) |
| Alerts fire correctly but nobody can find the cause | Metrics have no exemplars; no `trace_id` in logs | Check for `# {trace_id=...}` in the `/metrics` exposition | Enable exemplars in the SDK/`spanmetrics`; run Prometheus with `--enable-feature=exemplar-storage` |

### 5.2 A structured triage procedure

Work **backwards from storage toward the application**. Most teams do the opposite and waste the first twenty minutes on the app.

**Step 1 — Is the backend receiving anything at all?**

```console
$ promtool query instant http://localhost:9090 'sum(rate(otelcol_exporter_sent_metric_points_total[5m]))'
{} => 0 @[1780584210.113]
```

Zero → the problem is upstream of the backend. Non-zero → the problem is your query, your labels, or your time range.

**Step 2 — Is the gateway exporting?**

```console
$ kubectl -n observability exec deploy/otel-gateway -c otelcol -- \
    wget -qO- http://127.0.0.1:8888/metrics | grep -E 'send_failed|queue_size|enqueue_failed'
otelcol_exporter_send_failed_spans_total{exporter="otlp/tempo"} 88214
otelcol_exporter_enqueue_failed_spans_total{exporter="otlp/tempo"} 12904
otelcol_exporter_queue_size{exporter="otlp/tempo"} 20000
```

Queue pinned at capacity with rising `send_failed` → the backend is rejecting. Read the actual error:

```console
$ kubectl -n observability logs deploy/otel-gateway -c otelcol --tail=5 | jq -r '.msg + " | " + (.error // "")'
Exporting failed. Will retry the request after interval. | rpc error: code = ResourceExhausted desc = grpc: received message larger than max (5242880 vs. 4194304)
```

Concrete and actionable: `send_batch_max_size` on the gateway exceeds the backend's `max_recv_msg_size`. Lower the batch or raise the backend limit.

**Step 3 — Is the gateway receiving?**

```console
$ kubectl -n observability exec deploy/otel-gateway -c otelcol -- \
    wget -qO- http://127.0.0.1:8888/metrics | grep receiver_accepted_spans
otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc"} 0
```

Zero → agents are not reaching the gateway. Test the path directly:

```console
$ kubectl -n observability exec ds/otel-agent -c otelcol -- \
    wget -qO- --timeout=3 http://otel-gateway.observability.svc.cluster.local:13133/health/status
wget: can't connect to remote host (10.43.201.88): Connection timed out
```

Now it is a networking question, not an observability one — NetworkPolicy, Service selector, or gateway readiness:

```console
$ kubectl -n observability get endpointslices -l kubernetes.io/service-name=otel-gateway \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
10.42.1.113 ready=false
10.42.2.87  ready=false
10.42.3.201 ready=false
```

All endpoints unready → the readiness probe is failing → back to gateway logs.

**Step 4 — Is the agent receiving from the application?**

```console
$ kubectl -n observability exec ds/otel-agent -c otelcol -- \
    wget -qO- http://127.0.0.1:8888/metrics | grep -E 'receiver_accepted_(spans|log_records)'
otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc"} 0
otelcol_receiver_accepted_log_records_total{receiver="filelog",transport=""} 4.81023e+06
```

Logs flowing, spans at zero → the pipeline is fine and the **application is not instrumented** (or not exporting). Confirm from inside the app pod:

```console
$ kubectl -n shop exec deploy/checkout -- env | grep -E 'OTEL_(SERVICE|EXPORTER|TRACES)'
OTEL_SERVICE_NAME=checkout
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
```

`otel-collector` does not resolve in namespace `shop` — the Service lives in `observability` and there is no local alias. The SDK has been silently retrying and dropping spans for weeks. Turn SDK diagnostics on to see it:

```console
$ kubectl -n shop set env deploy/checkout OTEL_LOG_LEVEL=debug OTEL_SDK_DISABLED=false
deployment.apps/checkout env updated

$ kubectl -n shop logs deploy/checkout --tail=3
[otel.javaagent 2026-08-06 14:41:07:220 +0000] [OkHttp http://otel-collector:4317/...] DEBUG io.opentelemetry.exporter.internal.grpc.GrpcExporter - Failed to export spans. The request could not be executed. Full error message: otel-collector: Name or service not known
```

**Step 5 — Synthetic end-to-end probe.** Bypass the application entirely and inject a known span with `telemetrygen`. If this arrives and your app's telemetry does not, the pipeline is exonerated:

```console
$ kubectl -n shop run telemetrygen --rm -it --restart=Never \
    --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest -- \
    traces --otlp-insecure --otlp-endpoint otel-agent.observability:4317 \
    --service canary-probe --traces 5 --child-spans 3
2026-08-06T14:44:12.001Z  INFO  traces/traces.go:58  starting HTTP exporter
2026-08-06T14:44:12.214Z  INFO  traces/worker.go:103 traces generated  {"worker": 0, "traces": 5}
2026-08-06T14:44:12.215Z  INFO  traces/traces.go:74  stopping the exporter
pod "telemetrygen" deleted
```

```console
$ curl -s 'localhost:3200/api/search?tags=service.name%3Dcanary-probe&limit=5' | jq '.traces | length'
5
```

Five in, five out: the pipeline works. Run this permanently as a CronJob — a **synthetic canary is the only way to detect a silently dead telemetry pipeline**, because a broken pipeline produces no alerts by construction.

### 5.3 The observability paradox

The pipeline that tells you the system is broken cannot tell you it is itself broken. Three defenses, all required:

1. **Meta-monitoring** — the Collector's own metrics are scraped by Prometheus, and Prometheus's own metrics (`up`, `prometheus_tsdb_head_series`, `prometheus_rule_evaluation_failures_total`) are alerted on. See §3.7.
2. **Dead man's switch** — a rule that always fires, wired to an external service (Dead Man's Snitch, Healthchecks.io, or a second cluster) that pages when the heartbeat *stops*:

```yaml
        - alert: Watchdog
          expr: vector(1)
          labels:
            severity: none
          annotations:
            summary: "Always firing. If this stops arriving, the alerting pipeline is dead."
```

3. **Synthetic canary** — the `telemetrygen` probe from Step 5, on a schedule, asserting round-trip arrival in the backend.

### 5.4 Cost control checklist

| Lever | Where | Typical saving |
|---|---|---|
| Drop unused metrics at scrape | `metric_relabel_configs` / `filter` processor | 30–60% of series |
| Delete unbounded labels | `transform` processor `delete_key` | Order of magnitude |
| Tail-sample traces | Gateway `tail_sampling` | 95–99% of trace volume |
| Drop `DEBUG` logs in production | `filter` processor on `severity_number` | 40–70% of log volume |
| Reduce histogram buckets / use exponential histograms | SDK view configuration | 50%+ of histogram series |
| Tier retention (hot 7d / cold 90d / archive 13mo) | Backend config | 60–80% of storage cost |
| Aggregate before storing | `metricstransform` / recording rules | Varies |

Publish the cost per team as a metric derived from `k8s.namespace.name` + the `app.cost_center` annotation. Telemetry spend that is invisible grows without bound; telemetry spend that shows up on a team's dashboard gets optimized within a sprint.

---

## 6. References

**CNCF / Certification**
- CNPA Curriculum (official PDF) — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF Curriculum repository — https://github.com/cncf/curriculum
- CNCF Cloud Native Glossary — https://glossary.cncf.io/
- CNCF Observability TAG — https://github.com/cncf/tag-observability
- CNCF Observability Whitepaper — https://github.com/cncf/tag-observability/blob/main/whitepaper.md

**OpenTelemetry**
- What is OpenTelemetry — https://opentelemetry.io/docs/what-is-opentelemetry/
- Signals overview (traces, metrics, logs, baggage) — https://opentelemetry.io/docs/concepts/signals/
- Semantic Conventions — https://opentelemetry.io/docs/specs/semconv/
- Kubernetes resource conventions — https://opentelemetry.io/docs/specs/semconv/resource/k8s/
- Collector architecture — https://opentelemetry.io/docs/collector/architecture/
- Collector deployment patterns (agent, gateway, sidecar) — https://opentelemetry.io/docs/collector/deployment/
- Collector configuration — https://opentelemetry.io/docs/collector/configuration/
- Collector internal telemetry — https://opentelemetry.io/docs/collector/internal-telemetry/
- Scaling the Collector — https://opentelemetry.io/docs/collector/scaling/
- Sampling (head vs. tail) — https://opentelemetry.io/docs/concepts/sampling/
- SDK environment variables — https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- OTLP specification — https://opentelemetry.io/docs/specs/otlp/
- Metric temporality — https://opentelemetry.io/docs/specs/otel/metrics/data-model/#temporality
- Exemplars — https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exemplars
- OpenTelemetry Operator — https://opentelemetry.io/docs/platforms/kubernetes/operator/
- Zero-code instrumentation — https://opentelemetry.io/docs/zero-code/
- Collector Contrib components — https://github.com/open-telemetry/opentelemetry-collector-contrib
- `k8sattributes` processor — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/k8sattributesprocessor
- `tail_sampling` processor — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- `filelog` receiver — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/filelogreceiver
- `k8sobjects` receiver — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/k8sobjectsreceiver
- `kubeletstats` receiver — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/kubeletstatsreceiver
- `loadbalancing` exporter — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- `spanmetrics` connector — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector
- OTTL (transform language) — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/pkg/ottl

**W3C standards**
- Trace Context (`traceparent` / `tracestate`) — https://www.w3.org/TR/trace-context/
- Baggage — https://www.w3.org/TR/baggage/

**Prometheus**
- Data model and cardinality — https://prometheus.io/docs/concepts/data_model/
- Instrumentation best practices — https://prometheus.io/docs/practices/instrumentation/
- Naming conventions — https://prometheus.io/docs/practices/naming/
- Histograms and summaries — https://prometheus.io/docs/practices/histograms/
- Kubernetes service discovery — https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config
- Feature flags (exemplar storage, native histograms) — https://prometheus.io/docs/prometheus/latest/feature_flags/
- TSDB admin API — https://prometheus.io/docs/prometheus/latest/querying/api/#tsdb-admin-apis
- OpenMetrics specification — https://github.com/prometheus/OpenMetrics/blob/main/specification/OpenMetrics.md
- Prometheus Operator API (`PodMonitor`, `PrometheusRule`) — https://prometheus-operator.dev/docs/api-reference/api/

**Kubernetes**
- Logging architecture — https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Metrics for control plane components — https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
- Events API (`events.k8s.io/v1`) — https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/
- `kube-apiserver` flags (`--event-ttl`) — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubelet flags (`--container-log-max-size`, `--container-log-max-files`) — https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
- Debug running pods (`kubectl debug`) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- CRI log format specification — https://github.com/kubernetes/design-proposals-archive/blob/main/node/kubelet-cri-logging.md

**SRE practice**
- Google SRE Book — Monitoring Distributed Systems (Four Golden Signals) — https://sre.google/sre-book/monitoring-distributed-systems/
- Google SRE Workbook — Alerting on SLOs (multi-window multi-burn-rate) — https://sre.google/workbook/alerting-on-slos/
- Google SRE Workbook — Implementing SLOs — https://sre.google/workbook/implementing-slos/
- Brendan Gregg — The USE Method — https://www.brendangregg.com/usemethod.html
- Tom Wilkie — The RED Method — https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/
- R. E. Kálmán, *On the General Theory of Control Systems* (1960) — origin of the observability definition — https://www.sciencedirect.com/science/article/pii/S1474667017700948