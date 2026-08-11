# Topic 3.3 — Scaling the OpenTelemetry Collector

> Domain 3: *The OpenTelemetry Collector* · Weight ≈ 5.2%
> Certification: **OTCA — OpenTelemetry Certified Associate**

---

## 1. Motivation: the production architecture problem

A single Collector process is trivial to run and dangerous to depend on. The moment your telemetry volume grows past one node's headroom — or the moment you introduce a *stateful* processing step — the naïve answer ("run more replicas behind a Service") silently corrupts your data. Scaling the Collector is therefore not a capacity problem; it is a **data-affinity problem**.

Two forces drive the design:

1. **Throughput and blast radius.** Applications should not block on telemetry export, and a Collector restart must not take an application down with it. This pushes processing *off* the workload (the **agent** pattern) and concentrates heavy work in a shared, independently-scalable tier (the **gateway** pattern).

2. **Stateful pipelines break under naïve horizontal scaling.** Tail-based sampling, `spanmetrics`, `servicegraph`, and `groupbytrace` all need **every span of a given trace (or every span of a given service edge) on the same instance**. Put a plain round-robin load balancer in front of a tail-sampling gateway and you shard a single trace across N replicas: each replica sees a fragment, each makes a partial decision, and the "keep on error" policy fails to fire because the erroring span landed on a different pod than the root. The telemetry looks healthy and is quietly wrong — the worst failure mode in observability.

The core SRE insight: **classify every component as stateless or stateful before you choose a scaling strategy.** Stateless components scale like any web service. Stateful components require *consistent routing* by a key (usually `traceID`) so related data converges on one instance.

---

## 2. Deployment patterns and where state lives

### 2.1 Agent vs Gateway

| Dimension | Agent (DaemonSet / sidecar) | Gateway (standalone Deployment/StatefulSet) |
|---|---|---|
| Topology | One per node (DaemonSet) or per pod (sidecar) | Small central pool, N replicas |
| Primary job | Offload app fast; resource detection; `k8sattributes`; host metrics | Tail sampling, filtering, PII scrubbing, aggregation, egress/auth |
| Scaling axis | Scales *with the cluster* (nodes/pods) — no explicit HPA | Scales independently via HPA/KEDA |
| State | Should stay **stateless** | Often **stateful** (sampling/aggregation) |
| Failure blast radius | One node/pod | Shared — needs replicas + queues |
| Network | Local hop (lowest latency, no cross-AZ cost) | Fan-in; watch cross-AZ egress cost |

The production standard is **both**: a stateless agent layer feeding a scalable gateway. Push CPU-cheap, node-local work (batching, k8s metadata enrichment, resource detection) to the agent; reserve the gateway for work that needs a global view or privileged egress.

### 2.2 Stateless vs stateful components (the decision table)

| Component | Type | Scales by round-robin? | Routing requirement |
|---|---|---|---|
| `batch`, `resource`, `attributes`, `filter`, `transform`, `memory_limiter` | Stateless | ✅ Yes | none |
| `tail_sampling` | **Stateful** | ❌ No | all spans of a trace → same instance (`traceID`) |
| `groupbytrace` | **Stateful** | ❌ No | `traceID` |
| `spanmetrics` connector | **Stateful (aggregating)** | ❌ No | consistent per `service`/`traceID`; else series double-count |
| `servicegraph` connector | **Stateful** | ❌ No | both edge spans (client+server) → same instance (`traceID`) |
| `groupbyattrs` | Stateless (per-batch) | ✅ Yes | none |

Anything in the "stateful" rows forces the two-tier `loadbalancing` design in §3.

---

## 3. Full manifests

### 3.1 Agent — DaemonSet (stateless, node-local offload)

```yaml
# otel-agent-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-agent
  namespace: observability
  labels: { app: otel-agent }
spec:
  selector:
    matchLabels: { app: otel-agent }
  template:
    metadata:
      labels: { app: otel-agent }
    spec:
      serviceAccountName: otel-agent          # RBAC for k8sattributes below
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.110.0
          args: ["--config=/conf/agent.yaml"]
          env:
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef: { fieldPath: spec.nodeName }
          resources:
            requests: { cpu: "100m", memory: "192Mi" }
            limits:   { cpu: "500m", memory: "512Mi" }   # limit == memory_limiter anchor
          ports:
            - { name: otlp-grpc, containerPort: 4317, protocol: TCP }
            - { name: metrics,   containerPort: 8888, protocol: TCP }
          volumeMounts:
            - { name: conf, mountPath: /conf }
      volumes:
        - name: conf
          configMap: { name: otel-agent-conf }
```

```yaml
# otel-agent-conf.yaml (ConfigMap data key: agent.yaml)
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }

processors:
  # ORDER MATTERS: memory_limiter FIRST, batch LAST (before export).
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80          # relative to the container memory LIMIT
    spike_limit_percentage: 25
  k8sattributes:                  # enrich here (node-local), not on the gateway
    passthrough: false
    extract:
      metadata: [k8s.pod.name, k8s.namespace.name, k8s.deployment.name, k8s.node.name]
  batch:
    send_batch_size: 8192
    send_batch_max_size: 10000
    timeout: 5s

exporters:
  otlp:
    endpoint: otel-gateway-lb.observability.svc.cluster.local:4317
    tls: { insecure: true }
    sending_queue: { enabled: true, num_consumers: 4, queue_size: 5000 }
    retry_on_failure: { enabled: true, initial_interval: 5s, max_interval: 30s }

service:
  telemetry:
    metrics: { level: detailed, address: 0.0.0.0:8888 }
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, k8sattributes, batch]
      exporters:  [otlp]
```

RBAC required for `k8sattributes`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: otel-agent }
rules:
  - apiGroups: [""]
    resources: [pods, namespaces, nodes]
    verbs: [get, list, watch]
  - apiGroups: ["apps"]
    resources: [replicasets, deployments]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: otel-agent }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: otel-agent }
subjects:
  - { kind: ServiceAccount, name: otel-agent, namespace: observability }
```

### 3.2 The two-tier gateway — the canonical scalable design

The only correct way to horizontally scale tail sampling: a **stateless Tier-1** that routes by `traceID` using the `loadbalancing` exporter, feeding a **stateful Tier-2** pool that owns the sampling decision.

```
agents ──▶  Tier-1 (loadbalancing, stateless, HPA on CPU)
                │  consistent-hash by traceID
                ▼
           Tier-2 (tail_sampling, stateful, FIXED replicas)  ──▶  backend (OTLP/Tempo/…)
```

**Tier-1 — load-balancing router (stateless):**

```yaml
# gateway-lb-conf.yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }

processors:
  memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }

exporters:
  loadbalancing:
    routing_key: traceID                 # traceID | service | metric | resource | streamID
    protocol:
      otlp:
        tls: { insecure: true }
        timeout: 3s
    resolver:
      k8s:                               # watches EndpointSlices → auto-detects Tier-2 scale changes
        service: otel-sampling.observability.svc.cluster.local
        ports: [4317]

service:
  telemetry: { metrics: { address: 0.0.0.0:8888 } }
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter]
      exporters:  [loadbalancing]
```

**Tier-2 — tail-sampling pool (stateful, headless Service):**

```yaml
# gateway-sampling-conf.yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }

processors:
  memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }
  tail_sampling:
    decision_wait: 15s                   # must exceed max inter-span gap of a trace
    num_traces: 200000                   # in-memory trace buffer; sized for peak
    expected_new_traces_per_sec: 2000
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
  batch: { send_batch_size: 8192, timeout: 5s }

exporters:
  otlp/backend:
    endpoint: tempo-distributor.tracing.svc.cluster.local:4317
    tls: { insecure: true }
    sending_queue: { enabled: true, queue_size: 10000 }
    retry_on_failure: { enabled: true }

service:
  telemetry: { metrics: { level: detailed, address: 0.0.0.0:8888 } }
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, tail_sampling, batch]
      exporters:  [otlp/backend]
```

The headless Service that the `k8s` resolver watches (its `EndpointSlice` is the source of truth for consistent hashing — this is why Tier-2 scale events are picked up automatically):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: otel-sampling
  namespace: observability
spec:
  clusterIP: None                        # headless → per-pod endpoints for the resolver
  selector: { app: otel-sampling }
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: 4317, protocol: TCP }
```

### 3.3 Autoscaling with the OpenTelemetry Operator (CRD + HPA)

Prefer the Operator's `OpenTelemetryCollector` CRD — it wires the HPA for you and adds the **Target Allocator** for metrics scaling (§3.4).

```yaml
# tier1-lb-collector.yaml — STATELESS tier: safe to autoscale
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-lb
  namespace: observability
spec:
  mode: deployment
  image: otel/opentelemetry-collector-contrib:0.110.0
  autoscaler:
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilization: 70
    behavior:
      scaleDown:
        stabilizationWindowSeconds: 300   # damp flapping on bursty trace volume
  resources:
    requests: { cpu: "500m", memory: "512Mi" }
    limits:   { cpu: "2",    memory: "2Gi" }
  config:                                 # inline the Tier-1 config from §3.2
    receivers:  { otlp: { protocols: { grpc: { endpoint: 0.0.0.0:4317 } } } }
    processors: { memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 } }
    exporters:
      loadbalancing:
        routing_key: traceID
        protocol: { otlp: { tls: { insecure: true } } }
        resolver: { k8s: { service: otel-sampling.observability.svc.cluster.local, ports: [4317] } }
    service:
      pipelines:
        traces: { receivers: [otlp], processors: [memory_limiter], exporters: [loadbalancing] }
```

> ⚠️ **Do NOT put an HPA on the Tier-2 sampling pool without care.** When a sampling pod is added/removed, the Tier-1 consistent hash re-maps a slice of the `traceID` space to different backends. In-flight traces straddling the rebalance are split and get partial decisions. Mitigations: keep Tier-2 replicas **fixed** (or scale rarely with long stabilization windows), size `decision_wait` generously, and always use `allocationStrategy: consistent-hashing` so only ~`1/N` of keys move per scale event rather than the whole ring.

### 3.4 Scaling Prometheus scraping — the Target Allocator

A different scaling problem: one Collector cannot scrape thousands of Prometheus targets. The **Target Allocator** shards `ServiceMonitor`/`PodMonitor` targets across a `StatefulSet` of Collectors using consistent hashing, so adding a replica redistributes scrape load automatically.

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-metrics
  namespace: observability
spec:
  mode: statefulset                       # stable identity for per-replica target assignment
  replicas: 3
  targetAllocator:
    enabled: true
    allocationStrategy: consistent-hashing
    prometheusCR:
      enabled: true                       # discover ServiceMonitor/PodMonitor CRs
      scrapeInterval: 30s
  config:
    receivers:
      prometheus:
        config:
          scrape_configs: []              # Target Allocator injects the sharded targets
        target_allocator:
          endpoint: http://otel-metrics-targetallocator:80
          interval: 30s
          collector_id: ${env:POD_NAME}
    processors: { batch: {} }
    exporters:
      otlphttp/prom:
        endpoint: http://prometheus.monitoring.svc:9090/api/v1/otlp
    service:
      pipelines:
        metrics: { receivers: [prometheus], processors: [batch], exporters: [otlphttp/prom] }
```

---

## 4. CLI and expected terminal output

Deploy and confirm the topology:

```console
$ kubectl -n observability get deploy,ds,hpa
NAME                              READY   UP-TO-DATE   AVAILABLE
deployment.apps/otel-lb-collector 2/2     2            2
deployment.apps/otel-sampling     3/3     3            3

NAME                        DESIRED   CURRENT   READY   NODE SELECTOR
daemonset.apps/otel-agent   6         6         6       <none>

NAME                                            REFERENCE                     TARGETS   MINPODS MAXPODS REPLICAS
horizontalpodautoscaler/otel-lb-collector-hpa  Deployment/otel-lb-collector  62%/70%   2       10      2
```

Watch the Tier-1 pool scale under load:

```console
$ kubectl -n observability get hpa otel-lb-collector-hpa -w
NAME                     TARGETS    MINPODS  MAXPODS  REPLICAS
otel-lb-collector-hpa    62%/70%    2        10       2
otel-lb-collector-hpa    88%/70%    2        10       2
otel-lb-collector-hpa    91%/70%    2        10       4      # scale-up fired
otel-lb-collector-hpa    58%/70%    2        10       4
```

Confirm the `loadbalancing` resolver actually sees every Tier-2 endpoint (scrape the internal telemetry on `:8888`):

```console
$ kubectl -n observability port-forward deploy/otel-lb-collector 8888:8888 >/dev/null 2>&1 &
$ curl -s localhost:8888/metrics | grep -E 'loadbalancer_num_backends|loadbalancer_backend_latency_count'
otelcol_loadbalancer_num_backends{...} 3
otelcol_loadbalancer_backend_latency_count{endpoint="10.42.1.7:4317",...} 41233
otelcol_loadbalancer_backend_latency_count{endpoint="10.42.2.9:4317",...} 40817
otelcol_loadbalancer_backend_latency_count{endpoint="10.42.3.4:4317",...} 41902
```

`num_backends = 3` and near-equal per-endpoint counts prove the ring is balanced. If you see `num_backends 1` while three sampling pods run, the resolver is misconfigured (wrong Service DNS or a `clusterIP` Service instead of headless) and **all traces are pinned to one pod** — your sampling tier is not scaling at all.

Inspect the sampling decisions on a Tier-2 pod:

```console
$ kubectl -n observability port-forward otel-sampling-0 8888:8888 >/dev/null 2>&1 &
$ curl -s localhost:8888/metrics | grep tail_sampling
otelcol_processor_tail_sampling_count_traces_sampled{policy="keep-errors",sampled="true"} 1204
otelcol_processor_tail_sampling_count_traces_sampled{policy="baseline-10pct",sampled="true"} 9871
otelcol_processor_tail_sampling_global_count_traces_sampled 210443
otelcol_processor_tail_sampling_sampling_trace_dropped_too_early 0
otelcol_processor_tail_sampling_new_trace_id_received 210443
```

Live decision spans via the `zpages` extension:

```console
$ kubectl -n observability port-forward otel-sampling-0 55679:55679 >/dev/null 2>&1 &
$ curl -s "localhost:55679/debug/tracez?ztype=1&tracename=tail_sampling" | head
# HTML table of recent sampling-decision latencies and error samples
```

---

## 5. Verification & failure diagnosis

Key internal-telemetry metrics (`:8888/metrics`) and what they mean when they move:

| Symptom (metric) | Likely cause | Fix |
|---|---|---|
| `otelcol_receiver_refused_spans` rising | `memory_limiter` applying backpressure — heap near limit | Raise memory limit **and** `check_interval`/replicas; lower `send_batch_size`; add `sending_queue` persistence |
| `otelcol_exporter_send_failed_spans` rising | Downstream (backend/Tier-2) down or slow | Check `retry_on_failure`, backend health, TLS; watch `otelcol_exporter_queue_size` vs `_queue_capacity` |
| `otelcol_exporter_queue_size ≈ _queue_capacity` | Export slower than ingest; queue saturating → drops next | Increase `num_consumers`, `queue_size`; scale Tier-2; enable `file_storage` persistent queue |
| `otelcol_loadbalancer_num_backends` < replica count | Resolver misconfig / non-headless Service | Use headless Service + correct FQDN; `k8s` resolver needs EndpointSlice RBAC |
| Traces incomplete / "keep-errors" not firing | Round-robin instead of `traceID` routing; spans of a trace split | Insert Tier-1 `loadbalancing` with `routing_key: traceID` |
| `tail_sampling_trace_dropped_too_early > 0` | `decision_wait` shorter than trace span gap, or `num_traces` buffer too small | Raise `decision_wait`; increase `num_traces`; add sampling replicas |
| Duplicate/doubled `spanmetrics` series after scale-out | Aggregating connector split across instances | Route by `traceID`/`service` to one instance, or sum in the backend with correct temporality |
| `process_runtime_total_alloc_bytes` climbing to OOM despite `memory_limiter` | `memory_limiter` placed after a buffering processor, or limit set above container limit | Put `memory_limiter` **first**; anchor `limit_percentage` to the container memory *limit* |

Fast triage playbook:

```console
# 1. Is the Collector even healthy? (health_check extension on :13133)
$ curl -s localhost:13133/ | jq .status
"Server available"

# 2. Ingest vs egress balance
$ curl -s localhost:8888/metrics | grep -E 'accepted_spans|sent_spans|refused_spans|send_failed'

# 3. Queue pressure (drops imminent when size→capacity)
$ curl -s localhost:8888/metrics | grep -E 'exporter_queue_(size|capacity)'

# 4. Confirm memory_limiter is armed, not thrashing
$ curl -s localhost:8888/metrics | grep -E 'process_runtime_total_(alloc|sys)_bytes'
```

**The golden rule of Collector scaling verification:** counts must reconcile end-to-end. `receiver_accepted` at the agents should equal `receiver_accepted` at Tier-1, and Tier-2 `tail_sampling_new_trace_id_received` summed across the pool should track distinct traces — not diverge by a factor of the replica count. A divergence proportional to replica count is the signature of broken `traceID` affinity.

---

## 6. References

- OpenTelemetry — *Scaling the Collector*: https://opentelemetry.io/docs/collector/scaling/
- OpenTelemetry — *Gateway deployment*: https://opentelemetry.io/docs/collector/deployment/gateway/
- OpenTelemetry — *Agent deployment*: https://opentelemetry.io/docs/collector/deployment/agent/
- `loadbalancingexporter` (contrib): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- `tailsamplingprocessor` (contrib): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- `spanmetricsconnector` (contrib): https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/spanmetricsconnector/README.md
- `servicegraphconnector` (contrib): https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/servicegraphconnector/README.md
- `memorylimiterprocessor`: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
- `batchprocessor`: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md
- OpenTelemetry Operator — *Target Allocator*: https://opentelemetry.io/docs/platforms/kubernetes/operator/target-allocator/
- OpenTelemetry Operator (CRD, autoscaler): https://github.com/open-telemetry/opentelemetry-operator
- Collector *internal telemetry*: https://opentelemetry.io/docs/collector/internal-telemetry/
- CNCF OTCA curriculum: https://github.com/cncf/curriculum