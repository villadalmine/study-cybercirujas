# Topic 2.1 — Implementing Monitoring, Alerting, Logging, and Tracing Solutions

> **Exam weight: 6.66** · CNPE Domain 2 (Observability & Platform Operations)
> **Profile:** Platform Engineering — building the observability *substrate* other teams consume, not instrumenting a single app.

---

## 1. The architectural problem: observability is a platform capability, not an add-on

In a monolith, "monitoring" meant a CPU graph and a log file you `tail`ed. In a Kubernetes platform serving dozens of tenant teams, the failure you are paid to prevent is different: a request enters through an ingress gateway, fans out across a service mesh into 14 microservices, three of which are owned by other teams, touches two databases and a Kafka topic, and returns a `503` — and nobody can say *where* the latency came from without a shared, correlated view.

Observability is the property that lets you ask **new questions about the system without shipping new code**. That is the working definition the CNCF Observability TAG uses, and it is the bar a platform engineer must hit. Three telemetry signals make it possible, and a mature platform treats them as one correlated dataset, not three silos:

| Signal | Answers | Cost driver | Cardinality risk |
|---|---|---|---|
| **Metrics** | "Is it broken, and how badly?" (aggregate) | Active time series (cardinality) | **Extreme** — every label combination is a series |
| **Logs** | "What exactly happened to *this* request?" | Bytes ingested + retention | Low (indexed labels), but volume is high |
| **Traces** | "*Where* in the call graph did time/errors go?" | Spans/sec × sampling rate | Medium — per-span attributes |

The platform-engineering mandate is to provide these as a **multi-tenant, self-service, cost-bounded** service. The three hard problems that flow from that mandate, and that this topic exists to solve:

1. **Cardinality explosion.** A single careless `user_id` label on a metric can generate millions of time series and take down your Prometheus. Governance is architecture.
2. **Correlation across signals.** A metric spike must jump to the exemplar trace, which must jump to the logs of the exact pod. Without this, MTTR is dominated by humans copy-pasting timestamps between three UIs.
3. **The pull-vs-push and head-vs-tail decisions.** These are not preferences; they have concrete failure modes under load that you must be able to reason about.

**The reference cloud-native stack** (CNCF-graduated / incubating projects, which is what CNPE tests):

- **Metrics + Alerting:** Prometheus + Alertmanager (+ Thanos/Mimir/Cortex for long-term, HA, and multi-tenant storage).
- **Logs:** Fluent Bit / Fluentd (collection) → Loki or OpenSearch (storage).
- **Traces:** OpenTelemetry (instrumentation + Collector) → Jaeger or Tempo (storage/query).
- **Visualization:** Grafana as the single pane of glass over all three.

---

## 2. Metrics & Alerting with Prometheus

### 2.1 Why pull, and what it costs you

Prometheus **scrapes** targets over HTTP (`GET /metrics`) on an interval. This is a deliberate architectural choice with real trade-offs.

| Property | **Pull** (Prometheus native) | **Push** (StatsD, InfluxDB, OTLP push) |
|---|---|---|
| Target liveness | Free — a failed scrape *is* an `up == 0` signal | Silent — a dead pusher looks identical to a healthy-but-idle one |
| Service discovery | Prometheus owns the target list (k8s SD) | Each client must know the collector address |
| Firewall direction | Prometheus → target (one direction to secure) | Target → collector (every client is an egress point) |
| Short-lived / batch jobs | **Weak** — the job may exit before a scrape → **Pushgateway** | Natural fit |
| Backpressure | Prometheus controls its own load (scrape interval) | Clients can overwhelm the collector |
| High-cardinality client-side | Bounded by scrape | Easy to flood |

The pull model's Achilles' heel is **ephemeral workloads** (CronJobs, Jobs, serverless). The answer is the **Pushgateway** — but it is a *cache*, not a gateway: metrics pushed to it persist until overwritten or deleted, so a batch job that pushes `job_last_success_timestamp_seconds` and never cleans up leaves stale series forever. Use it *only* for service-level batch metrics, never as a general push endpoint. This is a classic exam trap.

### 2.2 The metric types and the golden methods

Four core types you must instrument correctly:

- **Counter** — monotonically increasing (requests, errors). Only ever query with `rate()`/`increase()`, never the raw value.
- **Gauge** — up/down (memory, queue depth, temperature).
- **Histogram** — pre-bucketed observations (request duration). Exposes `_bucket`, `_sum`, `_count`. Percentiles computed server-side with `histogram_quantile()`. Bucket boundaries are fixed at instrumentation time.
- **Summary** — client-side quantiles. Cheaper to query, **cannot be aggregated across instances** (you cannot average a p99). Prefer histograms in distributed systems for exactly this reason.

Instrument to a **method**, not by taste:

| Method | For | Signals |
|---|---|---|
| **RED** | Request-driven services | **R**ate, **E**rrors, **D**uration |
| **USE** | Resources (nodes, disks, saturable pools) | **U**tilization, **S**aturation, **E**rrors |
| **Four Golden Signals** (Google SRE) | Any user-facing system | Latency, Traffic, Errors, Saturation |

A production alert stack layers these: RED/golden signals drive **symptom-based** alerts (page on user pain), USE drives **cause-based** dashboards (diagnose after paging). **Alert on symptoms, dashboard on causes** — paging on every high-CPU node produces alert fatigue and trains your on-call to ignore the pager.

### 2.3 Scraping in Kubernetes — the Prometheus Operator

Hand-writing `scrape_configs` in a `ConfigMap` does not scale to a multi-tenant platform: every new service means editing central config and reloading Prometheus. The **Prometheus Operator** (shipped in `kube-prometheus-stack`) replaces this with CRDs so that *teams declare their own scrape intent* next to their app:

- `Prometheus` — the desired Prometheus cluster (replicas, retention, resources).
- `ServiceMonitor` — "scrape the endpoints behind Services matching this selector."
- `PodMonitor` — same, but selects Pods directly (for Services-less workloads).
- `PrometheusRule` — recording + alerting rules.
- `Alertmanager` + `AlertmanagerConfig` — routing, per-namespace.
- `Probe` — blackbox/synthetic checks.

A `ServiceMonitor` a tenant team ships with their app:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: checkout-api
  namespace: team-payments
  labels:
    release: kube-prometheus-stack   # matches the Prometheus serviceMonitorSelector
spec:
  jobLabel: app.kubernetes.io/name
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  namespaceSelector:
    matchNames: [team-payments]
  endpoints:
    - port: http-metrics          # named port on the Service
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
      scheme: http
      honorLabels: false
      metricRelabelings:
        # Cardinality guardrail: drop a known-explosive series at ingest
        - sourceLabels: [__name__]
          regex: 'checkout_.*_user_id_bucket'
          action: drop
        # Rewrite a noisy path label into a bounded set
        - sourceLabels: [path]
          regex: '/order/[0-9]+'
          targetLabel: path
          replacement: '/order/:id'
```

The critical, easily-missed wiring: the `Prometheus` resource has a `serviceMonitorSelector`. If your `ServiceMonitor`'s labels don't match it, **you get no scrape and no error** — the target simply never appears. `kube-prometheus-stack` defaults this to `release: <helm-release-name>`.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: platform
  namespace: monitoring
spec:
  replicas: 2
  shards: 1
  retention: 6h                    # keep local retention short; ship the rest to Thanos
  retentionSize: 40GB
  serviceMonitorSelector:
    matchLabels:
      release: kube-prometheus-stack
  serviceMonitorNamespaceSelector: {}   # {} = all namespaces; tenants opt in via labels
  podMonitorSelector:
    matchLabels:
      release: kube-prometheus-stack
  ruleSelector:
    matchLabels:
      release: kube-prometheus-stack
  resources:
    requests: { memory: 4Gi, cpu: "1" }
    limits:   { memory: 8Gi }
  storage:
    volumeClaimTemplate:
      spec:
        storageClassName: fast-ssd
        resources: { requests: { storage: 100Gi } }
  enableFeatures:
    - exemplar-storage             # required to jump metric → trace
  externalLabels:
    cluster: prod-eu-west-1
    replica: $(POD_NAME)           # Thanos dedup key
  thanos:
    image: quay.io/thanos/thanos:v0.37.2
    objectStorageConfig:
      key: thanos.yaml
      name: thanos-objstore
```

### 2.4 Recording and alerting rules

**Recording rules** pre-compute expensive queries at evaluation time so dashboards and alerts read a cheap pre-aggregated series. **Alerting rules** fire when a PromQL expression is true `for` a duration.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: checkout-slo
  namespace: team-payments
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: checkout.recording
      interval: 30s
      rules:
        # Pre-aggregate the RED signals once
        - record: job:http_request_duration_seconds:rate5m
          expr: sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
        - record: job:http_requests:rate5m
          expr: sum by (job) (rate(http_requests_total[5m]))
        - record: job:http_errors:rate5m
          expr: sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))

    - name: checkout.slo.alerts
      rules:
        # --- Multi-window, multi-burn-rate SLO alert (Google SRE method) ---
        # 99.9% availability SLO -> 0.1% error budget.
        # Fast burn: 14.4x over 1h AND 5m (page immediately).
        - alert: CheckoutErrorBudgetFastBurn
          expr: |
            (
              job:http_errors:rate5m{job="checkout-api"}
              / job:http_requests:rate5m{job="checkout-api"}
            ) > (14.4 * 0.001)
            and
            (
              sum(rate(http_requests_total{job="checkout-api",code=~"5.."}[1h]))
              / sum(rate(http_requests_total{job="checkout-api"}[1h]))
            ) > (14.4 * 0.001)
          for: 2m
          labels:
            severity: critical
            team: payments
          annotations:
            summary: "Checkout burning error budget 14.4x (page)"
            description: "5m and 1h error rate both exceed the fast-burn threshold."
            runbook_url: "https://runbooks.internal/checkout/fast-burn"

        # Slow burn: 6x over 6h AND 30m (ticket, not page).
        - alert: CheckoutErrorBudgetSlowBurn
          expr: |
            (
              sum(rate(http_requests_total{job="checkout-api",code=~"5.."}[6h]))
              / sum(rate(http_requests_total{job="checkout-api"}[6h]))
            ) > (6 * 0.001)
            and
            (
              sum(rate(http_requests_total{job="checkout-api",code=~"5.."}[30m]))
              / sum(rate(http_requests_total{job="checkout-api"}[30m]))
            ) > (6 * 0.001)
          for: 15m
          labels:
            severity: warning
            team: payments
          annotations:
            summary: "Checkout slow error-budget burn (ticket)"
            runbook_url: "https://runbooks.internal/checkout/slow-burn"

        # p99 latency SLO
        - alert: CheckoutLatencyP99High
          expr: |
            histogram_quantile(0.99,
              job:http_request_duration_seconds:rate5m{job="checkout-api"}
            ) > 0.5
          for: 10m
          labels: { severity: warning, team: payments }
          annotations:
            summary: "Checkout p99 latency > 500ms for 10m"
```

**Why multi-burn-rate matters:** a single-threshold alert (`error_rate > 0.1%`) is either too sensitive (pages on brief blips) or too slow (only fires after the budget is already gone). Multi-window burn-rate alerts *page fast on catastrophic burns and open tickets on slow leaks*, spending the error budget the way the SLO intends. This is the single most important alerting pattern in the syllabus.

### 2.5 Alertmanager: routing, grouping, inhibition, silences

Prometheus **decides an alert is firing**; Alertmanager **decides who hears about it and how**. It deduplicates alerts from HA Prometheus replicas (which both fire the same alert), groups related alerts into one notification, suppresses downstream noise, and honors silences during maintenance.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Alertmanager
metadata:
  name: platform
  namespace: monitoring
spec:
  replicas: 3          # gossip cluster for HA dedup
  configSecret: alertmanager-config
---
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: monitoring
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
      slack_api_url_file: /etc/alertmanager/secrets/slack/url
    route:
      receiver: default-slack
      group_by: ['alertname', 'cluster', 'namespace']
      group_wait: 30s        # buffer to batch related alerts into one notification
      group_interval: 5m     # wait before adding new alerts to an existing group
      repeat_interval: 4h    # re-page cadence for still-firing alerts
      routes:
        - matchers: [ 'severity="critical"' ]
          receiver: pagerduty
          continue: true      # ALSO fall through to Slack
        - matchers: [ 'team="payments"' ]
          receiver: payments-slack
          group_by: ['alertname', 'namespace']
    inhibit_rules:
      # If the whole cluster is down, don't also page for every service in it.
      - source_matchers: [ 'alertname="ClusterDown", severity="critical"' ]
        target_matchers: [ 'severity=~"warning|critical"' ]
        equal: ['cluster']
    receivers:
      - name: default-slack
        slack_configs:
          - channel: '#alerts'
            send_resolved: true
      - name: payments-slack
        slack_configs:
          - channel: '#payments-oncall'
            send_resolved: true
            title: '{{ .CommonAnnotations.summary }}'
            text: >-
              {{ range .Alerts }}*{{ .Labels.severity }}* {{ .Annotations.description }}
              <{{ .Annotations.runbook_url }}|runbook>{{ end }}
      - name: pagerduty
        pagerduty_configs:
          - routing_key_file: /etc/alertmanager/secrets/pd/key
            severity: '{{ .CommonLabels.severity }}'
```

The four Alertmanager concepts, precisely:

| Concept | What it does | Failure it prevents |
|---|---|---|
| **Grouping** | Collapses N alerts sharing `group_by` labels into 1 notification | 500 pods down → 500 pages |
| **Inhibition** | A firing "parent" alert mutes "child" alerts | Node-down muting every pod-down on that node |
| **Silence** | Time-boxed mute matching labels (via UI/`amtool`) | Paging during a planned maintenance window |
| **Dedup** | HA replicas send identical alerts; gossip picks one | Double-paging from `replicas: 3` |

### 2.6 Long-term storage & multi-tenancy — Thanos vs Mimir vs Cortex

Vanilla Prometheus is **single-node, limited-retention, single-tenant**. A platform needs global query, years of retention, and hard tenant isolation. The three answers:

| | **Thanos** | **Cortex** | **Mimir** (Grafana) |
|---|---|---|---|
| Model | Sidecar ships blocks to object storage; components federate | Push-based (remote_write), microservices | Cortex fork, opinionated & tuned |
| Ingestion | Sidecar reads Prometheus TSDB | `remote_write` into ingesters | `remote_write` into ingesters |
| Storage | Object storage (S3/GCS) + Store Gateway | Object storage via ingesters | Object storage, blocks engine |
| Global query | Querier fans out to sidecars + store | Query frontend | Query frontend |
| Multi-tenancy | Weaker (external labels) | Native (`X-Scope-OrgID`) | Native, strong |
| Operational cost | Lower (bolt onto existing Prom) | High (many components) | Medium-high |
| Best for | Existing Prometheus fleets | Legacy | Greenfield multi-tenant at scale |

Rule of thumb the exam rewards: **Thanos** if you already run Prometheus and want to add global view + cheap retention with minimal disruption; **Mimir** if you are building a large multi-tenant metrics platform from scratch.

---

## 3. Logging

### 3.1 Collection architectures

| Pattern | Mechanism | Pros | Cons |
|---|---|---|---|
| **Node-level agent (DaemonSet)** | One collector per node reads `/var/log/containers/*.log` | Efficient, app-agnostic, no app change | Only captures stdout/stderr |
| **Sidecar** | A logging container in each Pod | Handles apps that log to files, per-app parsing | Resource cost × every pod |
| **Direct/library** | App ships logs itself (e.g. via SDK) | Structured at source | Couples app to logging backend |

The platform default is the **DaemonSet node-agent**, because in Kubernetes the container runtime already writes every container's stdout/stderr to the node filesystem, and it costs one agent per node instead of one per pod.

### 3.2 Fluentd vs Fluent Bit

| | **Fluentd** | **Fluent Bit** |
|---|---|---|
| Language | CRuby + C | Pure C |
| Memory footprint | ~40 MB+ | **~450 KB–few MB** |
| Plugins | ~1000, Ruby gems | ~100, built-in |
| Role | Aggregator | Edge collector (DaemonSet) |
| Throughput | High, heavier | Very high, lightweight |

Modern platform pattern: **Fluent Bit as the DaemonSet edge agent** on every node (cheap), optionally forwarding to a **Fluentd aggregation tier** for heavy routing/transform, then to storage. On resource-constrained platforms, Fluent Bit alone → Loki is common.

### 3.3 Loki vs Elasticsearch/OpenSearch — the index trade-off

This is *the* logging design decision:

| | **Loki (PLG)** | **Elasticsearch/OpenSearch (EFK)** |
|---|---|---|
| Indexing | **Labels only**, log body unindexed | **Full-text** inverted index on content |
| Storage cost | Low (object storage, compressed chunks) | High (index is often larger than data) |
| Query speed (label-filtered) | Fast | Fast |
| Query speed (arbitrary text, wide range) | Slower (brute-force scan of chunks) | Fast |
| Ingest cost | Cheap | CPU-heavy (indexing) |
| Cardinality risk | **High labels = index explosion** (same failure mode as Prometheus) | Tolerant |
| Grafana correlation | Native (same label model as Prometheus) | Via plugin |

**Loki** wins when you already have Grafana + Prometheus and query logs *by label then grep* ("show me `checkout-api` logs in `team-payments` around 14:32"). **OpenSearch** wins when you need arbitrary full-text search and analytics across huge volumes (security/SIEM, audit). Loki's hazard mirrors Prometheus: **never put unbounded values (request_id, user_id) in a Loki label** — put them in the log line and filter with `|=`.

### 3.4 Promtail / Fluent Bit → Loki, deployed

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: logging
spec:
  selector: { matchLabels: { app: fluent-bit } }
  template:
    metadata:
      labels: { app: fluent-bit }
    spec:
      serviceAccountName: fluent-bit
      tolerations:
        - operator: Exists          # run on control-plane / tainted nodes too
      containers:
        - name: fluent-bit
          image: cr.fluentbit.io/fluent/fluent-bit:3.1.9
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { memory: 128Mi }
          volumeMounts:
            - { name: varlog, mountPath: /var/log, readOnly: true }
            - { name: config, mountPath: /fluent-bit/etc/ }
      volumes:
        - { name: varlog, hostPath: { path: /var/log } }
        - { name: config, configMap: { name: fluent-bit-config } }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: logging
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         1
        Log_Level     info
        Parsers_File  parsers.conf

    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        multiline.parser  cri
        Tag               kube.*
        Mem_Buf_Limit     16MB
        Skip_Long_Lines   On

    [FILTER]
        Name                kubernetes
        Match               kube.*
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On   # let pods opt out via annotation

    # Cardinality guard: promote only bounded fields to Loki labels
    [OUTPUT]
        Name                   loki
        Match                  kube.*
        Host                   loki-gateway.logging.svc
        Port                   80
        Labels                 job=fluentbit
        Label_Keys             $kubernetes['namespace_name'],$kubernetes['pod_name'],$kubernetes['container_name']
        Line_Format            json
        Remove_Keys            kubernetes,stream
```

Note the discipline: `namespace`, `pod`, `container` become Loki *labels* (bounded); the message body (including any `request_id`) stays in the log line, searchable with LogQL `|= "request_id=abc"` but never indexed.

---

## 4. Distributed Tracing

### 4.1 Concepts

A **trace** is a DAG of **spans**; each span is a timed operation with a `trace_id`, `span_id`, `parent_span_id`, start/end, status, and attributes. The magic is **context propagation**: a service reads the incoming trace context, and passes it downstream, so spans created in different processes stitch into one trace. The standard is the **W3C Trace Context** header:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
          version   trace-id (16 bytes)      parent span-id    trace-flags (sampled)
```

If any hop drops `traceparent`, the trace breaks there — this is the #1 "why is my trace missing spans" cause. Legacy systems may use B3 (Zipkin) headers; the Collector can translate.

### 4.2 OpenTelemetry — the vendor-neutral standard

OpenTelemetry (OTel) is the CNCF project that unifies instrumentation. Key insight for platform engineers: **instrument once with the OTel SDK, export anywhere via OTLP.** You are not locked to Jaeger or Tempo. Components:

- **SDK/API + auto-instrumentation** — generates spans (and increasingly metrics/logs) in the app.
- **OTLP** — the wire protocol (gRPC :4317 / HTTP :4318).
- **Collector** — receives, processes (batch, filter, sample, enrich), and exports. Deployed two ways, usually **both**:
  - **Agent** (DaemonSet/sidecar): local, low-latency receive, adds resource attributes.
  - **Gateway** (Deployment): central, does **tail sampling**, backend fan-out, tenant routing.

### 4.3 Head vs tail sampling — the decision that defines your tracing bill

You cannot store 100% of spans at scale. *How* you drop them matters enormously:

| | **Head sampling** | **Tail sampling** |
|---|---|---|
| Decision point | At trace *start*, before outcome known | At trace *end*, after all spans collected |
| Sees the outcome? | **No** | **Yes** (can keep all errors + slow traces) |
| Where | In the SDK or agent | Gateway Collector (must buffer whole trace) |
| Cost | Cheap, stateless | Memory-heavy (buffers traces in flight) |
| Keeps the interesting traces? | Only statistically | **Yes — keep every error, slow, or rare trace** |
| Consistency across services | Needs propagated sampling flag | Centralized, consistent by construction |

The mature platform pattern: **light head sampling to protect the app, then tail sampling at the gateway to keep 100% of errors and slow traces plus a small % of the rest.** All spans of a trace *must* reach the same tail-sampling Collector instance — hence you shard by `trace_id` with a `loadbalancing` exporter in front of the tail-sampling gateway.

### 4.4 Collector: agent + tail-sampling gateway, deployed with the OTel Operator

```yaml
# Agent tier — DaemonSet on every node
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-agent
  namespace: observability
spec:
  mode: daemonset
  config:
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    processors:
      k8sattributes: {}            # enrich spans with pod/namespace/node
      resourcedetection:
        detectors: [env, kubernetes]
      batch:
        send_batch_size: 1024
        timeout: 5s
    exporters:
      # Shard by trace_id so every span of a trace lands on the same gateway pod
      loadbalancing:
        routing_key: traceID
        protocol:
          otlp: { tls: { insecure: true } }
        resolver:
          k8s:
            service: otel-gateway.observability.svc.cluster.local
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [k8sattributes, resourcedetection, batch]
          exporters: [loadbalancing]
---
# Gateway tier — Deployment doing tail sampling + backend export
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-gateway
  namespace: observability
spec:
  mode: deployment
  replicas: 3
  config:
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
    processors:
      tail_sampling:
        decision_wait: 10s          # buffer window to see the whole trace
        num_traces: 100000
        policies:
          - name: keep-errors
            type: status_code
            status_code: { status_codes: [ERROR] }
          - name: keep-slow
            type: latency
            latency: { threshold_ms: 500 }
          - name: baseline-10pct
            type: probabilistic
            probabilistic: { sampling_percentage: 10 }
      batch: {}
    exporters:
      otlp/tempo:
        endpoint: tempo-distributor.observability.svc:4317
        tls: { insecure: true }
      # Derive RED metrics FROM spans, and emit exemplars linking metric→trace
    connectors:
      spanmetrics:
        histogram: { explicit: { buckets: [10ms,50ms,100ms,250ms,500ms,1s,5s] } }
        dimensions:
          - { name: service.name }
          - { name: http.status_code }
        exemplars: { enabled: true }
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [tail_sampling, batch]
          exporters: [otlp/tempo, spanmetrics]
        metrics:
          receivers: [spanmetrics]
          exporters: [otlp/tempo]     # or prometheusremotewrite
```

The `spanmetrics` connector is a platform-engineering power move: it **generates RED metrics from trace data** and attaches **exemplars**, so a latency histogram in Grafana carries clickable links straight to the exact slow trace. That closes the metric→trace correlation loop with zero app changes.

### 4.5 Jaeger vs Tempo

| | **Jaeger** | **Tempo** (Grafana) |
|---|---|---|
| Storage | Cassandra / Elasticsearch / OpenSearch | **Object storage only** (S3/GCS) — cheap |
| Index | Full trace index (searchable by tags) | **trace_id lookup + TraceQL**; relies on metrics/logs to *find* the id |
| Cost | Higher (index DB) | Very low |
| Search model | Rich tag search out of the box | "Pivot from an exemplar/log to the trace_id" |
| Best for | Standalone trace search | Grafana-native correlated stack |

**Tempo** is cheapest because it doesn't index span contents — the workflow assumes you arrive with a `trace_id` from a metric exemplar or a log line. **Jaeger** is the pick when trace search itself must be first-class without a metrics/logs pivot.

---

## 5. Correlation — the payoff

The whole point is one investigation flow, not three tools:

1. **Alert** fires (Alertmanager: `CheckoutLatencyP99High`).
2. Dashboard latency panel shows a spike; its **exemplar** dot links to a slow **trace** (Tempo).
3. The trace shows the slow span is `payments-db`; the span's `trace_id`/`pod` **derives a Loki query** for that pod's logs at that instant.
4. Logs reveal a lock-wait. MTTR measured in minutes, not hours.

Grafana wires this with **`derivedFields`** (log → trace) and **exemplar** links (metric → trace), all keyed on `trace_id`:

```yaml
# Grafana Loki datasource: turn a trace_id in a log line into a Tempo link
jsonData:
  derivedFields:
    - name: TraceID
      matcherRegex: 'trace_id=(\w+)'
      url: '$${__value.raw}'
      datasourceUid: tempo-uid
```

The non-negotiable enabler: **propagate `trace_id` into structured logs** (via the OTel logging bridge or a log MDC), and enable `exemplar-storage` in Prometheus. Without a shared `trace_id`, correlation is manual timestamp archaeology.

---

## 6. Verification & failure diagnosis

### 6.1 Prometheus — is it scraping?

```console
$ kubectl -n team-payments get servicemonitor checkout-api
NAME           AGE
checkout-api   3m

# Are targets actually up? Query the Prometheus API through a port-forward.
$ kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
$ curl -s localhost:9090/api/v1/targets | \
    jq -r '.data.activeTargets[] | select(.labels.job=="checkout-api") | "\(.scrapeUrl)\t\(.health)\t\(.lastError)"'
http://10.244.2.17:8080/metrics   up
http://10.244.3.9:8080/metrics    down    server returned HTTP status 404 Not Found

# up{} is the ground truth of scrape health
$ curl -sG localhost:9090/api/v1/query --data-urlencode 'query=up{job="checkout-api"}' | \
    jq -r '.data.result[] | "\(.metric.instance) up=\(.value[1])"'
10.244.2.17:8080 up=1
10.244.3.9:8080  up=0
```

**Target missing entirely?** The `ServiceMonitor` labels don't match `serviceMonitorSelector`. Confirm:

```console
$ kubectl -n monitoring get prometheus platform -o jsonpath='{.spec.serviceMonitorSelector}'
{"matchLabels":{"release":"kube-prometheus-stack"}}
# ...then verify your ServiceMonitor carries that label. Silent failure if not.
```

**Validate rules before shipping** (fail closed in CI):

```console
$ promtool check rules checkout-slo.yaml
Checking checkout-slo.yaml
  SUCCESS: 3 rules found

$ promtool test rules checkout-slo_test.yaml
Unit Testing:  checkout-slo_test.yaml
  SUCCESS
```

**Cardinality — the leading cause of Prometheus OOM.** Find the offender:

```console
$ curl -s localhost:9090/api/v1/status/tsdb | \
    jq -r '.data.seriesCountByMetricName[:5][] | "\(.value)\t\(.name)"'
1841233   http_request_duration_seconds_bucket
  92310   http_requests_total
   4102   go_gc_duration_seconds
# 1.8M series on ONE metric => an unbounded label (path, user_id). Drop/relabel at scrape.
```

### 6.2 The metric endpoint itself

```console
$ kubectl -n team-payments exec deploy/checkout-api -- \
    wget -qO- localhost:8080/metrics | grep -E '^http_requests_total' | head -3
http_requests_total{code="200",method="POST",path="/checkout"} 48213
http_requests_total{code="500",method="POST",path="/checkout"} 27
http_requests_total{code="200",method="GET",path="/health"} 990122
```

### 6.3 Alertmanager

```console
$ kubectl -n monitoring exec sts/alertmanager-platform-0 -c alertmanager -- \
    amtool --alertmanager.url=http://localhost:9093 alert query severity=critical
Alertname                       Starts At            Summary
CheckoutErrorBudgetFastBurn     2026-08-07 14:12 UTC Checkout burning error budget 14.4x (page)

# Silence during a deploy window
$ amtool --alertmanager.url=http://localhost:9093 silence add \
    alertname=CheckoutLatencyP99High team=payments \
    --duration=1h --comment="deploy v2.4.1" --author="sre@corp"
b1f0c3a2-7e4d-4b9a-9c11-2f8e6a0d5c73

# Prove routing works WITHOUT waiting for a real alert
$ amtool config routes test --config.file=alertmanager.yaml \
    severity=critical team=payments
pagerduty
payments-slack
```

### 6.4 Loki / LogQL

```console
$ logcli --addr=http://loki-gateway.logging.svc query \
    '{namespace="team-payments", container="checkout-api"} |= "level=error" | json | line_format "{{.msg}}"' \
    --since=15m --limit=5
2026-08-07T14:12:03Z  db lock wait timeout on payments.orders trace_id=4bf92f35...
2026-08-07T14:12:04Z  db lock wait timeout on payments.orders trace_id=9a01ce88...

# Diagnose a label-cardinality problem in Loki
$ logcli series '{namespace="team-payments"}' --since=1h | wc -l
1
$ logcli labels --since=1h
container
namespace
pod
# GOOD: no request_id/user_id here. If you see one, your index is exploding.
```

### 6.5 Traces / OTel Collector

```console
# Is the collector healthy and receiving? Its own metrics endpoint tells you.
$ kubectl -n observability port-forward svc/otel-gateway 8888:8888 &
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver_accepted|processor_dropped|exporter_send_failed)_spans'
otelcol_receiver_accepted_spans{receiver="otlp"} 184203
otelcol_processor_dropped_spans{processor="tail_sampling"} 0
otelcol_exporter_send_failed_spans{exporter="otlp/tempo"} 0

# refused_spans climbing => backpressure; sending_queue full => backend (Tempo) is the bottleneck
$ curl -s localhost:8888/metrics | grep otelcol_exporter_queue_size
otelcol_exporter_queue_size{exporter="otlp/tempo"} 4998   # near capacity => Tempo can't keep up

# Missing spans in a trace? Confirm the header actually propagates between two hops.
$ kubectl -n team-payments exec deploy/checkout-api -- \
    curl -s -D - -o /dev/null http://payments-db-proxy:8080/health | grep -i traceparent
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
# If this header is absent at any hop, the trace breaks there.
```

### 6.6 Failure catalogue

| Symptom | Likely cause | Verify | Fix |
|---|---|---|---|
| Target never appears in Prometheus | `ServiceMonitor` label ≠ `serviceMonitorSelector` | compare labels (§6.1) | add `release:` label |
| Target `down`, `404` | wrong `path`/`port` in ServiceMonitor | curl `/metrics` (§6.2) | fix endpoint |
| Prometheus OOM / slow | cardinality explosion | `status/tsdb` (§6.1) | `metricRelabelings` drop/rewrite |
| No alerts despite firing metric | rule labels ≠ `ruleSelector`; or Alertmanager route mismatch | `amtool config routes test` | fix labels/route |
| Double pages | HA replicas not gossip-clustered | check `replicas` + mesh | one Alertmanager cluster |
| Loki queries slow / index huge | high-cardinality label | `logcli labels` (§6.4) | demote label into log line |
| Trace has gaps | `traceparent` dropped at a hop | curl header check (§6.5) | fix instrumentation/proxy |
| Spans dropped at gateway | tail-sampling buffer / Tempo backpressure | `queue_size`, `send_failed` (§6.5) | scale gateway, raise `num_traces`, scale Tempo |
| Metric spike has no exemplar link | `exemplar-storage` off, or spanmetrics exemplars disabled | check Prometheus features | enable exemplar storage + connector |

---

## 7. References

- **CNPE Curriculum** — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- **Prometheus — Overview, data model, storage** — https://prometheus.io/docs/introduction/overview/ · https://prometheus.io/docs/concepts/data_model/ · https://prometheus.io/docs/prometheus/latest/storage/
- **Prometheus — Alerting & recording rules** — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/ · https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- **Alertmanager** — https://prometheus.io/docs/alerting/latest/alertmanager/ · https://prometheus.io/docs/alerting/latest/configuration/
- **Prometheus Operator (CRD API)** — https://prometheus-operator.dev/docs/ · https://github.com/prometheus-operator/kube-prometheus
- **Google SRE — Golden Signals & SLO burn-rate alerting** — https://sre.google/sre-book/monitoring-distributed-systems/ · https://sre.google/workbook/alerting-on-slos/
- **Thanos** — https://thanos.io/tip/thanos/getting-started.md/ · **Grafana Mimir** — https://grafana.com/docs/mimir/latest/ · **Cortex** — https://cortexmetrics.io/docs/
- **Fluentd** — https://docs.fluentd.org/ · **Fluent Bit** — https://docs.fluentbit.io/manual
- **Grafana Loki & LogQL** — https://grafana.com/docs/loki/latest/ · https://grafana.com/docs/loki/latest/query/
- **OpenSearch (logging/observability)** — https://opensearch.org/docs/latest/
- **OpenTelemetry — Collector, sampling, OTLP** — https://opentelemetry.io/docs/collector/ · https://opentelemetry.io/docs/concepts/sampling/ · https://opentelemetry.io/docs/specs/otlp/
- **OpenTelemetry Operator** — https://github.com/open-telemetry/opentelemetry-operator
- **W3C Trace Context** — https://www.w3.org/TR/trace-context/
- **Jaeger** — https://www.jaegertracing.io/docs/latest/ · **Grafana Tempo & TraceQL** — https://grafana.com/docs/tempo/latest/ · https://grafana.com/docs/tempo/latest/traceql/
- **Grafana exemplars & derived fields (correlation)** — https://grafana.com/docs/grafana/latest/fundamentals/exemplars/ · https://grafana.com/docs/grafana/latest/datasources/loki/#derived-fields
- **CNCF Observability Whitepaper** — https://github.com/cncf/tag-observability/blob/main/whitepaper.md