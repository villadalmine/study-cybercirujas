# Topic 3.2 — Deploying the OpenTelemetry Collector

> Domain 3, *The OpenTelemetry Collector* · exam weight 5.2
> The exercises below assume a working Docker install, a local Kubernetes cluster (`kind`, `minikube` or `k3d`), `kubectl`, and network access to download the Collector binary. Every manifest and command is meant to be run as written. Version strings shown in outputs (`0.119.0`) are illustrative — your Collector may print a newer one.

These labs walk you through the four canonical deployment patterns the OTCA syllabus expects you to distinguish — **No-Collector**, **Agent**, **Gateway**, and **Sidecar** — and then through **scaling** a stateful gateway tier. Do them in order; each builds on the pipeline you configured before.

---

## Exercise 1 — The Collector as a single binary (baseline)

Before you can reason about *where* to run a Collector, you need to see one process ingest, process and export data. This is the shape every deployment mode reuses.

### Steps

1. Download the **contrib** distribution binary for your platform from the release page and make it executable:

   ```bash
   VERSION=0.119.0
   OS=linux ARCH=amd64
   curl -sSLo otelcol-contrib.tar.gz \
     "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${VERSION}/otelcol-contrib_${VERSION}_${OS}_${ARCH}.tar.gz"
   tar -xzf otelcol-contrib.tar.gz otelcol-contrib
   ./otelcol-contrib --version
   ```

   Expected:

   ```
   otelcol-contrib version 0.119.0
   ```

2. Write a minimal but production-shaped config to `config.yaml`. Note the order of processors and the three diagnostic extensions:

   ```yaml
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
     batch:
       send_batch_size: 8192
       timeout: 5s

   exporters:
     debug:
       verbosity: detailed

   extensions:
     health_check:
       endpoint: 0.0.0.0:13133
     pprof:
       endpoint: 0.0.0.0:1777
     zpages:
       endpoint: 0.0.0.0:55679

   service:
     extensions: [health_check, pprof, zpages]
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, batch]
         exporters: [debug]
     telemetry:
       metrics:
         level: detailed
         address: 0.0.0.0:8888
   ```

3. Start the Collector and read the startup logs:

   ```bash
   ./otelcol-contrib --config=config.yaml
   ```

   Expected (trimmed):

   ```
   info    service@v0.119.0/service.go:...  Setting up own telemetry...
   info    otlpreceiver@.../otlp.go:...     Starting GRPC server  {"endpoint": "0.0.0.0:4317"}
   info    otlpreceiver@.../otlp.go:...     Starting HTTP server  {"endpoint": "0.0.0.0:4318"}
   info    service@v0.119.0/service.go:...  Everything is ready. Begin running and processing data.
   ```

4. In a second terminal, generate five test spans with `telemetrygen` (part of the same release org) and watch the first terminal:

   ```bash
   telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 5
   ```

   The Collector's `debug` exporter prints:

   ```
   info    Traces  {"resource spans": 1, "spans": 5}
   info    ResourceSpans #0
   Resource attributes:
        -> service.name: Str(telemetrygen)
   ScopeSpans #0
   Span #0
       Trace ID       : 6a...  Span ID: 1f...  Name: okey-dokey-0  Kind: Server
   ...
   ```

5. Confirm the operational surfaces are live:

   ```bash
   curl -s localhost:13133          # health_check → HTTP 200
   curl -s localhost:8888/metrics | grep otelcol_receiver_accepted_spans
   ```

   Expected metric line:

   ```
   otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc",...} 5
   ```

**Comprehension questions (Block 1)**

- **1a.** Why does `memory_limiter` appear *first* in the `processors` list of the pipeline, before `batch`?
- **1b.** Ports `4317` and `4318` carry telemetry *in*. What are ports `13133`, `8888`, `1777` and `55679` for, and why would you never expose them to application traffic?
- **1c.** You ran the `contrib` distribution. When would the smaller `otelcol` (core) distribution be the correct choice instead, and what is the risk of standardizing on `contrib` everywhere?

---

## Exercise 2 — Agent vs Gateway: chaining two Collector tiers

The Agent runs *close to the workload* (one per node, or per pod) and offloads fast. The Gateway is a *standalone, horizontally-scaled service* that does the heavier, centralized work. Production pipelines usually run **both**: agents fan-in to a gateway. You will build exactly that.

### Steps

1. Install the OpenTelemetry Operator (it requires cert-manager). Wait for both to be ready:

   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
   kubectl wait --for=condition=Available deploy --all -n cert-manager --timeout=180s

   kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
   kubectl wait --for=condition=Available deploy/opentelemetry-operator-controller-manager \
     -n opentelemetry-operator-system --timeout=180s

   kubectl create namespace observability
   ```

2. Deploy the **Gateway** tier as a `Deployment` with three replicas. It terminates the pipeline in `debug` for now:

   ```yaml
   # gateway.yaml
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: gateway
     namespace: observability
   spec:
     mode: deployment
     replicas: 3
     config:
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
         debug:
           verbosity: normal
       service:
         pipelines:
           traces:
             receivers: [otlp]
             processors: [memory_limiter, batch]
             exporters: [debug]
   ```

   ```bash
   kubectl apply -f gateway.yaml
   kubectl -n observability get otelcol,deploy,svc
   ```

   The operator materializes a Deployment plus stable Services. Expected (trimmed):

   ```
   NAME                             MODE         REPLICAS
   opentelemetrycollector/gateway   deployment   3

   NAME                          READY
   deployment.apps/gateway-collector   3/3

   NAME                                     TYPE        PORT(S)
   service/gateway-collector               ClusterIP   4317/TCP,4318/TCP
   service/gateway-collector-headless      ClusterIP   4317/TCP,4318/TCP
   service/gateway-collector-monitoring    ClusterIP   8888/TCP
   ```

3. Deploy the **Agent** tier as a `DaemonSet` (one pod per node). It receives OTLP locally, enriches it, batches, and forwards to the gateway `Service` over OTLP:

   ```yaml
   # agent.yaml
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: agent
     namespace: observability
   spec:
     mode: daemonset
     config:
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
         resourcedetection:
           detectors: [env, system]
         batch: {}
       exporters:
         otlp:
           endpoint: gateway-collector.observability.svc.cluster.local:4317
           tls:
             insecure: true
       service:
         pipelines:
           traces:
             receivers: [otlp]
             processors: [memory_limiter, resourcedetection, batch]
             exporters: [otlp]
   ```

   ```bash
   kubectl apply -f agent.yaml
   kubectl -n observability get ds/agent-collector
   ```

4. Send traffic *to an agent pod* and prove it reaches the gateway. Port-forward the agent, fire spans, then read the gateway logs:

   ```bash
   kubectl -n observability port-forward ds/agent-collector 4317:4317 &
   telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 3

   kubectl -n observability logs deploy/gateway-collector --all-pods=true --tail=20 | grep -i "spans"
   ```

   Expected — the gateway (not the agent) is the tier that prints the exported spans:

   ```
   info    Traces  {"resource spans": 1, "spans": 3}
   ```

**Comprehension questions (Block 2)**

- **2a.** The agent uses `mode: daemonset` and the gateway `mode: deployment`. Explain *why each pattern maps to that workload kind* — what property of the node topology forces the DaemonSet, and why is the gateway a Deployment rather than a DaemonSet?
- **2b.** The agent pipeline includes `resourcedetection` but the gateway does not. Why is resource enrichment (host, k8s, cloud metadata) a job for the tier *nearest the workload* and not the central gateway?
- **2c.** The agent exports to `gateway-collector` (the regular ClusterIP Service), not to `gateway-collector-headless`. What does the regular Service give you here, and in what later scenario (Exercise 4) does that choice become *wrong*?
- **2d.** Give two concrete responsibilities you would push *up* to the gateway rather than run on every agent, and explain the resource/consistency reason for each.

---

## Exercise 3 — Sidecar deployment with the Operator

The Sidecar is an Agent that shares a **pod** with exactly one application instance. The Operator injects it as an extra container when a pod is annotated. Use this when you need per-pod isolation, per-pod lifecycle, or a localhost-only OTLP endpoint that never leaves the pod unbatched.

### Steps

1. Define a Collector in `mode: sidecar`. In sidecar mode you must *not* fix the receiver to `0.0.0.0` on a shared port that could collide — bind localhost and forward to the gateway:

   ```yaml
   # sidecar.yaml
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: sidecar
     namespace: observability
   spec:
     mode: sidecar
     config:
       receivers:
         otlp:
           protocols:
             grpc:
               endpoint: 127.0.0.1:4317
             http:
               endpoint: 127.0.0.1:4318
       processors:
         batch: {}
       exporters:
         otlp:
           endpoint: gateway-collector.observability.svc.cluster.local:4317
           tls:
             insecure: true
       service:
         pipelines:
           traces:
             receivers: [otlp]
             processors: [batch]
             exporters: [otlp]
   ```

   ```bash
   kubectl apply -f sidecar.yaml
   ```

2. Deploy a workload and request injection with the pod annotation. The annotation value `sidecar` must match the CR name in that namespace:

   ```yaml
   # app.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: demo-app
     namespace: observability
   spec:
     replicas: 1
     selector: { matchLabels: { app: demo-app } }
     template:
       metadata:
         labels: { app: demo-app }
         annotations:
           sidecar.opentelemetry.io/inject: "sidecar"
       spec:
         containers:
           - name: app
             image: ghcr.io/open-telemetry/opentelemetry-collector-releases/telemetrygen:latest
             args:
               - traces
               - --otlp-insecure
               - --otlp-endpoint=localhost:4317
               - --duration=10m
               - --rate=1
   ```

   ```bash
   kubectl apply -f app.yaml
   ```

3. Verify the pod now runs **two** containers — your app plus `otc-container`:

   ```bash
   kubectl -n observability get pod -l app=demo-app \
     -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
   ```

   Expected:

   ```
   app otc-container
   ```

4. Confirm the app's telemetry, sent to `localhost:4317`, transits the injected sidecar and lands on the gateway:

   ```bash
   kubectl -n observability logs deploy/gateway-collector --all-pods=true --tail=5 | grep -i spans
   ```

**Comprehension questions (Block 3)**

- **3a.** The sidecar's OTLP receiver binds `127.0.0.1`, but the DaemonSet agent in Exercise 2 bound `0.0.0.0`. Why is the localhost bind correct — even required for isolation — in the sidecar case, and what would break if the app pointed at the node IP instead of `localhost`?
- **3b.** A cluster with 400 application pods across 10 nodes: how many Collector processes exist under the Sidecar pattern versus the Agent (DaemonSet) pattern, and what is the operational trade-off that number represents?
- **3c.** The injection annotation lives on the **pod template**, not the Deployment. What does that tell you about *when* the sidecar is added, and why does changing the annotation require a pod restart to take effect?

---

## Exercise 4 — Scaling the gateway for stateful processing

A stateless gateway scales trivially: add replicas behind the Service. It stops being trivial the moment a processor needs **all spans of a trace on the same instance** — tail-based sampling and span-to-metrics are the canonical cases. This exercise fixes the consistency problem with a two-layer gateway and the `loadbalancing` exporter.

### Steps

1. Observe the failure mode first. `tail_sampling` on a 3-replica gateway that is load-balanced *per connection* will see fragments of each trace on different replicas, so sampling decisions are made on incomplete traces. Confirm the risk conceptually by inspecting how OTLP/gRPC connections spread across replicas:

   ```bash
   kubectl -n observability get endpoints gateway-collector -o wide
   ```

   Three endpoint IPs → three independent decision-makers, no shared trace state.

2. Introduce a **layer-1 routing gateway** whose only job is to hash by trace ID and pin every span of a trace to one **layer-2** collector. The layer-1 config uses the `loadbalancing` exporter with a Kubernetes resolver against the headless service:

   ```yaml
   # gateway-lb.yaml  (layer 1 — routing)
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: gw-router
     namespace: observability
   spec:
     mode: deployment
     replicas: 2
     config:
       receivers:
         otlp:
           protocols:
             grpc:
               endpoint: 0.0.0.0:4317
       exporters:
         loadbalancing:
           routing_key: traceID
           protocol:
             otlp:
               tls:
                 insecure: true
           resolver:
             k8s:
               service: gw-sampler-collector-headless.observability
               ports: [4317]
       service:
         pipelines:
           traces:
             receivers: [otlp]
             exporters: [loadbalancing]
   ```

3. Deploy the **layer-2 sampling gateway** that actually runs `tail_sampling`. Because layer 1 guarantees trace affinity, each layer-2 replica sees whole traces:

   ```yaml
   # gateway-sampler.yaml  (layer 2 — stateful decision)
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: gw-sampler
     namespace: observability
   spec:
     mode: deployment
     replicas: 3
     config:
       receivers:
         otlp:
           protocols:
             grpc:
               endpoint: 0.0.0.0:4317
       processors:
         tail_sampling:
           decision_wait: 10s
           policies:
             - name: keep-errors
               type: status_code
               status_code: { status_codes: [ERROR] }
             - name: sample-rest
               type: probabilistic
               probabilistic: { sampling_percentage: 10 }
       exporters:
         debug: { verbosity: normal }
       service:
         pipelines:
           traces:
             receivers: [otlp]
             processors: [tail_sampling]
             exporters: [debug]
   ```

   ```bash
   kubectl apply -f gateway-sampler.yaml   # create the target first
   kubectl apply -f gateway-lb.yaml        # then the router that resolves it
   ```

4. Point the agents from Exercise 2 at the **router** (`gw-router-collector:4317`) instead of the old gateway, re-apply, and add horizontal autoscaling to the *sampler* tier:

   ```yaml
   # in agent.yaml, change the exporter endpoint:
   #   endpoint: gw-router-collector.observability.svc.cluster.local:4317
   ```

   ```yaml
   # hpa.yaml
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: gw-sampler
     namespace: observability
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: gw-sampler-collector
     minReplicas: 3
     maxReplicas: 10
     metrics:
       - type: Resource
         resource:
           name: cpu
           target: { type: Utilization, averageUtilization: 70 }
   ```

   ```bash
   kubectl apply -f hpa.yaml
   kubectl -n observability get hpa gw-sampler
   ```

5. Watch the `loadbalancing` exporter react when the sampler tier scales. The k8s resolver re-reads endpoints and rebalances the hash ring:

   ```bash
   kubectl -n observability logs deploy/gw-router-collector --all-pods=true | grep -i "resolver\|endpoints"
   ```

   Expected on a scale event:

   ```
   info    loadbalancingexporter  Resolving backends  {"backends": ["10.244.1.7:4317","10.244.2.9:4317", ...]}
   ```

**Comprehension questions (Block 4)**

- **4a.** Why can a `batch`-only gateway be scaled with a plain round-robin Service, while a `tail_sampling` gateway cannot? Name the exact property that `loadbalancing` with `routing_key: traceID` restores.
- **4b.** The router in layer 1 resolves `gw-sampler-collector-headless`, not the regular `gw-sampler-collector` Service. Why must it target the **headless** service specifically for the resolver to work?
- **4c.** The HPA is attached to the **sampler** tier, not the router tier. Given how each tier does its work, why is that the right tier to autoscale, and what makes the sampler tier the memory-hungry one?
- **4d.** When the sampler scales from 3 → 4 pods, the hash ring changes and a fraction of in-flight traces get their spans split across an old and a new owner for the duration of `decision_wait`. Is this a correctness bug or an accepted trade-off? Justify in one or two sentences.

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Block 1

**1a.** The pipeline executes processors **in list order**. `memory_limiter` must run first so it can reject or slow incoming data *before* memory is committed to batching. If `batch` ran first, the Collector would already have allocated large in-memory batches by the time the limiter noticed pressure, defeating its purpose and risking an OOM-kill. The rule of thumb: `memory_limiter` first, `batch` last (immediately before the exporters). *Source: https://opentelemetry.io/docs/collector/configuration/#processors and the memory_limiter processor README.*

**1b.** Those are the Collector's **operational / diagnostic surfaces**, not data planes:
- `13133` — `health_check` extension (liveness/readiness probe target).
- `8888` — the Collector's **own** internal telemetry (`otelcol_*` metrics in Prometheus format).
- `1777` — `pprof` extension (Go CPU/heap profiling).
- `55679` — `zpages` extension (live in-process trace/pipeline debug pages, e.g. `/debug/tracez`).
You keep them off the data path and off untrusted networks because they expose internals (profiles, in-flight data, health) and answer no application traffic; exposing them widens the attack surface for zero telemetry benefit. *Source: https://opentelemetry.io/docs/collector/internal-telemetry/*

**1c.** `otelcol` (**core**) ships only the stable, widely-used components; `otelcol-contrib` bundles the large community set (extra receivers/processors/exporters like `loadbalancing`, `tail_sampling`, `resourcedetection`, vendor exporters). Choose **core** when your pipeline only needs stable components — you get a smaller image, smaller attack surface, and fewer moving parts. Standardizing on **contrib** everywhere means shipping and securing dozens of components you never use (larger image, more CVE exposure, more config foot-guns). Production teams often build a **custom distribution** with the OpenTelemetry Collector Builder (`ocb`) containing exactly the components they use. *Source: https://opentelemetry.io/docs/collector/distributions/ and https://opentelemetry.io/docs/collector/custom-collector/*

### Block 2

**2a.** A **DaemonSet** guarantees *exactly one pod per node*, which is the definition of "an agent local to every workload host" — telemetry from any app never has to cross a node boundary to reach its agent. A **Gateway** has no per-node affinity: it is a pool of interchangeable workers sized to *throughput*, so a **Deployment** (an arbitrary replica count you scale up and down, scheduled anywhere) is the correct kind. Running the gateway as a DaemonSet would wastefully couple its replica count to node count and pin capacity to topology instead of load. *Source: https://opentelemetry.io/docs/collector/deployment/agent/ and .../gateway/*

**2b.** Resource enrichment needs **local ground truth** — the host name, node, pod, container, cloud region — which is only unambiguously available *where the workload runs*. The agent (DaemonSet/sidecar) sits there and can attach correct `host.*`, `k8s.*`, `cloud.*` attributes. By the time data reaches a central gateway it has been mixed from many nodes; the gateway can no longer tell which host a given span came from, so detection there would be wrong or impossible.

**2c.** The regular ClusterIP `gateway-collector` Service gives you **kube-proxy load-balancing** across the three gateway replicas — fine when the gateway is stateless (`batch` only), because any replica can handle any span. It becomes **wrong** in Exercise 4: once the gateway does `tail_sampling`, per-connection round-robin scatters a single trace's spans across replicas, and sampling decisions are made on partial traces. That is exactly what the `loadbalancing` exporter + headless service fixes.

**2d.** Any two of: **tail-based sampling** (needs the whole trace in one place → centralize on the gateway, not per-node); **cross-service aggregation / span-metrics** (a node only sees a slice of traffic, so aggregates must be central); **egress auth & backend fan-out** (keep vendor credentials and retry/queue buffers on a small managed tier, not on hundreds of agents); **heavy transforms / PII redaction** (CPU-expensive, cheaper to do once centrally than on every node). The common reasons are *consistency* (needs a global view) and *resource economy* (do expensive work on a few well-sized pods, not N agents).

### Block 3

**3a.** In a sidecar the Collector shares the **pod's network namespace** with the app, so `localhost:4317` reaches the sidecar and nothing else — the endpoint is private to that one pod, which is the whole point of per-pod isolation. Binding `127.0.0.1` guarantees no other pod can send to it and no port collides on the node. If the app instead pointed at the **node IP**, it would bypass its own sidecar and hit the DaemonSet agent (or nothing), losing the per-pod isolation and the pod-scoped batching the sidecar exists to provide. *Source: https://opentelemetry.io/docs/collector/deployment/#sidecar (deployment patterns).*

**3b.** Sidecar: **one Collector per application pod = 400 Collectors**. Agent/DaemonSet: **one Collector per node = 10 Collectors**. The trade-off: the sidecar gives the strongest isolation and per-pod lifecycle (a noisy pod can't affect a neighbor's Collector) at the cost of 40× the process count, memory overhead and config churn; the DaemonSet is far cheaper and simpler but shares one agent's fate and resources among every pod on the node.

**3c.** The annotation on the **pod template** means injection is an **admission-time mutation**: the Operator's mutating webhook adds the `otc-container` when the pod is *created*. Existing pods are never mutated in place, so changing the annotation only affects pods born afterward — you must trigger a rollout (restart) for running pods to be re-created with (or without) the sidecar. *Source: https://github.com/open-telemetry/opentelemetry-operator#sidecar-injection*

### Block 4

**4a.** A `batch`-only gateway is **stateless**: each span is independent, so any replica can process any span and round-robin is fine. `tail_sampling` is **stateful per trace** — the decision requires *every span of a trace* to be co-located so the processor can evaluate policies against the complete trace. `loadbalancing` with `routing_key: traceID` restores **trace affinity**: it hashes on the trace ID so all spans of a given trace deterministically land on the same downstream replica. *Source: https://opentelemetry.io/docs/collector/scaling/ and the loadbalancingexporter README.*

**4b.** The `k8s` resolver must enumerate the **individual pod IPs (endpoints)** of the target tier to build and maintain its hash ring. A regular ClusterIP Service hides the pods behind one virtual IP (kube-proxy load-balances opaquely), so the exporter would see a single backend and could not pin traces to specific pods. A **headless** Service (`clusterIP: None`) publishes the pod IPs directly via DNS/Endpoints, which is exactly what the resolver reads. *Source: https://opentelemetry.io/docs/collector/scaling/*

**4c.** `tail_sampling` **buffers every span of every in-flight trace for `decision_wait`** before deciding, so the sampler tier's memory and CPU grow with trace volume — it is the stateful, resource-hungry tier and therefore the one whose load actually varies with traffic. The router tier just hashes and forwards (cheap, roughly constant per-span cost), so autoscaling it buys little. Scale where the work and the buffered state live: the sampler.

**4d.** It is an **accepted trade-off**, not a correctness bug. Trace completeness in a distributed, elastically-scaled sampler is *best-effort*: during a rebalance a small fraction of traces spanning the scale event may be split, causing at worst a slightly-off sampling decision (a trace kept or dropped it shouldn't have) — never data corruption. Techniques that reduce it — longer `decision_wait`, consistent-hashing resolvers, scaling during low traffic — mitigate but don't eliminate it, and the observability cost is negligible against the benefit of elastic scale. *Source: https://opentelemetry.io/docs/collector/scaling/*

</details>

---

**Reference sources**
- OTCA curriculum: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
- Collector deployment patterns: https://opentelemetry.io/docs/collector/deployment/
- Agent: https://opentelemetry.io/docs/collector/deployment/agent/ · Gateway: https://opentelemetry.io/docs/collector/deployment/gateway/
- Scaling the Collector: https://opentelemetry.io/docs/collector/scaling/
- Kubernetes / Operator: https://opentelemetry.io/docs/platforms/kubernetes/operator/ · https://github.com/open-telemetry/opentelemetry-operator
- Distributions & builder: https://opentelemetry.io/docs/collector/distributions/ · https://opentelemetry.io/docs/collector/custom-collector/
- Releases (binaries): https://github.com/open-telemetry/opentelemetry-collector-releases