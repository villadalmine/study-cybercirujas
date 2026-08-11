# 3.2 Deployment — The OpenTelemetry Collector in Production

> Domain 3: The OpenTelemetry Collector · Topic 3.2 · Exam weight ≈ 5.2%
> Level: SRE / Platform Architect — internal mechanics, trade-offs, full manifests, diagnostics.

---

## 1. Motivation: the architectural problem

The naïve observability topology is **SDK → backend**: every instrumented process opens a connection straight to Jaeger, Prometheus, Tempo, or a vendor endpoint. It works on a laptop and collapses in a fleet. The failure modes are structural, not incidental:

- **Backend coupling.** Endpoint URLs, auth tokens, sampling policy, and protocol dialect are baked into every workload. Rotating a credential or swapping a vendor becomes a fleet-wide redeploy. The telemetry destination is a deployment-time decision when it should be an operational one.
- **No buffering or back-pressure isolation.** When the backend is slow or down, the exporter's retry queue lives *inside the application process*. A telemetry outage becomes an application memory-pressure event. There is no bulkhead.
- **Egress and cardinality amplification.** N pods each hold long-lived gRPC streams to the backend, each emitting un-batched, un-filtered, high-cardinality data. Cross-AZ/cross-region egress is billed per byte, and the backend sees N× the connection count it needs.
- **Credential sprawl.** Every pod holds backend write credentials. The blast radius of a leaked token is the entire fleet.
- **No place to enrich or redact.** k8s metadata (`pod.name`, `node`, `deployment`), tenant routing, PII scrubbing, and tail-based sampling require a *stateful, centralized* vantage point that a per-process SDK cannot provide.

The **Collector** is the answer: a vendor-neutral **telemetry control plane** — a pipeline of `receivers → processors/connectors → exporters` — that decouples *what produces* telemetry from *what stores* it. Instrument once against OTLP; change destinations, sampling, and enrichment in the Collector without touching a single workload.

**Topic 3.2 is about *where you run that Collector*** — the deployment patterns, the distributions you ship, the Kubernetes topologies, and how you verify and scale them.

---

## 2. Deployment patterns compared

OpenTelemetry defines three canonical patterns. They are not mutually exclusive — production usually **layers agent + gateway**.

| Pattern | Where it runs | Cardinality of Collectors | Adds latency hop? | Primary purpose | Main risk |
|---|---|---|---|---|---|
| **No Collector** | Nowhere — SDK exports direct | 0 | No | Prototyping, serverless with no host access | All coupling/credential problems of §1 |
| **Agent — sidecar** | One container **per pod** | = pod count | No (localhost) | Per-workload isolation, per-tenant config, guaranteed local buffer | Highest overhead; resource cost scales with pods |
| **Agent — DaemonSet** | One pod **per node** | = node count | No (node-local) | Host metrics, log tailing (`filelog`), `kubeletstats`, offload batching from apps | Node-local blast radius; noisy-neighbor across pods on the node |
| **Gateway** | Standalone `Deployment`/`StatefulSet` behind a `Service` | Independent (HPA-scaled) | Yes (network hop) | Central egress, tail sampling, tenant routing, credential concentration, rate limiting | It is a chokepoint; needs HA + autoscaling |

### The layered production topology

```
┌────────────┐    OTLP     ┌────────────────┐    OTLP     ┌──────────────────┐   remote
│ App + SDK  │ ──localhost─▶│ Agent          │ ──cluster──▶│ Gateway          │ ─────────▶ Backend(s)
│ (no creds) │             │ (DaemonSet)    │             │ (Deployment/STS) │           Tempo/Mimir/
└────────────┘             │ batch, k8sattr │             │ tail_sampling,   │           vendor
                           │ hostmetrics    │             │ auth, routing    │
                           └────────────────┘             └──────────────────┘
```

- **Agent (DaemonSet)** collects node-local signals (host metrics, container logs), attaches k8s metadata cheaply (it knows which pods are on its node), does first-pass batching, and forwards to the gateway. Apps hold **no** backend credentials.
- **Gateway (Deployment/StatefulSet)** is the only tier with egress credentials. It owns expensive, stateful decisions — **tail-based sampling**, multi-tenant routing, backend fan-out — and scales independently of the workload.

**Decision heuristics**

- Need `filelog`, `hostmetrics`, or `kubeletstats`? → you need a **DaemonSet agent** (node-scoped data cannot be gathered from a central Deployment).
- Need **tail sampling** or per-trace decisions? → you need a **gateway**, and traffic to it must be **trace-ID-aware routed** (see §4.3), otherwise decisions run on partial traces.
- Strict per-pod isolation / per-tenant Collector config / hard guarantee of a local buffer even if the DaemonSet pod is evicted? → **sidecar**, accepting the overhead.

---

## 3. Distributions: what binary do you actually ship?

The Collector is a set of Go modules assembled at build time. You never ship "the Collector" — you ship a **distribution** with a fixed component set.

| Distribution | Binary | Component set | When to use |
|---|---|---|---|
| **Core** | `otelcol` | OTLP + a minimal, stable set | You only speak OTLP end-to-end |
| **Contrib** | `otelcol-contrib` | ~everything (all vendor exporters, `filelog`, `k8sattributes`, `tail_sampling`, `spanmetrics`…) | Getting started, dev, "kitchen sink" |
| **Custom (OCB)** | `otelcol-custom` | Exactly the components you list | **Production**: minimal attack surface, smaller image, no unused receivers open |
| **k8s** | `otelcol-k8s` | Curated for Kubernetes (used by Helm defaults) | Kubernetes deployments |

**Why not just run contrib everywhere?** Contrib carries every receiver — each is an open listener or scrape target and part of your attack surface, plus supply-chain surface and image size. Production hardens by building a **custom distribution** with the **OpenTelemetry Collector Builder (OCB / `builder`)** that contains only what your pipelines reference.

### OCB build manifest (`builder-config.yaml`) — complete

```yaml
dist:
  name: otelcol-custom
  description: Hardened OTel Collector for gateway tier
  output_path: ./_build
  otelcol_version: 0.115.0

# Core components live under go.opentelemetry.io/collector/...
# Contrib components under github.com/open-telemetry/opentelemetry-collector-contrib/...
receivers:
  - gomod: go.opentelemetry.io/collector/receiver/otlpreceiver v0.115.0

processors:
  - gomod: go.opentelemetry.io/collector/processor/memorylimiterprocessor v0.115.0
  - gomod: go.opentelemetry.io/collector/processor/batchprocessor v0.115.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/processor/k8sattributesprocessor v0.115.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor v0.115.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/processor/resourcedetectionprocessor v0.115.0

exporters:
  - gomod: go.opentelemetry.io/collector/exporter/otlpexporter v0.115.0
  - gomod: go.opentelemetry.io/collector/exporter/debugexporter v0.115.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/exporter/loadbalancingexporter v0.115.0

extensions:
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/extension/healthcheckextension v0.115.0
  - gomod: go.opentelemetry.io/collector/extension/zpagesextension v0.115.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/extension/pprofextension v0.115.0
```

```console
$ builder --config builder-config.yaml
2026-02-10T14:03:11.204Z  INFO  internal/command.go:60  OpenTelemetry Collector Builder  {"version": "0.115.0"}
2026-02-10T14:03:11.205Z  INFO  internal/command.go:83  Using config file  {"path": "builder-config.yaml"}
2026-02-10T14:03:11.206Z  INFO  builder/config.go:142   Using go  {"go-executable": "/usr/local/go/bin/go"}
2026-02-10T14:03:11.210Z  INFO  builder/main.go:76      Sources created  {"path": "./_build"}
2026-02-10T14:03:17.882Z  INFO  builder/main.go:108     Getting go modules
2026-02-10T14:03:24.011Z  INFO  builder/main.go:87      Compiling
2026-02-10T14:03:41.559Z  INFO  builder/main.go:94      Compiled  {"binary": "./_build/otelcol-custom"}

$ ./_build/otelcol-custom components | head -n 20
buildinfo:
    command: otelcol-custom
    description: Hardened OTel Collector for gateway tier
    version: 0.115.0
receivers:
    - otlp
processors:
    - memory_limiter
    - batch
    - k8sattributes
    - tail_sampling
    - resourcedetection
exporters:
    - otlp
    - debug
    - loadbalancing
```

---

## 4. Manifests

All examples assume namespace `observability`. Every pipeline follows the golden rule: **`memory_limiter` is the first processor; `batch` is last before the exporter.**

### 4.1 Agent — DaemonSet (raw Kubernetes)

Node-local collection: host metrics, container logs, k8s enrichment, forward to gateway.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-agent
  namespace: observability
---
# k8sattributes needs to read pods/namespaces cluster-wide.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-agent
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "watch", "list"]
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
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-agent-conf
  namespace: observability
data:
  relay: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      hostmetrics:
        collection_interval: 30s
        root_path: /hostfs
        scrapers:
          cpu: {}
          memory: {}
          load: {}
          filesystem: {}
          network: {}
      filelog:
        include: [ /var/log/pods/*/*/*.log ]
        include_file_path: true
        start_at: end
        operators:
          - type: container
            id: container-parser

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        filter:
          # Only look at pods on THIS node — cheap, node-scoped watch.
          node_from_env_var: KUBE_NODE_NAME
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.deployment.name
            - k8s.node.name
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
          - sources:
              - from: connection
      batch:
        send_batch_size: 8192
        send_batch_max_size: 10000
        timeout: 5s

    exporters:
      otlp:
        endpoint: otel-gateway.observability.svc.cluster.local:4317
        tls:
          insecure: true
        sending_queue:
          enabled: true
          num_consumers: 10
          queue_size: 5000
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      zpages:
        endpoint: 0.0.0.0:55679

    service:
      extensions: [health_check, zpages]
      telemetry:
        metrics:
          level: detailed
          address: 0.0.0.0:8888
        logs:
          level: info
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlp]
        metrics:
          receivers: [otlp, hostmetrics]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlp]
        logs:
          receivers: [otlp, filelog]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlp]
---
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
      containers:
        - name: otel-agent
          image: otel/opentelemetry-collector-contrib:0.115.0
          args: ["--config=/conf/relay.yaml"]
          env:
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef: { fieldPath: spec.nodeName }
          ports:
            - { name: otlp-grpc, containerPort: 4317, hostPort: 4317, protocol: TCP }
            - { name: otlp-http, containerPort: 4318, hostPort: 4318, protocol: TCP }
            - { name: metrics,   containerPort: 8888, protocol: TCP }
          resources:
            requests: { cpu: 100m, memory: 200Mi }
            limits:   { cpu: 500m, memory: 500Mi }
          livenessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 10
          readinessProbe:
            httpGet: { path: /, port: 13133 }
          volumeMounts:
            - { name: config,   mountPath: /conf }
            - { name: hostfs,   mountPath: /hostfs, readOnly: true }
            - { name: varlogpods, mountPath: /var/log/pods, readOnly: true }
      volumes:
        - name: config
          configMap:
            name: otel-agent-conf
            items: [{ key: relay, path: relay.yaml }]
        - name: hostfs
          hostPath: { path: / }
        - name: varlogpods
          hostPath: { path: /var/log/pods }
      tolerations:
        - operator: Exists   # run on every node, including tainted control-plane nodes
```

> `limit_percentage`/`spike_limit_percentage` are read against the **cgroup limit** the container sees, so the `memory_limiter` self-tunes if you resize the pod. Keep the container `limits.memory` a bit above the soft limit so the limiter reacts *before* the OOM killer does.

### 4.2 Gateway — Deployment + Service + HPA

Stateless fan-out tier. Scales horizontally with the HPA.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-gateway-conf
  namespace: observability
data:
  relay: |
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
        send_batch_size: 8192
        send_batch_max_size: 10000
        timeout: 5s

    exporters:
      otlp/backend:
        endpoint: tempo-distributor.tracing.svc.cluster.local:4317
        tls: { insecure: true }
        sending_queue: { enabled: true, num_consumers: 20, queue_size: 10000 }
        retry_on_failure: { enabled: true }
      debug:
        verbosity: normal

    extensions:
      health_check: { endpoint: 0.0.0.0:13133 }

    service:
      extensions: [health_check]
      telemetry:
        metrics: { level: detailed, address: 0.0.0.0:8888 }
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/backend]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-gateway
  namespace: observability
  labels: { app: otel-gateway }
spec:
  replicas: 3
  selector:
    matchLabels: { app: otel-gateway }
  template:
    metadata:
      labels: { app: otel-gateway }
    spec:
      containers:
        - name: otel-gateway
          image: otel/opentelemetry-collector-contrib:0.115.0
          args: ["--config=/conf/relay.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: metrics,   containerPort: 8888 }
          resources:
            requests: { cpu: 500m, memory: 1Gi }
            limits:   { cpu: "2",  memory: 2Gi }
          livenessProbe:  { httpGet: { path: /, port: 13133 } }
          readinessProbe: { httpGet: { path: /, port: 13133 } }
          volumeMounts:
            - { name: config, mountPath: /conf }
      volumes:
        - name: config
          configMap:
            name: otel-gateway-conf
            items: [{ key: relay, path: relay.yaml }]
---
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway
  namespace: observability
spec:
  selector: { app: otel-gateway }
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: 4317, protocol: TCP }
    - { name: otlp-http, port: 4318, targetPort: 4318, protocol: TCP }
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
  maxReplicas: 15
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
    - type: Resource
      resource:
        name: memory
        target: { type: Utilization, averageUtilization: 75 }
```

> **gRPC + a `ClusterIP` `Service` load-balances connections, not requests.** gRPC multiplexes on one long-lived HTTP/2 connection, so kube-proxy pins each agent to a single gateway pod. Fix with a headless `Service` + client-side round-robin, an L7 mesh (Envoy/Linkerd), or the `loadbalancing` exporter (§4.3). Otherwise a scaled-up gateway sees skewed load.

### 4.3 Trace-aware gateway for tail sampling — StatefulSet + `loadbalancing` exporter

**The problem:** `tail_sampling` must see *every span of a trace* to decide. If spans of one trace land on different gateway replicas, each decides on a partial trace → broken sampling. **The fix:** a two-layer gateway. Layer 1 routes by trace ID with the `loadbalancing` exporter to a **headless** Service; layer 2 (a `StatefulSet`) runs `tail_sampling`, guaranteeing all spans of a trace hit the same pod.

```yaml
# ---------- Layer 1: routing gateway (Deployment) ----------
apiVersion: v1
kind: ConfigMap
metadata: { name: otel-router-conf, namespace: observability }
data:
  relay: |
    receivers:
      otlp: { protocols: { grpc: { endpoint: 0.0.0.0:4317 } } }
    processors:
      memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }
    exporters:
      loadbalancing:
        routing_key: traceID        # consistent hashing per trace
        protocol:
          otlp:
            tls: { insecure: true }
        resolver:
          k8s:
            service: otel-sampler-headless.observability
            ports: [4317]
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter]
          exporters: [loadbalancing]
---
# ---------- Layer 2: sampling gateway (StatefulSet) ----------
apiVersion: v1
kind: ConfigMap
metadata: { name: otel-sampler-conf, namespace: observability }
data:
  relay: |
    receivers:
      otlp: { protocols: { grpc: { endpoint: 0.0.0.0:4317 } } }
    processors:
      memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }
      tail_sampling:
        decision_wait: 10s
        num_traces: 100000
        policies:
          - name: errors
            type: status_code
            status_code: { status_codes: [ERROR] }
          - name: slow
            type: latency
            latency: { threshold_ms: 500 }
          - name: baseline-10pct
            type: probabilistic
            probabilistic: { sampling_percentage: 10 }
      batch: { timeout: 5s, send_batch_size: 8192 }
    exporters:
      otlp/backend:
        endpoint: tempo-distributor.tracing.svc.cluster.local:4317
        tls: { insecure: true }
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, tail_sampling, batch]
          exporters: [otlp/backend]
---
apiVersion: v1
kind: Service
metadata: { name: otel-sampler-headless, namespace: observability }
spec:
  clusterIP: None                    # headless: the loadbalancing resolver reads each pod IP
  selector: { app: otel-sampler }
  ports: [{ name: otlp-grpc, port: 4317, targetPort: 4317 }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: otel-sampler, namespace: observability }
spec:
  serviceName: otel-sampler-headless
  replicas: 3
  selector: { matchLabels: { app: otel-sampler } }
  template:
    metadata: { labels: { app: otel-sampler } }
    spec:
      containers:
        - name: otel-sampler
          image: otel/opentelemetry-collector-contrib:0.115.0
          args: ["--config=/conf/relay.yaml"]
          ports: [{ containerPort: 4317 }]
          resources:
            requests: { cpu: "1", memory: 2Gi }   # tail_sampling holds traces in RAM — size num_traces × avg trace
            limits:   { cpu: "2", memory: 4Gi }
          volumeMounts: [{ name: config, mountPath: /conf }]
      volumes:
        - name: config
          configMap: { name: otel-sampler-conf, items: [{ key: relay, path: relay.yaml }] }
```

> Scaling the sampler `StatefulSet` reshuffles the `loadbalancing` hash ring; the resolver re-reads pod IPs and rebalances. Give it a generous `terminationGracePeriodSeconds` so in-flight traces drain before a pod dies.

### 4.4 OpenTelemetry Operator — the CRD way

The Operator manages Collectors declaratively via the `OpenTelemetryCollector` CRD (`mode: deployment | daemonset | statefulset | sidecar`) and auto-injects sidecars. It requires **cert-manager**.

```console
$ kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.1/cert-manager.yaml
$ kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
$ kubectl -n opentelemetry-operator-system get pods
NAME                                                        READY   STATUS    RESTARTS   AGE
opentelemetry-operator-controller-manager-6b8f9c7d4-jr2kx   2/2     Running   0          41s
```

**DaemonSet agent via CRD** (structured `config`, API `v1beta1`):

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: agent
  namespace: observability
spec:
  mode: daemonset
  image: otel/opentelemetry-collector-contrib:0.115.0
  resources:
    requests: { cpu: 100m, memory: 200Mi }
    limits:   { cpu: 500m, memory: 500Mi }
  config:
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    processors:
      memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }
      batch: {}
    exporters:
      otlp:
        endpoint: otel-gateway.observability.svc.cluster.local:4317
        tls: { insecure: true }
    service:
      pipelines:
        traces:  { receivers: [otlp], processors: [memory_limiter, batch], exporters: [otlp] }
        metrics: { receivers: [otlp], processors: [memory_limiter, batch], exporters: [otlp] }
        logs:    { receivers: [otlp], processors: [memory_limiter, batch], exporters: [otlp] }
```

**Sidecar injection** — a per-workload Collector, opted in by annotation:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: sidecar
  namespace: apps
spec:
  mode: sidecar
  config:
    receivers: { otlp: { protocols: { grpc: { endpoint: 0.0.0.0:4317 } } } }
    processors: { batch: {} }
    exporters:
      otlp:
        endpoint: otel-gateway.observability.svc.cluster.local:4317
        tls: { insecure: true }
    service:
      pipelines:
        traces: { receivers: [otlp], processors: [batch], exporters: [otlp] }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: checkout, namespace: apps }
spec:
  replicas: 2
  selector: { matchLabels: { app: checkout } }
  template:
    metadata:
      labels: { app: checkout }
      annotations:
        sidecar.opentelemetry.io/inject: "true"   # operator injects the sidecar Collector here
    spec:
      containers:
        - name: checkout
          image: registry.example.com/checkout:1.7.0
          env:
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://localhost:4317        # export to the injected sidecar on localhost
```

```console
$ kubectl -n observability get opentelemetrycollectors
NAME    MODE        VERSION   READY   AGE   IMAGE
agent   daemonset   0.115.0   6/6     3m    otel/opentelemetry-collector-contrib:0.115.0

$ kubectl -n apps get pod -l app=checkout -o jsonpath='{.items[0].spec.containers[*].name}'
checkout otc-container
```

### 4.5 Helm — the fast path

The `opentelemetry-collector` chart uses **presets** that expand into the RBAC, mounts, and pipeline wiring for common jobs.

```console
$ helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
$ helm repo update
```

`values-agent.yaml`:

```yaml
mode: daemonset          # daemonset | deployment | statefulset
image:
  repository: otel/opentelemetry-collector-contrib
presets:
  kubernetesAttributes:  { enabled: true }   # wires k8sattributes + RBAC
  hostMetrics:           { enabled: true }
  kubeletMetrics:        { enabled: true }
  logsCollection:        { enabled: true, includeCollectorLogs: false }
resources:
  limits: { cpu: 500m, memory: 500Mi }
config:
  exporters:
    otlp:
      endpoint: otel-gateway.observability.svc.cluster.local:4317
      tls: { insecure: true }
  service:
    pipelines:
      traces:  { exporters: [otlp] }
      metrics: { exporters: [otlp] }
      logs:    { exporters: [otlp] }
```

```console
$ helm upgrade --install otel-agent open-telemetry/opentelemetry-collector \
    -n observability --create-namespace -f values-agent.yaml
Release "otel-agent" does not exist. Installing it now.
NAME: otel-agent
STATUS: deployed
REVISION: 1

$ kubectl -n observability rollout status daemonset/otel-agent
daemon set "otel-agent" successfully rolled out
```

---

## 5. Verification & failure diagnosis

### 5.1 Validate config *before* it ships

```console
$ otelcol-contrib validate --config config.yaml
$ echo $?
0
```

A bad pipeline fails loudly with a component-path error:

```console
$ otelcol-contrib validate --config broken.yaml
Error: invalid configuration: service::pipelines::traces: references processor "tail_sampling" which is not configured
exit status 1
```

### 5.2 The four built-in diagnostic surfaces

| Surface | Extension / port | What it tells you |
|---|---|---|
| **Health** | `health_check` :13133 | Is the Collector up and its pipelines running? (drives k8s probes) |
| **Live pipeline** | `zpages` :55679 `/debug/tracez`, `/debug/pipelinez` | Per-component span/error samples, pipeline wiring, live |
| **Profiling** | `pprof` :1777 | CPU/heap/goroutine profiles for leaks & hot paths |
| **Internal metrics** | `service.telemetry.metrics` :8888 (`/metrics`) | The Collector's own Prometheus metrics — the source of truth |

```console
$ kubectl -n observability port-forward daemonset/otel-agent 13133:13133 8888:8888 55679:55679
$ curl -s localhost:13133 | jq .
{ "status": "Server available", "upSince": "2026-02-10T14:20:03Z", "uptime": "12m4s" }
```

### 5.3 The internal metrics that actually matter

Scrape `:8888/metrics`. These are your first stop for any pipeline incident:

```console
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|exporter|processor)_' | grep -v '^#'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 1.284551e+06
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 0
otelcol_processor_refused_spans{processor="memory_limiter"} 0
otelcol_exporter_sent_spans{exporter="otlp"} 1.284551e+06
otelcol_exporter_send_failed_spans{exporter="otlp"} 0
otelcol_exporter_queue_size{exporter="otlp"} 12
otelcol_exporter_queue_capacity{exporter="otlp"} 5000
otelcol_exporter_enqueue_failed_spans{exporter="otlp"} 0
```

**Read them as ratios:**
- `receiver_refused_*` climbing → back-pressure reached the receiver (usually `memory_limiter` upstream).
- `processor_refused_spans{processor="memory_limiter"}` > 0 → the limiter is shedding load; **you are dropping data**.
- `exporter_send_failed_*` > 0 → the backend is rejecting/unreachable.
- `exporter_queue_size` approaching `queue_capacity` → sink slower than source; `enqueue_failed_*` starts and data drops next.

### 5.4 Prove the path end-to-end with `telemetrygen`

```console
$ kubectl -n observability port-forward daemonset/otel-agent 4317:4317 &
$ telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 5
2026-02-10T14:33:09Z  INFO  traces/traces.go:58  generation of traces isn't being throttled
2026-02-10T14:33:09Z  INFO  traces/worker.go:96  traces generated  {"worker": 0, "traces": 5}
2026-02-10T14:33:09Z  INFO  traces/traces.go:83  stop the batch span processor
```

Confirm they moved through (a `debug` exporter is the fastest sanity check):

```console
$ kubectl -n observability logs daemonset/otel-agent | grep -i 'TracesExporter\|spans'
2026-02-10T14:33:10.114Z  info  TracesExporter  {"kind": "exporter", "data_type": "traces", "name": "debug", "resource spans": 5, "spans": 5}
```

### 5.5 Failure playbook

| Symptom (log / metric) | Root cause | Fix |
|---|---|---|
| `data refused due to high memory usage` · `otelcol_processor_refused_spans{memory_limiter}` rising | Ingest > processing/egress; limiter shedding to avoid OOM | Add gateway replicas / bump HPA; raise container `memory` limit **and** `limit_percentage`; ensure `batch` isn't set too large |
| Pod `OOMKilled` with **no** limiter refusals | `memory_limiter` missing/last in pipeline, or soft limit ≥ cgroup limit | Put `memory_limiter` **first**; keep `limits.memory` above the soft limit so it triggers first |
| `sending_queue is full` · `otelcol_exporter_enqueue_failed_spans` > 0 | Backend slower than ingest; queue saturated | Raise `sending_queue.queue_size` / `num_consumers`; add a **persistent queue** via `file_storage` extension so restarts don't lose data; scale the backend |
| `Permanent error ... rpc error: code = InvalidArgument` — never retried | Backend rejects the payload (schema/tenant header). Permanent ≠ transient → dropped immediately | Fix headers/tenant/attributes; a `retry_on_failure` bump will **not** help a permanent error |
| `no such host` / `connection refused` to gateway | DNS/Service wrong, or gateway not `Ready` | Check the `Service` name/namespace FQDN; `kubectl get endpoints otel-gateway`; verify readiness probe passing |
| Gateway pods wildly uneven CPU after scale-up | gRPC pins one HTTP/2 conn per agent to one pod | Use headless Service + client round-robin, a mesh, or the `loadbalancing` exporter (§4.3) |
| Tail sampling keeps only fragments of traces | Spans of one trace split across sampler replicas | Front the samplers with a `loadbalancing` exporter, `routing_key: traceID` → headless Service (§4.3) |
| `bind: address already in use` on `hostPort` | Two DaemonSet agents (or a leftover) claim `hostPort: 4317` on the node | One agent per node; free the port or drop `hostPort` and use the ClusterIP |

```console
$ kubectl -n observability get endpoints otel-gateway
NAME           ENDPOINTS                                            AGE
otel-gateway   10.244.1.23:4317,10.244.2.41:4317,10.244.3.9:4317   9m

$ kubectl -n observability describe pod otel-gateway-6b8f9c7d4-xk2 | grep -A3 'Last State'
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

---

## Referencias

- OpenTelemetry — Collector Deployment (overview): https://opentelemetry.io/docs/collector/deployment/
- OpenTelemetry — Agent pattern: https://opentelemetry.io/docs/collector/deployment/agent/
- OpenTelemetry — Gateway pattern: https://opentelemetry.io/docs/collector/deployment/gateway/
- OpenTelemetry — No Collector pattern: https://opentelemetry.io/docs/collector/deployment/no-collector/
- OpenTelemetry — Scaling the Collector: https://opentelemetry.io/docs/collector/scaling/
- OpenTelemetry — Collector configuration (receivers/processors/exporters/service): https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry — Building a custom Collector (OCB): https://opentelemetry.io/docs/collector/custom-collector/
- OpenTelemetry — Installation & distributions: https://opentelemetry.io/docs/collector/installation/
- OpenTelemetry — Internal telemetry & troubleshooting: https://opentelemetry.io/docs/collector/internal-telemetry/
- OpenTelemetry — Kubernetes Operator: https://opentelemetry.io/docs/platforms/kubernetes/operator/
- OpenTelemetry — Kubernetes Helm charts: https://opentelemetry.io/docs/platforms/kubernetes/helm/
- opentelemetry-collector (core): https://github.com/open-telemetry/opentelemetry-collector
- opentelemetry-collector-contrib (`k8sattributes`, `tail_sampling`, `loadbalancing`, `filelog`…): https://github.com/open-telemetry/opentelemetry-collector-contrib
- opentelemetry-operator: https://github.com/open-telemetry/opentelemetry-operator
- CNCF Curriculum (OTCA): https://github.com/cncf/curriculum