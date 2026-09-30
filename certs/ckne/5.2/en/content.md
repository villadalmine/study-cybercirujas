# 5.2 Troubleshooting End-to-End Network Performance with Tracing

> **Exam weight: 5.0**. The CKNE curriculum is published as domain titles without a detailed objective list, so this chapter covers the skill the title names. Given a slow or flaky request path in Kubernetes, you should be able to break its latency into layers and find the one that is responsible. You do this by correlating distributed traces, service mesh telemetry, eBPF flow data and packet-level evidence.

---

## 1. Motivation: the production problem

A user reports that "checkout is slow". The dashboards show the `checkout` p99 rising from 120 ms to 1.1 s. That number tells you **that** something is slow. It does not tell you **where**. A single HTTP request in a modern cluster crosses a long chain of places where time can be spent:

```
Browser
  │  DNS (public) → TCP → TLS
  ▼
Cloud LB ──► Ingress / Gateway (Envoy)          ← TLS termination, routing, head sampling decision
  │   kube-proxy / eBPF service translation (DNAT)
  ▼
Node A: frontend pod
  │  app → CoreDNS lookup (ndots=5 search expansion, A + AAAA)
  │  app → outbound sidecar (iptables REDIRECT or eBPF)   ← connection pool wait, retries, mTLS origination
  │  CNI datapath: veth → (VXLAN/Geneve/WireGuard encap) → NIC
  ▼
Node B: checkout pod
  │  CNI decap → veth → inbound sidecar (mTLS termination, authz)
  │  app processing → calls payments (repeat the whole chain)
  ▼
payments → database (outside the mesh, no spans unless instrumented)
```

Every arrow is a place where time can be lost: DNS search-domain expansion, a conntrack race, SYN retransmits after a drop, MTU black holes, connection pool exhaustion, retry storms, TLS handshakes on cold connections, CPU throttling in a sidecar, or plain slow application code.

The architectural problem is that **each layer's observability tool only sees its own layer**:

| Layer | Tool | Sees | Blind to |
|---|---|---|---|
| Application | OpenTelemetry SDK spans | business operations, DB calls, in-process time | the network, the proxies |
| Service mesh (L7 proxy) | Envoy spans, access logs, stats | per-hop request timing, retries, response flags | kernel drops, DNS inside the app, app internals |
| Kernel / CNI (eBPF) | Cilium Hubble flows and metrics | L3/L4 verdicts, drops with reasons, TCP flags, DNS, optional L7 | application semantics, time spent inside processes |
| Wire | `tcpdump`, `ss`, `conntrack`, `nstat` | ground truth for packets and retransmits | everything above L4, and it does not scale |

To troubleshoot end to end, you **join these views on shared keys**: the W3C `trace-id`, `x-request-id`, pod identity, the 5-tuple and timestamps. You then subtract the durations reported by one layer from those reported by the next layer down. **Latency lives in the gap between two adjacent measurements.**

---

## 2. Distributed tracing fundamentals

### 2.1 Data model

- **Trace**: the tree of all the work done for one request, identified by a 16-byte `trace-id`.
- **Span**: one timed operation (`start`, `end`, `name`, `kind`, `status`, `attributes`, `events`) with an 8-byte `span-id` and a `parent-span-id`.
- **SpanKind** is what matters for network analysis:
  - `CLIENT`: time as seen by the caller, from the first byte sent to the last byte received. It includes the network, both proxies and the server.
  - `SERVER`: time as seen by the callee, from the request received to the response sent.
  - **`CLIENT.duration − SERVER.duration` = network + proxies + queueing between the two.** This subtraction is the core of the whole topic.

### 2.2 Context propagation

Tracing only works if every hop forwards the context. The W3C Trace Context standard defines two headers:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ││ └───────────── trace-id ─────────┘ └─ parent-id ──┘ └┴ flags (01 = sampled)
             └┴ version
tracestate:  congo=t61rcWkgMzE,rojo=00f067aa0ba902b7
```

Older Zipkin-based systems use **B3** (`x-b3-traceid`, `x-b3-spanid`, `x-b3-parentspanid`, `x-b3-sampled`, or the single `b3` header). Envoy's OpenTelemetry tracer uses W3C `traceparent`. Its Zipkin tracer uses B3.

**The critical rule for service meshes:** a sidecar can create spans for traffic entering and leaving the pod. It **cannot** know that the outbound call to `payments` was caused by the inbound request from `frontend`. That relationship exists only inside the application process. **The application must copy the trace headers from the inbound request to its outbound requests.** An auto-instrumentation agent or an OpenTelemetry SDK does this for you. If nobody does it, every hop starts a new trace, and you see many short, disconnected traces with a single service each.

| Header | Standard | Must the app forward it? | Notes |
|---|---|---|---|
| `traceparent` / `tracestate` | W3C Trace Context | yes | default for OpenTelemetry and Envoy's OTel tracer |
| `x-b3-*` / `b3` | Zipkin B3 | yes | legacy; Zipkin tracer; many older Istio setups |
| `x-request-id` | Envoy convention | yes (recommended) | joins access logs across hops even without tracing |
| `baggage` | W3C Baggage | optional | key/value context (tenant, feature flag); not a trace id |

### 2.3 Sampling: head, tail, parent-based

At 5,000 RPS × 8 hops, keeping every span is expensive. Where you make the sampling decision determines which problems you can still see later.

| Strategy | Where the decision is made | Pros | Cons | Use for |
|---|---|---|---|---|
| **Head, random** (e.g. Istio `randomSamplingPercentage: 1`) | first hop (usually the ingress gateway) sets the `sampled` flag | cheap; consistent across hops; no buffering | blind to rare slow or failed requests: a 0.1% tail at 1% sampling is almost never kept | baseline traffic shape |
| **Parent-based** (`parentbased_traceidratio`) | each hop follows the incoming flag and applies the ratio only to root spans | keeps traces complete; mesh and SDK agree | inherits the head's blindness | **always** in SDKs behind a mesh |
| **Tail** (OTel Collector `tail_sampling`) | collector, after it has buffered the whole trace | keep 100% of errors and slow traces plus a small baseline | memory; needs trace-id-aware load balancing; adds `decision_wait` delay | incident analysis, SLO outliers |
| **Force / debug** | client sends a flagged request | exact trace on demand | only for requests you trigger yourself | reproducing an issue |

> **Trade-off:** with tail sampling, the **head** must still sample at a high rate (for example 100% or 50%) so spans actually reach the collector. Tail sampling saves storage, not the cost of producing and exporting spans. Make sure the sidecar's and the collector's CPU and network budget can carry that export volume.

### 2.4 Which signal answers which question

| Question | Best signal | Why |
|---|---|---|
| Is the SLO breached, and since when? | metrics (Istio `istio_request_duration_milliseconds`, Hubble `hubble_http_request_duration_seconds`) | cheap, complete, aggregatable |
| Which hop adds the latency for *this* slow request? | trace | causal tree with per-hop timing |
| Why did the proxy fail or retry? | Envoy access log `%RESPONSE_FLAGS%` and timing operators | per-request proxy detail |
| Is the network dropping packets, and why? | Hubble flows (`--verdict DROPPED`, drop reason) | kernel-level truth, per pod |
| Are there retransmits, or is the window/MTU wrong? | `tcpdump`, `ss -ti`, `nstat` | wire-level truth |
| How do I jump from a metric spike to one example request? | **exemplars** (a trace id attached to a histogram bucket) | links an aggregate to one instance |

---

## 3. Reference architecture

```
                        ┌───────────── namespace: shop (istio-injection=enabled) ─────────────┐
 Istio ingress GW ──►   frontend[app+envoy] ──► checkout[app+envoy] ──► payments[app+envoy]
   (head sample)          │ spans (OTLP gRPC)     │                      │
                          ▼                       ▼                      ▼
                 ┌───────────────── namespace: observability (no injection) ───────────────┐
                 │ otel-gateway (Deployment, N replicas)                                   │
                 │   otlp → memory_limiter → k8sattributes → loadbalancing(routing_key=traceID)
                 │                                     │                                   │
                 │ otel-sampler (Deployment + headless Service, M replicas)                │
                 │   otlp ─┬─► spanmetrics connector ──► prometheus exporter :8889 (exemplars)
                 │         └─► tail_sampling → batch ──► otlp → Jaeger v2 (OTLP 4317, UI 16686)
                 └──────────────────────────────────────────────────────────────────────────┘
 Cilium + Hubble (every node) ──► hubble-relay ──► hubble CLI / UI
                               └► hubble metrics (httpV2 with exemplars) ──► Prometheus
```

**Why two collector tiers?** Tail sampling has to see **all the spans of one trace in the same collector instance**. With a single tier behind a normal ClusterIP Service, the spans of one trace are spread across replicas, and each replica decides on a fragment. The `loadbalancing` exporter hashes `traceID` so that each trace always goes to the same sampler pod.

**Why run `k8sattributes` in the gateway tier?** Envoy sidecars export spans directly from the pod's IP, so the gateway can match the connection's source IP to a pod. By the time spans reach the sampler tier, the source IP belongs to the gateway pod.

### 3.1 Namespace, RBAC and gateway tier

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    istio-injection: disabled
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector-k8sattributes
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["apps"]
    resources: ["replicasets", "deployments"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector-k8sattributes
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-collector-k8sattributes
subjects:
  - kind: ServiceAccount
    name: otel-collector
    namespace: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-gateway-config
  namespace: observability
data:
  config.yaml: |
    extensions:
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
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.deployment.name
            - k8s.node.name
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
          - sources:
              - from: connection
    exporters:
      loadbalancing:
        routing_key: traceID
        protocol:
          otlp:
            timeout: 5s
            tls:
              insecure: true
        resolver:
          dns:
            hostname: otel-sampler-headless.observability.svc.cluster.local
            port: 4317
    service:
      extensions: [health_check]
      telemetry:
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
          processors: [memory_limiter, k8sattributes]
          exporters: [loadbalancing]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-gateway
  namespace: observability
  labels:
    app: otel-gateway
spec:
  replicas: 2
  selector:
    matchLabels:
      app: otel-gateway
  template:
    metadata:
      labels:
        app: otel-gateway
    spec:
      serviceAccountName: otel-collector
      containers:
        - name: collector
          # Pin to a version you have validated; tail_sampling and loadbalancing live in -contrib.
          image: otel/opentelemetry-collector-contrib:0.123.0
          args: ["--config=/conf/config.yaml"]
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: otlp-http
              containerPort: 4318
            - name: metrics
              containerPort: 8888
          readinessProbe:
            httpGet:
              path: /
              port: 13133
          livenessProbe:
            httpGet:
              path: /
              port: 13133
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: conf
              mountPath: /conf
      volumes:
        - name: conf
          configMap:
            name: otel-gateway-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway
  namespace: observability
spec:
  selector:
    app: otel-gateway
  ports:
    - name: grpc-otlp
      port: 4317
      targetPort: 4317
    - name: http-otlp
      port: 4318
      targetPort: 4318
```

> The port name prefix `grpc-` matters when a mesh is involved: Istio uses it for protocol selection. OTLP/gRPC is HTTP/2. If a meshed exporter sees it misdetected as plain TCP, the connections do not balance per request.

### 3.2 Sampler tier, spanmetrics and Jaeger

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-sampler-config
  namespace: observability
data:
  config.yaml: |
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20
      tail_sampling:
        decision_wait: 10s
        num_traces: 100000
        expected_new_traces_per_sec: 2000
        policies:
          - name: keep-errors
            type: status_code
            status_code:
              status_codes: [ERROR]
          - name: keep-slow
            type: latency
            latency:
              threshold_ms: 500
          - name: baseline
            type: probabilistic
            probabilistic:
              sampling_percentage: 5
      batch:
        send_batch_size: 1024
        timeout: 2s
    connectors:
      spanmetrics:
        histogram:
          explicit:
            buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2s, 5s]
        dimensions:
          - name: http.response.status_code
          - name: k8s.namespace.name
        exemplars:
          enabled: true
    exporters:
      otlp/jaeger:
        endpoint: jaeger.observability.svc.cluster.local:4317
        tls:
          insecure: true
      prometheus:
        endpoint: 0.0.0.0:8889
        enable_open_metrics: true
    service:
      extensions: [health_check]
      telemetry:
        metrics:
          level: detailed
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
      pipelines:
        traces/unsampled:
          receivers: [otlp]
          processors: [memory_limiter]
          exporters: [spanmetrics]
        traces/sampled:
          receivers: [otlp]
          processors: [memory_limiter, tail_sampling, batch]
          exporters: [otlp/jaeger]
        metrics/spanmetrics:
          receivers: [spanmetrics]
          processors: [batch]
          exporters: [prometheus]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-sampler
  namespace: observability
  labels:
    app: otel-sampler
spec:
  replicas: 3
  selector:
    matchLabels:
      app: otel-sampler
  template:
    metadata:
      labels:
        app: otel-sampler
    spec:
      serviceAccountName: otel-collector
      containers:
        - name: collector
          image: otel/opentelemetry-collector-contrib:0.123.0
          args: ["--config=/conf/config.yaml"]
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: spanmetrics
              containerPort: 8889
            - name: metrics
              containerPort: 8888
          readinessProbe:
            httpGet:
              path: /
              port: 13133
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              memory: 2Gi
          volumeMounts:
            - name: conf
              mountPath: /conf
      volumes:
        - name: conf
          configMap:
            name: otel-sampler-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-sampler-headless
  namespace: observability
spec:
  clusterIP: None
  selector:
    app: otel-sampler
  ports:
    - name: grpc-otlp
      port: 4317
      targetPort: 4317
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: observability
  labels:
    app: jaeger
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
        - name: jaeger
          # Jaeger v2 is built on the OTel Collector and ingests OTLP natively.
          # All-in-one with in-memory storage: lab use only.
          image: jaegertracing/jaeger:2.5.0
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: otlp-http
              containerPort: 4318
            - name: ui
              containerPort: 16686
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              memory: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: observability
spec:
  selector:
    app: jaeger
  ports:
    - name: grpc-otlp
      port: 4317
      targetPort: 4317
    - name: http-otlp
      port: 4318
      targetPort: 4318
    - name: http-ui
      port: 16686
      targetPort: 16686
```

**Design decisions and their trade-offs:**

| Decision | Why | Cost / risk |
|---|---|---|
| `spanmetrics` fed by an **unsampled** pipeline | RED metrics (rate, errors, duration) reflect 100% of spans; if computed after tail sampling, latency percentiles would be skewed toward slow traces | exemplars can point to trace ids that tail sampling later dropped, which gives a "trace not found" on click |
| `decision_wait: 10s` | long enough for slow child spans to arrive | traces appear in Jaeger ≥10 s late; `num_traces × average spans` must fit in memory |
| DNS resolver on a headless Service | no extra RBAC; the resolver re-resolves periodically | scaling the sampler **re-shards** the hash ring, so traces in flight during a scale event can be split and sampled partially |
| `memory_limiter` first in every pipeline | refuses data (backpressure) instead of being OOM-killed | the sender sees refusals; Envoy drops spans silently, so watch the collector's refused-spans metrics |

---

## 4. Mesh-layer tracing and timing with Istio

### 4.1 Register the OpenTelemetry provider

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  profile: default
  meshConfig:
    enableTracing: true
    extensionProviders:
      - name: otel-tracing
        opentelemetry:
          service: otel-gateway.observability.svc.cluster.local
          port: 4317
      - name: envoy-json-timing
        envoyFileAccessLog:
          path: /dev/stdout
          logFormat:
            labels:
              start_time: "%START_TIME%"
              method: "%REQ(:METHOD)%"
              path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
              authority: "%REQ(:AUTHORITY)%"
              response_code: "%RESPONSE_CODE%"
              response_flags: "%RESPONSE_FLAGS%"
              response_code_details: "%RESPONSE_CODE_DETAILS%"
              upstream_transport_failure_reason: "%UPSTREAM_TRANSPORT_FAILURE_REASON%"
              duration_ms: "%DURATION%"
              request_duration_ms: "%REQUEST_DURATION%"
              response_duration_ms: "%RESPONSE_DURATION%"
              response_tx_duration_ms: "%RESPONSE_TX_DURATION%"
              upstream_pool_ready_ms: "%UPSTREAM_CONNECTION_POOL_READY_DURATION%"
              upstream_service_time_ms: "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%"
              upstream_host: "%UPSTREAM_HOST%"
              upstream_cluster: "%UPSTREAM_CLUSTER%"
              downstream_remote: "%DOWNSTREAM_REMOTE_ADDRESS%"
              request_id: "%REQ(X-REQUEST-ID)%"
              trace_id: "%TRACE_ID%"
              route_name: "%ROUTE_NAME%"
```

Every value starts with `%`, which YAML reserves as the directive indicator, so each value is quoted.

Meaning of the timing operators (all in milliseconds, all measured from the moment the downstream request started):

| Operator | Measures | Large value means |
|---|---|---|
| `%REQUEST_DURATION%` | until the full downstream request body was received | slow client or large upload |
| `%UPSTREAM_CONNECTION_POOL_READY_DURATION%` | until the connection pool handed over an upstream connection | TCP/TLS connect time or **pool exhaustion** (circuit-breaker limits) |
| `%RESPONSE_DURATION%` | until the first byte of the upstream response | upstream processing plus the network (≈ time to first byte) |
| `%RESPONSE_TX_DURATION%` | from the first upstream byte to the last byte sent downstream | large or streamed body, slow downstream reader |
| `%DURATION%` | total | — |
| `x-envoy-upstream-service-time` | time the upstream took as measured by this Envoy, **including retries** | compare it with the destination's own `%DURATION%` |

Response flags you must recognize on sight:

| Flag | Meaning | Typical network cause |
|---|---|---|
| `UF` | upstream connection failure | endpoint gone, policy drop, port not listening |
| `UH` | no healthy upstream | every endpoint was ejected by outlier detection or failed health checks |
| `UT` | upstream request timeout | slow upstream, or packet loss causing retransmits past the route timeout |
| `URX` | upstream retry limit exceeded | persistent failures; retries amplify load |
| `UO` | upstream overflow (circuit breaker) | `connectionPool` limits reached; queueing |
| `UC` | upstream connection termination | idle-timeout mismatch; the upstream closed a keep-alive connection that was being reused |
| `DC` | downstream connection termination | the client gave up (its own timeout is shorter than the server's) |
| `NR` | no route configured | missing VirtualService/HTTPRoute or Sidecar scope |

### 4.2 Enable tracing and access logs with the Telemetry API

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  tracing:
    - providers:
        - name: otel-tracing
      randomSamplingPercentage: 5
  accessLogging:
    - providers:
        - name: envoy-json-timing
      filter:
        expression: "response.code >= 400 || response.duration > 500"
---
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: shop-debug
  namespace: shop
spec:
  tracing:
    - providers:
        - name: otel-tracing
      randomSamplingPercentage: 100
      customTags:
        cluster:
          literal:
            value: prod-eu-1
        user_tier:
          header:
            name: x-user-tier
            defaultValue: unknown
  accessLogging:
    - providers:
        - name: envoy-json-timing
```

Precedence is workload selector > namespace > root namespace (`istio-system`). The `filter.expression` on the mesh default keeps log volume down: only errors and requests slower than 500 ms are logged. The `shop` override logs everything while you are investigating.

> **Sampling nuance that misleads many engineers:** the sampling percentage applies only when a request arrives **without** a sampling decision. If the ingress gateway samples at 1% and marks `traceparent` flags `00` (not sampled), the sidecars in `shop` honour that decision. Setting 100% in `shop` then produces nothing for traffic that entered through the gateway. To trace ingress traffic you have to raise the rate where the trace starts, at the gateway: use a Telemetry resource in the gateway's namespace with a selector for the gateway pods. The alternative is to send your own `traceparent` with `-01` on a test request.

### 4.3 Enable the Envoy histograms you need

By default Istio keeps Envoy's per-cluster statistics minimal to save memory. Opt in per workload:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app: checkout
spec:
  replicas: 3
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
        version: v1
      annotations:
        proxy.istio.io/config: |
          proxyStatsMatcher:
            inclusionSuffixes:
              - upstream_rq_time
              - upstream_cx_connect_ms
              - upstream_cx_connect_fail
              - upstream_rq_retry
              - upstream_rq_timeout
              - upstream_rq_pending_overflow
              - upstream_cx_destroy_remote_with_active_rq
    spec:
      containers:
        - name: checkout
          image: ghcr.io/example/checkout:1.8.2
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: PAYMENTS_URL
              value: "http://payments.shop.svc.cluster.local:8080"
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              memory: 512Mi
```

### 4.4 Linkerd and ambient mode, for comparison

| Aspect | Istio sidecar | Istio ambient | Linkerd |
|---|---|---|---|
| Who emits spans | each sidecar (client and server span per hop) | **waypoint** proxies only; ztunnel is L4 and emits no spans | each linkerd2-proxy, when the `linkerd-jaeger` extension is installed |
| Config | Telemetry API + `extensionProviders` | same API, applied to waypoints | extension install + `config.linkerd.io/trace-collector` annotation |
| Propagation | W3C (OTel provider) or B3 (Zipkin provider) | same, at the waypoint | W3C or B3 (depends on the version) |
| Per-hop timing without tracing | access logs and histograms (`%DURATION%`, `upstream_rq_time`) | ztunnel L4 logs (bytes, duration) | `linkerd viz stat/top/tap` with live latency |
| The app must propagate headers | **yes** | **yes** | **yes** |

---

## 5. Application layer: making propagation actually work

Mesh spans without application propagation produce broken traces. The OpenTelemetry Operator injects auto-instrumentation agents that handle the in-process `inbound → outbound` context link:

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: shop-instrumentation
  namespace: shop
spec:
  exporter:
    # The Java agent 2.x defaults to http/protobuf, hence 4318.
    endpoint: http://otel-gateway.observability.svc.cluster.local:4318
  propagators:
    - tracecontext
    - baggage
    - b3
  sampler:
    # Follow the mesh's decision; apply the ratio only when this service is the root.
    type: parentbased_traceidratio
    argument: "1"
  resource:
    addK8sUIDAttributes: true
```

Opt a workload in with the pod template annotation `instrumentation.opentelemetry.io/inject-java: "true"`. There are equivalents for `-python`, `-nodejs`, `-dotnet` and `-go`.

> **Why `parentbased`?** Behind Envoy, the inbound request already carries a sampling decision. A non-parent-based sampler in the app makes an independent decision. The result is that app spans exist for traces whose proxy spans were dropped, or the other way round, and you get "holes" in the waterfall.

---

## 6. Kernel / eBPF layer: Cilium Hubble

Hubble records a flow event for every packet decision the Cilium datapath makes: forwarded, dropped (with a reason), TCP flags, and the source and destination identities. With L7 visibility enabled it also records HTTP, DNS and Kafka metadata, including the latency between request and response, and **the trace id taken from the `traceparent` header**.

### 6.1 Helm values for Hubble with exemplar-enabled HTTP metrics

```yaml
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
  metrics:
    enableOpenMetrics: true
    enabled:
      - "dns:query"
      - drop
      - tcp
      - flow
      - "port-distribution"
      - "httpV2:exemplars=true;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction"
    serviceMonitor:
      enabled: true
```

`enableOpenMetrics: true` is required: exemplars exist only in the OpenMetrics exposition format. Prometheus must also run with `--enable-feature=exemplar-storage`.

### 6.2 L7 visibility through policy

Hubble sees L7 only for traffic redirected to Cilium's embedded Envoy proxy, and L7 policy rules are what trigger that redirect. **Important:** a CiliumNetworkPolicy that selects an endpoint puts that endpoint in default-deny for the direction the policy covers, so allow everything that is legitimate:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: checkout-l7-visibility
  namespace: shop
spec:
  endpointSelector:
    matchLabels:
      app: checkout
  ingress:
    - fromEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": shop
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - {}
  egress:
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": kube-system
            "k8s:k8s-app": kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": shop
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - {}
```

`http: [{}]` allows every HTTP request but forces L7 parsing. `matchPattern: "*"` (quoted, because a bare `*` is a YAML alias) allows every DNS name but makes DNS visible.

| Trade-off | Detail |
|---|---|
| Per-hop latency added | every redirected connection goes through a userspace Envoy (Cilium's own), which adds sub-millisecond to low-millisecond latency and CPU per node |
| Double proxy with Istio | Istio sidecar plus Cilium L7 redirect gives two Envoys per hop; with **mTLS from the sidecar, Cilium sees only TLS**, so L7 visibility is lost for meshed traffic (L3/L4 and DNS still work) |
| Enforcement risk | a visibility policy is still a policy; a forgotten port is dropped (`Policy denied`) |

### 6.3 Querying Hubble

```
$ cilium hubble port-forward &
$ hubble status
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 24,570/24,570 (100.00%)
Flows/s: 412.37
Connected Nodes: 6/6
```

L7 latency between two workloads:

```
$ hubble observe --namespace shop --protocol http --to-label app=checkout --last 5
Sep 30 10:14:02.118: shop/frontend-7d9c8b6f4-x2k9p:43822 (ID:18321) -> shop/checkout-5f6c7d8b9-qwz7l:8080 (ID:40211) http-request FORWARDED (HTTP/1.1 POST http://checkout.shop.svc.cluster.local:8080/api/v1/orders)
Sep 30 10:14:03.162: shop/frontend-7d9c8b6f4-x2k9p:43822 (ID:18321) <- shop/checkout-5f6c7d8b9-qwz7l:8080 (ID:40211) http-response FORWARDED (HTTP/1.1 200 1044ms (POST http://checkout.shop.svc.cluster.local:8080/api/v1/orders))
Sep 30 10:14:03.201: shop/frontend-7d9c8b6f4-x2k9p:43830 (ID:18321) -> shop/checkout-5f6c7d8b9-m8d2c:8080 (ID:40211) http-request FORWARDED (HTTP/1.1 POST http://checkout.shop.svc.cluster.local:8080/api/v1/orders)
Sep 30 10:14:03.318: shop/frontend-7d9c8b6f4-x2k9p:43830 (ID:18321) <- shop/checkout-5f6c7d8b9-m8d2c:8080 (ID:40211) http-response FORWARDED (HTTP/1.1 200 117ms (POST http://checkout.shop.svc.cluster.local:8080/api/v1/orders))
```

The slow response came from `qwz7l` and the fast one from `m8d2c`. That points to a problem specific to one pod or one node.

Pivot from a trace to the flows for the same request:

```
$ hubble observe --trace-id 4bf92f3577b34da6a3ce929d0e0e4736 -o json | jq -c '{time, src: .flow.source.pod_name, dst: .flow.destination.pod_name, type: .flow.l7.type, lat: .flow.l7.latency_ns}'
{"time":"2026-09-30T10:14:02.118Z","src":"frontend-7d9c8b6f4-x2k9p","dst":"checkout-5f6c7d8b9-qwz7l","type":"REQUEST","lat":null}
{"time":"2026-09-30T10:14:03.162Z","src":"checkout-5f6c7d8b9-qwz7l","dst":"frontend-7d9c8b6f4-x2k9p","type":"RESPONSE","lat":"1044128312"}
```

Drops, with reasons:

```
$ hubble observe --verdict DROPPED --namespace shop --last 10
Sep 30 10:13:59.004: shop/checkout-5f6c7d8b9-qwz7l:51244 (ID:40211) -> shop/payments-6b8f9c7d5-7hq4n:8080 (ID:30988) Policy denied DROPPED (TCP Flags: SYN)
Sep 30 10:14:00.021: shop/checkout-5f6c7d8b9-qwz7l:51244 (ID:40211) -> shop/payments-6b8f9c7d5-7hq4n:8080 (ID:30988) Policy denied DROPPED (TCP Flags: SYN)
```

The same source port appears twice, about 1 s apart. That is a SYN **retransmission**: the Linux initial RTO is 1 s.

DNS visibility (the `ndots` expansion problem):

```
$ hubble observe --namespace shop --protocol dns --from-label app=checkout --last 6
Sep 30 10:15:11.402: shop/checkout-5f6c7d8b9-qwz7l:39811 (ID:40211) -> kube-system/coredns-5d78c9869d-9b2lk:53 (ID:102) dns-request proxy FORWARDED (DNS Query api.stripe.com.shop.svc.cluster.local. A)
Sep 30 10:15:11.403: shop/checkout-5f6c7d8b9-qwz7l:39811 (ID:40211) <- kube-system/coredns-5d78c9869d-9b2lk:53 (ID:102) dns-response proxy FORWARDED (DNS Answer RCode: Non-Existent Domain TTL: 4294967295 (Proxy api.stripe.com.shop.svc.cluster.local. A))
Sep 30 10:15:11.404: shop/checkout-5f6c7d8b9-qwz7l:39811 (ID:40211) -> kube-system/coredns-5d78c9869d-9b2lk:53 (ID:102) dns-request proxy FORWARDED (DNS Query api.stripe.com.svc.cluster.local. A)
Sep 30 10:15:11.405: shop/checkout-5f6c7d8b9-qwz7l:39811 (ID:40211) <- kube-system/coredns-5d78c9869d-9b2lk:53 (ID:102) dns-response proxy FORWARDED (DNS Answer RCode: Non-Existent Domain TTL: 4294967295 (Proxy api.stripe.com.svc.cluster.local. A))
Sep 30 10:15:11.406: shop/checkout-5f6c7d8b9-qwz7l:39811 (ID:40211) -> kube-system/coredns-5d78c9869d-9b2lk:53 (ID:102) dns-request proxy FORWARDED (DNS Query api.stripe.com.cluster.local. A)
Sep 30 10:15:11.407: shop/checkout-5f6c7d8b9-qwz7l:39811 (ID:40211) <- kube-system/coredns-5d78c9869d-9b2lk:53 (ID:102) dns-response proxy FORWARDED (DNS Answer RCode: Non-Existent Domain TTL: 4294967295 (Proxy api.stripe.com.cluster.local. A))
```

`api.stripe.com` has only 2 dots, fewer than `ndots:5`, so the resolver tries every search domain first. That costs 3 or more wasted round trips, doubled for A plus AAAA, before the real query. Fixes: use the fully qualified name with a trailing dot (`api.stripe.com.`), set `dnsConfig.options: [{name: ndots, value: "2"}]`, or run NodeLocal DNSCache.

---

## 7. Reading a trace: latency gap analysis

A waterfall for the slow request (Istio sidecars plus Java auto-instrumentation):

```
trace 4bf92f3577b34da6a3ce929d0e0e4736                                     total 1,062 ms
├─ istio-ingressgateway  frontend.shop.svc.cluster.local:80/*       SERVER→CLIENT   1,061 ms
│  └─ frontend (envoy inbound)                                      SERVER          1,058 ms
│     └─ frontend  POST /checkout                                   SERVER (app)    1,055 ms
│        └─ frontend (envoy outbound) checkout.shop:8080            CLIENT          1,049 ms   ◄─┐ A
│           └─ checkout (envoy inbound)                             SERVER          1,046 ms     │
│              └─ checkout  POST /api/v1/orders                     SERVER (app)    1,043 ms     │
│                 ├─ checkout  SELECT orders                        CLIENT             4 ms      │
│                 └─ checkout (envoy outbound) payments.shop:8080   CLIENT          1,031 ms  ◄─┐ B
│                    └─ payments (envoy inbound)                    SERVER             14 ms  ◄─┘ C
│                       └─ payments  POST /charge                   SERVER (app)       12 ms
```

The procedure:

1. **Find the deepest span that still accounts for the excess.** The time drops sharply from **B** (1,031 ms) to **C** (14 ms).
2. **B − C = 1,017 ms spent between checkout's outbound Envoy and payments' inbound Envoy.** That is the network, TCP/TLS connection setup, or pool waiting. It is not the payments code.
3. Check B's span attributes and tags. Envoy's `upstream_cluster`, `peer.address` and `response_flags` tell you which endpoint was used and whether a retry happened. A retried request may show one span with `URX`, or several attempts.
4. **Classify the gap by its value**, using the "latency signatures" below.

| Gap pattern | Most likely layer | Confirm with |
|---|---|---|
| CLIENT − SERVER ≈ **1 s, 3 s, 7 s** (1+2+4) | TCP SYN retransmission after a dropped SYN (initial RTO 1 s, doubling) | `hubble observe --tcp-flags SYN`, `tcpdump` SYN repeats, conntrack / policy drops |
| gap ≈ **5 s** (or multiples) | DNS timeout (glibc resolver `timeout:5`), classically the UDP conntrack race between parallel A and AAAA queries | Hubble DNS flows, `options single-request-reopen`, NodeLocal DNSCache |
| gap ≈ **200 ms** on small writes | Nagle + delayed ACK interaction | `ss -ti`, `TCP_NODELAY` |
| gap equals `%UPSTREAM_CONNECTION_POOL_READY_DURATION%` | pool exhaustion or slow connect/mTLS handshake | `upstream_rq_pending_overflow`, `upstream_cx_connect_ms`, the DestinationRule `connectionPool` |
| gap grows with **payload size**; small requests are fine | MTU / PMTUD black hole (encapsulation overhead) | `ping -M do -s <size>`, `tcpdump` showing a stalled large segment |
| SERVER span ≈ CLIENT span, both slow | real server-side work (or CPU throttling) | app child spans, `container_cpu_cfs_throttled_periods_total` |
| inbound Envoy SERVER ≫ app SERVER | the sidecar itself: CPU-limited proxy, heavy authz/Wasm filters | `istio-proxy` CPU throttling, Envoy `server.*` stats |
| child span **starts before** its parent | node clock skew, not latency | `chronyc tracking` on the nodes; Jaeger's clock-skew adjuster warnings |

---

## 8. Complementary metrics: two-reporter latency without traces

Istio records every request twice: `reporter="source"` (client sidecar) and `reporter="destination"` (server sidecar). The difference between them is the network plus the destination sidecar. That makes it the aggregate equivalent of B − C:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: mesh-network-latency
  namespace: observability
spec:
  groups:
    - name: mesh-network-latency
      rules:
        - record: shop:request_p99_ms:source
          expr: |
            histogram_quantile(0.99,
              sum by (le, source_workload, destination_workload) (
                rate(istio_request_duration_milliseconds_bucket{reporter="source", destination_workload_namespace="shop"}[5m])
              )
            )
        - record: shop:request_p99_ms:destination
          expr: |
            histogram_quantile(0.99,
              sum by (le, source_workload, destination_workload) (
                rate(istio_request_duration_milliseconds_bucket{reporter="destination", destination_workload_namespace="shop"}[5m])
              )
            )
        - alert: MeshHopNetworkLatencyHigh
          expr: |
            (shop:request_p99_ms:source - shop:request_p99_ms:destination) > 250
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "p99 network+proxy gap {{ $value }}ms from {{ $labels.source_workload }} to {{ $labels.destination_workload }}"
```

> Subtracting two p99 values is not mathematically exact, because quantiles do not subtract. It is still a good detector. Confirm the result with traces, which give the exact per-request subtraction.

Exemplars bridge the metric to a trace. In Grafana, enable exemplars on the Prometheus data source and link `trace_id` to Jaeger or Tempo. Clicking an exemplar dot on the p99 panel opens the matching slow trace. The same works for `hubble_http_request_duration_seconds` when `httpV2:exemplars=true` is set and the requests carry `traceparent`.

---

## 9. Hands-on diagnostic toolkit

### 9.1 Break a single request into phases with curl

`curl -w` timings are **cumulative** from the start of the transfer:

```
$ kubectl -n shop exec deploy/frontend -c frontend -- \
    curl -o /dev/null -s \
    -w 'dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} pretransfer=%{time_pretransfer} ttfb=%{time_starttransfer} total=%{time_total} code=%{http_code}\n' \
    http://checkout.shop.svc.cluster.local:8080/api/v1/health
dns=0.004212 tcp=1.006871 tls=0.000000 pretransfer=1.006930 ttfb=1.019554 total=1.019702 code=200
```

Read it as deltas:

| Phase | Computation | Value | Interpretation |
|---|---|---|---|
| DNS | `time_namelookup` | 4 ms | fine |
| TCP connect | `time_connect − time_namelookup` | **1,003 ms** | SYN retransmit: the first SYN was lost |
| TLS | `time_appconnect − time_connect` | 0 | plain HTTP from the app; mTLS happens in the sidecar and is invisible here |
| Server | `time_starttransfer − time_pretransfer` | 13 ms | the server is fast |

> **The trap:** with an Istio sidecar, the app's TCP connect goes to the **local** outbound Envoy, which accepts it almost instantly. The 1 s connect seen here means the outbound listener was not intercepting the traffic, or this is a non-meshed client. In a normal meshed pod, the upstream connect delay appears in Envoy's `upstream_cx_connect_ms` and in `%UPSTREAM_CONNECTION_POOL_READY_DURATION%`, not in curl. Always check which hop your measurement actually covers.

Force a sampled trace for the test request, then search for it:

```
$ TRACE=$(openssl rand -hex 16); SPAN=$(openssl rand -hex 8)
$ kubectl -n shop exec deploy/frontend -c frontend -- \
    curl -s -o /dev/null -D - -H "traceparent: 00-${TRACE}-${SPAN}-01" \
    http://checkout.shop.svc.cluster.local:8080/api/v1/orders/probe
HTTP/1.1 200 OK
content-type: application/json
x-envoy-upstream-service-time: 1017
server: envoy
$ echo $TRACE
9f1c2e8a4b7d6c3e1f0a9b8c7d6e5f4a
```

### 9.2 Query the trace backend from the CLI

```
$ kubectl -n observability port-forward svc/jaeger 16686:16686 &
$ curl -s 'http://localhost:16686/api/traces?service=checkout.shop&minDuration=500ms&lookback=1h&limit=5' \
    | jq -r '.data[] | [.traceID, (.spans | map(.duration) | max / 1000 | tostring + "ms"), (.spans | length | tostring + " spans")] | @tsv'
4bf92f3577b34da6a3ce929d0e0e4736	1062ms	9 spans
9f1c2e8a4b7d6c3e1f0a9b8c7d6e5f4a	1031ms	9 spans
a1b2c3d4e5f60718293a4b5c6d7e8f90	3044ms	9 spans
```

The 1,0xx ms and 3,044 ms durations (1 s, then 1 + 2 s) match the SYN retransmit schedule.

### 9.3 Envoy: configuration, endpoints, histograms, logs

Check that tracing is actually configured on the listener:

```
$ istioctl proxy-config listener deploy/checkout -n shop --port 15006 -o json \
    | jq '[.. | .tracing? // empty][0]'
{
  "provider": {
    "name": "envoy.tracers.opentelemetry",
    "typedConfig": {
      "@type": "type.googleapis.com/envoy.config.trace.v3.OpenTelemetryConfig",
      "grpcService": {
        "envoyGrpc": {
          "clusterName": "outbound|4317||otel-gateway.observability.svc.cluster.local",
          "authority": "otel-gateway.observability.svc.cluster.local"
        }
      },
      "serviceName": "checkout.shop"
    }
  },
  "randomSampling": {
    "value": 100
  }
}
```

Which endpoints the proxy uses, and whether outlier detection ejected any:

```
$ istioctl proxy-config endpoint deploy/checkout -n shop \
    --cluster "outbound|8080||payments.shop.svc.cluster.local"
ENDPOINT             STATUS      OUTLIER CHECK     CLUSTER
10.244.3.17:8080     HEALTHY     OK                outbound|8080||payments.shop.svc.cluster.local
10.244.5.22:8080     HEALTHY     OK                outbound|8080||payments.shop.svc.cluster.local
10.244.5.31:8080     HEALTHY     FAILED            outbound|8080||payments.shop.svc.cluster.local
```

Upstream timing histograms (enabled in §4.3):

```
$ kubectl -n shop exec deploy/checkout -c istio-proxy -- \
    pilot-agent request GET 'stats?filter=payments.*(upstream_cx_connect_ms|upstream_rq_time|upstream_cx_connect_fail|upstream_rq_retry)'
cluster.outbound|8080||payments.shop.svc.cluster.local.upstream_cx_connect_fail: 0
cluster.outbound|8080||payments.shop.svc.cluster.local.upstream_rq_retry: 37
cluster.outbound|8080||payments.shop.svc.cluster.local.upstream_cx_connect_ms: P0(nan,0) P25(nan,1.03) P50(nan,1.07) P75(nan,1.9) P90(nan,1010) P95(nan,1020) P99(nan,3050) P99.5(nan,3060) P99.9(nan,3080) P100(nan,3100)
cluster.outbound|8080||payments.shop.svc.cluster.local.upstream_rq_time: P0(nan,2) P25(nan,11) P50(nan,13) P75(nan,17) P90(nan,1020) P95(nan,1030) P99(nan,3060) P99.5(nan,3070) P99.9(nan,3090) P100(nan,3100)
```

The p50 connect time is about 1 ms, while p90 is about 1,010 ms and p99 about 3,050 ms. This is a bimodal distribution locked to the retransmit schedule, so **connection establishment is losing SYNs**. The `upstream_rq_time` tail matches it exactly. The two values in each pair are (interval, cumulative); `nan` means no samples in the current interval.

The JSON access log for one slow request:

```
$ kubectl -n shop logs deploy/checkout -c istio-proxy --since=5m | jq -c 'select(.duration_ms > 500) | {upstream_host, response_flags, pool: .upstream_pool_ready_ms, ttfb: .response_duration_ms, total: .duration_ms, trace_id}' | head -3
{"upstream_host":"10.244.5.22:8080","response_flags":"-","pool":1008,"ttfb":1021,"total":1022,"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736"}
{"upstream_host":"10.244.5.22:8080","response_flags":"-","pool":3011,"ttfb":3027,"total":3028,"trace_id":"a1b2c3d4e5f60718293a4b5c6d7e8f90"}
{"upstream_host":"10.244.5.22:8080","response_flags":"-","pool":1004,"ttfb":1016,"total":1017,"trace_id":"9f1c2e8a4b7d6c3e1f0a9b8c7d6e5f4a"}
```

`pool ≈ ttfb − 13 ms`: almost all the latency is spent before a connection exists. Every slow request goes to `10.244.5.22`. Which node is that on?

```
$ kubectl get pod -A -o wide --field-selector status.podIP=10.244.5.22
NAMESPACE   NAME                        READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
shop        payments-6b8f9c7d5-2xk8m    2/2     Running   0          3d    10.244.5.22   worker-5   <none>           <none>
```

### 9.4 Wire-level confirmation

Capture inside the client pod's network namespace with an ephemeral debug container:

```
$ kubectl -n shop debug -it pod/checkout-5f6c7d8b9-qwz7l --image=nicolaka/netshoot --target=checkout -- \
    tcpdump -i eth0 -nn 'host 10.244.5.22 and tcp[tcpflags] & (tcp-syn) != 0'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
10:21:04.118244 IP 10.244.2.41.47102 > 10.244.5.22.8080: Flags [S], seq 3620112211, win 64240, options [mss 1460,sackOK,TS val 1840021 ecr 0,nop,wscale 7], length 0
10:21:05.130871 IP 10.244.2.41.47102 > 10.244.5.22.8080: Flags [S], seq 3620112211, win 64240, options [mss 1460,sackOK,TS val 1841033 ecr 0,nop,wscale 7], length 0
10:21:05.131902 IP 10.244.5.22.8080 > 10.244.2.41.47102: Flags [S.], seq 118822301, ack 3620112212, win 65160, options [mss 1410,sackOK,TS val 99120 ecr 1841033,nop,wscale 7], length 0
```

The same `seq` resent after about 1 s, and the SYN-ACK arrives only after the retransmission: the first SYN was lost on the way to worker-5. Note also `mss 1460` from the client against `mss 1410` from the server. This cluster uses encapsulation, so keep MTU in mind (§9.5).

Kernel TCP state inside the pod's network namespace:

```
$ kubectl -n shop debug -it pod/checkout-5f6c7d8b9-qwz7l --image=nicolaka/netshoot --target=checkout -- \
    ss -tin dst 10.244.5.22
State  Recv-Q Send-Q  Local Address:Port    Peer Address:Port
ESTAB  0      0       10.244.2.41:47102     10.244.5.22:8080
	 cubic wscale:7,7 rto:204 rtt:1.412/0.61 mss:1398 pmtu:1450 rcvmss:1398 advmss:1398 cwnd:10 bytes_acked:18233 segs_out:74 segs_in:61 retrans:0/1 lost:0
```

`retrans:0/1` means one retransmission over the connection's lifetime (the SYN).

On the destination node, look for the drop:

```
$ kubectl debug node/worker-5 -it --image=nicolaka/netshoot -- chroot /host sh -c 'dmesg -T | grep -i conntrack | tail -3; conntrack -S | head -3'
[Wed Sep 30 10:20:58 2026] nf_conntrack: nf_conntrack: table full, dropping packet
[Wed Sep 30 10:21:04 2026] nf_conntrack: nf_conntrack: table full, dropping packet
[Wed Sep 30 10:21:09 2026] nf_conntrack: nf_conntrack: table full, dropping packet
cpu=0   found=0 invalid=412 insert=0 insert_failed=18233 drop=18233 early_drop=0 error=0 search_restart=31
cpu=1   found=0 invalid=388 insert=0 insert_failed=17904 drop=17904 early_drop=0 error=0 search_restart=27
cpu=2   found=0 invalid=401 insert=0 insert_failed=18410 drop=18410 early_drop=0 error=0 search_restart=29
```

Root cause: worker-5's conntrack table is full, so new flows (SYNs) are dropped and retried after the RTO. Remediation, in order: find the connection leak (here a batch job opening short-lived connections without keep-alive), raise `net.netfilter.nf_conntrack_max` as a stopgap, and consider a datapath that does not depend on netfilter conntrack for service traffic (for example Cilium's kube-proxy replacement, which uses its own eBPF CT maps sized with `bpf-ct-global-*`).

### 9.5 MTU check

```
$ kubectl -n shop debug -it pod/checkout-5f6c7d8b9-qwz7l --image=nicolaka/netshoot --target=checkout -- \
    sh -c 'ping -c1 -M do -s 1422 10.244.5.22; ping -c1 -M do -s 1472 10.244.5.22'
PING 10.244.5.22 (10.244.5.22) 1422(1450) bytes of data.
1430 bytes from 10.244.5.22: icmp_seq=1 ttl=62 time=0.61 ms
PING 10.244.5.22 (10.244.5.22) 1472(1500) bytes of data.
ping: local error: message too long, mtu=1450
```

The pod MTU is 1450 (a 1500-byte underlay minus 50 bytes of VXLAN). If the pod interface were wrongly set to 1500, the error would not appear locally. Instead, large packets would disappear silently in the underlay. The trace signature is that small requests are fast while large responses hang until a timeout (`UT`).

---

## 10. Worked incident: from alert to root cause

| Step | Action | Evidence | Conclusion |
|---|---|---|---|
| 1 | `MeshHopNetworkLatencyHigh` fires for `checkout → payments` | source p99 3.0 s, destination p99 15 ms | time is lost **between** the sidecars, not inside payments |
| 2 | click an exemplar on the p99 panel | trace `4bf92f35…`: outbound CLIENT 1,031 ms, inbound SERVER 14 ms | confirmed per request; gap = 1,017 ms |
| 3 | classify the gap | durations cluster at ~1 s and ~3 s | SYN retransmission signature |
| 4 | Envoy access log with a `trace_id` filter | `upstream_pool_ready_ms ≈ total`; always `10.244.5.22` | connection establishment, one endpoint |
| 5 | Envoy `upstream_cx_connect_ms` | bimodal, p50 1 ms / p90 1,010 ms | connection setup fails intermittently |
| 6 | `tcpdump` in checkout | the same SYN `seq` retransmitted after 1 s | a packet is lost in the direction toward the node |
| 7 | node `dmesg`, `conntrack -S` | `table full, dropping packet`; `insert_failed` climbing | **root cause: conntrack exhaustion on worker-5** |
| 8 | mitigation | drain the node or cordon it and reschedule payments; raise `nf_conntrack_max`; fix the leaking job | p99 back to 120 ms; verify with the same queries |

Note what each layer contributed. Metrics **detected** the problem, the trace **located** the hop, Envoy **narrowed** it to connection setup and one endpoint, the wire **proved** packet loss, and the node **explained** it. No single tool would have been enough.

---

## 11. Failure modes of the tracing pipeline itself

When a trace is missing or wrong, first suspect the observability stack before you suspect the network.

| Symptom | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| Every trace has 1–2 spans; services appear disconnected | the app does not propagate headers | two traces with the same `x-request-id` in access logs but different `trace_id`s | auto-instrumentation or manual header forwarding |
| Mesh spans present, app spans missing (or the reverse) | different propagators (B3 vs W3C) or an independent sampler | inspect inbound headers: `kubectl exec ... -- env`, or log the request headers | same propagator on both sides; `parentbased_*` sampler |
| No spans at all from a namespace | the Telemetry resource is missing, or the gateway's upstream decision was "not sampled" | `istioctl proxy-config listener ... | jq '..|.tracing?'` | raise the rate at the trace root; force it with `traceparent ...-01` |
| Traces truncated or partially sampled | the tail sampler received spans for the same trace on different replicas | sampler-tier scale events; missing `loadbalancing` exporter | `routing_key: traceID`; avoid rapid autoscaling of the sampler tier |
| Spans lost under load | `memory_limiter` refusals; exporter queue full | `curl otel-gateway:8888/metrics` → `otelcol_receiver_refused_spans*`, `otelcol_exporter_send_failed_spans*`, `otelcol_exporter_queue_size` | scale the gateway; raise memory; tune `batch` and `sending_queue` |
| Children start before parents; negative gaps | clock skew between nodes | `chronyc tracking` on the nodes | fix NTP; do not read network time from cross-node skew |
| Exemplar click shows "trace not found" | exemplar from unsampled spanmetrics, and tail sampling dropped that trace | expected for fast traces | accept it, or add a tail policy that keeps traces referenced by exemplars (sample more) |
| Collector reachable but Envoy exports nothing | wrong port name / protocol detection, or `outbound|4317||...` has no endpoints | `istioctl proxy-config endpoint deploy/x --cluster "outbound|4317||otel-gateway.observability.svc.cluster.local"` | `grpc-` port naming; confirm the Service and endpoints |
| Hubble shows no L7 for meshed pods | Istio mTLS encrypts before the Cilium datapath sees the traffic | the flows show TCP only | use mesh spans for L7; use Hubble for L3/L4 and DNS |

Collector self-check:

```
$ kubectl -n observability port-forward deploy/otel-gateway 8888:8888 &
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver_accepted|receiver_refused|exporter_sent|exporter_send_failed)_spans' | grep -v '^#'
otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc"} 4.822173e+06
otelcol_receiver_refused_spans_total{receiver="otlp",transport="grpc"} 0
otelcol_exporter_sent_spans_total{exporter="loadbalancing"} 4.821904e+06
otelcol_exporter_send_failed_spans_total{exporter="loadbalancing"} 269
```

(Internal metric names gained the `_total` suffix and changed labels across collector versions, so grep with a prefix.)

---

## 12. Verification checklist

1. **Pipeline alive:** the collector pods are Ready (`:13133`), `refused` and `send_failed` stay flat, and Jaeger lists the services (`/api/services`).
2. **Configuration applied:** `istioctl proxy-config listener` shows `envoy.tracers.opentelemetry` with the expected `randomSampling`; `kubectl get telemetry -A` lists the expected overrides.
3. **Propagation proven:** a request with `traceparent: 00-<id>-<span>-01` produces **one** trace that contains every hop (gateway → frontend → checkout → payments).
4. **Timing per hop available:** the access log includes `%DURATION%`, `%RESPONSE_DURATION%`, `%UPSTREAM_CONNECTION_POOL_READY_DURATION%` and `%TRACE_ID%`; the Envoy `upstream_rq_time` and `upstream_cx_connect_ms` histograms are populated.
5. **Kernel view:** `hubble status` shows all nodes connected; `hubble observe --verdict DROPPED` is empty or explained; DNS flows show no NXDOMAIN storm.
6. **Correlation works:** a Grafana exemplar opens the trace, and `hubble observe --trace-id <id>` returns the matching flows.
7. **After the fix:** repeat the **same** queries (two-reporter p99 gap, `upstream_cx_connect_ms` p90, Hubble drops) and compare them with the pre-incident baseline. Do not declare victory based on a single request.

### Exam-oriented quick reference

```
# who is slow, per hop (Istio two-reporter)
histogram_quantile(0.99, sum by (le) (rate(istio_request_duration_milliseconds_bucket{reporter="source",destination_workload="payments"}[5m])))

# force a sampled trace
curl -H "traceparent: 00-$(openssl rand -hex 16)-$(openssl rand -hex 8)-01" http://svc:port/path

# phase timings (cumulative)
curl -o /dev/null -s -w 'dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}\n' URL

# envoy
istioctl proxy-config endpoint deploy/<w> -n <ns> --cluster "outbound|<port>||<fqdn>"
kubectl exec deploy/<w> -c istio-proxy -- pilot-agent request GET 'stats?filter=upstream_(rq_time|cx_connect_ms)'
kubectl logs deploy/<w> -c istio-proxy | jq 'select(.response_flags != "-")'

# hubble
hubble observe -n <ns> --protocol http --to-label app=<x>
hubble observe --verdict DROPPED -n <ns>
hubble observe --tcp-flags SYN --to-ip <podIP>
hubble observe --protocol dns --from-label app=<x>
hubble observe --trace-id <trace-id>

# wire
kubectl debug -it pod/<p> --image=nicolaka/netshoot --target=<c> -- tcpdump -i eth0 -nn 'tcp[tcpflags] & tcp-syn != 0'
ss -tin dst <ip>        # retrans, rtt, pmtu
ping -M do -s <size> <ip>
conntrack -S            # insert_failed / drop
```

Latency signatures to memorize: **1 s / 3 s / 7 s → lost SYN**, **5 s → DNS timeout**, **200 ms → Nagle/delayed ACK**, **only large payloads fail → MTU**, **gap equals the pool-ready time → connection pool or connect**, **CLIENT ≈ SERVER → the server itself**.

---

## References

- CKNE certification page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- W3C Trace Context: https://www.w3.org/TR/trace-context/
- W3C Baggage: https://www.w3.org/TR/baggage/
- OpenTelemetry: context propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- OpenTelemetry: sampling (head and tail): https://opentelemetry.io/docs/concepts/sampling/
- OpenTelemetry Collector: configuration: https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry Collector: scaling, including stateful tail sampling with the load-balancing exporter: https://opentelemetry.io/docs/collector/scaling/
- OpenTelemetry Collector internal telemetry: https://opentelemetry.io/docs/collector/internal-telemetry/
- Tail sampling processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- Load-balancing exporter: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- Span metrics connector: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector
- Kubernetes attributes processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/k8sattributesprocessor
- OpenTelemetry Operator: auto-instrumentation: https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/
- Istio: distributed tracing overview: https://istio.io/latest/docs/tasks/observability/distributed-tracing/overview/
- Istio: OpenTelemetry tracing: https://istio.io/latest/docs/tasks/observability/distributed-tracing/opentelemetry/
- Istio: Telemetry API: https://istio.io/latest/docs/tasks/observability/telemetry/
- Istio: Telemetry reference: https://istio.io/latest/docs/reference/config/telemetry/
- Istio: Envoy access logs: https://istio.io/latest/docs/tasks/observability/logs/access-log/
- Istio: standard metrics: https://istio.io/latest/docs/reference/config/metrics/
- Istio: Envoy statistics (proxyStatsMatcher): https://istio.io/latest/docs/ops/configuration/telemetry/envoy-stats/
- Istio: debugging Envoy and istiod: https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Envoy: access log format and command operators: https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage
- Envoy: cluster manager statistics: https://www.envoyproxy.io/docs/envoy/latest/configuration/upstream/cluster_manager/cluster_stats
- Envoy: tracing architecture: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/observability/tracing
- Linkerd: distributed tracing: https://linkerd.io/2/tasks/distributed-tracing/
- Cilium Hubble: observability setup: https://docs.cilium.io/en/stable/observability/hubble/setup/
- Cilium: Hubble metrics (including httpV2 exemplars): https://docs.cilium.io/en/stable/observability/metrics/
- Cilium: Layer 7 protocol visibility: https://docs.cilium.io/en/stable/observability/visibility/
- Cilium: L7 policy language: https://docs.cilium.io/en/stable/security/policy/language/
- Jaeger v2 documentation: https://www.jaegertracing.io/docs/latest/
- Prometheus: exemplar storage: https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- Kubernetes: debugging DNS resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Kubernetes: NodeLocal DNSCache: https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
- Kubernetes: ephemeral debug containers: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container