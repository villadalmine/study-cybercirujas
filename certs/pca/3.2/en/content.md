# 3.2 Understand Logs and Events

> **Domain:** Observability Concepts · **Exam weight:** 3 · **Certification:** Prometheus Certified Associate (PCA)
>
> Prometheus is a *metrics* system. It does **not** store, index, or query logs, and it treats Kubernetes Events only indirectly. Yet the PCA curriculum requires you to *understand* logs and events because a metric alone answers **"how much / how often"** — it never answers **"which request, on which pod, with what error string, in what order."** This topic is about knowing precisely where the metrics pillar ends, what logs and events add, and how the two planes are correlated in a production observability stack.

---

## 1. Motivation and the production architectural problem

### 1.1 The core distinction a metric cannot cross

A Prometheus metric is a **numeric sample** aggregated over a label set and sampled on a fixed scrape interval. That design buys you cheap, bounded-cardinality, long-retention time series — but it structurally throws away two things:

1. **Per-event detail.** `http_requests_total{code="500"}` tells you 47 requests failed in the last minute. It cannot tell you *which* 47, the stack trace, the trace ID, or the offending payload.
2. **Ordering and discrete state transitions.** A counter that goes `5 → 6` loses the fact that "at 14:03:22.114Z pod `checkout-7f9` was `OOMKilled` after `BackOff` restart #4."

Logs recover (1); events recover (2). This is the classic **three (or four) pillars** framing: *metrics, logs, traces* — with **events** frequently called out as a distinct fourth signal because they are discrete, self-describing, and typically low-volume-but-high-value.

```
                    aggregated / numeric                discrete / textual
                 ┌──────────────────────────┐   ┌──────────────────────────────┐
   sampled  ───► │  METRICS (Prometheus)     │   │  TRACES (Tempo/Jaeger)       │
                 │  "how much, how often"    │   │  "where the time went"       │
                 └──────────────────────────┘   └──────────────────────────────┘
   per-event ──► ┌──────────────────────────┐   ┌──────────────────────────────┐
                 │  EVENTS (k8s API, CloudEvents) │  LOGS (Loki/ELK/OTel)        │
                 │  "what changed, in order" │   │  "what exactly happened"     │
                 └──────────────────────────┘   └──────────────────────────────┘
```

### 1.2 The RED/USE gap in production

You are paged: `ALERTS{alertname="HighErrorRate", service="checkout"}` fires. Prometheus got you to the **symptom** and to the **service** (via labels), but the root cause — `pq: too many connections`, or `OOMKilled` — lives in logs and events. A mature stack is built so that a single alert carries you across the planes:

- **Metric** (Prometheus): error rate crossed threshold → alert with `namespace`, `pod`, `service` labels.
- **Event** (Kubernetes): `kubectl get events` shows `Warning OOMKilling` / `BackOff` on that pod.
- **Log** (Loki): the *same label set* (`namespace`, `pod`) pivots you straight to the stderr line and the trace ID.
- **Trace** (Tempo): the trace ID from the log opens the exact failing span.

The architectural requirement is **shared label conventions** so a human (or a Grafana "drilldown") can move between planes without re-searching. Loki was explicitly designed to make logs "feel like Prometheus" precisely to enable this pivot.

### 1.3 Kubernetes Events are ephemeral by design — the silent-loss problem

Kubernetes `Event` objects are stored in etcd like any API object, but the API server **garbage-collects them after `--event-ttl` (default `1h0m0s`)**. This is the single most common production surprise: the post-mortem starts two hours after the incident and `kubectl get events` shows *nothing*. Events must be **exported off-cluster** to a durable sink (Loki, Elasticsearch, a webhook, an event bus) if they are to survive an incident review. That export is an explicit architectural decision, not a default.

---

## 2. Technical comparisons and trade-offs

### 2.1 The four telemetry signals

| Dimension | Metrics | Logs | Events (k8s) | Traces |
|---|---|---|---|---|
| Shape | Numeric time series | Timestamped text/JSON lines | Structured API objects | Spans in a DAG |
| Primary question | How much / how often | What exactly happened | What changed, in order | Where latency went |
| Cardinality tolerance | **Low** (labels bounded) | High (indexed on labels only, in Loki) | Low volume | Medium |
| Storage cost / GB signal | Lowest | Highest (raw text) | Low | High |
| Retention (typical) | Weeks–months | Days–weeks | **≈1h in-cluster** (must export) | Days |
| Query language | PromQL | LogQL / Lucene / KQL | `kubectl`, field selectors | TraceQL |
| Cardinality failure mode | TSDB blow-up (churn) | Index blow-up (if content indexed) | etcd pressure (event storms) | Sampling loss |
| CNCF/eco tool | Prometheus | Loki, Fluent Bit, ELK, OTel | kube-event-exporter, k8s API | Tempo, Jaeger |

**Key exam-level insight:** the *same* enemy — **high cardinality** — hurts each signal differently. In Prometheus it explodes the number of active series; in a log system that indexes content (ELK) it explodes the inverted index; in Loki it is deliberately avoided by indexing **only labels** and keeping the log body unindexed and compressed.

### 2.2 Log-aggregation architectures

| Property | Loki | Elasticsearch (EFK/ELK) |
|---|---|---|
| Index scope | **Labels only** (metadata) | Full-text inverted index over content |
| Storage backend | Object store (S3/GCS) + small index | Local/replicated shards on SSD |
| Cost profile | Low (no content index) | High (index + hot storage) |
| Query model | Label filter → **grep-like** scan of chunks (LogQL) | Rich full-text, aggregations |
| Best when | High volume, label-driven access, Prometheus shop | Ad-hoc full-text search, security/SIEM |
| Cardinality risk | High-cardinality **labels** kill it (put IDs in the *line*, not labels) | Content cardinality tolerated but expensive |
| Prometheus affinity | Native (same labels, Grafana pivot) | Requires correlation glue |

### 2.3 Turning logs/events into metrics — where the planes meet

Sometimes you need a *number* out of a log or event (e.g. "rate of `panic:` lines"). Three canonical patterns:

| Tool / mechanism | Input | Output | When to use |
|---|---|---|---|
| **Loki LogQL metric queries** (`rate(... [5m])`, `unwrap`) | Log stream | Prometheus-style vector | Ad-hoc; already running Loki |
| **google/mtail** | Log file lines (regex programs) | `/metrics` endpoint | Extract metrics at the node, no log backend needed |
| **grok_exporter** | Log lines (grok patterns) | `/metrics` endpoint | Legacy/unstructured logs, Logstash-style patterns |
| **kube-state-metrics** | k8s API objects (incl. `kube_pod_status_reason`) | `/metrics` | Object *state* as metrics (not raw events) |
| **kubernetes-event-exporter → Prometheus** | k8s Events | metrics/labels via sink | Alert on event *reasons* (e.g. `OOMKilling`) |

> **Anti-pattern:** parsing high-cardinality identifiers (request IDs, user IDs) out of logs into Prometheus labels. This recreates the cardinality explosion Prometheus is designed to avoid. Keep those in the log body / trace, keep only bounded dimensions (`reason`, `code`, `service`) as metric labels.

---

## 3. Complete manifests and infrastructure

### 3.1 Loki (single-binary) + Promtail DaemonSet — the Prometheus-adjacent log plane

`loki-config.yaml` (mounted into the Loki pod):

```yaml
# loki-config.yaml — single-binary Loki suitable for a small/medium cluster.
# Source of options: https://grafana.com/docs/loki/latest/configure/
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:            # swap for S3/GCS in production (see storage_config)
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  # Guardrails that keep Loki healthy: bound label cardinality and stream churn.
  ingestion_rate_mb: 8
  ingestion_burst_size_mb: 16
  max_label_names_per_series: 15
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  max_streams_per_user: 10000

# Loki can run Prometheus-style recording/alerting rules over LogQL.
ruler:
  storage:
    type: local
    local:
      directory: /loki/rules
  rule_path: /loki/rules-temp
  alertmanager_url: http://alertmanager.monitoring.svc:9093
  enable_alertmanager_v2: true
```

`promtail.yaml` — the node agent that discovers pods and attaches **Prometheus-compatible labels**:

```yaml
# promtail.yaml — Promtail scrapes container logs and relabels using the
# Kubernetes SD, mirroring Prometheus relabel semantics so labels line up.
# https://grafana.com/docs/loki/latest/send-data/promtail/configuration/
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /run/promtail/positions.yaml   # resume offset after restart (idempotency)

clients:
  - url: http://loki.monitoring.svc:3100/loki/api/v1/push

scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    pipeline_stages:
      - cri: {}                            # parse CRI log format (time, stream, flags, content)
      - match:
          selector: '{app="checkout"}'
          stages:
            - json:                        # extract structured fields from JSON logs
                expressions:
                  level: level
                  trace_id: trace_id
            - labels:
                level:                     # low-cardinality -> safe as a label
            # NOTE: trace_id is intentionally NOT promoted to a label
            #       (high cardinality); it stays queryable in the line body.
    relabel_configs:
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: app
      - source_labels: [__meta_kubernetes_pod_container_name]
        target_label: container
      - source_labels: [__meta_kubernetes_pod_node_name]
        target_label: node
      - source_labels: [__meta_kubernetes_pod_uid, __meta_kubernetes_pod_container_name]
        target_label: __path__
        separator: /
        replacement: /var/log/pods/*$1/*.log
```

DaemonSet + RBAC for Promtail:

```yaml
# promtail-daemonset.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: promtail
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: promtail
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/proxy", "services", "endpoints", "pods"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: promtail
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: promtail
subjects:
  - kind: ServiceAccount
    name: promtail
    namespace: monitoring
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  namespace: monitoring
  labels: { app: promtail }
spec:
  selector:
    matchLabels: { app: promtail }
  template:
    metadata:
      labels: { app: promtail }
    spec:
      serviceAccountName: promtail
      tolerations:
        - effect: NoSchedule
          operator: Exists            # run on control-plane nodes too
      containers:
        - name: promtail
          image: grafana/promtail:3.0.0
          args: ["-config.file=/etc/promtail/promtail.yaml"]
          ports:
            - { name: http-metrics, containerPort: 9080 }
          volumeMounts:
            - { name: config,    mountPath: /etc/promtail }
            - { name: run,       mountPath: /run/promtail }
            - { name: pods,      mountPath: /var/log/pods, readOnly: true }
            - { name: containers,mountPath: /var/lib/docker/containers, readOnly: true }
      volumes:
        - name: config
          configMap: { name: promtail }
        - name: run
          hostPath: { path: /run/promtail }
        - name: pods
          hostPath: { path: /var/log/pods }
        - name: containers
          hostPath: { path: /var/lib/docker/containers }
```

### 3.2 kubernetes-event-exporter — make ephemeral Events durable and alertable

```yaml
# event-exporter-config.yaml
# https://github.com/resmoio/kubernetes-event-exporter
logLevel: info
logFormat: json
route:
  routes:
    - match:
        - receiver: "loki"          # everything -> Loki for durability + correlation
    - match:
        - type: "Warning"
          receiver: "alert-webhook" # only Warnings -> paging/webhook path
receivers:
  - name: "loki"
    loki:
      streamLabels:
        source: kubernetes-event-exporter
      url: "http://loki.monitoring.svc:3100/loki/api/v1/push"
  - name: "alert-webhook"
    webhook:
      endpoint: "http://alert-router.monitoring.svc/events"
      headers:
        Content-Type: application/json
```

```yaml
# event-exporter-deploy.yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: event-exporter, namespace: monitoring }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: event-exporter }
rules:
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["events.k8s.io"]      # the modern events API group
    resources: ["events"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: event-exporter }
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: event-exporter
subjects:
  - kind: ServiceAccount
    name: event-exporter
    namespace: monitoring
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: event-exporter, namespace: monitoring }
spec:
  replicas: 1                          # single writer avoids duplicate exports
  selector: { matchLabels: { app: event-exporter } }
  template:
    metadata: { labels: { app: event-exporter } }
    spec:
      serviceAccountName: event-exporter
      containers:
        - name: event-exporter
          image: ghcr.io/resmoio/kubernetes-event-exporter:v1.7
          args: ["-conf=/data/config.yaml"]
          volumeMounts:
            - { name: cfg, mountPath: /data }
      volumes:
        - name: cfg
          configMap: { name: event-exporter-cfg }
```

### 3.3 Logs → metrics with mtail (node-level, no log backend required)

`http_errors.mtail`:

```
# http_errors.mtail — compiled program that emits Prometheus metrics
# https://google.github.io/mtail/Programming-Guide.html
counter http_requests_total by code
counter panic_lines_total

/HTTP\/1\.[01]" (?P<code>\d{3})/ {
  http_requests_total[$code]++
}

/panic:/ {
  panic_lines_total++
}
```

The mtail process then exposes `/metrics` on `:3903`, scraped by Prometheus exactly like any exporter — the log plane feeds the metrics plane without ever indexing the raw text.

### 3.4 Alerting on Kubernetes Events surfaced as metrics

`kube-state-metrics` exposes state that mirrors the events you care about, e.g. `kube_pod_container_status_last_terminated_reason`. A Prometheus rule turns "OOMKilled" (an *event*) into an *alert*:

```yaml
# oom-alert.rules.yaml
groups:
  - name: pod-lifecycle
    rules:
      - alert: PodOOMKilled
        expr: |
          kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
        for: 0m
        labels: { severity: warning }
        annotations:
          summary: "OOMKilled: {{ $labels.namespace }}/{{ $labels.pod }}"
          description: "Container {{ $labels.container }} was OOMKilled. Pivot to logs: {namespace=\"{{ $labels.namespace }}\", pod=\"{{ $labels.pod }}\"}"
```

---

## 4. CLI commands and real terminal output

### 4.1 Kubernetes Events — the discrete state-change plane

```console
$ kubectl get events -n shop --sort-by='.lastTimestamp'
LAST SEEN   TYPE      REASON              OBJECT                       MESSAGE
3m12s       Normal    Scheduled           pod/checkout-7f9c5-abcde     Successfully assigned shop/checkout-7f9c5-abcde to node-3
3m10s       Normal    Pulled              pod/checkout-7f9c5-abcde     Container image "checkout:1.4.2" already present on machine
3m10s       Normal    Created             pod/checkout-7f9c5-abcde     Created container checkout
3m09s       Normal    Started             pod/checkout-7f9c5-abcde     Started container checkout
90s         Warning   Unhealthy           pod/checkout-7f9c5-abcde     Readiness probe failed: HTTP probe failed with statuscode: 503
61s         Warning   OOMKilling          pod/checkout-7f9c5-abcde     Memory cgroup out of memory: Killed process 12841 (checkout)
58s         Warning   BackOff             pod/checkout-7f9c5-abcde     Back-off restarting failed container checkout in pod checkout-7f9c5-abcde
```

The modern subcommand (`kubectl events`, GA since 1.26) adds watch and richer filtering:

```console
$ kubectl events -n shop --for pod/checkout-7f9c5-abcde --types=Warning
LAST SEEN   TYPE      REASON       OBJECT                       MESSAGE
90s         Warning   Unhealthy    Pod/checkout-7f9c5-abcde     Readiness probe failed: statuscode 503
61s         Warning   OOMKilling   Pod/checkout-7f9c5-abcde     Memory cgroup out of memory: Killed process 12841 (checkout)

$ kubectl get event -n shop --field-selector type=Warning,reason=OOMKilling -o json \
    | jq -r '.items[] | "\(.count)x  \(.involvedObject.name)  \(.message)"'
4x  checkout-7f9c5-abcde  Memory cgroup out of memory: Killed process 12841 (checkout)
```

Note `count: 4` — Kubernetes **aggregates repeated identical events** into a single object with a counter and `firstTimestamp`/`lastTimestamp`, which is why an event storm does not always mean thousands of objects.

The Events section of `describe` is where most operators actually read them:

```console
$ kubectl describe pod checkout-7f9c5-abcde -n shop | sed -n '/^Events:/,$p'
Events:
  Type     Reason      Age                From               Message
  ----     ------      ----               ----               -------
  Normal   Scheduled   3m                 default-scheduler  Successfully assigned shop/checkout-7f9c5-abcde to node-3
  Warning  Unhealthy   90s (x3 over 2m)   kubelet            Readiness probe failed: statuscode 503
  Warning  OOMKilling  61s                kubelet            Memory cgroup out of memory: Killed process 12841
  Warning  BackOff     11s (x5 over 58s)  kubelet            Back-off restarting failed container
```

### 4.2 Container logs

```console
$ kubectl logs checkout-7f9c5-abcde -n shop --previous --tail=5
{"ts":"2026-08-08T14:03:21.980Z","level":"info","msg":"serving on :8080","trace_id":"9af1..."}
{"ts":"2026-08-08T14:03:22.101Z","level":"error","msg":"db pool exhausted","trace_id":"c73e...","code":500}
fatal error: runtime: out of memory
panic: cannot allocate 512 MiB

$ journalctl -u kubelet --since "5 min ago" -o cat | grep -i oom
memory cgroup out of memory: Killed process 12841 (checkout) total-vm:1048576kB
```

`--previous` reads the **crashed** container's logs — essential when a pod is CrashLooping, because the current container's log is empty or from the new attempt.

### 4.3 Loki via LogQL (`logcli`) — the metrics-shaped log query

```console
$ export LOKI_ADDR=http://loki.monitoring.svc:3100

# Raw filter: last error lines for the checkout pod
$ logcli query '{namespace="shop", app="checkout"} |= "error" | json | level="error"' --limit=3
2026-08-08T14:03:22Z {app="checkout", namespace="shop", pod="checkout-7f9c5-abcde"} db pool exhausted
2026-08-08T14:01:07Z {app="checkout", namespace="shop", pod="checkout-7f9c5-fghij"} db pool exhausted
2026-08-08T13:58:44Z {app="checkout", namespace="shop", pod="checkout-7f9c5-fghij"} timeout waiting for conn

# Metric query: error-line rate per pod — a Prometheus-style vector, from logs
$ logcli query 'sum by (pod) (rate({namespace="shop", app="checkout"} |= "error" [5m]))'
{pod="checkout-7f9c5-abcde"}  0.40
{pod="checkout-7f9c5-fghij"}  0.13
```

That second query is the crux of "understand logs and events": **LogQL deliberately mirrors PromQL** (`rate(...[5m])`, `sum by (...)`) so a log stream can be reduced to a metric on demand, and so the mental model transfers directly.

### 4.4 Confirming the metrics-plane view of the same incident

```console
$ curl -s 'http://prometheus:9090/api/v1/query' \
    --data-urlencode 'query=kube_pod_container_status_last_terminated_reason{reason="OOMKilled",namespace="shop"}' \
    | jq -r '.data.result[] | "\(.metric.pod)  \(.value[1])"'
checkout-7f9c5-abcde  1
```

One incident, three planes, one label set (`namespace="shop"`, `pod="checkout-7f9c5-abcde"`): Prometheus said *it OOMKilled*, the Event said *when and which PID*, the log said *why (db pool exhausted → OOM)*.

---

## 5. Verification and failure-diagnosis guide

### 5.1 Verify the pipeline end to end

```console
# 1. Promtail is tailing and pushing (targets should be 'ready', not 'error')
$ kubectl exec -n monitoring ds/promtail -- \
    wget -qO- localhost:9080/metrics | grep -E 'promtail_(sent_bytes_total|dropped)'
promtail_sent_bytes_total{host="node-3"} 4.19e+07
promtail_dropped_bytes_total{reason="line_too_long"} 0

# 2. Loki is ingesting (rate should be non-zero under load)
$ curl -s localhost:3100/metrics | grep loki_distributor_lines_received_total
loki_distributor_lines_received_total{tenant="fake"} 918273

# 3. Labels actually exist (proves relabeling worked)
$ logcli labels
app  container  filename  job  namespace  node  pod  level

# 4. Event exporter is watching (informer synced, no auth errors)
$ kubectl logs -n monitoring deploy/event-exporter | grep -Ei 'started|forbidden'
{"level":"info","msg":"Starting EventWatcher"}
```

### 5.2 Failure catalogue

| Symptom | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| Loki OOM / `too many streams` | High-cardinality **label** (e.g. `trace_id` promoted to a label) | `logcli series '{}'` shows explosive stream count | Move the ID into the log body; drop the `labels` stage |
| `kubectl get events` empty during post-mortem | `--event-ttl` GC'd them (~1h) | Events older than TTL are gone | Export via kubernetes-event-exporter to Loki/ES |
| Promtail sends nothing | Wrong `__path__` / hostPath, or CRI vs docker format | `promtail_targets_active_total == 0`; check `positions.yaml` | Fix mount, set correct pipeline (`cri:` vs `docker:`) |
| Log rate metric is flat/zero in LogQL | Query time range shorter than `[range]`; or label filter too tight | Widen selector, verify with raw query first | Correct label matchers; check step vs range |
| Event storm, etcd pressure | Controller reconcile loop emitting Warnings | `kubectl get events --sort-by=.count`, watch `count` climb | Fix the controller; events already aggregate by identity |
| Prometheus label churn / TSDB blow-up | Log-derived IDs pushed into metric labels (mtail/grok) | `topk(10, count by (__name__)({...}))`; check active series | Restrict extracted metric labels to bounded dimensions |
| Duplicate exported events | >1 event-exporter replica | Two writers to the sink | Keep `replicas: 1` (leader election if HA needed) |
| Missing logs from a crashing pod | Reading current, not previous container | `kubectl logs <pod> --previous` | Use `--previous`; rely on Loki for durability |

### 5.3 Cardinality self-check (the one habit that prevents most outages)

```console
# Loki: how many streams does a label set produce? (want tens–hundreds, not thousands)
$ logcli series '{namespace="shop"}' | wc -l
214

# Prometheus: which metric drives your active-series count?
$ curl -s 'http://prometheus:9090/api/v1/status/tsdb' \
    | jq '.data.seriesCountByMetricName[0:3]'
[
  {"name":"http_request_duration_seconds_bucket","value":48210},
  {"name":"kube_pod_container_status_last_terminated_reason","value":312}
]
```

If either number grows without a matching growth in real entities (pods, services), a high-cardinality value has leaked into a label — the shared failure mode across all three planes.

---

## 6. References

- CNCF Curriculum (PCA source of truth): https://github.com/cncf/curriculum — `PCA_Curriculum.pdf`
- Prometheus — Overview & data model: https://prometheus.io/docs/introduction/overview/ · https://prometheus.io/docs/concepts/data_model/
- Prometheus — Alerting / Alertmanager: https://prometheus.io/docs/alerting/latest/alertmanager/
- Grafana Loki — Documentation: https://grafana.com/docs/loki/latest/
- LogQL (log & metric queries): https://grafana.com/docs/loki/latest/query/
- Promtail configuration: https://grafana.com/docs/loki/latest/send-data/promtail/configuration/
- Loki configuration reference: https://grafana.com/docs/loki/latest/configure/
- Kubernetes — Events API (`events.k8s.io/v1`): https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/
- Kubernetes — `kube-apiserver` flags (`--event-ttl`, default `1h0m0s`): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes — `kubectl events` / logging architecture: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#events · https://kubernetes.io/docs/concepts/cluster-administration/logging/
- kube-state-metrics: https://github.com/kubernetes/kube-state-metrics
- kubernetes-event-exporter (maintained fork): https://github.com/resmoio/kubernetes-event-exporter
- google/mtail — log-to-metric extraction: https://github.com/google/mtail
- grok_exporter: https://github.com/fstab/grok_exporter
- Fluent Bit / Fluentd: https://docs.fluentbit.io/ · https://docs.fluentd.org/
- OpenTelemetry — Logs specification: https://opentelemetry.io/docs/specs/otel/logs/
- CloudEvents specification (CNCF): https://cloudevents.io/