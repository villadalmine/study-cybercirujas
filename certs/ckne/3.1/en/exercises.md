# Optimizing LLM Traffic: Guided Exercises (CKNE 3.1)

> **Exam weight:** 5% · **Scope:** model-aware routing with the Gateway API Inference Extension (`InferencePool`, `InferenceObjective`, Endpoint Picker), body-based routing, streaming-safe timeouts, failure modes, and diagnosing LLM traffic on Kubernetes.

**Official references used throughout:**

- CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Gateway API Inference Extension: https://gateway-api-inference-extension.sigs.k8s.io/
- Gateway API (HTTPRoute, timeouts): https://gateway-api.sigs.k8s.io/
- Envoy External Processing filter: https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_proc_filter
- vLLM production metrics: https://docs.vllm.ai/
- llm-d inference simulator: https://github.com/llm-d/llm-d-inference-sim
- Istio Gateway API support: https://istio.io/latest/docs/

---

## Lab setup and conventions

You need no GPU. These exercises use the **llm-d inference simulator**, which exposes the same OpenAI-compatible API and the same `vllm:*` Prometheus metrics as a real vLLM server. It fakes token generation with configurable latency.

**Requirements**

- A Kubernetes cluster at v1.29 or later. `kind`, `k3d` or a small cloud cluster all work. You need enough CPU for about 6 small pods.
- `kubectl`, `helm` v3.8+ (for OCI charts), `curl`, `jq`.
- A Gateway API implementation that supports the Inference Extension. The commands below use **Istio**. kgateway, Envoy Gateway / Envoy AI Gateway and GKE Gateway work too; only the `gatewayClassName` and the provider-specific install step change.

**Version pinning.** Every command below that names a version uses a variable. Before you start, look up the current releases and set them:

```
export GW_API_VERSION=v1.3.0        # Gateway API standard channel
export GIE_VERSION=v1.0.0           # Gateway API Inference Extension
export SIM_IMAGE=ghcr.io/llm-d/llm-d-inference-sim:latest   # pin a tag in real use
```

Command output in this document is **representative**. Your pod names, IPs and exact numbers will differ. Metric names can also change between vLLM/EPP versions. When a metric is missing, `grep` the `/metrics` endpoint instead of assuming it was renamed.

---

## Exercise 1: Why round-robin is the wrong algorithm for LLMs

**Goal:** see for yourself why a plain `Service` (kube-proxy / L4 load balancing) handles inference traffic badly.

### Steps

1. Create the namespace and three simulated model-server replicas behind a normal ClusterIP Service:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: llm
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-llama3-8b-instruct
  namespace: llm
spec:
  replicas: 3
  selector:
    matchLabels:
      app: vllm-llama3-8b-instruct
  template:
    metadata:
      labels:
        app: vllm-llama3-8b-instruct
    spec:
      containers:
      - name: vllm-sim
        image: ghcr.io/llm-d/llm-d-inference-sim:latest
        imagePullPolicy: IfNotPresent
        args:
        - --model
        - meta-llama/Llama-3.1-8B-Instruct
        - --port
        - "8000"
        - --max-num-seqs
        - "4"
        - --time-to-first-token
        - "200"
        - --inter-token-latency
        - "50"
        - --max-loras
        - "2"
        - --lora-modules
        - '{"name":"food-review-1"}'
        ports:
        - name: http
          containerPort: 8000
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          periodSeconds: 5
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-llama3-8b-instruct
  namespace: llm
spec:
  selector:
    app: vllm-llama3-8b-instruct
  ports:
  - name: http
    port: 8000
    targetPort: 8000
```

   Save it as `01-sim.yaml` and apply it:

```
kubectl apply -f 01-sim.yaml
kubectl -n llm rollout status deploy/vllm-llama3-8b-instruct
kubectl -n llm get pods -o wide -l app=vllm-llama3-8b-instruct
```

   Expected:

```
NAME                                       READY   STATUS    RESTARTS   AGE   IP
vllm-llama3-8b-instruct-7c9f8d6b5d-2kq7x   1/1     Running   0          40s   10.244.1.12
vllm-llama3-8b-instruct-7c9f8d6b5d-m4hzp   1/1     Running   0          40s   10.244.2.9
vllm-llama3-8b-instruct-7c9f8d6b5d-xw8rt   1/1     Running   0          40s   10.244.1.13
```

2. Start a throwaway client pod and send a single completion through the Service:

```
kubectl -n llm run client --image=curlimages/curl:8.10.1 --restart=Never -- sleep 3600
kubectl -n llm wait --for=condition=Ready pod/client

kubectl -n llm exec client -- curl -s http://vllm-llama3-8b-instruct:8000/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":"Explain kube-proxy","max_tokens":20}'
```

   Expected (simulated text, truncated):

```
{"id":"cmpl-5a1...","object":"text_completion","model":"meta-llama/Llama-3.1-8B-Instruct","choices":[{"index":0,"text":"...","finish_reason":"length"}],"usage":{"prompt_tokens":4,"completion_tokens":20,"total_tokens":24}}
```

3. Create an uneven load: a few very long generations mixed with many short ones. This mirrors real traffic, where output length varies by orders of magnitude.

```
kubectl -n llm exec client -- sh -c '
for i in $(seq 1 6); do
  curl -s -o /dev/null http://vllm-llama3-8b-instruct:8000/v1/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"meta-llama/Llama-3.1-8B-Instruct\",\"prompt\":\"long\",\"max_tokens\":600}" &
done
for i in $(seq 1 24); do
  curl -s -o /dev/null http://vllm-llama3-8b-instruct:8000/v1/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"meta-llama/Llama-3.1-8B-Instruct\",\"prompt\":\"short\",\"max_tokens\":5}" &
done
wait' &
```

4. While that runs, scrape each pod's queue depth directly:

```
for ip in $(kubectl -n llm get pods -l app=vllm-llama3-8b-instruct -o jsonpath='{.items[*].status.podIP}'); do
  echo "== $ip"
  kubectl -n llm exec client -- curl -s http://$ip:8000/metrics \
    | grep -E '^vllm:(num_requests_running|num_requests_waiting|gpu_cache_usage_perc|kv_cache_usage_perc)'
done
```

   Representative output:

```
== 10.244.1.12
vllm:num_requests_running{model_name="meta-llama/Llama-3.1-8B-Instruct"} 4
vllm:num_requests_waiting{model_name="meta-llama/Llama-3.1-8B-Instruct"} 7
vllm:gpu_cache_usage_perc{model_name="meta-llama/Llama-3.1-8B-Instruct"} 0.81
== 10.244.2.9
vllm:num_requests_running{model_name="meta-llama/Llama-3.1-8B-Instruct"} 2
vllm:num_requests_waiting{model_name="meta-llama/Llama-3.1-8B-Instruct"} 0
vllm:gpu_cache_usage_perc{model_name="meta-llama/Llama-3.1-8B-Instruct"} 0.12
== 10.244.1.13
vllm:num_requests_running{model_name="meta-llama/Llama-3.1-8B-Instruct"} 4
vllm:num_requests_waiting{model_name="meta-llama/Llama-3.1-8B-Instruct"} 3
vllm:gpu_cache_usage_perc{model_name="meta-llama/Llama-3.1-8B-Instruct"} 0.55
```

### Questions

- **Q1.1** kube-proxy (iptables or IPVS round-robin/random) spread the *connections* roughly evenly. Why are the *queues* so uneven anyway?
- **Q1.2** `--max-num-seqs 4` caps concurrent sequences per replica. What does `num_requests_waiting > 0` mean for a request's **time to first token (TTFT)**?
- **Q1.3** Name two server-side signals that a load balancer would need to see to route this traffic well. Why can't an L4 balancer see them?
- **Q1.4** Would switching the Service to `sessionAffinity: ClientIP` help? When could it actually make things worse?

---

## Exercise 2: Install Gateway API, the Inference Extension CRDs and a Gateway

**Goal:** install the control-plane pieces and learn which API groups own which resources.

### Steps

1. Install the Gateway API standard-channel CRDs, then the Inference Extension CRDs:

```
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GW_API_VERSION}/standard-install.yaml
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml
```

2. List what was added:

```
kubectl get crd | grep -E 'gateway.networking.k8s.io|inference.networking'
```

   Expected (subset):

```
gatewayclasses.gateway.networking.k8s.io                 2026-09-30T10:02:11Z
gateways.gateway.networking.k8s.io                       2026-09-30T10:02:11Z
httproutes.gateway.networking.k8s.io                     2026-09-30T10:02:12Z
inferencepools.inference.networking.k8s.io               2026-09-30T10:02:20Z
inferenceobjectives.inference.networking.x-k8s.io        2026-09-30T10:02:20Z
```

3. Check which API versions each CRD serves:

```
kubectl get crd inferencepools.inference.networking.k8s.io \
  -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{" storage="}{.storage}{"\n"}{end}'
kubectl get crd inferenceobjectives.inference.networking.x-k8s.io \
  -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{" storage="}{.storage}{"\n"}{end}'
```

   Representative:

```
v1 served=true storage=true
v1alpha2 served=true storage=true
```

4. Install Istio with the Inference Extension integration turned on. Then create the Gateway:

```
istioctl install -y --set profile=minimal \
  --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true
```

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
```

```
kubectl apply -f 02-gateway.yaml
kubectl -n llm wait --for=condition=Programmed gateway/inference-gateway --timeout=120s
kubectl -n llm get gateway inference-gateway
```

   Expected:

```
NAME                CLASS   ADDRESS        PROGRAMMED   AGE
inference-gateway   istio   10.96.200.41   True         35s
```

### Questions

- **Q2.1** `InferencePool` lives in `inference.networking.k8s.io`, while `InferenceObjective` lives in `inference.networking.x-k8s.io`. What does the `x-` prefix tell you about each API's stability and support guarantees?
- **Q2.2** The Inference Extension is not a new proxy. So what is it, architecturally? Which Envoy mechanism lets a Gateway implementation delegate the endpoint choice?
- **Q2.3** Why does the Istio control plane need a feature flag before it will translate an `HTTPRoute` whose backend is an `InferencePool`?

---

## Exercise 3: Create an InferencePool and its Endpoint Picker (EPP)

**Goal:** replace "any ready pod" with "the best pod right now", as chosen by an Endpoint Picker.

### Steps

1. Install the `inferencepool` Helm chart. It creates the `InferencePool`, the EPP Deployment and Service, the RBAC, and (for Istio) the provider-specific glue such as a `DestinationRule` for the EPP:

```
helm install vllm-llama3-8b-instruct \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version ${GIE_VERSION} \
  --namespace llm \
  --set inferencePool.modelServers.matchLabels.app=vllm-llama3-8b-instruct \
  --set provider.name=istio
```

2. Look at the resulting pool. Its shape should match this manifest (written out so you can see every field):

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

```
kubectl -n llm get inferencepool vllm-llama3-8b-instruct -o yaml | sed -n '/^spec:/,$p'
kubectl -n llm get deploy,svc -l app.kubernetes.io/name=vllm-llama3-8b-instruct-epp 2>/dev/null \
  || kubectl -n llm get deploy,svc | grep epp
```

   Expected:

```
deployment.apps/vllm-llama3-8b-instruct-epp   1/1     1            1           50s
service/vllm-llama3-8b-instruct-epp           ClusterIP   10.96.14.7   <none>   9002/TCP,9090/TCP   50s
```

3. Read the EPP startup logs. Confirm that it discovered the three model-server pods and is scraping them:

```
kubectl -n llm logs deploy/vllm-llama3-8b-instruct-epp | grep -iE 'pod|metrics|pool' | head -20
```

4. Scale the model server and watch the EPP follow. No Service or EndpointSlice change is involved in its decision set:

```
kubectl -n llm scale deploy/vllm-llama3-8b-instruct --replicas=4
kubectl -n llm logs deploy/vllm-llama3-8b-instruct-epp --since=30s | grep -iE 'add|pod' 
```

### Questions

- **Q3.1** `InferencePool.spec.selector` looks like a Service selector. Why did the designers make `InferencePool` a *backend type* for `HTTPRoute` rather than reusing `Service`?
- **Q3.2** Port 9002 on the EPP speaks gRPC. Which Envoy API is it serving, and in what order do the proxy, the EPP and the model server exchange messages for one request?
- **Q3.3** List the inputs the EPP uses to score endpoints. Which of them come from the request, and which from scraping the model servers?
- **Q3.4** The EPP sees three pods but only allows 4 concurrent sequences each. What does the EPP do that kube-proxy never could when *every* pod is saturated?

---

## Exercise 4: Route to the pool, with timeouts that survive streaming

**Goal:** attach an `HTTPRoute` to the `InferencePool` and set timeouts that fit long-lived token streams.

### Steps

1. Create the route:

```yaml
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
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: vllm-llama3-8b-instruct
    timeouts:
      request: 300s
```

```
kubectl apply -f 04-route.yaml
kubectl -n llm get httproute llm-route \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
```

   Expected:

```
Accepted=True (Accepted)
ResolvedRefs=True (ResolvedRefs)
```

2. Send a non-streaming request through the Gateway:

```
GW=$(kubectl -n llm get gateway inference-gateway -o jsonpath='{.status.addresses[0].value}')
kubectl -n llm exec client -- curl -si http://$GW/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":"What is an InferencePool?","max_tokens":30}'
```

3. Send a **streaming** request and watch the Server-Sent Events arrive one chunk at a time:

```
kubectl -n llm exec client -- curl -sN http://$GW/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","stream":true,"max_tokens":40,
       "messages":[{"role":"user","content":"Stream me a haiku about Envoy"}]}'
```

   Expected:

```
data: {"id":"chatcmpl-9c...","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Pack"}}]}

data: {"id":"chatcmpl-9c...","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"ets"}}]}

...
data: [DONE]
```

4. Break it on purpose. Change `timeouts.request` to `2s`, re-apply, and send a request with `"max_tokens":200`. At 50 ms per token that needs about 10 s:

```
kubectl -n llm patch httproute llm-route --type=json \
  -p='[{"op":"replace","path":"/spec/rules/0/timeouts/request","value":"2s"}]'
kubectl -n llm exec client -- curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' \
  http://$GW/v1/completions -H 'Content-Type: application/json' \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":"x","max_tokens":200}'
```

   Expected:

```
504 2.004s
```

   Restore it to `300s` afterwards.

### Questions

- **Q4.1** Why does `ResolvedRefs=True` depend on the Inference Extension CRDs being installed *and* the Gateway implementation supporting them? What reason would you expect if either piece were missing?
- **Q4.2** With `timeouts.request` at 2 s, what does a *streaming* client see: an HTTP 504, or a stream cut off after some tokens? Why is that harder to spot in dashboards?
- **Q4.3** Give two reasons, other than timeouts, why proxy **response buffering** hurts LLM streaming.
- **Q4.4** Why is a per-request timeout a blunt tool for inference? What would a better SLO signal be?

---

## Exercise 5: Watch the Endpoint Picker make decisions

**Goal:** turn "the gateway picked a pod" into something you can observe and prove.

### Steps

1. Port-forward the EPP metrics port and list the pool-level gauges:

```
kubectl -n llm port-forward deploy/vllm-llama3-8b-instruct-epp 9090:9090 &
curl -s localhost:9090/metrics | grep -E '^inference_(pool|objective|model)_' | sort | head -30
```

   Representative:

```
inference_pool_average_kv_cache_utilization{name="vllm-llama3-8b-instruct"} 0.21
inference_pool_average_queue_size{name="vllm-llama3-8b-instruct"} 0.5
inference_pool_ready_pods{name="vllm-llama3-8b-instruct"} 4
inference_objective_request_total{model_name="meta-llama/Llama-3.1-8B-Instruct",target_model_name="meta-llama/Llama-3.1-8B-Instruct"} 12
```

2. Rerun the mixed load from Exercise 1, step 3, this time against `http://$GW/v1/completions`. While it runs, sample every pod's queue again (same loop as Exercise 1, step 4).

3. Raise the EPP log verbosity temporarily. Then find the scheduling decisions for single requests:

```
kubectl -n llm set env deploy/vllm-llama3-8b-instruct-epp -- 2>/dev/null; \
kubectl -n llm get deploy vllm-llama3-8b-instruct-epp -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
```

   If the args include `--v=` or `-v=`, raise it (for example to 4) with `kubectl edit`. Then:

```
kubectl -n llm logs deploy/vllm-llama3-8b-instruct-epp --since=1m \
  | grep -iE 'schedul|picked|target|endpoint' | tail -10
```

4. Prove which pod served a request by comparing per-pod request counters before and after a single call:

```
for ip in $(kubectl -n llm get pods -l app=vllm-llama3-8b-instruct -o jsonpath='{.items[*].status.podIP}'); do
  printf '%s ' $ip
  kubectl -n llm exec client -- curl -s http://$ip:8000/metrics | grep -E '^vllm:request_success_total' | awk '{s+=$2} END {print s+0}'
done
```

### Questions

- **Q5.1** Compare the per-pod `num_requests_waiting` spread here with Exercise 1. Explain the difference in terms of what each balancer knows.
- **Q5.2** The EPP puts its choice in a request header / dynamic metadata that the proxy honours (`x-gateway-destination-endpoint`). Why must the proxy be configured to *trust* only the EPP for this, and never the client?
- **Q5.3** The EPP learns pod state by scraping, so there is a delay. What happens under a sudden burst if its view is stale by a few hundred milliseconds? Which scorer helps offset that?
- **Q5.4** What is **prefix-cache-aware** scoring, and why does it pay off for chat workloads that resend a long system prompt?

---

## Exercise 6: Priorities and load shedding with InferenceObjective

**Goal:** when the pool is saturated, protect interactive traffic and shed the batch traffic.

### Steps

1. Create two objectives against the same pool:

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: chat-interactive
  namespace: llm
spec:
  priority: 10
  poolRef:
    group: inference.networking.k8s.io
    name: vllm-llama3-8b-instruct
---
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: batch-summaries
  namespace: llm
spec:
  priority: -1
  poolRef:
    group: inference.networking.k8s.io
    name: vllm-llama3-8b-instruct
```

```
kubectl apply -f 06-objectives.yaml
kubectl -n llm get inferenceobjectives
```

2. Scale the model servers down to 1 replica so saturation is easy to reach:

```
kubectl -n llm scale deploy/vllm-llama3-8b-instruct --replicas=1
```

3. Flood the pool with batch traffic. Tag each request with the objective header (check your EPP version's docs for the exact header name; v1.x uses `x-gateway-inference-objective`):

```
kubectl -n llm exec client -- sh -c '
for i in $(seq 1 40); do
  curl -s -o /dev/null -w "batch %{http_code}\n" http://'"$GW"'/v1/completions \
    -H "Content-Type: application/json" \
    -H "x-gateway-inference-objective: batch-summaries" \
    -d "{\"model\":\"meta-llama/Llama-3.1-8B-Instruct\",\"prompt\":\"sum\",\"max_tokens\":300}" &
done; wait' | sort | uniq -c
```

   Representative:

```
      9 batch 200
     31 batch 429
```

4. While the flood runs, send a few interactive requests from a second shell:

```
for i in 1 2 3; do
  kubectl -n llm exec client -- curl -s -o /dev/null -w "chat %{http_code} %{time_starttransfer}s\n" \
    http://$GW/v1/completions -H 'Content-Type: application/json' \
    -H 'x-gateway-inference-objective: chat-interactive' \
    -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":"hi","max_tokens":10}'
done
```

5. Scale back to 3 replicas.

### Questions

- **Q6.1** Why were batch requests rejected quickly with 429 instead of being queued behind the running work? What would queuing them have done to interactive TTFT?
- **Q6.2** What makes a request "sheddable" in this model? What priority does a request get when it carries no objective header?
- **Q6.3** Should a client retry a 429 from the gateway right away? Which HTTP mechanism and client pattern should it use?
- **Q6.4** Who should own `InferenceObjective` resources: the platform team that owns the `InferencePool`, or the application teams? Why does that split matter for RBAC?

---

## Exercise 7: EPP failure modes (FailClose vs FailOpen)

**Goal:** know exactly what happens to traffic when the Endpoint Picker is unavailable.

### Steps

1. Confirm the current mode:

```
kubectl -n llm get inferencepool vllm-llama3-8b-instruct -o jsonpath='{.spec.endpointPickerRef.failureMode}{"\n"}'
```

   Expected: `FailClose`

2. Take the EPP down and send a request:

```
kubectl -n llm scale deploy/vllm-llama3-8b-instruct-epp --replicas=0
kubectl -n llm exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://$GW/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":"x","max_tokens":5}'
```

   Expected: a 5xx, typically `503` or `500` depending on the implementation.

3. Switch to `FailOpen` and repeat:

```
kubectl -n llm patch inferencepool vllm-llama3-8b-instruct --type=merge \
  -p '{"spec":{"endpointPickerRef":{"failureMode":"FailOpen"}}}'
sleep 5
kubectl -n llm exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://$GW/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":"x","max_tokens":5}'
```

   Expected: `200`. The proxy fell back to its own load balancing over the pool's endpoints.

4. Restore everything:

```
kubectl -n llm patch inferencepool vllm-llama3-8b-instruct --type=merge \
  -p '{"spec":{"endpointPickerRef":{"failureMode":"FailClose"}}}'
kubectl -n llm scale deploy/vllm-llama3-8b-instruct-epp --replicas=1
```

### Questions

- **Q7.1** Give one production scenario where `FailClose` is the right choice and one where `FailOpen` is.
- **Q7.2** Under `FailOpen`, which features from Exercises 5 and 6 silently disappear?
- **Q7.3** The EPP is now on the critical path of every inference request. List three things you would do to make it highly available (think replicas, leader election, PDB, probes, alerts).

---

## Exercise 8: Model-aware routing with Body-Based Routing (BBR)

**Goal:** route by the `model` field inside the JSON body. Standard `HTTPRoute` matching cannot read the body.

### Steps

1. Deploy a second, smaller model with its own pool. Reuse `01-sim.yaml` with every name changed to `vllm-qwen-small` and `--model Qwen/Qwen2.5-1.5B-Instruct`. Then:

```
helm install vllm-qwen-small \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version ${GIE_VERSION} --namespace llm \
  --set inferencePool.modelServers.matchLabels.app=vllm-qwen-small \
  --set provider.name=istio
```

2. Install the Body-Based Router. It is another ext-proc service; it copies the body's `model` into a header:

```
helm install body-based-router \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/body-based-routing \
  --version ${GIE_VERSION} --namespace llm \
  --set provider.name=istio
```

3. Replace the route with header matches on the injected header:

```yaml
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
    timeouts:
      request: 300s
  - matches:
    - path:
        type: PathPrefix
        value: /v1/
      headers:
      - type: Exact
        name: X-Gateway-Model-Name
        value: Qwen/Qwen2.5-1.5B-Instruct
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: vllm-qwen-small
    timeouts:
      request: 300s
```

4. Test both models, plus one that does not exist:

```
for m in meta-llama/Llama-3.1-8B-Instruct Qwen/Qwen2.5-1.5B-Instruct unknown/model; do
  kubectl -n llm exec client -- curl -s -o /dev/null -w "$m -> %{http_code}\n" \
    http://$GW/v1/completions -H 'Content-Type: application/json' \
    -d "{\"model\":\"$m\",\"prompt\":\"hi\",\"max_tokens\":5}"
done
```

   Expected:

```
meta-llama/Llama-3.1-8B-Instruct -> 200
Qwen/Qwen2.5-1.5B-Instruct -> 200
unknown/model -> 404
```

5. Test a LoRA adapter served by the Llama pool. The simulator registered `food-review-1`:

```
kubectl -n llm exec client -- curl -s http://$GW/v1/completions -H 'Content-Type: application/json' \
  -H 'X-Gateway-Model-Name: meta-llama/Llama-3.1-8B-Instruct' \
  -d '{"model":"food-review-1","prompt":"Rate this taco","max_tokens":10}' | jq -r .model
```

### Questions

- **Q8.1** Why does the model name live in the body in OpenAI-style APIs, and what does it cost the gateway to read it (buffering, latency, memory)?
- **Q8.2** Why did `unknown/model` return 404 rather than reaching a pool that would reject it?
- **Q8.3** In step 5 the client set `X-Gateway-Model-Name` by hand. What security problem appears if BBR does not **overwrite** a client-supplied header? How do you close it?
- **Q8.4** When should a LoRA adapter share its base model's pool, and when should it get its own? Which EPP scorer makes sharing efficient?

---

## Exercise 9: Troubleshooting drill

Each scenario is a broken state. Diagnose it with the commands you have already used before you open the answers.

1. `kubectl get httproute llm-route` shows `ResolvedRefs=False`, reason `InvalidKind`.
2. Every request returns 503 immediately. The EPP pod is `Running` but its logs repeat `no pods available in pool`.
3. Short requests succeed, but long streaming responses always stop at exactly 15 s with no error in the model-server logs.
4. The pool has 4 ready pods, yet `inference_pool_average_kv_cache_utilization` stays at `0` and routing looks random.
5. After a Gateway API upgrade, the HTTPRoute uses `group: inference.networking.x-k8s.io` for the `InferencePool` backend and the route stops resolving.

### Questions

- **Q9.1–Q9.5** For each scenario: name the most likely root cause, the command that confirms it, and the fix.

---

## Cleanup

```
helm -n llm uninstall body-based-router vllm-qwen-small vllm-llama3-8b-instruct
kubectl delete ns llm
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**Q1.1** L4 balancers balance *connections or requests*, not *work*. The cost of one LLM request varies by orders of magnitude: a 5-token reply and a 600-token reply count as "one request" each. Also, prefill cost grows with prompt length, and decode holds a slot plus KV-cache memory for the whole generation. A few long generations landing on one pod pile up there while their neighbours sit idle. kube-proxy has no feedback loop at all. It never learns that a pod is busy.

**Q1.2** The server is at its sequence limit, so new requests wait in the scheduler queue. TTFT becomes *queue wait + prefill*. The queue wait is unbounded and depends on how long the in-flight generations last, so TTFT tail latency (p99) explodes even when the average looks fine.

**Q1.3** Queue depth (`vllm:num_requests_waiting`) and KV-cache utilisation (`vllm:gpu_cache_usage_perc` / `kv_cache_usage_perc`). Others: which LoRA adapters are loaded, and prefix-cache contents. An L4 balancer sees only TCP 5-tuples. It never parses HTTP, never reads the body, and never scrapes the backends.

**Q1.4** It pins each client to one pod. That helps prefix-cache hits for a single chatty client. But a gateway or egress NAT makes many users look like one IP, which pins *all* that traffic to one replica and makes the hotspot worse. It is still blind to load.

### Exercise 2

**Q2.1** `*.k8s.io` without `x-` means an official, approved API group with compatibility guarantees. `InferencePool` reached `v1`, so it will not break without a deprecation cycle. `x-k8s.io` marks an experimental group: `InferenceObjective` can change shape or be renamed. It already has once: it replaced `InferenceModel`.

**Q2.2** It is an extension of Gateway API: new CRDs plus a reference Endpoint Picker. The existing proxy (Envoy under Istio, kgateway, Envoy Gateway, GKE) calls the EPP through Envoy's **External Processing (`ext_proc`)** filter over gRPC. The EPP returns the chosen endpoint, and the proxy sends the request to that pod through an "original destination"-style cluster.

**Q2.3** The implementation must add a new backend kind (`InferencePool`), generate the ext_proc filter and cluster config, and set up TLS/trust to the EPP. Until that translation logic is turned on, the controller does not recognise the backend kind and marks the reference unresolved.

### Exercise 3

**Q3.1** A `Service` means "any ready endpoint is interchangeable" and is carried out by kube-proxy or the dataplane with no per-request intelligence. An `InferencePool` adds a *required* endpoint picker and model-server semantics (target ports, failure mode). Making it a distinct backend kind keeps `Service` semantics untouched and lets routes opt into inference-aware selection explicitly. Portability comes from conformance tests.

**Q3.2** The Envoy `ext_proc` gRPC service (`envoy.service.ext_proc.v3.ExternalProcessor`), as a bidirectional stream. The order: the proxy receives the request → sends request headers (and the body, which the EPP needs to read `model` and the prompt) to the EPP → the EPP scores candidates and replies with header mutations / dynamic metadata naming the target `ip:port` → the proxy forwards to that pod → response headers and body can also flow through the EPP, which is how it counts tokens from `usage` for metrics.

**Q3.3** From the request: model name / LoRA adapter, prompt (for prefix-cache hashing), and objective/priority header. From scraping each pod's `/metrics`: waiting-queue length, running requests, KV-cache utilisation, and loaded/active LoRA adapters. Filters remove ineligible pods, then weighted scorers (queue, KV-cache, prefix, LoRA affinity) rank the rest.

**Q3.4** It can refuse or shed the request (429/503) based on saturation and priority, instead of piling it onto an already full queue. It can also steer each request to the *least bad* pod. kube-proxy can only forward.

### Exercise 4

**Q4.1** `ResolvedRefs` reports whether every `backendRef` points to a kind the implementation supports and an object that exists. Without the CRDs, or without implementation support, you would see `ResolvedRefs=False` with reason `InvalidKind`. If the pool name were wrong, the reason would be `BackendNotFound`.

**Q4.2** The status line (200) and the first chunks have already been sent, so the proxy cannot change the status to 504. It resets the stream instead. The client sees a truncated stream without `data: [DONE]`. Access logs and dashboards often record a 200 with a response flag such as `UT` (upstream timeout), so status-code error-rate alerts miss it.

**Q4.3** (a) Buffering delays the first bytes, which destroys perceived TTFT; the whole point of streaming is to show tokens as they come. (b) It holds whole responses in proxy memory, which risks OOM or buffer-limit errors (413/500) on long generations. Also: it defeats client-side cancellation (the user closes the tab, but the backend keeps generating) and it batches SSE events so they arrive in bursts.

**Q4.4** Legitimate generation time varies hugely with `max_tokens`, so any fixed request timeout either cuts off real work or is too loose to catch hangs. Better signals: TTFT, inter-token latency (time per output token) and queue time. The TTFT/ITL SLOs are the ones the EPP optimises for. An idle/stream timeout between chunks catches stalls without capping total length.

### Exercise 5

**Q5.1** Queues should now be more even. Long requests are spread by *measured load*, and the EPP steers away from pods whose queue or KV-cache is high. In Exercise 1 the balancer was blind; here the balancer sees the metrics.

**Q5.2** The header selects the destination pod directly. If a client could set it, they could bypass the scheduler, priority and shedding. They could pin load onto one pod (a noisy-neighbour or DoS vector), or reach any IP that the proxy's original-destination cluster will accept. The proxy must strip or overwrite client values and honour only what ext_proc sets.

**Q5.3** Several requests picked in the same staleness window all see the same "least-loaded" pod and herd onto it. Mitigations: the EPP adds in-flight requests it has already assigned to its local view, and it uses combined or randomised scoring among near-equal candidates rather than a strict argmin. Prefix scoring and queue scoring together also stop one pod from winning every time.

**Q5.4** The EPP hashes blocks of the prompt prefix and remembers which pod recently served each prefix. vLLM keeps the KV blocks it computed for that prefix, so routing a matching prompt back to the same pod skips re-running prefill on the shared part. That lowers TTFT and saves compute. Chat and agent workloads resend the same long system prompt and conversation history every turn, so the hit rate is high.

### Exercise 6

**Q6.1** When the pool is saturated, the EPP sheds requests with negative priority at the door, so they never take up a server queue slot. Queuing them would put interactive requests behind many 300-token batch generations and push chat TTFT to tens of seconds. Rejecting fast lets batch clients back off and retry later.

**Q6.2** An objective with `priority < 0` is sheddable. A request with no objective (or an unknown one) gets the default priority, 0: it is not sheddable, but it ranks below positive priorities.

**Q6.3** No. It should use exponential backoff with jitter and honour `Retry-After` if the gateway sends it. Retrying immediately turns shedding into a retry storm that keeps the pool saturated. Batch pipelines should also cap concurrency on the client side.

**Q6.4** Application teams own objectives: they declare how important their workload is. The platform team owns the pool, the EPP and the Gateway. RBAC should let app teams create `InferenceObjective` in their namespace, but priority values need governance (a policy engine / admission rule). Otherwise every team sets `priority: 1000` and the scheme means nothing.

### Exercise 7

**Q7.1** `FailClose`: when routing to the wrong pod is unacceptable. Examples: pools where only some pods have a LoRA adapter or model loaded, or where strict shedding protects expensive GPUs from overload and cascading failure. `FailOpen`: a homogeneous pool where availability matters more than optimal placement, such as an internal chat tool where a slower answer beats no answer.

**Q7.2** All the load-aware scoring (queue, KV-cache, prefix, LoRA affinity) and all priority-based shedding. Traffic goes back to the proxy's default algorithm, which is effectively Exercise 1 behaviour, and a sudden fail-open can overload the pool right when you are already degraded.

**Q7.3** Run ≥2 EPP replicas (with leader election if your version needs one active scheduler, or active-active where supported), add a `PodDisruptionBudget`, spread replicas across nodes/zones with topology constraints, set proper readiness/liveness probes (gRPC health on its health port), give it enough CPU (it sits in the per-request path), and alert on EPP availability, ext_proc error rate and its own request latency.

### Exercise 8

**Q8.1** The OpenAI-compatible API puts `model` in the JSON body, and many clients have that API hard-coded. The proxy has to buffer the body (or at least the start of it) and parse JSON before it can route. That adds latency and memory per request and caps the maximum body size. Large multimodal or long-context payloads make this cost bigger.

**Q8.2** BBR set `X-Gateway-Model-Name: unknown/model`. No `HTTPRoute` rule matched that header value, so the Gateway returned 404 without contacting any pool. That behaviour is correct: it keeps garbage off the GPUs.

**Q8.3** If BBR only adds the header when it is missing, a client could send a body for model A with a header for model B, and bypass routing or reach a pool it is not allowed to use. BBR must always overwrite the header from the body. Also strip that header at the edge, and enforce authorisation per model or pool rather than only in the route match.

**Q8.4** Share the base model's pool when adapters are small and used intermittently. vLLM can hot-load several adapters (`--max-loras`) onto the same GPUs, which is much cheaper than a dedicated deployment per adapter. The **LoRA-affinity** scorer prefers pods that already have the adapter loaded, avoiding load/evict churn. Give an adapter its own pool when it has sustained heavy traffic, a different SLO, or isolation requirements.

### Exercise 9

**Q9.1** Root cause: the implementation does not support `InferencePool` as a backend. Either the Inference Extension feature flag is off, or the controller version is too old. Confirm with `kubectl get httproute llm-route -o yaml` (status conditions) and the controller or istiod logs. Fix: enable `ENABLE_GATEWAY_API_INFERENCE_EXTENSION` (or your implementation's equivalent), or upgrade the controller.

**Q9.2** Root cause: the pool selector matches no ready pods. Common reasons are a label typo, the wrong namespace, or pods failing readiness. Confirm with `kubectl -n llm get inferencepool -o yaml` and `kubectl -n llm get pods -l app=<label> --show-labels`. Fix: correct `spec.selector.matchLabels` (or `inferencePool.modelServers.matchLabels` in Helm) or fix the pods.

**Q9.3** Root cause: a 15 s timeout somewhere in the path. It could be `HTTPRoute.timeouts.request` or `backendRequest`, an implementation default route timeout, or an L7 load balancer / ingress in front of the Gateway. Confirm by checking proxy access logs for response flag `UT` and duration ≈15000 ms, then `kubectl get httproute -o yaml` and any cloud LB idle-timeout settings. Fix: raise request timeouts to fit your longest generation, and set idle/stream timeouts separately.

**Q9.4** Root cause: the EPP cannot scrape the model-server metrics. Possible reasons: a metrics port or path mismatch, a NetworkPolicy blocking EPP→pod on 8000, or a metric-name mismatch (for example, the EPP expects `vllm:gpu_cache_usage_perc` while a newer vLLM exposes `vllm:kv_cache_usage_perc`). Confirm with the EPP logs (scrape errors) and `curl http://<pod>:8000/metrics | grep kv`. Fix: allow the traffic, or configure the EPP's metric-name flags to match your server version.

**Q9.5** Root cause: `InferencePool` graduated to `inference.networking.k8s.io/v1`, but the route still references the old experimental group. The controller looks for a kind in a group it no longer serves or watches. Confirm with `kubectl api-resources | grep -i inferencepool`. Fix: update `backendRefs[].group` to `inference.networking.k8s.io` and migrate the pool objects to `v1`.

</details>