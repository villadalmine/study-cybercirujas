# 5.2 Troubleshooting End-to-End Network Performance with Tracing: Guided Exercises

> **Goal:** Build a working tracing pipeline (Envoy sidecars → OpenTelemetry Collector → Jaeger). Then use it to find where latency and errors come from as a request crosses pods, proxies and nodes. You will inject faults at the application layer and at the network layer, and learn to tell them apart using span timing, Envoy response flags, access logs and packet captures.
>
> **Estimated time:** 90–120 minutes
> **Prerequisites:** `kind`, `kubectl` ≥ 1.30, `docker` (or `podman` with `KIND_EXPERIMENTAL_PROVIDER=podman`), `jq`, `openssl`, `curl`

**Official references**

- CKNE certification: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Istio distributed tracing with OpenTelemetry: https://istio.io/latest/docs/tasks/observability/distributed-tracing/opentelemetry/
- Istio Telemetry API: https://istio.io/latest/docs/reference/config/telemetry/
- Istio fault injection: https://istio.io/latest/docs/tasks/traffic-management/fault-injection/
- W3C Trace Context: https://www.w3.org/TR/trace-context/
- OpenTelemetry Collector configuration: https://opentelemetry.io/docs/collector/configuration/
- Tail sampling processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- Jaeger: https://www.jaegertracing.io/docs/
- Envoy response flags: https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage
- Debugging with ephemeral containers: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container
- Hubble / Cilium observability: https://docs.cilium.io/en/stable/observability/hubble/

---

## Exercise 0: Lab setup

### 0.1 Create a multi-node cluster

You need at least two workers so that some requests actually cross nodes.

```yaml
# kind-ckne-trace.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ckne-trace
nodes:
- role: control-plane
- role: worker
- role: worker
```

```bash
kind create cluster --config kind-ckne-trace.yaml
kubectl get nodes
```

Expected output:

```
NAME                       STATUS   ROLES           AGE   VERSION
ckne-trace-control-plane   Ready    control-plane   60s   v1.33.1
ckne-trace-worker          Ready    <none>          40s   v1.33.1
ckne-trace-worker2         Ready    <none>          40s   v1.33.1
```

### 0.2 Install Istio with an OpenTelemetry tracing provider

```bash
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.27.1 sh -
cd istio-1.27.1
export PATH=$PWD/bin:$PATH
istioctl version --remote=false
```

Declare an extension provider that points at the Collector you will deploy in step 0.3:

```yaml
# istio-tracing.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: default
  meshConfig:
    enableTracing: true
    extensionProviders:
    - name: otel-tracing
      opentelemetry:
        service: otel-collector.observability.svc.cluster.local
        port: 4317
```

```bash
istioctl install -y -f istio-tracing.yaml
kubectl -n istio-system get pods
```

Now turn the provider on for the whole mesh with the Telemetry API. Enable Envoy access logs at the same time, because you will correlate them with spans later:

```yaml
# telemetry-mesh.yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  accessLogging:
  - providers:
    - name: envoy
  tracing:
  - providers:
    - name: otel-tracing
    randomSamplingPercentage: 100
```

```bash
kubectl apply -f telemetry-mesh.yaml
```

### 0.3 Deploy the tracing backend (Jaeger) and the OpenTelemetry Collector

Jaeger comes from the Istio sample addons. It creates the Services `tracing` (UI, port 80) and `jaeger-collector` (OTLP gRPC, port 4317) in `istio-system`:

```bash
kubectl apply -f samples/addons/jaeger.yaml
kubectl -n istio-system get svc tracing jaeger-collector
```

The Collector runs in its own namespace **without** sidecar injection:

```yaml
# otel-collector.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
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
        spike_limit_percentage: 25
      batch: {}
    exporters:
      otlp/jaeger:
        endpoint: jaeger-collector.istio-system.svc.cluster.local:4317
        tls:
          insecure: true
      debug:
        verbosity: basic
    service:
      extensions: [health_check]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/jaeger, debug]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      containers:
      - name: otelcol
        image: otel/opentelemetry-collector-contrib:0.123.0
        args: ["--config=/conf/config.yaml"]
        ports:
        - name: otlp-grpc
          containerPort: 4317
        - name: otlp-http
          containerPort: 4318
        readinessProbe:
          httpGet:
            path: /
            port: 13133
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 512Mi
        volumeMounts:
        - name: config
          mountPath: /conf
      volumes:
      - name: config
        configMap:
          name: otel-collector-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
spec:
  selector:
    app: otel-collector
  ports:
  - name: grpc-otlp
    port: 4317
    targetPort: 4317
    appProtocol: grpc
  - name: http-otlp
    port: 4318
    targetPort: 4318
```

```bash
kubectl apply -f otel-collector.yaml
kubectl -n observability rollout status deploy/otel-collector
```

### 0.4 Deploy the workload and a load generator

```bash
kubectl create namespace bookinfo
kubectl label namespace bookinfo istio-injection=enabled
kubectl -n bookinfo apply -f samples/bookinfo/platform/kube/bookinfo.yaml
kubectl -n bookinfo wait --for=condition=Ready pod --all --timeout=300s
```

```yaml
# loadgen.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loadgen
  namespace: bookinfo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loadgen
  template:
    metadata:
      labels:
        app: loadgen
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.10.1
        command: ["/bin/sh", "-c"]
        args:
        - |
          while true; do
            curl -s -o /dev/null -w "%{http_code} %{time_total}\n" http://productpage:9080/productpage
            sleep 0.5
          done
```

```bash
kubectl apply -f loadgen.yaml
kubectl -n bookinfo get pods -o wide
kubectl -n bookinfo logs deploy/loadgen -c curl --tail=5
```

Expected output:

```
200 0.041233
200 0.038872
200 0.052110
200 0.036904
200 0.044517
```

**Questions**

- **Q0.1** The Collector namespace is deliberately *not* labelled for injection. The Envoy sidecars nevertheless send it plaintext OTLP. Why does this work while the mesh is in its default mTLS mode?
- **Q0.2** `randomSamplingPercentage: 100` is fine in a lab. What does it mean at the network layer (bytes, connections, Collector CPU) for a mesh doing 20,000 requests per second across 5 hops?

---

## Exercise 1: Verify the pipeline end to end

A tracing pipeline that silently drops spans is worse than having none: it tells you "no slow requests" when in fact you have no data. Check every hop of the telemetry path.

1. Check that the Collector is receiving spans:

   ```bash
   kubectl -n observability logs deploy/otel-collector --tail=20 | grep -i traces
   ```

   Illustrative output:

   ```
   ... info Traces {"otelcol.component.id": "debug", "otelcol.signal": "traces", "resource spans": 6, "spans": 6}
   ```

2. Check that the Collector exports without errors:

   ```bash
   kubectl -n observability logs deploy/otel-collector | grep -iE "error|refused|dropping" | tail -5
   ```

   Nothing should come back. If you see `connection refused` to `jaeger-collector`, fix that before going on.

3. Open the Jaeger query API and list the services it knows about:

   ```bash
   kubectl -n istio-system port-forward svc/tracing 16686:80 >/dev/null 2>&1 &
   sleep 2
   curl -s localhost:16686/api/services | jq -r '.data[]' | sort
   ```

   Expected output:

   ```
   details.bookinfo
   jaeger-all-in-one
   loadgen.bookinfo
   productpage.bookinfo
   ratings.bookinfo
   reviews.bookinfo
   ```

4. Check the tracer configuration Envoy actually received:

   ```bash
   POD=$(kubectl -n bookinfo get pod -l app=productpage -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config listener -n bookinfo "$POD" --port 15006 -o json \
     | jq '[.. | .tracing? | select(. != null)][0]'
   ```

   You should see an `envoy.tracers.opentelemetry` provider whose `grpcService` points at `outbound|4317||otel-collector.observability.svc.cluster.local`, and `randomSampling.value` set to `100`.

**Questions**

- **Q1.1** Name the four places in this pipeline where spans can be lost. For each one, give the command from this exercise that proves it is healthy.
- **Q1.2** `ratings.bookinfo` is missing from the service list, but the other services are there. List two causes that do not involve the Collector.

---

## Exercise 2: Anatomy of a mesh trace

1. Fetch the 5 most recent traces that go through `productpage` and count their spans:

   ```bash
   curl -s -G localhost:16686/api/traces \
     --data-urlencode 'service=productpage.bookinfo' \
     --data-urlencode 'limit=5' \
     | jq -r '.data[] | "\(.traceID)  spans=\(.spans | length)"'
   ```

   Illustrative output:

   ```
   7c1e0b4f2a9d8e3f6a1b2c3d4e5f6a7b  spans=8
   2b9d0f7e1c3a5b4d6e8f0a1b2c3d4e5f  spans=6
   f0e1d2c3b4a5968778695a4b3c2d1e0f  spans=8
   ...
   ```

2. Break one trace down into service, operation, span kind and duration (in microseconds):

   ```bash
   TID=$(curl -s -G localhost:16686/api/traces \
     --data-urlencode 'service=productpage.bookinfo' --data-urlencode 'limit=20' \
     | jq -r '[.data[] | select((.spans | length) == 8)][0].traceID')

   curl -s localhost:16686/api/traces/$TID | jq -r '
     .data[0] as $t
     | $t.spans
     | sort_by(.startTime)[]
     | [ $t.processes[.processID].serviceName,
         (.tags[] | select(.key == "span.kind") | .value),
         .operationName,
         .duration ] | @tsv' | column -t
   ```

   Illustrative output:

   ```
   loadgen.bookinfo      client  productpage.bookinfo.svc.cluster.local:9080/productpage  38412
   productpage.bookinfo  server  productpage.bookinfo.svc.cluster.local:9080/productpage  36120
   productpage.bookinfo  client  details.bookinfo.svc.cluster.local:9080/*                3310
   details.bookinfo      server  details.bookinfo.svc.cluster.local:9080/*                1402
   productpage.bookinfo  client  reviews.bookinfo.svc.cluster.local:9080/*                21870
   reviews.bookinfo      server  reviews.bookinfo.svc.cluster.local:9080/*                20015
   reviews.bookinfo      client  ratings.bookinfo.svc.cluster.local:9080/*                4203
   ratings.bookinfo      server  ratings.bookinfo.svc.cluster.local:9080/*                1851
   ```

3. Open the same trace in the UI (`http://localhost:16686/trace/$TID`) and expand the `reviews.bookinfo` client span that calls `ratings`. Find the tags `upstream_cluster`, `peer.address`, `response_flags`, `http.status_code` and `guid:x-request-id`.

**Questions**

- **Q2.1** Some traces have 8 spans and others have 6. Explain exactly which spans are missing and why.
- **Q2.2** Each hop appears twice (a `client` span and a `server` span) with the same operation name. Who emits each one?
- **Q2.3** Using the illustrative numbers, estimate (a) the time spent *between* the `reviews` sidecar and the `ratings` sidecar, and (b) the self-time of the `productpage` application.
- **Q2.4** In the waterfall, are the calls to `details` and to `reviews` sequential or parallel? What does that imply for the critical path?

---

## Exercise 3: Trace context propagation

1. Build your own W3C `traceparent` header and send a request that carries it:

   ```bash
   TRACE_ID=$(openssl rand -hex 16)
   PARENT_ID=$(openssl rand -hex 8)
   TP="00-${TRACE_ID}-${PARENT_ID}-01"
   echo "$TP"

   kubectl -n bookinfo exec deploy/loadgen -c curl -- \
     curl -s -o /dev/null -w "%{http_code}\n" -H "traceparent: ${TP}" \
     http://productpage:9080/productpage
   ```

2. Look up exactly that trace:

   ```bash
   sleep 5
   curl -s localhost:16686/api/traces/$TRACE_ID | jq -r '
     .data[0] as $t | $t.spans[]
     | [$t.processes[.processID].serviceName, .spanID,
        ((.references[0].spanID) // "-")] | @tsv' | column -t
   ```

   One span must have `$PARENT_ID` as its parent: that is the span created by the loadgen sidecar.

3. Now send a request whose sampled flag is `00`:

   ```bash
   TRACE_ID2=$(openssl rand -hex 16)
   kubectl -n bookinfo exec deploy/loadgen -c curl -- \
     curl -s -o /dev/null -H "traceparent: 00-${TRACE_ID2}-$(openssl rand -hex 8)-00" \
     http://productpage:9080/productpage
   sleep 5
   curl -s localhost:16686/api/traces/$TRACE_ID2 | jq '.errors // .data | length'
   ```

4. Look at which headers the application forwards. Bookinfo's `productpage` explicitly copies a list of tracing headers onto its outbound calls:

   ```bash
   kubectl -n bookinfo exec deploy/productpage-v1 -c productpage -- \
     grep -n -A25 "headers_to_propagate\|def getForwardHeaders" /opt/microservices/productpage.py | head -40
   ```

**Questions**

- **Q3.1** What does each of the four fields of `00-<32 hex>-<16 hex>-01` mean?
- **Q3.2** Step 3 did not produce a trace even though sampling is at 100%. Why is this the *correct* behaviour?
- **Q3.3** Envoy creates spans, but it cannot link an inbound request to the outbound requests the application makes afterwards. Why not? Describe what the trace would look like if `reviews` stopped forwarding `traceparent`.
- **Q3.4** What is `x-request-id` for in Istio, and how does it relate to the trace ID?

---

## Exercise 4: Application-layer latency (fault injection)

1. Inject a 1.5 s delay into 50% of requests to `ratings`:

   ```yaml
   # ratings-delay.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: ratings
     namespace: bookinfo
   spec:
     hosts:
     - ratings
     http:
     - fault:
         delay:
           percentage:
             value: 50
           fixedDelay: 1.5s
       route:
       - destination:
           host: ratings
   ```

   ```bash
   kubectl apply -f ratings-delay.yaml
   sleep 20
   kubectl -n bookinfo logs deploy/loadgen -c curl --tail=10
   ```

   Illustrative output: a mix of approximately 0.04 s and 1.55 s responses.

2. Find the slow traces:

   ```bash
   curl -s -G localhost:16686/api/traces \
     --data-urlencode 'service=productpage.bookinfo' \
     --data-urlencode 'minDuration=1s' \
     --data-urlencode 'limit=5' \
     | jq -r '.data[].traceID'
   ```

3. Break one of them down (reuse the `jq` from Exercise 2.2) and extract the tags of the `reviews → ratings` client span:

   ```bash
   SLOW=$(curl -s -G localhost:16686/api/traces \
     --data-urlencode 'service=productpage.bookinfo' --data-urlencode 'minDuration=1s' \
     --data-urlencode 'limit=1' | jq -r '.data[0].traceID')

   curl -s localhost:16686/api/traces/$SLOW | jq -r '
     .data[0] as $t | $t.spans[]
     | select($t.processes[.processID].serviceName == "reviews.bookinfo")
     | select(any(.tags[]; .key == "span.kind" and .value == "client"))
     | {op: .operationName, duration_us: .duration,
        tags: ([.tags[] | select(.key | test("response_flags|http.status_code|upstream_cluster")) | {(.key): .value}] | add)}'
   ```

   Illustrative output:

   ```
   {
     "op": "ratings.bookinfo.svc.cluster.local:9080/*",
     "duration_us": 1503912,
     "tags": {
       "http.status_code": "200",
       "response_flags": "DI",
       "upstream_cluster": "outbound|9080||ratings.bookinfo.svc.cluster.local"
     }
   }
   ```

4. Compare this with the `ratings.bookinfo` *server* span of the same trace.

5. Clean up:

   ```bash
   kubectl delete -f ratings-delay.yaml
   ```

**Questions**

- **Q4.1** The client span lasts ~1.5 s but the `ratings` server span lasts only a few milliseconds. Where exactly did the 1.5 s go?
- **Q4.2** What does `response_flags: DI` mean? Why is it the key to not blaming the network or the `ratings` application?
- **Q4.3** Why does the delay also show up in the `productpage` server span and in the `loadgen` client span?

---

## Exercise 5: Network-layer latency (netem on the veth)

Now the fault is real: packets heading to the `ratings` pod are delayed on the node's host-side veth. No Envoy flag will tell you this one.

1. Find the node and the host-side veth of the `ratings` pod:

   ```bash
   NODE=$(kubectl -n bookinfo get pod -l app=ratings -o jsonpath='{.items[0].spec.nodeName}')
   IDX=$(kubectl -n bookinfo exec deploy/ratings-v1 -c istio-proxy -- cat /sys/class/net/eth0/iflink | tr -d '\r')
   VETH=$(docker exec "$NODE" ip -o link | awk -F': ' -v i="$IDX" '$1 == i {print $2}' | cut -d@ -f1)
   echo "node=$NODE ifindex=$IDX veth=$VETH"
   ```

   Illustrative output:

   ```
   node=ckne-trace-worker2 ifindex=11 veth=veth3f9a2c1b
   ```

2. Add 200 ms of delay on that interface's egress, which carries the traffic *entering* the pod:

   ```bash
   docker exec "$NODE" sh -c 'command -v tc >/dev/null || (apt-get update -qq && apt-get install -y -qq iproute2)'
   docker exec "$NODE" tc qdisc add dev "$VETH" root netem delay 200ms
   docker exec "$NODE" tc qdisc show dev "$VETH"
   ```

   Expected output:

   ```
   qdisc netem 8001: root refcnt 2 limit 1000 delay 200ms
   ```

   > If `tc` returns `Error: Specified qdisc kind is unknown.`, your host kernel does not have the `sch_netem` module (on Fedora: `sudo dnf install kernel-modules-extra && sudo modprobe sch_netem`).

3. Wait 20 s and compare, in one slow trace, the durations of the `reviews → ratings` pair:

   ```bash
   sleep 20
   T=$(curl -s -G localhost:16686/api/traces \
     --data-urlencode 'service=ratings.bookinfo' --data-urlencode 'minDuration=150ms' \
     --data-urlencode 'limit=1' | jq -r '.data[0].traceID')

   curl -s localhost:16686/api/traces/$T | jq -r '
     .data[0] as $t | $t.spans[]
     | select(.operationName | startswith("ratings."))
     | [$t.processes[.processID].serviceName,
        (.tags[] | select(.key == "span.kind") | .value),
        .duration,
        ((.tags[] | select(.key == "response_flags") | .value) // "-")] | @tsv' | column -t
   ```

   Illustrative output:

   ```
   reviews.bookinfo  client  203914  -
   ratings.bookinfo  server  1733    -
   ```

4. Confirm it at the packet level from the **caller** side, using an ephemeral debug container:

   ```bash
   REVIEWS=$(kubectl -n bookinfo get pod -l app=reviews,version=v2 -o jsonpath='{.items[0].metadata.name}')
   RATINGS_IP=$(kubectl -n bookinfo get pod -l app=ratings -o jsonpath='{.items[0].status.podIP}')

   kubectl -n bookinfo debug -it "$REVIEWS" --image=nicolaka/netshoot:v0.13 --profile=netadmin -- \
     tcpdump -i eth0 -nn -ttt -c 12 "host ${RATINGS_IP} and tcp port 9080"
   ```

   Illustrative output (the `-ttt` column is the time elapsed since the previous packet):

   ```
    00:00:00.000000 IP 10.244.1.12.47730 > 10.244.2.9.9080: Flags [P.], seq 1:1311, ack 1, win 501, length 1310
    00:00:00.203118 IP 10.244.2.9.9080 > 10.244.1.12.47730: Flags [P.], seq 1:1102, ack 1311, win 509, length 1101
    00:00:00.000041 IP 10.244.1.12.47730 > 10.244.2.9.9080: Flags [.], ack 1102, win 501, length 0
   ```

   The payload is not readable: it is Istio mTLS. You can still read the *timing*.

5. Remove the delay:

   ```bash
   docker exec "$NODE" tc qdisc del dev "$VETH" root
   ```

**Questions**

- **Q5.1** In Exercise 4 and in this exercise the client span grows and the server span does not. What evidence in the trace separates "delay inside the calling proxy" from "delay on the network"?
- **Q5.2** Why does the `ratings` server span not include the 200 ms, even though the delay is applied "on the ratings side"?
- **Q5.3** You capture on the `ratings` pod's `eth0` instead of on `reviews`. Would you see the 200 ms between request and response? Justify your answer.
- **Q5.4** In a real multi-node cluster, what trace artefact can make a server span appear to *start before* its client span, and how does it affect this kind of analysis?
- **Q5.5** Why is `tcpdump` on the pod's `eth0` unable to show the HTTP path or status code, and what would you use to see them?

---

## Exercise 6: Hidden errors and Envoy response flags

1. Take out the `ratings` backend completely:

   ```bash
   kubectl -n bookinfo scale deploy/ratings-v1 --replicas=0
   sleep 15
   kubectl -n bookinfo logs deploy/loadgen -c curl --tail=5
   ```

   Illustrative output: still all `200`.

2. Look for spans with errors in `reviews`:

   ```bash
   curl -s -G localhost:16686/api/traces \
     --data-urlencode 'service=reviews.bookinfo' \
     --data-urlencode 'tags={"error":"true"}' \
     --data-urlencode 'limit=3' \
     | jq -r '.data[0] as $t | $t.spans[]
       | select(any(.tags[]; .key == "error"))
       | [$t.processes[.processID].serviceName, .operationName,
          (.tags[] | select(.key == "http.status_code") | .value),
          (.tags[] | select(.key == "response_flags") | .value),
          (.tags[] | select(.key == "guid:x-request-id") | .value)] | @tsv'
   ```

   Illustrative output:

   ```
   reviews.bookinfo  ratings.bookinfo.svc.cluster.local:9080/*  503  UH  9d4b0f52-8a0c-9b1e-a7d3-2f6c1e0b4a77
   ```

3. Correlate with the Envoy access log of the same pod using `x-request-id`:

   ```bash
   RID=<paste the x-request-id>
   kubectl -n bookinfo logs -l app=reviews,version=v2 -c istio-proxy --tail=500 | grep "$RID"
   ```

   Illustrative output:

   ```
   [2026-09-30T10:12:03.412Z] "GET /ratings/0 HTTP/1.1" 503 UH no_healthy_upstream - "-" 0 19 0 - "-" "Apache-CXF/3.1.18" "9d4b0f52-8a0c-9b1e-a7d3-2f6c1e0b4a77" "ratings:9080" "-" outbound|9080||ratings.bookinfo.svc.cluster.local - 10.96.54.12:9080 10.244.1.12:40512 - default
   ```

4. Check what Envoy sees as the endpoints of that cluster:

   ```bash
   istioctl proxy-config endpoint -n bookinfo "$REVIEWS" \
     --cluster "outbound|9080||ratings.bookinfo.svc.cluster.local"
   ```

   Expected result: no endpoints are listed.

5. Restore:

   ```bash
   kubectl -n bookinfo scale deploy/ratings-v1 --replicas=1
   ```

**Questions**

- **Q6.1** `loadgen` sees 100% HTTP 200. Why? What does that say about monitoring only edge metrics?
- **Q6.2** Why is there no `ratings.bookinfo` server span for these requests?
- **Q6.3** Say what `UH`, `UF`, `UT`, `URX` and `DI` mean. Which ones point to a network or connectivity problem, and which do not?
- **Q6.4** If instead of `UH` you saw `UF` with `upstream_transport_failure_reason` mentioning TLS, which layer would you investigate?

---

## Exercise 7: Tail sampling in the Collector

At 100% head sampling everything is stored. In production you want to keep **every** slow or failed trace and discard the healthy fast ones, and that decision can only be made once the trace is complete.

1. Replace the Collector configuration:

   ```yaml
   # otel-collector-tail.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: otel-collector-config
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
           spike_limit_percentage: 25
         tail_sampling:
           decision_wait: 10s
           num_traces: 50000
           expected_new_traces_per_sec: 100
           policies:
           - name: keep-errors
             type: status_code
             status_code:
               status_codes: [ERROR]
           - name: keep-slow
             type: latency
             latency:
               threshold_ms: 500
         batch: {}
       exporters:
         otlp/jaeger:
           endpoint: jaeger-collector.istio-system.svc.cluster.local:4317
           tls:
             insecure: true
         debug:
           verbosity: basic
       service:
         extensions: [health_check]
         pipelines:
           traces:
             receivers: [otlp]
             processors: [memory_limiter, tail_sampling, batch]
             exporters: [otlp/jaeger, debug]
   ```

   ```bash
   kubectl apply -f otel-collector-tail.yaml
   kubectl -n observability rollout restart deploy/otel-collector
   kubectl -n observability rollout status deploy/otel-collector
   ```

2. Reapply the ratings delay, but at only 10%:

   ```bash
   sed 's/value: 50/value: 10/' ratings-delay.yaml | kubectl apply -f -
   START=$(( $(date +%s) * 1000000 ))
   sleep 90
   END=$(( $(date +%s) * 1000000 ))
   ```

3. Count what reached Jaeger in that window, split by duration:

   ```bash
   curl -s -G localhost:16686/api/traces \
     --data-urlencode 'service=loadgen.bookinfo' \
     --data-urlencode "start=${START}" --data-urlencode "end=${END}" \
     --data-urlencode 'limit=1000' \
     | jq '[.data[] | ([.spans[].duration] | max)] | {total: length, slow: map(select(. >= 500000)) | length}'
   ```

   Illustrative output:

   ```
   {
     "total": 17,
     "slow": 17
   }
   ```

   Compare with the ~180 requests the loadgen made in 90 s.

4. Clean up:

   ```bash
   kubectl delete -f ratings-delay.yaml
   ```

**Questions**

- **Q7.1** Why can't Envoy, which makes the *head* sampling decision, implement "keep only traces slower than 500 ms"?
- **Q7.2** You scale the Collector to 3 replicas behind the ClusterIP Service. Which traces will now be evaluated incorrectly, and which component fixes it?
- **Q7.3** What does `decision_wait: 10s` cost in memory, and what happens to a trace whose last span arrives at second 12?
- **Q7.4** Tail sampling cuts storage. Does it cut the network traffic from the sidecars to the Collector? How would you combine head and tail sampling?

---

## Exercise 8 (optional): Hubble L7 flows on a Cilium cluster without a mesh

> Run this on a **separate** cluster with Cilium as the CNI and without Istio (for example `kind` with `disableDefaultCNI: true` + `cilium install`), with Bookinfo deployed in `bookinfo` without injection.

1. Enable Hubble and open the relay:

   ```bash
   cilium hubble enable
   cilium status --wait
   cilium hubble port-forward &
   ```

2. Turn on L7 visibility on `ratings` with a policy that has an HTTP rule:

   ```yaml
   # ratings-l7-visibility.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: ratings-l7-visibility
     namespace: bookinfo
   spec:
     endpointSelector:
       matchLabels:
         app: ratings
     ingress:
     - fromEndpoints:
       - matchLabels:
           k8s:io.kubernetes.pod.namespace: bookinfo
       toPorts:
       - ports:
         - port: "9080"
           protocol: TCP
         rules:
           http:
           - {}
   ```

   ```bash
   kubectl apply -f ratings-l7-visibility.yaml
   ```

3. Watch the HTTP flows with their latency:

   ```bash
   hubble observe --namespace bookinfo --protocol http --to-label app=ratings --last 10
   ```

   Illustrative output:

   ```
   Sep 30 10:30:14.201: bookinfo/reviews-v2-5b64f47978-kq7xw:52104 (ID:31544) -> bookinfo/ratings-v1-7f9d8c6b5-x2lpm:9080 (ID:10223) http-request FORWARDED (HTTP/1.1 GET http://ratings:9080/ratings/0)
   Sep 30 10:30:14.203: bookinfo/reviews-v2-5b64f47978-kq7xw:52104 (ID:31544) <- bookinfo/ratings-v1-7f9d8c6b5-x2lpm:9080 (ID:10223) http-response FORWARDED (HTTP/1.1 200 2ms (GET http://ratings:9080/ratings/0))
   ```

4. Extract the trace context that Hubble parses from the headers:

   ```bash
   hubble observe --namespace bookinfo --protocol http --to-label app=ratings --last 5 -o json \
     | jq -r 'select(.flow.trace_context != null) | .flow.trace_context.parent.trace_id'
   ```

**Questions**

- **Q8.1** Why does this exercise need a cluster *without* Istio sidecars to show HTTP flows?
- **Q8.2** Beyond visibility, what side effect does applying this CiliumNetworkPolicy have?
- **Q8.3** How would you use the `trace_id` that Hubble extracts together with Jaeger?

---

## Exercise 9: Cleanup

```bash
kill %1 %2 2>/dev/null
kind delete cluster --name ckne-trace
```

---

## Answers

<details>
<summary>Exercise 0</summary>

**Q0.1** The Envoy tracer's OTLP export is traffic generated by Envoy itself. Istio's iptables rules exclude the proxy's UID (1337) from redirection, so that traffic is not re-captured as application traffic. On top of that, Istio uses mTLS only toward destinations that have a sidecar. The Collector has none and the mesh is `PERMISSIVE` by default, so plaintext traffic is sent to it. In production you would put the Collector in the mesh or configure TLS on the receiver.

**Q0.2** Every hop produces two spans (client and server), so each request generates about 10 spans, which is 200,000 spans/s. At roughly 1–2 KB per span, gRPC-serialised with Envoy's attributes, that is hundreds of MB/s of telemetry traffic from every node toward the Collectors. Add persistent gRPC connections from every sidecar, CPU spent in each Envoy serialising, and Collector CPU and memory for decoding and batching. Tracing becomes a significant fraction of the traffic it is meant to observe.

</details>

<details>
<summary>Exercise 1</summary>

**Q1.1**
1. Envoy → Collector: the tracer configured in the listener (`istioctl proxy-config listener ... tracing`) plus spans arriving at the Collector (step 1).
2. Inside the Collector: `memory_limiter` can refuse data. A lack of `dropping` or refused messages in the logs (step 2) shows it is not.
3. Collector → Jaeger: exporter errors (step 2).
4. Jaeger storage/query: `/api/services` lists all the services (step 3).

**Q1.2** (a) The `ratings` pod has no sidecar: it was created before the namespace was labelled, or has `sidecar.istio.io/inject: "false"`. (b) Nobody calls `ratings`: only `reviews-v2` and `v3` call it, so if every request goes to `reviews-v1` it never shows up. Other possible causes: a namespace- or workload-level `Telemetry` overriding sampling to 0, or an incoming `traceparent` with flag `00`.

</details>

<details>
<summary>Exercise 2</summary>

**Q2.1** Bookinfo's `reviews-v1` does not call `ratings`, while `v2` and `v3` do. Traces that went through `reviews-v1` are missing the `reviews → ratings` pair: the `reviews` client span and the `ratings` server span. 8 − 2 = 6.

**Q2.2** The `client` span is emitted by the **caller's sidecar** in its outbound listener (15001). The `server` span is emitted by the **callee's sidecar** in its inbound listener (15006). The application creates no spans at all. It only forwards headers.

**Q2.3** (a) 4203 − 1851 ≈ 2.35 ms. That covers both directions of the network, TLS encryption and decryption, and time in the inbound sidecar before it parses the headers. (b) The `productpage` server span (36120) minus its child client spans (3310 + 21870 = 25180), assuming they are sequential, gives ≈ 10.9 ms. This is time inside `productpage` (Python rendering, logic) plus its local sidecar overhead.

**Q2.4** In Bookinfo they are sequential: the `reviews` client span starts after the `details` one ends. The critical path is therefore the sum of both. Optimising `details` does reduce total latency. If they ran in parallel, only the longer one would matter.

</details>

<details>
<summary>Exercise 3</summary>

**Q3.1** `00` = version of the format. `<32 hex>` = `trace-id` (16 bytes, shared by every span in the trace). `<16 hex>` = `parent-id` (8 bytes, the ID of the span that made the call). `01` = `trace-flags`, where bit 0 is `sampled`.

**Q3.2** The sampling decision is made once, at the head, and is **propagated** in the `sampled` flag. Envoy honours the upstream decision so that the trace is either complete or absent, never partial. `randomSamplingPercentage` only applies when there is no prior decision. If each hop decided independently, you would end up with fragmented traces.

**Q3.3** Envoy only sees independent HTTP connections and requests. It cannot know that an outbound request from `reviews` to `ratings` was *caused* by a particular inbound request, because that causality lives inside the application's memory. The application must copy the context headers (`traceparent`, `tracestate`, `x-request-id`, `b3`, …) from the incoming request onto its outgoing ones, or use an OpenTelemetry SDK that does it for it. If `reviews` did not propagate them, you would see two traces: one `loadgen → productpage → reviews` without the `ratings` call, and another *root* one `reviews(client) → ratings(server)` with a different trace ID.

**Q3.4** `x-request-id` is a UUID that Envoy generates or preserves at the edge and propagates. Istio records it as the `guid:x-request-id` span tag and includes it in the default access log format. It is the bridge between a span and the Envoy access log line. It is not the trace ID, but both travel together when the application propagates headers correctly.

</details>

<details>
<summary>Exercise 4</summary>

**Q4.1** Inside the **caller's** sidecar (`reviews`). The VirtualService is applied to the *outbound* listener/route of the client proxies. The `fault` filter holds the request 1.5 s *before* sending it upstream. The client span includes that wait. The `ratings` server span only starts when the request actually arrives, which happens after the delay.

**Q4.2** `DI` = *delay injected*: Envoy is reporting that it delayed the request itself because of a fault-injection configuration. It is direct, unambiguous evidence that the latency is intentional and local to the proxy. Without that flag, a gap between client and server would suggest network, TLS or queueing problems.

**Q4.3** Spans nest: the `reviews` server span contains its call to `ratings`, the `productpage → reviews` client span contains the `reviews` server span, and so on up to the root. Latency propagates up the tree, which is why you always go *down* to the deepest span that "explains" the time.

</details>

<details>
<summary>Exercise 5</summary>

**Q5.1** Look at the client span's `response_flags` and the existence of a VirtualService with `fault`. In Exercise 4 the flag is `DI`. In Exercise 5 the flag is `-` and the server span is normal. A large gap between client and server **without** a proxy flag points to what lies between the two sidecars: the network (veth, CNI, node, overlay), connection setup, or the inbound queue. Tools below L7 (`tcpdump`, `tc -s qdisc`, Hubble, node metrics) then confirm it.

**Q5.2** netem holds the packets *before* they enter the pod's network namespace. The inbound Envoy starts the server span when it receives and parses the request headers, which is after the delay. For `ratings`, the request simply "arrived later".

**Q5.3** No. Inside the pod, the request packets arrive already delayed, and the response leaves immediately (the qdisc only affects the host-side veth egress, that is, traffic *toward* the pod). The request-to-response delta would be a few ms. The 200 ms is only visible from the caller, or with a capture on the host side before the qdisc. This is why where you capture matters as much as what you capture.

**Q5.4** *Clock skew* between nodes. Each sidecar timestamps with its node's clock. If one node's clock is ahead, the child span can appear to start before its parent, or the "gap" can be negative or inflated. Jaeger applies a heuristic skew adjustment in the UI, but for network conclusions you should compare durations measured by a *single* clock (client span vs. server span, each computed locally) rather than absolute timestamps across nodes, and keep NTP/chrony healthy.

**Q5.5** Traffic between sidecars is mutual TLS: `tcpdump` only sees TCP/TLS headers and timing. To see L7 you use the sidecar's own telemetry (spans, access logs, `istioctl proxy-config`), or capture on the sidecar↔app loopback (`lo`, plaintext) inside the pod.

</details>

<details>
<summary>Exercise 6</summary>

**Q6.1** `reviews` degrades gracefully: it catches the failure from `ratings` and returns 200 without stars, and `productpage` renders "Ratings service is currently unavailable". The error is absorbed by an intermediate layer. Edge metrics (success rate at `productpage` or at the gateway) show 100% OK. Only per-hop telemetry, meaning traces or inter-service metrics, reveals the degradation.

**Q6.2** The request never left the `reviews` sidecar: with no endpoints, Envoy answers 503 locally. No `ratings` sidecar received anything, so none emitted a server span. A client span with an error and no server child is the trace signature of a failure *before reaching the destination*.

**Q6.3**
- `UH`: no healthy upstream hosts (empty cluster or all ejected). Service discovery/availability.
- `UF`: upstream connection failure. **Connectivity**: TCP refused, timeout, TLS.
- `UT`: upstream request timeout. It can be a slow network or a slow application; look at the server span to decide.
- `URX`: retry or connect-attempt limit reached. It follows repeated `UF`/5xx errors.
- `DI`: delay injected by fault injection. Local and intentional, not a network problem.

`UF` (and `UT` with no server span, or with a short one) point to the network. `UH` points to endpoints/readiness. `DI` points to configuration.

**Q6.4** The mTLS layer between sidecars. Look at certificates or trust domain (`istioctl proxy-config secret`), PeerAuthentication/DestinationRule `tls.mode` conflicts (e.g. `STRICT` on the server against a client with no sidecar or with `DISABLE`), and SNI or ALPN mismatches.

</details>

<details>
<summary>Exercise 7</summary>

**Q7.1** Head sampling is decided on the first span, before knowing how long the trace will take or whether it will fail. Whether a trace is "slow" is only known when the last span closes, and that requires holding every span of the trace in one place until then, which is exactly what `tail_sampling` does.

**Q7.2** The ClusterIP Service spreads the sidecars' gRPC connections across replicas. Spans from the same trace, emitted by different sidecars, land on different Collectors. Each replica sees a partial trace, so it may drop one that was slow as a whole or keep fragments. The fix is a two-tier layout: a first tier with the `loadbalancing` exporter using `routing_key: traceID` (resolving the backends through a headless Service), which sends every span of a trace to the same second-tier Collector where `tail_sampling` runs.

**Q7.3** It keeps up to `num_traces` traces in memory for 10 s each, so memory ≈ rate × 10 s × trace size, and that has to fit under `memory_limiter`. A span that arrives after the decision is no longer evaluated as part of the original batch. It is handled according to the decision already made for that trace ID, if it is still cached, or it ends up as an incomplete trace. `decision_wait` must exceed the duration of your longest traces plus export latency.

**Q7.4** No. Every span still travels from the sidecars to the Collector. Only the export to storage shrinks. The usual combination is a moderate head sampling (e.g. 10–20%) to bound network and CPU cost at the sidecars, plus tail sampling in the Collector to keep 100% of the errors and slow traces *within* that sample. You accept that very rare slow or error traces outside the head sample are lost, and cover them with metrics and access logs.

</details>

<details>
<summary>Exercise 8</summary>

**Q8.1** Cilium's L7 proxy (Envoy on the node) can only parse HTTP if it sees plaintext. With Istio sidecars, pod-to-pod traffic is mTLS, so Cilium only sees encrypted TCP and Hubble reports L3/L4 flows, not HTTP.

**Q8.2** Any CiliumNetworkPolicy with `ingress` puts the selected endpoint in *default deny* for ingress. Only what the policy allows gets through: pods in the `bookinfo` namespace on 9080/TCP. Traffic from other namespaces, or to other ports, is dropped. The L7 rule also forces all that traffic through Cilium's Envoy proxy, which adds latency and CPU.

**Q8.3** Hubble parses the W3C `traceparent` header and exposes `trace_context.parent.trace_id` on L7 flows. With that ID you open the trace in Jaeger (`/api/traces/<id>`) and compare Cilium's network view (policy verdicts, drops, source/destination identity, node) with the application view (spans). That shows whether a slow or failed span matches drops, retransmissions or policy decisions in the datapath.

</details>