# 3.1 Optimizing LLM Traffic

> **Exam weight: 5.0** · Scope: how a Kubernetes network layer should route, protect and observe traffic to self-hosted Large Language Model (LLM) inference servers, and why generic HTTP load balancing does a poor job of it.

---

## 1. Motivation: why LLM traffic breaks conventional load balancing

A stateless REST microservice has short, uniform requests. Its backends are interchangeable, and each one handles hundreds of concurrent requests with little per-request memory. Round-robin or least-request balancing gets you within a few percent of optimal.

An LLM inference server such as vLLM, SGLang, TGI or Triton+TensorRT-LLM works under very different conditions:

| Property | Typical microservice | LLM inference server |
|---|---|---|
| Request duration | 5–200 ms | 0.5 s – several minutes (grows with output tokens) |
| Variance between requests | Low | Extreme: a 20-token prompt vs a 100k-token RAG context with 4k output |
| Cost per request | ~uniform CPU | Proportional to **tokens** (prefill + decode), measured in GPU-seconds |
| Backend state that affects performance | None | **KV cache** (per sequence), **prefix cache** (shared prompt prefixes), **loaded LoRA adapters** |
| Concurrency limit | Thread pool, often large | Bounded by GPU memory for the KV cache; beyond it requests **queue** inside the server |
| Response shape | Single body | Often **streamed** (Server-Sent Events, `text/event-stream`), one chunk per token |
| Retry cost | Cheap | A retried generation burns the GPU time again; a retry after the first token duplicates output |
| Scale-up latency | Seconds | Minutes (image pull of 10+ GB, model weights download, CUDA graph capture) |
| Unit of capacity | Replica | Accelerator (GPU/TPU), expensive and scarce |

A few failure patterns follow directly from this table.

1. **Load-blind routing creates queueing hotspots.** Round-robin gives an equal *number* of requests to each replica, not an equal amount of *work*. One replica that receives three long-context requests fills its KV cache and starts queueing, while its neighbour sits at 30% KV-cache utilisation. Time-to-first-token (TTFT) on the hot replica goes up by seconds.
2. **Least-request is closer, but still blind.** Envoy's `LEAST_REQUEST` counts outstanding HTTP requests on the proxy's side. It knows nothing about the prompt length, the tokens still to decode, or how full each replica's KV cache is. It also can't see requests that other proxy instances sent to the same backend.
3. **Cache locality gets thrown away.** Requests that share a long system prompt or a RAG preamble can skip most of the prefill phase if they land on a replica whose prefix cache already holds those blocks. Random placement spreads them out, so every replica recomputes the same prefix.
4. **Adapter thrashing.** When many LoRA fine-tunes share one base model (multi-LoRA serving), each replica can keep only `--max-loras` adapters resident at once. Routing an adapter's request to a replica that doesn't have it loaded forces a swap, and latency goes up.
5. **Timeouts built for REST kill streams.** Envoy's default route timeout of 15 s, or an L7 load balancer's default 60 s idle timeout, cuts long generations in the middle of a stream.
6. **Request counts don't reflect fairness.** A single tenant sending 10 requests of 100k tokens each uses more GPU than 1,000 requests from someone else. A requests-per-second rate limit doesn't protect you here.

"Optimizing LLM traffic" therefore comes down to five capabilities, which structure the rest of this document:

| Capability | Mechanism in the Kubernetes ecosystem |
|---|---|
| Load- and cache-aware endpoint selection | Gateway API Inference Extension: `InferencePool` + Endpoint Picker (EPP) via Envoy `ext_proc` |
| Model-aware routing (by model / adapter name in the JSON body) | Body-Based Router (BBR) → header, then `HTTPRoute` header matches |
| Correct timeouts, streaming, retries, draining | `HTTPRoute.timeouts`, proxy settings, pod lifecycle |
| Token-based rate limiting and priority | AI-gateway implementations (e.g. Envoy AI Gateway + Envoy Gateway rate limiting), EPP priority/shedding |
| Capacity signals for autoscaling | Queue depth and KV-cache utilisation, not CPU |

---

## 2. Reference architecture

```
             Client (OpenAI-compatible API: /v1/chat/completions, /v1/completions)
                │
                ▼
┌───────────────────────────────────────────────────────────────┐
│ Gateway (Envoy-based: Istio, kgateway, Envoy Gateway, GKE…)   │
│                                                               │
│  1. [optional] BBR ext_proc: parse body → X-Gateway-Model-Name│
│  2. HTTPRoute match (path / header) → backendRef: InferencePool│
│  3. ext_proc call to Endpoint Picker (EPP) with headers+body ─┼──┐
│  5. Forward to IP:port from x-gateway-destination-endpoint    │  │
│     (ORIGINAL_DST cluster, no kube-proxy / Service VIP hop)   │  │
└───────────────┬───────────────────────────────────────────────┘  │
                │                                                  ▼
                │                               ┌──────────────────────────────┐
                │                               │ Endpoint Picker (EPP)        │
                │                               │ - watches InferencePool pods │
                │                               │ - scrapes /metrics per pod   │
                │                               │   (queue, KV cache, LoRA)    │
                │                               │ - filter → score → pick      │
                │                               │ 4. returns chosen endpoint   │
                │                               │    as a header / metadata    │
                │                               └──────────────┬───────────────┘
                ▼                                              │ scrape (~50 ms)
   ┌─────────────┐ ┌─────────────┐ ┌─────────────┐             │
   │ vLLM pod A  │ │ vLLM pod B  │ │ vLLM pod C  │ ◄───────────┘
   │ KV 82% q=4  │ │ KV 35% q=0  │ │ KV 50% q=1  │
   │ LoRA: x,y   │ │ LoRA: y     │ │ LoRA: x     │
   └─────────────┘ └─────────────┘ └─────────────┘
```

Some key design points:

- **The gateway data plane stays generic.** The inference-specific logic lives in a separately deployed Endpoint Picker, which the gateway calls through Envoy's External Processing (`ext_proc`) gRPC protocol. Any gateway that implements the extension protocol can use any EPP.
- **The EPP picks a pod, not a Service.** The gateway sends traffic directly to the pod IP the EPP chose, bypassing kube-proxy/Service VIP balancing (which would otherwise randomise the choice a second time).
- **The EPP has fresh model-server state.** It scrapes Prometheus metrics from every pod in the pool at high frequency, including metrics the proxy can't see: `vllm:num_requests_waiting`, KV-cache utilisation, and loaded LoRA adapters.
- **Failure mode is explicit.** If the EPP is down, the gateway either rejects requests (`FailClose`) or falls back to its own balancing (`FailOpen`).

---

## 3. Load-balancing strategies compared

| Strategy | Where it runs | Signal | Strengths | Weaknesses for LLMs |
|---|---|---|---|---|
| kube-proxy (iptables/IPVS/nftables) via ClusterIP | Node kernel | None (random / rr) | Zero configuration | L4 per *connection*: with HTTP/2 or keep-alive, one connection pins all requests to one pod |
| Envoy `ROUND_ROBIN` | Proxy | None | Predictable | Ignores request size and backend state |
| Envoy `LEAST_REQUEST` (power of two choices) | Proxy | Local outstanding requests | Cheap, decent for uniform work | Per-proxy view only; blind to tokens, KV cache and queue |
| Consistent hash (`RING_HASH`/`MAGLEV`) on a header or user ID | Proxy | Hash key | Session/prefix locality | Ignores load, so hot keys overload one pod; rebalances on scale events |
| Session persistence (cookie/header) | Proxy | Sticky key | Multi-turn chat locality | Same hotspot risk; experimental in Gateway API |
| **Endpoint Picker (Inference Extension)** | Out-of-process (`ext_proc`) | Queue depth, KV-cache %, LoRA residency, prefix-cache match, request priority | Balances by real work, keeps cache locality, sheds low-priority load | One extra hop (~ms) on each request; EPP is a critical component; it has to parse the request body |
| Disaggregated prefill/decode routing (e.g. llm-d) | EPP + model servers | Above + role of pod | Separates compute-bound prefill from memory-bound decode | Operationally complex; needs fast KV transfer (RDMA/NIXL) |

**Trade-off summary:** EPP adds a few milliseconds per request. Compare that with typical TTFTs of 100 ms–several seconds and decode times of tens of seconds, and the overhead is negligible. It's worth it when utilisation is high enough that queueing starts to show up.

---

## 4. Gateway API Inference Extension

The Gateway API Inference Extension project (kubernetes-sigs) defines:

| Resource | API group / version | Role |
|---|---|---|
| `InferencePool` | `inference.networking.k8s.io/v1` (GA in v1.0) | A group of model-server pods sharing base model and accelerator config, plus a reference to the EPP that picks among them. Used as a `backendRef` in `HTTPRoute`. |
| `InferenceObjective` | `inference.networking.x-k8s.io/v1alpha2` (alpha) | Per-workload serving objective, mainly **priority**, used by the EPP for queueing and shedding. It replaces the earlier alpha `InferenceModel` and its `criticality` field. |
| EPP configuration (`EndpointPickerConfig`) | `inference.networking.x-k8s.io/v1alpha1` | Chooses which filters, scorers and pickers the EPP scheduler runs. |

> Alpha APIs move between releases. In the exam and in production, confirm field names against the installed CRDs with `kubectl explain inferencepool.spec` and `kubectl explain inferenceobjective.spec` rather than relying on memory.

### 4.1 Install the CRDs

```
$ kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.0.0/manifests.yaml
customresourcedefinition.apiextensions.k8s.io/inferencepools.inference.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/inferenceobjectives.inference.networking.x-k8s.io created
customresourcedefinition.apiextensions.k8s.io/inferencepools.inference.networking.x-k8s.io created

$ kubectl api-resources --api-group=inference.networking.k8s.io
NAME             SHORTNAMES   APIVERSION                        NAMESPACED   KIND
inferencepools                inference.networking.k8s.io/v1    true         InferencePool
```

The Gateway API CRDs themselves (`gateway.networking.k8s.io`) must already be installed, together with a gateway implementation that supports the extension. With Istio, the inference extension is enabled through a pilot environment flag:

```
$ istioctl install -y \
    --set profile=minimal \
    --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true
✔ Istio core installed
✔ Istiod installed
✔ Installation complete
```

### 4.2 Model server Deployment (vLLM, multi-LoRA, prefix caching)

The model servers are ordinary Pods. The InferencePool selects them **by label**; no Service is needed for the data path.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: llm
---
apiVersion: v1
kind: Secret
metadata:
  name: hf-token
  namespace: llm
type: Opaque
stringData:
  token: "hf_REPLACE_ME"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-llama3-8b-instruct
  namespace: llm
  labels:
    app: vllm-llama3-8b-instruct
spec:
  replicas: 3
  selector:
    matchLabels:
      app: vllm-llama3-8b-instruct
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: vllm-llama3-8b-instruct
    spec:
      terminationGracePeriodSeconds: 180
      containers:
      - name: vllm
        image: vllm/vllm-openai:v0.10.1
        imagePullPolicy: IfNotPresent
        args:
        - --model
        - meta-llama/Llama-3.1-8B-Instruct
        - --port
        - "8000"
        - --tensor-parallel-size
        - "1"
        - --max-model-len
        - "16384"
        - --gpu-memory-utilization
        - "0.90"
        - --enable-prefix-caching
        - --enable-lora
        - --max-loras
        - "2"
        - --max-lora-rank
        - "8"
        - --lora-modules
        - food-review-1=Kawon/llama3.1-food-finetune_v14_r8
        env:
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-token
              key: token
        - name: VLLM_ALLOW_RUNTIME_LORA_UPDATING
          value: "true"
        ports:
        - name: http
          containerPort: 8000
          protocol: TCP
        startupProbe:
          httpGet:
            path: /health
            port: http
          periodSeconds: 10
          failureThreshold: 90
        readinessProbe:
          httpGet:
            path: /health
            port: http
          periodSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /health
            port: http
          periodSeconds: 10
          failureThreshold: 6
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "sleep 30"]
        resources:
          requests:
            cpu: "8"
            memory: 32Gi
            nvidia.com/gpu: "1"
          limits:
            memory: 32Gi
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: dshm
          mountPath: /dev/shm
        - name: hf-cache
          mountPath: /root/.cache/huggingface
      volumes:
      - name: dshm
        emptyDir:
          medium: Memory
          sizeLimit: 8Gi
      - name: hf-cache
        emptyDir: {}
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: vllm-llama3-8b-instruct
  namespace: llm
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: vllm-llama3-8b-instruct
```

Networking-relevant choices:

- `startupProbe` with a long budget (here 90 × 10 s = 15 min). Model loading takes minutes, and without it the liveness probe kills the pod in a restart loop.
- `readinessProbe` controls pool membership. The EPP only considers ready endpoints, the same way EndpointSlices do.
- `preStop` sleep plus a long `terminationGracePeriodSeconds`. Once a pod goes NotReady, the EPP and gateway stop sending it new requests, but its in-flight streams still need time to finish. Size the grace period to your p99 end-to-end generation time.
- `maxUnavailable: 0`. GPU capacity is scarce, so never drop below current capacity during a rollout.

> **No GPU in the lab?** The Inference Extension quickstart ships a vLLM **simulator** (`llm-d-inference-sim`). It exposes the same OpenAI API and the same `vllm:*` metrics, so you can practise the routing layer on a CPU-only cluster.

### 4.3 InferencePool

```yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: vllm-llama3-8b-instruct
  namespace: llm
spec:
  selector:
    matchLabels:
      app: vllm-llama3-8b-instruct
  targetPorts:
  - number: 8000
  endpointPickerRef:
    name: vllm-llama3-8b-instruct-epp
    port:
      number: 9002
    failureMode: FailClose
```

| Field | Meaning |
|---|---|
| `selector.matchLabels` | Which pods belong to the pool. Every pod must serve the **same base model** on the same accelerator type. |
| `targetPorts[].number` | Port on the pod the gateway sends traffic to. |
| `endpointPickerRef` | The Service in front of the EPP (defaults to `kind: Service`, core group). |
| `failureMode` | `FailClose`: the gateway returns an error when the EPP is unreachable. `FailOpen`: the gateway falls back to its own balancing across the pool. |

Choosing `failureMode`:

| | FailClose | FailOpen |
|---|---|---|
| EPP outage impact | Hard outage of the route (5xx) | Degraded balancing, and priority shedding is lost |
| Risk | Availability | Overloaded replicas and a TTFT blow-up during the outage |
| Use when | Strict fairness/priority guarantees matter more than availability | Availability comes first; EPP is treated as an optimisation |

Whichever you choose, run the EPP with ≥2 replicas (leader election / active-passive in the reference chart) and a PDB.

### 4.4 Deploy the Endpoint Picker

The project publishes a Helm chart that deploys the EPP (Deployment, Service, RBAC) and, optionally, the InferencePool. The `provider.name` value adds gateway-specific glue: for Istio, a `DestinationRule` for the TLS connection from the gateway to the EPP; for GKE, a health-check policy.

```
$ helm install vllm-llama3-8b-instruct \
    --namespace llm \
    --set inferencePool.modelServers.matchLabels.app=vllm-llama3-8b-instruct \
    --set provider.name=istio \
    --version v1.0.0 \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool
NAME: vllm-llama3-8b-instruct
NAMESPACE: llm
STATUS: deployed
REVISION: 1

$ kubectl -n llm get deploy,svc -l app=vllm-llama3-8b-instruct-epp
NAME                                          READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/vllm-llama3-8b-instruct-epp   1/1     1            1           42s

NAME                                  TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)             AGE
service/vllm-llama3-8b-instruct-epp   ClusterIP   10.96.41.187   <none>        9002/TCP,9090/TCP   42s
```

The EPP listens on `9002` (ext_proc gRPC) and `9090` (its own Prometheus metrics).

If the chart creates the InferencePool, don't also apply the manifest from 4.3. Use one or the other.

### 4.5 How the EPP scheduler decides

The EPP scheduler is a plugin pipeline: **filters** remove ineligible endpoints, **scorers** give each remaining endpoint a weighted score, and a **picker** chooses one. Typical plugins are:

| Plugin (conceptual) | Signal | Effect |
|---|---|---|
| Queue scorer | `vllm:num_requests_waiting` | Prefers pods with short queues, which minimises TTFT |
| KV-cache utilisation scorer | `vllm:kv_cache_usage_perc` (older vLLM: `vllm:gpu_cache_usage_perc`) | Avoids pods near KV exhaustion, where preemption and recomputation start |
| Prefix-cache scorer | Hashes of prompt prefix blocks, tracked per pod | Sends shared-prefix requests to the pod that already holds the blocks |
| LoRA affinity scorer | `vllm:lora_requests_info` (running/waiting adapters) | Prefers pods with the adapter already resident, or with a free adapter slot |
| Max-score picker | Combined score | Picks the best candidate (random tie-break) |

An illustrative configuration (plugin type names vary by release, so check the `config` directory of the release you run):

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha1
kind: EndpointPickerConfig
plugins:
- type: queue-scorer
- type: kv-cache-utilization-scorer
- type: prefix-cache-scorer
  parameters:
    blockSize: 64
    maxPrefixBlocksToMatch: 256
    lruCapacityPerServer: 31250
- type: max-score-picker
schedulingProfiles:
- name: default
  plugins:
  - pluginRef: queue-scorer
    weight: 2
  - pluginRef: kv-cache-utilization-scorer
    weight: 2
  - pluginRef: prefix-cache-scorer
    weight: 3
  - pluginRef: max-score-picker
```

**The central trade-off is cache affinity against load spread.** If the prefix scorer's weight is too high, every request with a popular system prompt lands on one pod and its queue grows without limit. If the weight is too low, the prefix cache never gets reused. Tune the weights against measured TTFT and the prefix-cache hit rate, not by intuition.

### 4.6 Gateway and HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: inference-gateway
  namespace: llm
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-route
  namespace: llm
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: inference-gateway
    sectionName: http
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: vllm-llama3-8b-instruct
      port: 8000
    timeouts:
      request: 600s
```

The `backendRef` points at the **InferencePool** (group `inference.networking.k8s.io`, kind `InferencePool`), not at a Service. This one line is what makes the gateway call the EPP for every request on this rule. Some implementations don't require `port` on an InferencePool backendRef because the pool defines `targetPorts`. Keep it if your implementation's validation expects it.

### 4.7 Priority with InferenceObjective

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: interactive-chat
  namespace: llm
spec:
  priority: 100
  poolRef:
    name: vllm-llama3-8b-instruct
---
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: batch-summaries
  namespace: llm
spec:
  priority: -10
  poolRef:
    name: vllm-llama3-8b-instruct
```

The client, or a gateway filter, names the objective in a request header (the reference EPP reads `x-gateway-inference-objective`). When the pool is saturated, the EPP holds or **sheds** lower-priority requests first. Shed requests get 429 (or 503, depending on the release and implementation) and should be retried later with backoff. Interactive traffic keeps its latency while batch work absorbs the overload.

This is admission control at the routing layer. A GPU server can't absorb a burst by "just queueing more", because every queued request makes TTFT worse for everyone behind it.

---

## 5. Inside the data path: ext_proc and ORIGINAL_DST

Knowing the Envoy primitives helps you debug any implementation (Istio, kgateway, Envoy Gateway and GKE all use them underneath). The following raw Envoy configuration shows the mechanism in isolation:

```yaml
static_resources:
  listeners:
  - name: llm_listener
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 8081
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: llm
          stream_idle_timeout: 300s
          request_timeout: 0s
          route_config:
            name: llm_routes
            virtual_hosts:
            - name: llm
              domains: ["*"]
              routes:
              - match:
                  prefix: "/v1/"
                route:
                  cluster: original_destination_cluster
                  timeout: 600s
                  idle_timeout: 120s
          http_filters:
          - name: envoy.filters.http.ext_proc
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
              failure_mode_allow: false
              message_timeout: 10s
              processing_mode:
                request_header_mode: SEND
                response_header_mode: SEND
                request_body_mode: FULL_DUPLEX_STREAMED
                request_trailer_mode: SEND
                response_body_mode: NONE
                response_trailer_mode: SKIP
              grpc_service:
                envoy_grpc:
                  cluster_name: epp
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: original_destination_cluster
    type: ORIGINAL_DST
    lb_policy: CLUSTER_PROVIDED
    connect_timeout: 10s
    original_dst_lb_config:
      use_http_header: true
      http_header_name: x-gateway-destination-endpoint
  - name: epp
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    connect_timeout: 5s
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options: {}
    load_assignment:
      cluster_name: epp
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: vllm-llama3-8b-instruct-epp.llm.svc.cluster.local
                port_value: 9002
```

Here is what each piece does:

1. `ext_proc` streams the request headers **and body** to the EPP. The body has to go too, because the model name, prompt (for prefix hashing) and `stream` flag are all in the JSON.
2. The EPP answers with a header mutation, `x-gateway-destination-endpoint: 10.244.2.17:8000`, and also returns it as dynamic metadata.
3. The `ORIGINAL_DST` cluster with `use_http_header: true` connects to exactly that IP:port. No Service VIP is involved, and kube-proxy doesn't get a second say.
4. `failure_mode_allow: false` is the Envoy equivalent of `FailClose`.
5. `timeout: 600s` is the route timeout (Envoy's default is **15 s**, fatal for LLM generation). `idle_timeout` bounds silence *between* stream chunks, and `stream_idle_timeout` does the same at the connection-manager level.

Because the body travels through `ext_proc`, **request body size limits** now matter. Very large RAG prompts (hundreds of KB) can hit proxy buffer limits and fail with `413` before any model sees them.

---

## 6. Model-aware routing: Body-Based Routing and canaries

OpenAI-compatible clients put the model name **in the JSON body** (`"model": "food-review-1"`), not in the path or in a header. `HTTPRoute` can only match on path, headers, query parameters and method. The Inference Extension closes this gap with the **Body-Based Router (BBR)**, a separate `ext_proc` that runs *before* route selection. BBR parses the body and copies `model` into the `X-Gateway-Model-Name` header, which standard `HTTPRoute` header matches can then use.

```
$ helm install body-based-router \
    --namespace llm \
    --set provider.name=istio \
    --version v1.0.0 \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/body-based-routing
NAME: body-based-router
STATUS: deployed
```

Routing two base models, plus a weighted canary of a new base-model build:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-model-routing
  namespace: llm
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: inference-gateway
    sectionName: http
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/
      headers:
      - type: Exact
        name: X-Gateway-Model-Name
        value: meta-llama/Llama-3.1-8B-Instruct
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: vllm-llama3-8b-instruct
      port: 8000
      weight: 90
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: vllm-llama3-8b-instruct-v2
      port: 8000
      weight: 10
    timeouts:
      request: 600s
  - matches:
    - path:
        type: PathPrefix
        value: /v1/
      headers:
      - type: Exact
        name: X-Gateway-Model-Name
        value: Qwen/Qwen2.5-32B-Instruct
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: vllm-qwen25-32b
      port: 8000
    timeouts:
      request: 900s
```

Notes:

- Each InferencePool serves **one base model** on one hardware profile. Split on the model and send traffic to separate pools. Mixing models in one pool makes the EPP's metrics comparisons meaningless.
- LoRA adapters of one base model live in the **same pool**. There, routing is the EPP's job (LoRA affinity), not the HTTPRoute's.
- The weighted split between two pools is standard Gateway API traffic splitting. Each pool keeps its own EPP, so both halves of the canary still get load-aware routing.
- Requests with an unknown model name match no rule and get a `404` from the gateway. That is usually better than letting the model server reply with a 400 after a GPU hop.

---

## 7. Timeouts, streaming, retries and draining

### 7.1 Timeouts

`HTTPRoute.spec.rules[].timeouts` (Standard channel since Gateway API v1.2):

| Field | Meaning | LLM guidance |
|---|---|---|
| `request` | Whole-request deadline from when the gateway receives the request until the full response completes | ≥ p99 end-to-end generation time, including streaming. `"0s"` disables the timeout, per the Gateway API spec. |
| `backendRequest` | Deadline for a single attempt to the backend (≤ `request`) | Useful with retries, so a stuck attempt can be retried within the overall budget |

Streaming responses stay open until the last token. On Envoy-based implementations the route timeout covers the **entire streamed response**, not just time-to-first-byte. A route with a 60 s `request` timeout truncates every generation longer than 60 s, and the client sees a stream that just stops (often with no error event).

Timeouts outside the gateway also need checking:

| Layer | Typical default | Symptom when it fires |
|---|---|---|
| Envoy route timeout (raw Envoy, Envoy Gateway) | 15 s | `504` / `upstream request timeout` on long completions |
| Cloud L4/L7 load balancer idle timeout | 60–350 s | Stream cut during a long silence (e.g. slow prefill of a huge prompt) |
| NGINX `proxy_read_timeout` | 60 s | `504` after exactly 60 s |
| Client SDK timeout | 60–600 s | Client-side abort; server keeps generating (wasted GPU) |

### 7.2 Streaming (SSE)

- Any **buffering** layer breaks streaming: the user sees nothing until the end. NGINX needs `proxy_buffering off` (or the `X-Accel-Buffering: no` response header). Envoy streams by default. Only enable response-body `ext_proc` modes or compression that buffer if you understand the effect.
- Leave **response compression** off for `text/event-stream`, since compressors buffer.
- HTTP/2 from client to gateway is fine and multiplexes streams. Between gateway and model server, HTTP/1.1 keep-alive is typical for vLLM.

### 7.3 Retries

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-route-retries
  namespace: llm
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: inference-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: vllm-llama3-8b-instruct
      port: 8000
    timeouts:
      request: 600s
      backendRequest: 300s
    retry:
      codes:
      - 503
      attempts: 1
      backoff: 200ms
```

`retry` is part of the Gateway API **Experimental** channel (GEP-1731), so check your installed CRDs and implementation support.

Retry policy for LLMs:

- **Retry connection failures and `503` returned before any response bytes.** The generation never started, so a retry is cheap and safe.
- **Don't retry `504`/timeouts automatically.** The first attempt may still be running on the GPU (the model server doesn't always detect the client disconnect immediately), so a retry doubles the load at exactly the moment the system is overloaded. That's a retry storm.
- **Never retry after streaming has begun.** The client would receive duplicated or divergent tokens. Envoy won't retry once response headers have been sent downstream, which is the correct behaviour.
- **Treat a `429` from priority shedding as a signal to back off.** The client should retry with exponential backoff and jitter. The gateway shouldn't retry it immediately.

### 7.4 Draining

When a model pod terminates:

1. The pod goes NotReady, is removed from EndpointSlices, and the EPP's pod watch drops it. No new requests arrive.
2. `preStop` sleep covers propagation delay to every gateway replica.
3. vLLM receives SIGTERM and finishes in-flight requests within `terminationGracePeriodSeconds`.

If the grace period is shorter than your longest generations, every rollout and every scale-down cuts off users mid-answer.

---

## 8. Token-based rate limiting and cost control

Request-rate limits don't fit a workload where cost is measured in tokens. AI-gateway implementations meter **tokens**: they read the `usage` object (`prompt_tokens`, `completion_tokens`, `total_tokens`) from the model's response and charge that against a budget.

Here is an example with **Envoy AI Gateway** running on **Envoy Gateway**. The AI Gateway's ext_proc extracts token usage into dynamic metadata, and an Envoy Gateway global rate-limit rule uses that metadata as the **cost** of the request. Global rate limiting requires the Envoy Gateway rate-limit service to be enabled with a Redis backend in the `EnvoyGateway` configuration.

```yaml
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIGatewayRoute
metadata:
  name: llm-ai-route
  namespace: llm
spec:
  parentRefs:
  - name: ai-gateway
    kind: Gateway
    group: gateway.networking.k8s.io
  rules:
  - matches:
    - headers:
      - type: Exact
        name: x-ai-eg-model
        value: meta-llama/Llama-3.1-8B-Instruct
    backendRefs:
    - name: vllm-llama3-8b-instruct
      group: inference.networking.k8s.io
      kind: InferencePool
  llmRequestCosts:
  - metadataKey: llm_input_token
    type: InputToken
  - metadataKey: llm_output_token
    type: OutputToken
  - metadataKey: llm_total_token
    type: TotalToken
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: llm-token-budget
  namespace: llm
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: llm-ai-route
  rateLimit:
    type: Global
    global:
      rules:
      - clientSelectors:
        - headers:
          - name: x-tenant-id
            type: Distinct
        limit:
          requests: 200000
          unit: Hour
        cost:
          request:
            from: Number
            number: 0
          response:
            from: Metadata
            metadata:
              namespace: io.envoy.ai_gateway
              key: llm_total_token
```

This works as follows:

- `x-tenant-id` with `type: Distinct` creates a separate bucket for **each tenant**.
- `request.number: 0` means the request is **checked** against the bucket on arrival (a tenant that's already over budget is rejected with `429`), but nothing is deducted up front.
- `response.from: Metadata` deducts the real `total_tokens` once the response completes. The unit `requests: 200000` therefore means **200k tokens per hour per tenant**.
- The AI Gateway controller translates the `AIGatewayRoute` into an `HTTPRoute` of the same name, which is why the policy targets an `HTTPRoute`.
- **Streaming caveat:** the token count is only known when the stream ends, and OpenAI-compatible servers only emit `usage` in a stream when `stream_options.include_usage` is set. Check whether your gateway injects it. Otherwise streamed requests are charged zero.
- **The budget can overshoot.** Because deduction happens after the fact, a tenant's final request can go over the limit by one request's worth of tokens. The check-then-charge model guarantees the budget is respected on average, not strictly.

Field names in `AIGatewayRoute` changed between Envoy AI Gateway minor releases (for example `targetRefs` → `parentRefs`, and how `InferencePool` backends are referenced), so verify them with `kubectl explain aigatewayroute.spec`.

| Control | Protects against | Layer |
|---|---|---|
| Token budget per tenant (above) | One tenant consuming the GPU fleet over time | AI gateway + rate-limit service |
| Priority / shedding (InferenceObjective) | Short-term saturation hurting interactive traffic | EPP |
| `max_tokens` cap (request validation / model server `--max-model-len`) | A single request's unbounded cost | Gateway policy / model server |
| Concurrency limit per pod (`--max-num-seqs`) | KV exhaustion and preemption thrash | Model server |

---

## 9. Capacity signals and autoscaling

CPU utilisation tells you nothing on a GPU inference pod. Scale on **queue depth** (a leading indicator of TTFT) or on **KV-cache utilisation**.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: vllm-llama3-8b-instruct
  namespace: llm
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: vllm-llama3-8b-instruct
  minReplicaCount: 2
  maxReplicaCount: 8
  pollingInterval: 15
  cooldownPeriod: 900
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0
          policies:
          - type: Pods
            value: 2
            periodSeconds: 60
        scaleDown:
          stabilizationWindowSeconds: 900
          policies:
          - type: Pods
            value: 1
            periodSeconds: 300
  triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus-operated.monitoring.svc:9090
      query: 'sum(vllm:num_requests_waiting{namespace="llm",model_name="meta-llama/Llama-3.1-8B-Instruct"})'
      threshold: "3"
```

Design notes:

- **Scale up aggressively and scale down slowly.** A new replica takes minutes to become Ready (image and weights download), so late scale-up hurts. Flapping scale-down throws away warm KV/prefix caches and loaded adapters.
- Scale on the **pool-wide sum** of waiting requests divided by a target per replica (`threshold` behaves as an average-value target). Per-pod peaks are misleading with a load-aware router that is already evening them out.
- Pre-pull images and cache weights on a node-local volume or a shared read-only volume to shorten cold start. This does more for tail latency than any HPA setting.
- The EPP publishes pool-level aggregates such as average queue size and KV-cache utilisation. These are usable as a single scaling signal when the model-server metrics are too fine-grained.

### Key metrics

| Metric | Source | What it tells you |
|---|---|---|
| `vllm:time_to_first_token_seconds` (histogram) | Model server | Queueing + prefill latency. The primary interactive SLI. |
| `vllm:time_per_output_token_seconds` / inter-token latency | Model server | Decode speed; the "smoothness" of streaming |
| `vllm:e2e_request_latency_seconds` | Model server | Whole-generation latency; sizes timeouts and grace periods |
| `vllm:num_requests_running` / `vllm:num_requests_waiting` | Model server | Concurrency and queue; the scaling signal |
| `vllm:kv_cache_usage_perc` (older: `vllm:gpu_cache_usage_perc`) | Model server | Memory headroom; near 1.0 → preemption |
| `vllm:num_preemptions_total` | Model server | Requests evicted from KV cache and recomputed (wasted GPU) |
| `vllm:prompt_tokens_total`, `vllm:generation_tokens_total` | Model server | Throughput in tokens; the capacity-planning basis |
| EPP request / pool metrics (e.g. `inference_objective_request_total`, `inference_pool_average_queue_size`, `inference_pool_ready_pods`) | EPP `:9090/metrics` | Routing volume, per-objective errors, pool health as the router sees it |

---

## 10. Verification and troubleshooting

### 10.1 Check the control-plane objects

```
$ kubectl -n llm get gateway,httproute,inferencepool
NAME                                                  CLASS   ADDRESS        PROGRAMMED   AGE
gateway.gateway.networking.k8s.io/inference-gateway   istio   172.18.255.200 True         12m

NAME                                            HOSTNAMES   AGE
httproute.gateway.networking.k8s.io/llm-route               11m

NAME                                                           AGE
inferencepool.inference.networking.k8s.io/vllm-llama3-8b-instruct   10m
```

```
$ kubectl -n llm get httproute llm-route -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
Accepted=True (Accepted)
ResolvedRefs=True (ResolvedRefs)
```

`ResolvedRefs=False` with reason `InvalidKind` means the implementation doesn't recognise `InferencePool` as a backend. The cause is either the inference extension not being enabled in the gateway (e.g. the Istio pilot flag), or a wrong `group` in the `backendRef`. Reason `BackendNotFound` means a name or namespace mismatch.

```
$ kubectl -n llm get inferencepool vllm-llama3-8b-instruct -o yaml | yq '.status'
parents:
- conditions:
  - lastTransitionTime: "2026-09-30T10:14:02Z"
    message: ""
    observedGeneration: 1
    reason: Accepted
    status: "True"
    type: Accepted
  - lastTransitionTime: "2026-09-30T10:14:02Z"
    message: ""
    observedGeneration: 1
    reason: ResolvedRefs
    status: "True"
    type: ResolvedRefs
  parentRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: inference-gateway
```

### 10.2 Check pool membership: selector vs pods

```
$ kubectl -n llm get pods -l app=vllm-llama3-8b-instruct -o wide
NAME                                       READY   STATUS    RESTARTS   AGE   IP            NODE
vllm-llama3-8b-instruct-6f9c7d8b9d-4kq2x   1/1     Running   0          14m   10.244.1.23   gpu-node-1
vllm-llama3-8b-instruct-6f9c7d8b9d-9zt7m   1/1     Running   0          14m   10.244.2.17   gpu-node-2
vllm-llama3-8b-instruct-6f9c7d8b9d-hx5wd   0/1     Running   0          2m    10.244.3.8    gpu-node-3
```

The third pod is still loading its model (`0/1`). The EPP has to exclude it, and its logs should show only two ready endpoints.

### 10.3 Check the EPP

```
$ kubectl -n llm logs deploy/vllm-llama3-8b-instruct-epp --tail=20
{"level":"info","ts":"2026-09-30T10:14:05Z","msg":"Pod added","pod":"llm/vllm-llama3-8b-instruct-6f9c7d8b9d-4kq2x","address":"10.244.1.23"}
{"level":"info","ts":"2026-09-30T10:14:05Z","msg":"Pod added","pod":"llm/vllm-llama3-8b-instruct-6f9c7d8b9d-9zt7m","address":"10.244.2.17"}
{"level":"info","ts":"2026-09-30T10:14:06Z","msg":"Starting ext-proc gRPC server","port":9002}
```

(Log wording differs between releases. What you're checking is that there are *pod added* events for the ready pods and that the gRPC server started.)

Metrics as the EPP sees them:

```
$ kubectl -n llm port-forward svc/vllm-llama3-8b-instruct-epp 9090:9090 &
$ curl -s localhost:9090/metrics | grep -E '^inference_pool_(ready_pods|average_queue_size|average_kv_cache_utilization)'
inference_pool_average_kv_cache_utilization{name="vllm-llama3-8b-instruct"} 0.41
inference_pool_average_queue_size{name="vllm-llama3-8b-instruct"} 0.5
inference_pool_ready_pods{name="vllm-llama3-8b-instruct"} 2
```

The same data straight from a model server, to confirm that the metric names the EPP expects actually exist in your vLLM version:

```
$ kubectl -n llm port-forward pod/vllm-llama3-8b-instruct-6f9c7d8b9d-4kq2x 8000:8000 &
$ curl -s localhost:8000/metrics | grep -E '^vllm:(num_requests_waiting|num_requests_running|kv_cache_usage_perc|gpu_cache_usage_perc|lora_requests_info)'
vllm:num_requests_running{engine="0",model_name="meta-llama/Llama-3.1-8B-Instruct"} 3.0
vllm:num_requests_waiting{engine="0",model_name="meta-llama/Llama-3.1-8B-Instruct"} 0.0
vllm:kv_cache_usage_perc{engine="0",model_name="meta-llama/Llama-3.1-8B-Instruct"} 0.37
vllm:lora_requests_info{max_lora="2",running_lora_adapters="food-review-1",waiting_lora_adapters=""} 1.759227245e+09
```

If the EPP is configured to scrape `vllm:gpu_cache_usage_perc` and the server only exports `vllm:kv_cache_usage_perc` (or the other way round), the KV scorer silently sees zero for every pod. Routing still "works", but the KV signal isn't being used. Align the EPP flags with the model server version.

### 10.4 End-to-end requests

```
$ IP=$(kubectl -n llm get gateway inference-gateway -o jsonpath='{.status.addresses[0].value}')

$ curl -s -i "http://${IP}/v1/completions" \
    -H 'Content-Type: application/json' \
    -H 'x-gateway-inference-objective: interactive-chat' \
    -d '{"model":"food-review-1","prompt":"Write as if you were a critic: San Francisco","max_tokens":64,"temperature":0}'
HTTP/1.1 200 OK
content-type: application/json
x-went-into-resp-headers: true
date: Wed, 30 Sep 2026 10:21:44 GMT
server: istio-envoy

{"id":"cmpl-4f6c...","object":"text_completion","created":1790763704,"model":"food-review-1","choices":[{"index":0,"text":" The city by the bay ...","logprobs":null,"finish_reason":"length"}],"usage":{"prompt_tokens":11,"total_tokens":75,"completion_tokens":64}}
```

Streaming, measuring TTFT and total time from the client side:

```
$ curl -s -N -o /dev/null "http://${IP}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","stream":true,"max_tokens":512,"messages":[{"role":"user","content":"Explain KV cache in 5 paragraphs"}]}' \
    -w 'ttfb=%{time_starttransfer}s total=%{time_total}s code=%{http_code}\n'
ttfb=0.183s total=7.912s code=200
```

To see the raw stream and confirm it isn't being buffered, drop `-o /dev/null`. Chunks should arrive progressively as `data: {...}` lines, ending with `data: [DONE]`:

```
data: {"id":"chatcmpl-...","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}
data: {"id":"chatcmpl-...","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"The"}}]}
...
data: [DONE]
```

If `ttfb` is nearly equal to `total`, some layer is buffering the response.

### 10.5 Proving the router balances by load

Send a burst of concurrent long requests, then compare queue depth across pods:

```
$ for i in $(seq 1 40); do
    curl -s -o /dev/null "http://${IP}/v1/completions" -H 'Content-Type: application/json' \
      -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":"Tell a long story","max_tokens":1024}' &
  done; sleep 5

$ for p in $(kubectl -n llm get pods -l app=vllm-llama3-8b-instruct -o name); do
    echo -n "$p "; kubectl -n llm exec "$p" -- curl -s localhost:8000/metrics | grep '^vllm:num_requests_running' | awk '{print $2}'
  done
pod/vllm-llama3-8b-instruct-6f9c7d8b9d-4kq2x 14.0
pod/vllm-llama3-8b-instruct-6f9c7d8b9d-9zt7m 13.0
pod/vllm-llama3-8b-instruct-6f9c7d8b9d-hx5wd 13.0
```

An even spread under a mixed-length burst is what you expect. A 30/5/5 spread points to either a dominant prefix-affinity weight or an HTTPRoute that isn't using the InferencePool (for example, a `backendRef` to a Service with connection reuse).

### 10.6 Failure-mode table

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| `500`/`503` on every request, EPP pod not Ready | EPP down with `failureMode: FailClose` | `kubectl get pods -l app=<pool>-epp`; gateway logs show ext_proc errors | Restore the EPP, run ≥2 replicas plus a PDB; consider `FailOpen` |
| `503 no healthy upstream` while model pods are Ready | Pool selector doesn't match pod labels, or `targetPorts` is wrong | Compare `inferencepool.spec.selector` with `kubectl get pods --show-labels`; EPP logs show no *pod added* | Fix the labels or ports |
| HTTPRoute `ResolvedRefs=False`, `InvalidKind` | Gateway doesn't support InferencePool, or the extension isn't enabled | `kubectl get httproute -o yaml` status | Enable the extension (Istio pilot env) or use a conformant implementation; fix the `group` |
| Istio gateway can't reach EPP (TLS errors in gateway logs) | Missing `DestinationRule` for the EPP's self-signed TLS | `istioctl proxy-config cluster` / Envoy logs | Install the chart with `provider.name=istio` |
| Long completions cut at exactly 15 s / 60 s | Route or LB timeout | Time-to-failure is constant; `504` / truncated stream | Raise `timeouts.request`, proxy and LB idle timeouts |
| Streaming arrives all at once | Buffering proxy or compression | `ttfb ≈ total` with `curl -N` | `proxy_buffering off`, disable compression for SSE |
| `413 Payload Too Large` on RAG prompts | Body buffer limit in the gateway / ext_proc path | Correlates with prompt size | Raise the proxy's per-request buffer limit; cap prompt size in the client |
| `429` for low-priority traffic under load | Intended EPP shedding (lower `priority`) | EPP metrics per objective; model queue high | Add capacity, or have batch clients retry with backoff and jitter |
| `429` for one tenant only, pool idle | Token budget exhausted | Rate-limit service logs / metrics | Raise the budget or wait for the window to reset |
| One pod hot, others idle | Prefix-affinity over-weighted, or bypass of the EPP (Service backendRef, HTTP/2 connection pinning) | Per-pod `num_requests_running`; HTTPRoute `backendRefs` | Rebalance scorer weights; route to the InferencePool |
| Latency spikes for LoRA requests | Adapter swapping; `--max-loras` too low for adapter count | `vllm:lora_requests_info` shows churn | Raise `--max-loras`, split adapters across pools, check the LoRA affinity scorer |
| TTFT fine but high `vllm:num_preemptions_total` | KV cache exhaustion under long contexts | `vllm:kv_cache_usage_perc` near 1.0 | Lower `--max-num-seqs`, cap `max_tokens`, add replicas, weight the KV scorer higher |
| Users cut off during rollouts | Grace period shorter than generations | Errors correlate with pod terminations | Increase `terminationGracePeriodSeconds`, add `preStop`, `maxUnavailable: 0` |
| Retry storm during overload | Gateway retries timeouts / 5xx after work started | Backend RPS > client RPS in metrics | Retry only `503` before first byte; no retries on `504` |

---

## 11. Design checklist

1. **Route to an `InferencePool`, not a Service**, so the EPP picks the pod with real load data.
2. **One pool per base model × hardware profile.** Route across pools by model name (BBR → `X-Gateway-Model-Name`).
3. **Choose `failureMode` deliberately.** Make the EPP highly available either way.
4. **Set timeouts for full-length generations**, at every layer from client to model server.
5. **Keep SSE unbuffered and uncompressed** from end to end.
6. **Retry only failures that happened before generation started.** Never retry mid-stream.
7. **Meter and limit tokens, not requests**, per tenant. Make sure streamed responses report usage.
8. **Protect interactive traffic with priority/shedding**, and give batch traffic lower priority.
9. **Scale on queue depth or KV-cache usage.** Scale up fast, scale down slowly, and cut cold-start time.
10. **Drain gracefully:** readiness gating, a `preStop` sleep, and a grace period of at least p99 generation time.

---

## Referencias

- CKNE certification page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Gateway API Inference Extension documentation: https://gateway-api-inference-extension.sigs.k8s.io/
- Gateway API Inference Extension, API overview: https://gateway-api-inference-extension.sigs.k8s.io/concepts/api-overview/
- Gateway API Inference Extension, API reference: https://gateway-api-inference-extension.sigs.k8s.io/reference/spec/
- Gateway API Inference Extension source and releases: https://github.com/kubernetes-sigs/gateway-api-inference-extension
- Kubernetes blog, "Introducing Gateway API Inference Extension": https://kubernetes.io/blog/2025/06/05/introducing-gateway-api-inference-extension/
- Gateway API, HTTPRoute timeouts (GEP-1742): https://gateway-api.sigs.k8s.io/geps/gep-1742/
- Gateway API, HTTPRoute retries (GEP-1731): https://gateway-api.sigs.k8s.io/geps/gep-1731/
- Gateway API, HTTP traffic splitting: https://gateway-api.sigs.k8s.io/guides/traffic-splitting/
- Envoy External Processing filter: https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_proc_filter
- Envoy original destination cluster: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/service_discovery#original-destination
- Envoy route timeouts: https://www.envoyproxy.io/docs/envoy/latest/faq/configuration/timeouts
- Envoy AI Gateway documentation: https://aigateway.envoyproxy.io/docs/
- Envoy Gateway global rate limiting: https://gateway.envoyproxy.io/docs/tasks/traffic/global-rate-limit/
- Istio, Gateway API Inference Extension support: https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api-inference-extension/
- vLLM production metrics: https://docs.vllm.ai/en/latest/usage/metrics.html
- vLLM LoRA adapters: https://docs.vllm.ai/en/latest/features/lora.html
- vLLM automatic prefix caching: https://docs.vllm.ai/en/latest/features/automatic_prefix_caching.html
- KEDA Prometheus scaler: https://keda.sh/docs/latest/scalers/prometheus/
- Kubernetes Pod lifecycle and termination: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination
- llm-d (disaggregated inference on Kubernetes): https://llm-d.ai/