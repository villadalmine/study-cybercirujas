# 2.7 — Agents

**OTCA · Domain 2 (The OpenTelemetry Collector) · Exam weight ≈ 6.57%**

> Scope note: In OpenTelemetry terminology an *agent* is not a distinct binary. It is a **deployment role** of the same Collector binary (`otelcol` / `otelcol-contrib` / a custom OCB build). A Collector is an *agent* when it runs **on the same host or in the same Pod as the workload it collects from**, as the first hop off the instrumented process. The complementary role is the *gateway* (a standalone, horizontally scaled service that fans in from many agents). This topic is about the agent role: why it exists, how it is deployed, and how it is operated in production.

---

## 1. The production problem: why an agent tier exists

An instrumented application has an SDK exporter that must ship spans, metrics, and logs somewhere. The naive design is **SDK → backend directly**. In production this fails on five distinct axes, and each failure is what the agent tier is designed to absorb.

1. **Egress latency bleeds into the request path.** A batch span processor still has to establish/maintain TLS to a remote backend that may be cross-AZ or cross-region. Any backpressure (429s, slow ACKs) propagates into the application process — memory grows in the export queue, GC pressure rises, and in pathological cases the app OOMs *because of its telemetry*. An agent on `localhost` (sidecar) or on the node's IP (DaemonSet) turns a remote, high-variance hop into a sub-millisecond loopback/host-local hop. The app offloads and forgets.

2. **Connection fan-in melts the backend and the gateway.** 10,000 Pods each opening a persistent gRPC stream to a backend is 10,000 connections to authenticate, keep alive, and load-balance. The agent tier collapses this: each node's agent multiplexes all local Pods into a small, stable number of upstream connections.

3. **Telemetry is under-contextualized at the source.** The SDK knows `service.name` and `service.version`, but it does **not** reliably know `k8s.pod.name`, `k8s.node.name`, `cloud.availability_zone`, `host.id`, or the container's image digest. The agent — because it sits on the node with access to the Kubernetes API and cloud metadata endpoints (IMDS) — enriches every signal with `k8sattributes` and `resourcedetection`. Doing this centrally in a gateway is possible for k8s attributes but impossible for host-scoped facts, which only exist at the node.

4. **Host- and node-scoped signals have no other collector.** Host CPU/memory/disk/network (`hostmetrics`), kubelet & cAdvisor stats (`kubeletstats`), and container stdout/stderr log files under `/var/log/pods` (`filelog`) are **node-local resources**. Only a per-node agent (DaemonSet) can read them. This is the single most common reason an agent tier is mandatory rather than optional.

5. **No local durability = data loss on any hiccup.** The SDK's buffer is small and volatile. An agent provides a persistent sending queue (`file_storage` extension), retry with backoff, and a `memory_limiter` that sheds load predictably instead of crashing.

**The reference architecture** is therefore two-tier:

```
┌─ node A ─────────────┐     ┌─ node B ─────────────┐
│  app pods            │     │  app pods            │
│    │ OTLP localhost/ │     │    │                 │
│    ▼ hostIP          │     │    ▼                 │
│  [Collector AGENT]   │     │  [Collector AGENT]   │
│   otlp,hostmetrics,  │     │   otlp,hostmetrics,  │
│   kubeletstats,      │     │   kubeletstats,      │
│   filelog            │     │   filelog            │
└────────┬─────────────┘     └────────┬─────────────┘
         │  OTLP (batched, few conns) │
         └───────────────┬────────────┘
                         ▼
              [Collector GATEWAY]  (Deployment, HPA)
               tail_sampling, aggregation, redaction
                         │
                         ▼
                   backend(s): Jaeger/Tempo/Prometheus/OTLP SaaS
```

The agent's job is **fast local offload + host enrichment + host-scoped collection**. Heavy, stateful, whole-population decisions (tail-based sampling, cardinality control, cross-service aggregation) belong in the gateway, never in the agent — an agent only ever sees the traffic of its own node, so it cannot make population-wide decisions correctly.

---

## 2. Deployment topologies & trade-offs

### 2.1 Agent vs Gateway (the two Collector roles)

| Dimension | **Agent** | **Gateway** |
|---|---|---|
| Kubernetes primitive | `DaemonSet` (1/node) or sidecar container | `Deployment` + `Service` (+ HPA) |
| Placement | Same host / same Pod as workload | Standalone, anywhere in cluster |
| Scope of visibility | One node (or one Pod) | All agents that target it |
| Primary duties | Local offload, `resourcedetection`, `k8sattributes`, host/kubelet/log collection | `tail_sampling`, aggregation, PII redaction, backend fan-out, load-balancing |
| Tail-based sampling | ❌ Incorrect (partial trace view) | ✅ Correct (needs full trace) |
| Blast radius of a bad config | One node's data | The whole pipeline |
| Scales with | Node count (automatic via DaemonSet) | Traffic volume (HPA on CPU/queue) |
| Upstream connections | Few (agent→gateway) | Managed pool (gateway→backend) |

### 2.2 Agent form factors

| | **DaemonSet agent** | **Sidecar agent** | **No agent (SDK→gateway/backend)** |
|---|---|---|---|
| Instances | 1 per node | 1 per Pod | 0 |
| Resource overhead | Amortized across all Pods on the node | Multiplied by Pod count (highest) | None |
| Blast/tenant isolation | Shared per node | Perfect per-Pod isolation | N/A |
| Host metrics / node logs / kubelet | ✅ Only this form can | ❌ | ❌ |
| Reachability from app | `status.hostIP` + `hostPort`, or node-local Service | `localhost` (shared Pod netns) | Remote Service DNS |
| Failure coupling to app | Independent Pod lifecycle | Dies/restarts with the Pod; blocks Pod start if not `restartPolicy: Always` init-style | None |
| Config rollout | Per-node, one DaemonSet | Per-workload; requires Pod restart / re-injection | Central |
| Best for | Cluster-wide baseline: host + k8s + app telemetry | Strict multi-tenant isolation, per-team pipelines, serverless-ish latency | Small/dev, or when a gateway is genuinely enough |

**Rule of thumb:** DaemonSet agent is the default in Kubernetes because it is the *only* form that can collect host, kubelet, and node-log signals, and its cost amortizes. Add sidecars only where per-Pod isolation or per-tenant pipelines justify the multiplied overhead.

### 2.3 How the app finds the DaemonSet agent

Because a DaemonSet Pod is per-node, the app must reach **its own node's** agent, not a random one. Three techniques, in order of preference:

| Technique | How | Trade-off |
|---|---|---|
| **Downward API `status.hostIP` + `hostPort`** | App reads node IP, sends to `http://$(NODE_IP):4318`; agent binds `hostPort: 4318` | Standard, explicit; requires a free hostPort and `NET` privileges on the node port |
| **`internalTrafficPolicy: Local` Service** | A ClusterIP Service over the DaemonSet with `internalTrafficPolicy: Local` routes only to the node-local endpoint | Cleaner DNS name; needs k8s ≥1.22 GA |
| **`hostNetwork: true`** | Agent shares node netns; app uses `NODE_IP` | Simplest routing, but consumes node ports and weakens isolation |

---

## 3. Complete, syntactically valid manifests

Two equivalent paths are shown: **(A)** the raw Kubernetes objects (what the Operator generates under the hood — know these for the exam), and **(B)** the OpenTelemetry Operator CRD (what you use in practice).

### 3.1 Path A — Raw DaemonSet agent (full stack: RBAC + ConfigMap + DaemonSet)

**3.1.1 ServiceAccount + RBAC** (required by `k8sattributes` and `kubeletstats`):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-agent
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-agent
rules:
  # k8sattributes processor: enrich telemetry with Pod/Namespace/workload metadata
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  # kubeletstats receiver: read the node's kubelet /stats/summary via the API proxy path
  - apiGroups: [""]
    resources: ["nodes/stats", "nodes/proxy"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-agent
subjects:
  - kind: ServiceAccount
    name: otel-agent
    namespace: observability
roleRef:
  kind: ClusterRole
  name: otel-agent
  apiGroup: rbac.authorization.k8s.io
```

**3.1.2 ConfigMap — the agent's Collector configuration** (the heart of the topic):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-agent-conf
  namespace: observability
data:
  otel-agent-config.yaml: |
    receivers:
      # Local offload point for every SDK on this node.
      otlp:
        protocols:
          grpc:
            endpoint: ${env:MY_POD_IP}:4317
          http:
            endpoint: ${env:MY_POD_IP}:4318
      # Host-scoped metrics — ONLY an agent can produce these.
      hostmetrics:
        collection_interval: 15s
        root_path: /hostfs
        scrapers:
          cpu: {}
          load: {}
          memory: {}
          disk: {}
          filesystem:
            exclude_mount_points:
              mount_points: ["/var/lib/kubelet/*", "/proc", "/sys"]
              match_type: regexp
          network: {}
          paging: {}
      # Kubelet + cAdvisor stats for this node's Pods/containers.
      kubeletstats:
        collection_interval: 20s
        auth_type: serviceAccount
        endpoint: https://${env:K8S_NODE_NAME}:10250
        insecure_skip_verify: true
        metric_groups: [container, pod, node, volume]
      # Container stdout/stderr from the node's log directory.
      filelog:
        include: [/var/log/pods/*/*/*.log]
        exclude: [/var/log/pods/observability_otel-agent-*/*/*.log]
        start_at: end
        include_file_path: true
        operators:
          - type: container
            id: container-parser

    processors:
      # ALWAYS first in every pipeline — bounds RAM and sheds load deterministically.
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      # Enrich with node/cloud facts available only at the host.
      resourcedetection:
        detectors: [env, system, eks, ec2, gcp, azure]
        timeout: 5s
        override: false
      # Enrich with Kubernetes metadata; correlate by source IP.
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        filter:
          node_from_env_var: K8S_NODE_NAME   # only watch THIS node's Pods → less API load
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.deployment.name
            - k8s.node.name
            - k8s.container.name
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
          - sources:
              - from: connection
      # Batch LAST — after enrichment, before export.
      batch:
        send_batch_size: 8192
        send_batch_max_size: 10000
        timeout: 5s

    exporters:
      # Ship to the gateway, not the backend. Durable queue + retry.
      otlp:
        endpoint: otel-gateway.observability.svc.cluster.local:4317
        tls:
          insecure: true
        sending_queue:
          enabled: true
          num_consumers: 10
          queue_size: 5000
          storage: file_storage   # survive restarts
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s

    extensions:
      health_check:
        endpoint: ${env:MY_POD_IP}:13133
      pprof:
        endpoint: ${env:MY_POD_IP}:1777
      zpages:
        endpoint: ${env:MY_POD_IP}:55679
      file_storage:
        directory: /var/lib/otelcol/queue
        timeout: 1s

    service:
      extensions: [health_check, pprof, zpages, file_storage]
      telemetry:
        metrics:
          level: detailed
          address: ${env:MY_POD_IP}:8888
        logs:
          level: info
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp]
        metrics:
          receivers: [otlp, hostmetrics, kubeletstats]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp]
        logs:
          receivers: [otlp, filelog]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp]
```

**3.1.3 The DaemonSet itself** (env wiring, host volume mounts, `hostPort`):

```yaml
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
      serviceAccountName: otel-agent
      # Tolerate control-plane taints so host metrics cover every node.
      tolerations:
        - operator: Exists
      containers:
        - name: otel-agent
          image: otel/opentelemetry-collector-contrib:0.112.0
          args: ["--config=/conf/otel-agent-config.yaml"]
          securityContext:
            runAsUser: 0            # required to read /var/log/pods and /hostfs
          env:
            - name: K8S_NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: MY_POD_IP
              valueFrom: { fieldRef: { fieldPath: status.podIP } }
          ports:
            - { name: otlp-grpc, containerPort: 4317, hostPort: 4317, protocol: TCP }
            - { name: otlp-http, containerPort: 4318, hostPort: 4318, protocol: TCP }
            - { name: metrics,   containerPort: 8888, protocol: TCP }
          livenessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 10
          readinessProbe:
            httpGet: { path: /, port: 13133 }
          resources:
            requests: { cpu: 100m, memory: 200Mi }
            limits:   { cpu: 500m, memory: 500Mi }   # memory_limiter's 80% is derived from this
          volumeMounts:
            - { name: config,   mountPath: /conf }
            - { name: hostfs,   mountPath: /hostfs, readOnly: true, mountPropagation: HostToContainer }
            - { name: varlogpods, mountPath: /var/log/pods, readOnly: true }
            - { name: queue,    mountPath: /var/lib/otelcol/queue }
      volumes:
        - name: config
          configMap: { name: otel-agent-conf }
        - name: hostfs
          hostPath: { path: / }
        - name: varlogpods
          hostPath: { path: /var/log/pods }
        - name: queue
          hostPath: { path: /var/lib/otelcol/queue, type: DirectoryOrCreate }
```

**3.1.4 App side — how a workload targets its node-local agent** (Downward API):

```yaml
# excerpt of an application Deployment's pod spec
env:
  - name: NODE_IP
    valueFrom: { fieldRef: { fieldPath: status.hostIP } }
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://$(NODE_IP):4318"
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "http/protobuf"
  - name: OTEL_SERVICE_NAME
    value: "checkout"
```

### 3.2 Path B — OpenTelemetry Operator (CRDs)

The Operator collapses all of §3.1 into one object. Same agent, declaratively:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: agent
  namespace: observability
spec:
  mode: daemonset          # <-- the "agent" role
  image: otel/opentelemetry-collector-contrib:0.112.0
  serviceAccount: otel-agent
  hostNetwork: false
  env:
    - name: K8S_NODE_NAME
      valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
  volumeMounts:
    - { name: hostfs, mountPath: /hostfs, readOnly: true, mountPropagation: HostToContainer }
    - { name: varlogpods, mountPath: /var/log/pods, readOnly: true }
  volumes:
    - { name: hostfs, hostPath: { path: / } }
    - { name: varlogpods, hostPath: { path: /var/log/pods } }
  config:
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
      hostmetrics:
        root_path: /hostfs
        scrapers: { cpu: {}, memory: {}, filesystem: {}, network: {}, load: {} }
      kubeletstats:
        auth_type: serviceAccount
        endpoint: https://${env:K8S_NODE_NAME}:10250
        insecure_skip_verify: true
    processors:
      memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }
      k8sattributes:
        filter: { node_from_env_var: K8S_NODE_NAME }
      batch: {}
    exporters:
      otlp:
        endpoint: otel-gateway-collector.observability.svc:4317
        tls: { insecure: true }
    service:
      pipelines:
        traces:  { receivers: [otlp], processors: [memory_limiter, k8sattributes, batch], exporters: [otlp] }
        metrics: { receivers: [otlp, hostmetrics, kubeletstats], processors: [memory_limiter, k8sattributes, batch], exporters: [otlp] }
```

**Sidecar agent via the Operator** — a separate `OpenTelemetryCollector` with `mode: sidecar`, injected by annotation:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: sidecar
  namespace: team-payments
spec:
  mode: sidecar
  config:
    receivers:
      otlp: { protocols: { grpc: { endpoint: localhost:4317 }, http: { endpoint: localhost:4318 } } }
    processors: { batch: {} }
    exporters:
      otlp: { endpoint: otel-gateway-collector.observability.svc:4317, tls: { insecure: true } }
    service:
      pipelines:
        traces: { receivers: [otlp], processors: [batch], exporters: [otlp] }
---
# Injection is opt-in per Pod:
apiVersion: apps/v1
kind: Deployment
metadata: { name: payments }
spec:
  template:
    metadata:
      annotations:
        sidecar.opentelemetry.io/inject: "team-payments/sidecar"
    spec:
      containers:
        - name: app
          image: payments:1.4.0
          # App exports to localhost:4318 — the injected sidecar shares the netns.
```

---

## 4. CLI & terminal

**Validate config before it ever reaches the cluster** (the free, offline check):

```console
$ docker run --rm -v "$PWD/otel-agent-config.yaml:/c.yaml" \
    otel/opentelemetry-collector-contrib:0.112.0 validate --config=/c.yaml
$ echo $?
0
```

A broken pipeline is caught here, not at runtime:

```console
$ otelcol-contrib validate --config=/c.yaml
Error: failed to build pipelines: pipeline "traces": references processor "k8sattribute" which is not configured
exit status 1
```

**Deploy and observe the agent DaemonSet:**

```console
$ kubectl apply -f rbac.yaml -f configmap.yaml -f daemonset.yaml
serviceaccount/otel-agent created
clusterrole.rbac.authorization.k8s.io/otel-agent created
clusterrolebinding.rbac.authorization.k8s.io/otel-agent created
configmap/otel-agent-conf created
daemonset.apps/otel-agent created

$ kubectl -n observability rollout status ds/otel-agent
Waiting for daemon set "otel-agent" rollout: 2 of 3 updated pods are available...
daemon set "otel-agent" successfully rolled out

$ kubectl -n observability get ds otel-agent
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
otel-agent   3         3         3       3            3           <none>          47s

$ kubectl -n observability get pods -o wide -l app=otel-agent
NAME               READY   STATUS    RESTARTS   AGE   IP           NODE
otel-agent-4f9q2   1/1     Running   0          51s   10.244.1.7   node-1
otel-agent-b2xzl   1/1     Running   0          51s   10.244.2.3   node-2
otel-agent-tk8mn   1/1     Running   0          51s   10.244.3.9   node-3
```

**Confirm the pipeline built** (startup log is the ground truth):

```console
$ kubectl -n observability logs otel-agent-4f9q2 | grep -E "Everything is ready|pipeline"
2026-08-10T14:22:07.114Z  info  service@v0.112.0/service.go:261  Everything is ready. Begin running and processing data.
2026-08-10T14:22:07.109Z  info  Starting receivers... {"pipeline": "metrics/hostmetrics"}
```

---

## 5. Verification & failure diagnosis

The agent exposes three diagnostic surfaces. Learn all three.

| Surface | Extension / port | What it answers |
|---|---|---|
| **Health** | `health_check` :13133 | Is the collector up and its pipelines running? (drives probes) |
| **Live pipeline** | `zpages` :55679 (`/debug/tracez`, `/debug/pipelinez`) | What is flowing right now, per component |
| **Self-metrics** | internal telemetry :8888 (Prometheus) | Accepted vs refused vs dropped vs sent, queue depth, RSS |
| **Profiling** | `pprof` :1777 | CPU/heap profiles when the agent itself misbehaves |

**5.1 Health & liveness:**

```console
$ kubectl -n observability exec otel-agent-4f9q2 -- \
    wget -qO- http://localhost:13133/
{"status":"Server available","upSince":"2026-08-10T14:22:07Z","uptime":"6m41s"}
```

**5.2 The four numbers that explain every data-loss incident.** Port-forward :8888 and read the counters:

```console
$ kubectl -n observability port-forward otel-agent-4f9q2 8888:8888 &
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|processor|exporter)'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 154820
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 0
otelcol_processor_dropped_spans{processor="memory_limiter"} 0
otelcol_exporter_sent_spans{exporter="otlp"} 154820
otelcol_exporter_send_failed_spans{exporter="otlp"} 0
otelcol_exporter_queue_size{exporter="otlp"} 3
otelcol_exporter_queue_capacity{exporter="otlp"} 5000
otelcol_process_memory_rss 148176896
```

Read them as a flow equation — **accepted − refused − dropped ≈ sent**. Any imbalance localizes the fault:

| Symptom in :8888 metrics | Root cause | Fix |
|---|---|---|
| `receiver_refused_spans` climbing | `memory_limiter` is rejecting at the door (soft limit hit) → backpressure to SDK | Raise Pod memory limit; lower ingest; add gateway capacity |
| `processor_dropped_spans{processor="memory_limiter"}` > 0 | Hard limit hit; data discarded to save the process | Same as above; check for a cardinality/batch explosion |
| `exporter_send_failed_spans` climbing | Agent → gateway path broken | See 5.3 |
| `exporter_queue_size` → `queue_capacity` | Gateway can't keep up; queue saturating, drops imminent | Scale gateway (HPA); increase `queue_size`; enable `file_storage` |
| `process_memory_rss` near limit + refusals | Under-provisioned agent | Bump `resources.limits.memory` |

**5.3 "Traces disappear between agent and gateway."** The canonical agent failure. Walk it:

```console
$ kubectl -n observability logs otel-agent-4f9q2 | grep -i "export"
2026-08-10T14:31:02.550Z  warn  exporterhelper/queue_sender.go:120  Exporting failed. Will retry.
  {"error": "rpc error: code = Unavailable desc = connection error: desc = \"transport: Error while dialing:
   dial tcp 10.96.0.42:4317: connect: connection refused\"", "interval": "8.6s"}

# Is the gateway even resolvable / up?
$ kubectl -n observability get svc otel-gateway
NAME           TYPE        CLUSTER-IP     PORT(S)             AGE
otel-gateway   ClusterIP   10.96.0.42     4317/TCP,4318/TCP   3h

$ kubectl -n observability get endpoints otel-gateway
NAME           ENDPOINTS   AGE
otel-gateway   <none>      3h          # <-- no ready backends: gateway Pods are down/unready
```

Empty `ENDPOINTS` is the smoking gun: the Service exists but no gateway Pod is Ready, so every agent export is refused. Fix the gateway (or its readiness probe); the agent's `retry_on_failure` + `file_storage` queue will drain the backlog once endpoints appear — *if* `max_elapsed_time` hasn't already expired (data past that window is dropped, and you'll see it in `exporter_send_failed_spans`).

**5.4 "Host metrics / kubelet stats are missing."** Almost always RBAC or a missing host mount:

```console
$ kubectl -n observability logs otel-agent-4f9q2 | grep -i kubeletstats
2026-08-10T14:22:10.880Z  error  scraperhelper/scrapercontroller.go  Error scraping metrics
  {"error": "Get \"https://node-1:10250/stats/summary\": Unauthorized", "scraper": "kubeletstats"}

# Prove the ServiceAccount can reach the kubelet stats path:
$ kubectl auth can-i get nodes/stats --as=system:serviceaccount:observability:otel-agent
no          # <-- ClusterRole is missing nodes/stats; add it (see §3.1.1)
```

For `hostmetrics` showing container-scoped rather than node-scoped values, verify `root_path: /hostfs` **and** the `hostfs` hostPath mount are both present — one without the other silently reports the container's view.

**5.5 Live component inspection with zpages:**

```console
$ kubectl -n observability port-forward otel-agent-4f9q2 55679:55679 &
$ curl -s localhost:55679/debug/pipelinez | sed 's/<[^>]*>//g' | grep -A2 traces
Pipeline traces
  MutatesData: true
  Receivers: [otlp]  Processors: [memory_limiter k8sattributes resourcedetection batch]  Exporters: [otlp]
```

---

## 6. References

- OpenTelemetry — Collector *Deployment* (agent vs gateway roles): https://opentelemetry.io/docs/collector/deployment/
- OpenTelemetry — Collector *Deployment › Agent*: https://opentelemetry.io/docs/collector/deployment/agent/
- OpenTelemetry — Collector *Deployment › Gateway*: https://opentelemetry.io/docs/collector/deployment/gateway/
- OpenTelemetry — Collector configuration (receivers/processors/exporters/extensions/service): https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry — `memory_limiter` processor: https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/memorylimiterprocessor
- OpenTelemetry — `k8sattributes` processor (incl. RBAC): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/k8sattributesprocessor
- OpenTelemetry — `resourcedetection` processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/resourcedetectionprocessor
- OpenTelemetry — `hostmetrics` receiver: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/hostmetricsreceiver
- OpenTelemetry — `kubeletstats` receiver: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/kubeletstatsreceiver
- OpenTelemetry — `filelog` receiver: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/filelogreceiver
- OpenTelemetry — Collector internal telemetry / self-observability: https://opentelemetry.io/docs/collector/internal-telemetry/
- OpenTelemetry — `health_check`, `pprof`, `zpages`, `file_storage` extensions: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension
- OpenTelemetry Operator — `OpenTelemetryCollector` CRD & sidecar injection: https://github.com/open-telemetry/opentelemetry-operator
- OpenTelemetry — Kubernetes Collector deployment patterns: https://opentelemetry.io/docs/platforms/kubernetes/collector/
- OTLP exporter environment variables (`OTEL_EXPORTER_OTLP_ENDPOINT`, `_PROTOCOL`): https://opentelemetry.io/docs/specs/otel/protocol/exporter/
- CNCF — OTCA Curriculum: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf