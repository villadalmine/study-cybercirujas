# OTCA — Domain 3: The OpenTelemetry Collector
## Topic 3.3 — Scaling (Guided Exercises)

> **Scope.** These exercises train the production reasoning the OTCA expects for scaling the OpenTelemetry Collector: distinguishing **stateless** from **stateful** pipelines, scaling stateless pipelines horizontally, solving the **trace-affinity** problem with the **load-balancing exporter**, sharding metric scrapes with the **Target Allocator**, and protecting a scaled fleet with **backpressure** and **autoscaling**. Every config is complete and valid for a recent `otelcol-contrib` build.
>
> **Prerequisites.** Docker (or Podman) for Exercises 1–3 and 5; a `kind`/`minikube` cluster plus `kubectl` and the **OpenTelemetry Operator** for Exercise 4. A traffic generator: `telemetrygen` (`go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest`). We use the `contrib` distribution because `loadbalancing`, `tail_sampling` and the `prometheus` receiver live there.
>
> **The mental model.** A Collector pipeline scales *horizontally and freely* **only if every component is stateless** — a decision about one item never depends on another item. The moment a component must *see a group of items together* (all spans of one trace, all delta points of one series), naive round-robin load balancing breaks it, and you need **affinity routing** or **sharding**.

---

## Exercise 1 — Baseline: one Collector and its internal telemetry

You cannot scale what you cannot measure. First, learn to read the Collector's own metrics, which are the ground truth for every scaling decision that follows.

**Steps**

1. Create `collector.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     batch:
       send_batch_size: 8192
       timeout: 5s

   exporters:
     debug:
       verbosity: basic

   service:
     telemetry:
       metrics:
         # Prometheus scrape endpoint for the Collector's own metrics
         readers:
           - pull:
               exporter:
                 prometheus:
                   host: 0.0.0.0
                   port: 8888
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [debug]
   ```

2. Run it:

   ```bash
   docker run --rm -p 4317:4317 -p 4318:4318 -p 8888:8888 \
     -v "$(pwd)/collector.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:latest \
     --config /etc/otelcol/config.yaml
   ```

3. In a second terminal, send a bounded, rate-limited load:

   ```bash
   telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure \
     --traces 5000 --rate 200 --child-spans 3
   ```

4. Scrape the Collector's internal metrics and pull out the signals that matter for scaling:

   ```bash
   curl -s localhost:8888/metrics | grep -E \
     'otelcol_receiver_(accepted|refused)_spans|otelcol_exporter_(sent|send_failed)_spans|otelcol_exporter_queue_(size|capacity)|otelcol_process_memory_rss'
   ```

   Expected (values will differ):

   ```text
   otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc"} 20000
   otelcol_receiver_refused_spans_total{receiver="otlp",transport="grpc"} 0
   otelcol_exporter_sent_spans_total{exporter="debug"} 20000
   otelcol_exporter_send_failed_spans_total{exporter="debug"} 0
   otelcol_exporter_queue_size{exporter="debug"} 0
   otelcol_exporter_queue_capacity{exporter="debug"} 1000
   otelcol_process_memory_rss_bytes 8.5e+07
   ```

**Check your understanding**

- **1a.** Which two counters, compared as a ratio, tell you whether the *receive* side is saturated, and which two tell you the *export* side is failing?
- **1b.** You observe `otelcol_exporter_queue_size` climbing steadily toward `otelcol_exporter_queue_capacity`. Is the bottleneck upstream (receiver) or downstream (backend/exporter)? Justify.
- **1c.** Why is “number of spans per second the process handles” a poor scaling target on its own, compared to watching `refused` + `send_failed` + `queue_size` together?

---

## Exercise 2 — Scaling a *stateless* pipeline horizontally

A pipeline of `otlp → batch → otlp/debug` keeps **no cross-item state**: any span can be processed by any replica. That is the easy case — put N replicas behind an L4/L7 load balancer and you are done.

**Steps**

1. Confirm the pipeline is stateless: list its components (`otlp` receiver, `batch`, `memory_limiter`, `resource`, `filter`, `transform`, most exporters). None of them makes a decision about item A that depends on item B.

2. Simulate three replicas behind round-robin DNS with Docker Compose. Create `compose.yaml`:

   ```yaml
   services:
     collector:
       image: otel/opentelemetry-collector-contrib:latest
       command: ["--config", "/etc/otelcol/config.yaml"]
       volumes:
         - ./collector.yaml:/etc/otelcol/config.yaml
       deploy:
         replicas: 3
       expose:
         - "4317"
     lb:
       image: nginx:latest
       ports:
         - "4317:4317"
       volumes:
         - ./nginx.conf:/etc/nginx/nginx.conf:ro
       depends_on:
         - collector
   ```

   `nginx.conf` (gRPC L4 stream balancing across the three backends):

   ```nginx
   events {}
   stream {
     upstream collectors {
       server collector:4317;   # Docker DNS returns all 3 replica IPs
     }
     server {
       listen 4317;
       proxy_pass collectors;
     }
   }
   ```

3. Launch and generate load:

   ```bash
   docker compose up -d
   telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure --traces 9000 --rate 300
   ```

4. Verify the load spread across replicas by summing `accepted_spans` from each:

   ```bash
   for id in $(docker compose ps -q collector); do
     ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id")
     echo -n "$ip: "
     docker exec "$id" wget -qO- "http://localhost:8888/metrics" \
       | grep '^otelcol_receiver_accepted_spans_total' | awk '{print $2}'
   done
   ```

   Expected — the total is conserved and roughly balanced:

   ```text
   172.20.0.3: 12040
   172.20.0.4: 11980
   172.20.0.5: 11980
   ```

**Check your understanding**

- **2a.** Why is round-robin balancing *correct* for this pipeline but would be *wrong* the moment you add a `tail_sampling` processor?
- **2b.** Name three Collector components that are safe to scale this way and one category of component that is not.
- **2c.** A gRPC client opens one long-lived HTTP/2 connection and multiplexes all streams over it. What does that imply about balancing at L4 (TCP) versus L7 (per-request), and which one actually spreads OTLP load evenly?

---

## Exercise 3 — The trace-affinity problem and the load-balancing exporter (two tiers)

`tail_sampling` is **stateful**: to decide whether to keep a trace, it must buffer *all spans of that trace* for `decision_wait`, then apply policies. If a trace's spans are scattered across replicas by round-robin, every replica sees a *partial* trace and makes a wrong or duplicated decision. The fix is a **two-tier (layered) deployment**: a stateless **gateway tier** that routes by trace ID, feeding a **sampling tier** where each backend owns whole traces.

**Steps**

1. **Sampling tier** — `sampling.yaml` (this is what scales for the actual decision):

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     tail_sampling:
       decision_wait: 10s
       num_traces: 100000
       expected_new_traces_per_sec: 1000
       policies:
         - name: keep-errors
           type: status_code
           status_code:
             status_codes: [ERROR]
         - name: keep-slow
           type: latency
           latency:
             threshold_ms: 500
         - name: baseline-sample
           type: probabilistic
           probabilistic:
             sampling_percentage: 10

   exporters:
     debug:
       verbosity: basic

   service:
     telemetry:
       metrics:
         readers:
           - pull: { exporter: { prometheus: { host: 0.0.0.0, port: 8888 } } }
     pipelines:
       traces:
         receivers: [otlp]
         processors: [tail_sampling]
         exporters: [debug]
   ```

2. **Gateway tier** — `gateway.yaml`. The `loadbalancing` exporter hashes on `routing_key: traceID`, so every span sharing a trace ID is sent to the *same* backend:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   exporters:
     loadbalancing:
       routing_key: traceID          # affinity by trace; use "service" for spanmetrics
       protocol:
         otlp:
           tls:
             insecure: true
       resolver:
         # In Docker, Compose DNS returns all sampler replica IPs for this name.
         dns:
           hostname: sampling
           port: 4317
         # In Kubernetes, prefer the k8s resolver against a headless Service:
         # k8s:
         #   service: otel-sampling-collector-headless.observability
         #   ports: [4317]

   service:
     pipelines:
       traces:
         receivers: [otlp]
         exporters: [loadbalancing]
   ```

3. `compose.yaml`:

   ```yaml
   services:
     sampling:
       image: otel/opentelemetry-collector-contrib:latest
       command: ["--config", "/etc/otelcol/config.yaml"]
       volumes: [./sampling.yaml:/etc/otelcol/config.yaml]
       deploy: { replicas: 3 }
       expose: ["4317", "8888"]
     gateway:
       image: otel/opentelemetry-collector-contrib:latest
       command: ["--config", "/etc/otelcol/config.yaml"]
       volumes: [./gateway.yaml:/etc/otelcol/config.yaml]
       ports: ["4317:4317"]
       depends_on: [sampling]
   ```

4. Send traces through the gateway, then confirm affinity — each sampler should report a `tail_sampling` decision count, and **no trace should be split**:

   ```bash
   docker compose up -d
   telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure --traces 6000 --rate 200 --child-spans 4

   for id in $(docker compose ps -q sampling); do
     echo -n "sampler $id sampled/dropped: "
     docker exec "$id" wget -qO- localhost:8888/metrics \
       | grep -E 'otelcol_processor_tail_sampling_(count_traces_sampled|global_count_traces_sampled)' | tr '\n' ' '
     echo
   done
   ```

   Expected — roughly a third of the *traces* (not spans) land on each sampler, and each sampler decided on whole traces:

   ```text
   sampler ...a sampled/dropped: otelcol_processor_tail_sampling_global_count_traces_sampled{...sampled="true"} 210 ...sampled="false"} 1790
   sampler ...b sampled/dropped: ... true 205 ... false 1795
   sampler ...c sampled/dropped: ... true 208 ... false 1792
   ```

5. Restart one sampler and re-send. Observe that only the traces hashed to that instance are affected during the DNS/resolver reconvergence — the other two continue unaffected.

**Check your understanding**

- **3a.** Precisely *why* does putting three `tail_sampling` collectors behind the round-robin balancer from Exercise 2 produce incorrect sampling?
- **3b.** Which tier is stateless and which is stateful in this design? Which tier do you autoscale with a plain CPU HPA, and which needs care?
- **3c.** When would you set `routing_key: service` instead of `traceID`? (Hint: which connector needs *all spans of a service*, not of a trace, on one instance?)
- **3d.** In Kubernetes, why must the `loadbalancing` exporter resolve a **headless** Service, and what would go wrong if you pointed its `dns` resolver at a normal ClusterIP Service?
- **3e.** You scale the sampling tier from 3 → 6 replicas. With `routing_key: traceID`, what fraction of trace-to-backend assignments churn, and why does that matter *only for traces in flight during the change*?

---

## Exercise 4 — Sharding metric scrapes with the Target Allocator

The `prometheus` receiver is also *stateful in a scaling sense*: if you run N collector replicas each with the same `scrape_configs`, **every replica scrapes every target**, producing N-way duplicate series. You cannot round-robin your way out of this — you must **shard the target list**. The OTel Operator's **Target Allocator (TA)** does exactly that: it discovers targets and assigns disjoint subsets to each collector replica.

**Steps**

1. Install the OpenTelemetry Operator (it pulls in cert-manager if needed):

   ```bash
   kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
   kubectl -n opentelemetry-operator-system rollout status deploy/opentelemetry-operator-controller-manager
   ```

2. Create a sharded, StatefulSet-mode collector with TA enabled — `otel-metrics.yaml`:

   ```yaml
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: otel-metrics
     namespace: observability
   spec:
     mode: statefulset            # stable pod identity is required for stable sharding
     replicas: 3
     targetAllocator:
       enabled: true
       allocationStrategy: consistent-hashing   # or per-node / least-weighted
       prometheusCR:
         enabled: true            # also honor ServiceMonitor / PodMonitor CRs
     config:
       receivers:
         prometheus:
           config:
             scrape_configs:
               - job_name: 'kubelet-cadvisor'
                 scheme: https
                 kubernetes_sd_configs:
                   - role: node
                 tls_config:
                   insecure_skip_verify: true
                 authorization:
                   credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
       processors:
         batch: {}
       exporters:
         debug:
           verbosity: basic
       service:
         pipelines:
           metrics:
             receivers: [prometheus]
             processors: [batch]
             exporters: [debug]
   ```

   ```bash
   kubectl create namespace observability
   kubectl apply -f otel-metrics.yaml
   ```

3. Observe what the Operator **injected**. The TA rewrites each collector's `prometheus` receiver to *pull its assignment from the allocator* instead of doing service discovery itself:

   ```bash
   kubectl -n observability get cm otel-metrics-collector -o yaml | sed -n '/prometheus:/,/service:/p'
   ```

   Expected (abbreviated) — note the injected `target_allocator` block and that `scrape_configs` is now managed by the TA:

   ```yaml
   receivers:
     prometheus:
       config:
         global: {}
       target_allocator:
         endpoint: http://otel-metrics-targetallocator:80
         interval: 30s
         collector_id: ${POD_NAME}
   ```

4. Ask the allocator how it sharded the targets across the three pods:

   ```bash
   kubectl -n observability port-forward svc/otel-metrics-targetallocator 8080:80 &
   curl -s localhost:8080/jobs/kubelet-cadvisor/targets | jq 'keys, (.. | .collector? // empty) ' | head
   # Per-collector view:
   curl -s 'localhost:8080/jobs/kubelet-cadvisor/targets?collector_id=otel-metrics-collector-0' | jq '.[].targets'
   ```

   Expected — the node targets are partitioned, not duplicated: collector-0, -1, -2 each own a disjoint slice of the nodes.

**Check your understanding**

- **4a.** Without the Target Allocator, what exactly is wrong with the metrics produced by 3 identical prometheus-receiver replicas?
- **4b.** Why does TA sharding require `mode: statefulset` rather than `deployment`? What property of StatefulSet pods does `consistent-hashing` rely on?
- **4c.** A node is added to the cluster. Walk through how the new node's cadvisor endpoint ends up assigned to exactly one collector replica.
- **4d.** Contrast the two scaling mechanisms you have now seen for stateful data: **affinity routing** (Exercise 3) vs **target sharding** (Exercise 4). What does each guarantee, and why can't you swap one for the other?

---

## Exercise 5 — Backpressure, `memory_limiter`, and autoscaling

Scaling out is not free: a downstream backend can still be the true bottleneck, and an over-fed Collector will OOM-kill rather than degrade gracefully. Production scaling always pairs replica count with **backpressure** (queue + retry, memory limiting) and an **autoscaling policy** driven by the right signal.

**Steps**

1. Harden a pipeline — `hardened.yaml`. Order matters: `memory_limiter` **first**, `batch` **after** it:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     memory_limiter:
       check_interval: 1s
       limit_percentage: 80
       spike_limit_percentage: 25
     batch:
       send_batch_size: 8192
       timeout: 5s

   exporters:
     otlp:
       endpoint: backend:4317
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
         max_elapsed_time: 300s

   service:
     telemetry:
       metrics:
         readers:
           - pull: { exporter: { prometheus: { host: 0.0.0.0, port: 8888 } } }
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, batch]
         exporters: [otlp]
   ```

2. Run it with **no backend listening** so the exporter fails, forcing the queue to fill and backpressure to propagate:

   ```bash
   docker run --rm -p 4317:4317 -p 8888:8888 \
     -v "$(pwd)/hardened.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:latest --config /etc/otelcol/config.yaml
   telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure --traces 200000 --rate 5000
   ```

3. Watch the backpressure signals rise. When the queue is full, the exporter stops accepting, the receiver returns `RESOURCE_EXHAUSTED` upstream, and `refused` climbs — the Collector sheds load instead of dying:

   ```bash
   watch -n1 "curl -s localhost:8888/metrics | grep -E \
     'otelcol_exporter_queue_size|otelcol_exporter_send_failed_spans|otelcol_receiver_refused_spans|otelcol_processor_refused_spans'"
   ```

   Expected trajectory:

   ```text
   otelcol_exporter_queue_size{exporter="otlp"} 5000          # pinned at queue_size
   otelcol_exporter_send_failed_spans_total{exporter="otlp"} 41000   # rising
   otelcol_receiver_refused_spans_total{receiver="otlp",...} 8600    # backpressure reaching the client
   otelcol_processor_refused_spans_total{processor="memory_limiter"} 0   # >0 only if memory ceiling is hit
   ```

4. Define an autoscaling policy. On the OTel Operator you declare it directly on the CR:

   ```yaml
   spec:
     autoscaler:
       minReplicas: 2
       maxReplicas: 10
       targetCPUUtilization: 70
       # For queue-driven scaling, feed exporter queue metrics to a
       # custom-metrics adapter and target them here instead of CPU.
   ```

   The equivalent plain HPA (for a `Deployment`-mode gateway):

   ```yaml
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
     minReplicas: 2
     maxReplicas: 10
     metrics:
       - type: Resource
         resource:
           name: cpu
           target:
             type: Utilization
             averageUtilization: 70
   ```

**Check your understanding**

- **5a.** Why must `memory_limiter` be the **first** processor and `batch` come **after** it? What breaks if you reverse them?
- **5b.** Trace the backpressure chain when the backend is down: exporter → queue → receiver → client. Which two metrics prove backpressure is working *as designed* rather than silently dropping data?
- **5c.** You autoscale the gateway on CPU at 70%, but the real bottleneck is a slow backend (exporter `send_failed` rising, queue pinned at capacity, CPU low). Will adding replicas help? What is the correct scaling signal here?
- **5d.** For the **sampling tier** of Exercise 3, why is a CPU-based HPA risky, and what must you account for before adding replicas to a running `tail_sampling` fleet?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**

- **1a.** *Receive saturation:* `otelcol_receiver_refused_spans_total` rising relative to `otelcol_receiver_accepted_spans_total` — the Collector is rejecting incoming data. *Export failure:* `otelcol_exporter_send_failed_spans_total` rising relative to `otelcol_exporter_sent_spans_total` — the backend/exporter is failing to deliver.
- **1b.** **Downstream.** The queue is the buffer *in front of the exporter*. It grows only when the exporter consumes slower than the receiver produces — i.e., the backend (or network to it) can't keep up. Scaling the Collector out will not help; the backend or exporter concurrency is the constraint.
- **1c.** Raw spans/sec measures throughput but hides *health*. A Collector can push high spans/sec while silently refusing (data loss on the receive side) or failing exports (data loss on the send side) or buffering toward OOM (queue near capacity). The triad `refused + send_failed + queue_size` distinguishes “healthy and fast” from “fast but losing data,” which is the distinction scaling decisions actually depend on. Source: https://opentelemetry.io/docs/collector/internal-telemetry/

**Exercise 2**

- **2a.** Because `batch`/`otlp` make no decision about span A that depends on span B, so scattering spans across replicas is harmless. `tail_sampling` decides about a *trace* by inspecting *all its spans together*; scattering them means no replica ever sees the whole trace, so its decision is based on partial data.
- **2b.** Safe: `otlp` receiver, `batch`, `memory_limiter`, `resource`, `filter`, `transform`, `attributes`, most exporters. Not safe (stateful / needs grouping): `tail_sampling`, the `spanmetrics`/`servicegraph` connectors, `groupbytrace`, cumulative↔delta conversion that keeps per-series state, and the `prometheus` receiver’s scrape ownership.
- **2c.** A single gRPC/HTTP2 connection multiplexes all requests, so **L4 (TCP) balancing pins the whole connection to one backend** — one noisy client can hammer a single replica. **L7 (per-request/gRPC-aware) balancing** spreads individual streams and actually distributes OTLP load. This is why the Collector’s own `loadbalancing` exporter (or an L7 mesh/proxy) is preferred over raw L4 for even distribution. Source: https://opentelemetry.io/docs/collector/scaling/

**Exercise 3**

- **3a.** With round-robin, the ~15 spans of one trace land on different replicas. Each `tail_sampling` instance buffers only *its* fragment for `decision_wait` and applies policies to a partial trace: it may miss the errored child span (so a policy like `keep-errors` fails to fire), or two instances may each independently decide to keep their fragment, producing an incomplete or duplicated sampled trace. Correct tail sampling requires *whole-trace locality*.
- **3b.** The **gateway tier is stateless** (just routes) and safely CPU-autoscaled. The **sampling tier is stateful**; you can scale it, but each scale event **rehashes trace→backend assignments** and traces in flight during reconvergence may be split, so scale it deliberately (not on twitchy CPU spikes) and let `decision_wait` windows drain.
- **3c.** Use `routing_key: service` when the downstream needs *all spans of a given service* on one instance — e.g., the `spanmetrics`/`servicegraph` connectors aggregating per-service metrics. `traceID` is for tail sampling; `service` is for per-service aggregation.
- **3d.** The `loadbalancing` exporter needs to see **every backend pod IP individually** so it can hash traces across them. A **headless** Service (`clusterIP: None`) makes DNS return *all* pod A-records; a normal ClusterIP returns a single virtual IP that kube-proxy load-balances opaquely — the exporter would then see *one* endpoint and lose all affinity control, collapsing back to the broken round-robin case. Source: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- **3e.** With plain modulo/hash-by-count balancing, going 3→6 could remap most assignments. The `loadbalancing` exporter uses a **consistent-hashing ring**, so only ~ the fraction of the keyspace owned by the *new* nodes churns (roughly the added capacity’s share), and it matters **only for traces still within their `decision_wait` window** during the change — already-decided traces are unaffected, and new traces simply hash to the new topology.

**Exercise 4**

- **4a.** All three replicas run identical `scrape_configs`, so each scrapes **every** target. You get **3× duplicate time series** (same labels, three sources), inflating cost and corrupting rates/aggregations. Round-robin can’t fix it because the duplication is in *what gets scraped*, not *where data is routed*.
- **4b.** `consistent-hashing` needs a **stable identity per collector** so the same target maps to the same replica across restarts and reconciles. StatefulSet pods have stable, ordinal names (`...-0`, `...-1`) and stable network identity; Deployment pods get random names that change on every roll, which would reshuffle the entire sharding on any restart. Source: https://opentelemetry.io/docs/kubernetes/operator/target-allocator/
- **4c.** The TA’s service discovery (node role / PodMonitor / ServiceMonitor) observes the new node → the allocator hashes the new target onto its ring → it assigns the target to exactly one `collector_id` → that collector, which polls `GET /jobs/<job>/targets?collector_id=...` every `interval`, picks it up on its next refresh and begins scraping it. No other replica scrapes it.
- **4d.** **Affinity routing** (Exercise 3) guarantees *all items of a group reach the same processing instance* — needed when a decision requires seeing the whole group (a trace). **Target sharding** (Exercise 4) guarantees *each source is owned by exactly one instance* — needed when the risk is *duplication* of independent pulls. They aren’t interchangeable: sharding scrape targets wouldn’t keep a trace’s spans together (traces arrive push-based, not as scrape targets), and affinity-routing metrics wouldn’t prevent every replica from scraping every endpoint.

**Exercise 5**

- **5a.** `memory_limiter` must run **first** so it can reject/refuse incoming data the instant memory pressure is detected, *before* any expensive processing or buffering happens; putting it after `batch` means batches are already accumulated in memory before the limiter can act, defeating its purpose and risking OOM. `batch` goes after so that only admitted data is batched. Source: https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/memorylimiterprocessor
- **5b.** Exporter fails → its `sending_queue` fills to `queue_size` → full queue applies backpressure to the pipeline → the receiver returns `RESOURCE_EXHAUSTED`/refuses → the OTLP client sees the error and (ideally) retries/slows. The proof it’s working *as designed*: `otelcol_exporter_queue_size` pinned at capacity **and** `otelcol_receiver_refused_spans_total` rising — the Collector is shedding load at the edge rather than silently dropping mid-pipeline or OOM-killing.
- **5c.** **No — adding replicas won’t help.** CPU is low and the constraint is the backend’s ingest rate; more Collector replicas just create more idle queues all blocked on the same slow backend. The correct scaling signal is the **exporter queue utilization / `send_failed` rate**, which points at the backend — the fix is scaling/optimizing the *backend* (or raising `num_consumers`/backend concurrency), not the Collector. CPU-based HPA is blind to this class of bottleneck.
- **5d.** `tail_sampling` holds up to `num_traces` in memory for `decision_wait`, so its load is **memory- and buffer-bound, not CPU-bound** — CPU can look idle while memory is near the limit, so a CPU HPA both scales late and, worse, **every scale event rehashes trace→backend assignments** (via the gateway’s consistent hash), splitting traces that are mid-`decision_wait`. Before adding replicas: size for memory, expect a brief window of degraded sampling accuracy during reconvergence, and prefer deliberate/step scaling over reactive CPU thresholds.

</details>

---

**Sources**

- OpenTelemetry Collector — *Scaling*: https://opentelemetry.io/docs/collector/scaling/
- OpenTelemetry Collector — *Deployment patterns (agent vs gateway)*: https://opentelemetry.io/docs/collector/deployment/
- Load-balancing exporter: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- Tail sampling processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- Target Allocator: https://opentelemetry.io/docs/kubernetes/operator/target-allocator/
- Memory limiter processor: https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/memorylimiterprocessor
- Collector internal telemetry: https://opentelemetry.io/docs/collector/internal-telemetry/
- OTCA curriculum: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf