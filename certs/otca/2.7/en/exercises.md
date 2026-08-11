# OTCA 2.7 — Agents: Guided Exercises

> **Terminology first.** In OpenTelemetry the word *agent* is overloaded, and the exam expects you to disambiguate:
> 1. **Collector in Agent mode** — a Collector process running *next to* the workload (per-node DaemonSet or per-pod sidecar), as opposed to a **Gateway** (standalone, shared service). This is the dominant meaning.
> 2. **Zero-code instrumentation agent** — a language runtime attachment (e.g. the Java `-javaagent`) that instruments an application *without code changes*.
> 3. **A managed agent under OpAMP** — any Collector whose configuration and lifecycle are driven remotely by an OpAMP server through a Supervisor.
>
> These exercises walk through all three. Every manifest is syntactically complete; every command shows representative output (versions and timestamps will differ on your machine).

**Prerequisites**

- A local Kubernetes cluster (`kind create cluster` or `minikube start`) and `kubectl`.
- `otelcol-contrib` binary (the *contrib* distribution — the *core* distribution lacks `hostmetrics`, `filelog`, `k8sattributes` and `opampsupervisor`). Download from the [Collector releases](https://github.com/open-telemetry/opentelemetry-collector-releases/releases).
- Docker, and `curl`/`jq`.
- Source references: [Collector deployment — Agent](https://opentelemetry.io/docs/collector/deployment/agent/), [Gateway](https://opentelemetry.io/docs/collector/deployment/gateway/), [Configuration](https://opentelemetry.io/docs/collector/configuration/).

---

## Exercise 1 — Run a Collector as an Agent (DaemonSet)

**Goal:** deploy one Collector per node that receives OTLP from local pods, scrapes host metrics, tails container logs, enriches everything with Kubernetes and host resource attributes, and forwards to a gateway.

### Steps

1. Create the namespace and RBAC. The `k8sattributes` processor and the `k8snode`/`k8sattributes` detectors need read access to pods, namespaces and nodes.

   ```yaml
   # 01-rbac.yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: observability
   ---
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
     - apiGroups: [""]
       resources: ["pods", "namespaces", "nodes"]
       verbs: ["get", "list", "watch"]
     - apiGroups: ["apps"]
       resources: ["replicasets"]
       verbs: ["get", "list", "watch"]
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
   ```

   ```bash
   kubectl apply -f 01-rbac.yaml
   ```

2. Write the agent configuration as a ConfigMap. Note the pipeline **processor order**: `memory_limiter` first, `batch` last.

   ```yaml
   # 02-agent-config.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: otel-agent-config
     namespace: observability
   data:
     config.yaml: |
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
             cpu:
             memory:
             load:
             disk:
             filesystem:
             network:
         filelog:
           include: [ /var/log/pods/*/*/*.log ]
           include_file_path: true
           operators:
             - type: container            # parses the CRI/containerd log envelope
       processors:
         memory_limiter:
           check_interval: 1s
           limit_percentage: 80
           spike_limit_percentage: 25
         k8sattributes:
           auth_type: serviceAccount
           passthrough: false
           extract:
             metadata: [k8s.pod.name, k8s.namespace.name, k8s.node.name, k8s.pod.uid]
         resourcedetection:
           detectors: [env, system, k8snode]
           system:
             hostname_sources: [os]
         batch:
           send_batch_size: 8192
           timeout: 5s
       exporters:
         otlp:
           endpoint: otel-gateway.observability.svc.cluster.local:4317
           tls:
             insecure: true            # demo only — use real TLS in production
       extensions:
         health_check:
           endpoint: 0.0.0.0:13133
       service:
         extensions: [health_check]
         telemetry:
           metrics:
             address: 0.0.0.0:8888
         pipelines:
           traces:
             receivers: [otlp]
             processors: [memory_limiter, k8sattributes, resourcedetection, batch]
             exporters: [otlp]
           metrics:
             receivers: [otlp, hostmetrics]
             processors: [memory_limiter, k8sattributes, resourcedetection, batch]
             exporters: [otlp]
           logs:
             receivers: [otlp, filelog]
             processors: [memory_limiter, k8sattributes, resourcedetection, batch]
             exporters: [otlp]
   ```

   ```bash
   kubectl apply -f 02-agent-config.yaml
   ```

3. Deploy the DaemonSet. It mounts the host filesystem read-only for `hostmetrics`, mounts pod logs for `filelog`, and injects the node IP via the Downward API so applications can target *their own node's* agent.

   ```yaml
   # 03-agent-daemonset.yaml
   apiVersion: apps/v1
   kind: DaemonSet
   metadata:
     name: otel-agent
     namespace: observability
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
             image: otel/opentelemetry-collector-contrib:0.106.1
             args: ["--config=/conf/config.yaml"]
             env:
               - name: K8S_NODE_NAME
                 valueFrom:
                   fieldRef: { fieldPath: spec.nodeName }
               - name: OTEL_RESOURCE_ATTRIBUTES
                 value: "k8s.node.name=$(K8S_NODE_NAME)"
             ports:
               - { containerPort: 4317, hostPort: 4317, protocol: TCP }   # OTLP gRPC on the node IP
               - { containerPort: 13133 }
             resources:
               limits: { memory: 400Mi }
               requests: { cpu: 100m, memory: 200Mi }
             livenessProbe:
               httpGet: { path: /, port: 13133 }
             volumeMounts:
               - { name: config, mountPath: /conf }
               - { name: hostfs, mountPath: /hostfs, readOnly: true, mountPropagation: HostToContainer }
               - { name: varlogpods, mountPath: /var/log/pods, readOnly: true }
         volumes:
           - name: config
             configMap: { name: otel-agent-config }
           - name: hostfs
             hostPath: { path: / }
           - name: varlogpods
             hostPath: { path: /var/log/pods }
   ```

   ```bash
   kubectl apply -f 03-agent-daemonset.yaml
   kubectl -n observability rollout status ds/otel-agent
   ```

4. Confirm the agent came up cleanly. Tail one pod's logs:

   ```bash
   kubectl -n observability logs ds/otel-agent | head -n 12
   ```

   Expected (abridged, format varies by version):

   ```
   info    service@v0.106.1/service.go:225   Starting otelcol-contrib...  {"Version": "0.106.1", "NumCPU": 8}
   info    extensions/extensions.go:34       Starting extensions...
   info    healthcheckextension@v0.106.1     Starting health_check extension {"endpoint": "0.0.0.0:13133"}
   info    otlpreceiver@v0.106.1/otlp.go:102 Starting GRPC server {"endpoint": "0.0.0.0:4317"}
   info    otlpreceiver@v0.106.1/otlp.go:152 Starting HTTP server {"endpoint": "0.0.0.0:4318"}
   info    hostmetricsreceiver@v0.106.1      started scraper {"kind": "receiver", "scrapers": 6}
   info    service@v0.106.1/service.go:251   Everything is ready. Begin running and processing data.
   ```

5. Point an application at *its node's* agent. An app pod uses the host IP, not a Service:

   ```yaml
   env:
     - name: HOST_IP
       valueFrom:
         fieldRef: { fieldPath: status.hostIP }
     - name: OTEL_EXPORTER_OTLP_ENDPOINT
       value: "http://$(HOST_IP):4317"
     - name: OTEL_EXPORTER_OTLP_PROTOCOL
       value: "grpc"
   ```

> **Comprehension check**
>
> **Q1.** Why is `memory_limiter` placed *first* and `batch` *last* in every pipeline? What breaks if you swap them?
>
> **Q2.** Applications target `http://$(HOST_IP):4317` instead of a Kubernetes `Service` DNS name. Why is that the correct choice for a per-node agent, and what does the `hostPort: 4317` line enable?
>
> **Q3.** The DaemonSet mounts host `/` at `/hostfs` and the config sets `root_path: /hostfs`. Which receiver needs this, and what would `hostmetrics` report without it?
>
> **Q4.** Name two enrichment steps the agent performs that an application SDK, on its own, generally cannot do reliably — and say why the *agent* is the right place for them.

---

## Exercise 2 — Agent → Gateway topology and the tail-sampling trade-off

**Goal:** understand why agents forward to gateways, and demonstrate the one thing an agent *cannot* correctly do alone: tail-based sampling.

### Steps

1. Deploy a minimal gateway (a `Deployment` behind a `Service`, scalable independently of nodes) that does tail-based sampling before exporting to a backend.

   ```yaml
   # 04-gateway.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata: { name: otel-gateway-config, namespace: observability }
   data:
     config.yaml: |
       receivers:
         otlp:
           protocols:
             grpc: { endpoint: 0.0.0.0:4317 }
       processors:
         memory_limiter:
           check_interval: 1s
           limit_percentage: 80
           spike_limit_percentage: 25
         tail_sampling:
           decision_wait: 10s
           policies:
             - name: keep-errors
               type: status_code
               status_code: { status_codes: [ERROR] }
             - name: keep-slow
               type: latency
               latency: { threshold_ms: 500 }
             - name: sample-the-rest
               type: probabilistic
               probabilistic: { sampling_percentage: 5 }
         batch: {}
       exporters:
         debug: { verbosity: normal }      # replaces the old "logging" exporter
       service:
         pipelines:
           traces:
             receivers: [otlp]
             processors: [memory_limiter, tail_sampling, batch]
             exporters: [debug]
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: otel-gateway, namespace: observability }
   spec:
     replicas: 2
     selector: { matchLabels: { app: otel-gateway } }
     template:
       metadata: { labels: { app: otel-gateway } }
       spec:
         containers:
           - name: otel-gateway
             image: otel/opentelemetry-collector-contrib:0.106.1
             args: ["--config=/conf/config.yaml"]
             volumeMounts: [ { name: config, mountPath: /conf } ]
         volumes:
           - name: config
             configMap: { name: otel-gateway-config }
   ---
   apiVersion: v1
   kind: Service
   metadata: { name: otel-gateway, namespace: observability }
   spec:
     selector: { app: otel-gateway }
     ports: [ { name: otlp-grpc, port: 4317, targetPort: 4317 } ]
   ```

   ```bash
   kubectl apply -f 04-gateway.yaml
   ```

2. Note the topology you now have: **app → node agent (DaemonSet) → gateway Service (2 replicas) → backend**. The agent config from Exercise 1 already exports to `otel-gateway.observability.svc.cluster.local:4317`.

3. Now reason about a failure. Suppose you tried to move `tail_sampling` *into the agents* instead of the gateway. Scale the gateway down and picture two agents each seeing only *part* of a distributed trace:

   ```bash
   kubectl -n observability scale deploy/otel-gateway --replicas=0
   ```

   A single request that crosses pods on Node A and Node B produces spans that land on **two different agents**. Each agent's `tail_sampling` sees an incomplete trace and makes its own decision.

4. Restore the gateway and confirm the correct placement:

   ```bash
   kubectl -n observability scale deploy/otel-gateway --replicas=2
   ```

   For tail sampling to work, all spans of a trace must reach the *same* Collector instance. That is why production gateways sit behind a **trace-ID-aware load balancer** (the `loadbalancing` exporter, routing by `traceID`), so every span of a trace lands on one gateway replica.

> **Comprehension check**
>
> **Q5.** Give three responsibilities that belong on the **gateway**, not the agent, and explain the common reason they all share.
>
> **Q6.** Why does tail-based sampling break when performed on per-node agents, but head-based (probabilistic, `parentbased_traceidratio`) sampling does not?
>
> **Q7.** A gateway is deployed with `replicas: 3` behind an ordinary round-robin `Service`, running `tail_sampling`. Even with the gateway "in the right tier," sampling still misbehaves. What is missing, and which exporter fixes it?
>
> **Q8.** State one availability advantage and one resource-cost disadvantage of the agent tier compared to sending telemetry directly from apps to a central gateway.

---

## Exercise 3 — Managing a fleet of agents with OpAMP

**Goal:** run a Collector under the **OpAMP Supervisor** so its configuration and health are driven by a remote OpAMP server. See [OpAMP specification](https://opentelemetry.io/docs/specs/opamp/) and the [`opampsupervisor`](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/opampsupervisor).

### Steps

1. Write a Supervisor configuration. The Supervisor is a thin process that *wraps* the Collector binary, connects to the OpAMP server over WebSocket, applies remote config, and restarts the Collector as needed.

   ```yaml
   # supervisor.yaml
   server:
     endpoint: wss://opamp.example.com/v1/opamp
     headers:
       Authorization: "Bearer ${env:OPAMP_TOKEN}"
   capabilities:
     accepts_remote_config: true
     reports_effective_config: true
     reports_own_metrics: true
     reports_health: true
     reports_remote_config: true
   agent:
     executable: /usr/bin/otelcol-contrib
   storage:
     directory: /var/lib/otelcol/supervisor
   ```

2. Start the Supervisor (it launches the Collector as a child process):

   ```bash
   OPAMP_TOKEN=... opampsupervisor --config supervisor.yaml
   ```

   Expected startup:

   ```
   info  Supervisor starting     {"id": "01J...ULID", "version": "0.106.1"}
   info  Connected to the OpAMP server
   info  Received remote config from server {"hash": "b3d1..."}
   info  Starting agent           {"agent": "/usr/bin/otelcol-contrib"}
   info  Agent process started    {"pid": 4711}
   info  Reporting health         {"healthy": true}
   ```

3. On the server side, an operator pushes a new pipeline (e.g. lowers the sampling rate) to *thousands* of agents at once. Each Supervisor:
   - receives the new `AgentConfigMap`,
   - writes it to `storage.directory`,
   - restarts the Collector with the merged config,
   - reports back `reports_effective_config` (what actually loaded) and `reports_remote_config` (accepted/failed + hash).

4. If a pushed config is invalid, the Supervisor reports the failure and keeps the last-known-good config running — the fleet does not go dark. Observe that behaviour by watching the health/status the Supervisor reports (`RemoteConfigStatus = FAILED`, `health.healthy = true` on the previous config).

> **Comprehension check**
>
> **Q9.** What is the division of labour between the **Supervisor** and the **Collector**? Why not build OpAMP directly into the Collector binary?
>
> **Q10.** Distinguish `reports_effective_config` from `reports_remote_config`. Why does an operator need *both* to trust a fleet rollout?
>
> **Q11.** OpAMP runs over a persistent connection (typically WebSocket) and supports capabilities like `AcceptsRemoteConfig` and `ReportsHealth`. Give two operational problems at fleet scale that OpAMP solves which editing per-node ConfigMaps by hand does not.

---

## Exercise 4 — Zero-code instrumentation agents (and Operator auto-injection)

**Goal:** produce telemetry from an *un-modified* application with a language agent, then have the OpenTelemetry Operator inject that agent automatically. See [Zero-code instrumentation](https://opentelemetry.io/docs/zero-code/), the [Java agent](https://opentelemetry.io/docs/zero-code/java/agent/), and [SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/).

### Steps

1. Attach the Java agent to a plain JAR — no source changes. Configuration is entirely through env vars / system properties:

   ```bash
   java -javaagent:./opentelemetry-javaagent.jar \
        -Dotel.service.name=checkout \
        -Dotel.exporter.otlp.endpoint=http://localhost:4317 \
        -Dotel.exporter.otlp.protocol=grpc \
        -Dotel.traces.sampler=parentbased_traceidratio \
        -Dotel.traces.sampler.arg=0.25 \
        -Dotel.propagators=tracecontext,baggage \
        -jar checkout.jar
   ```

   Expected agent banner:

   ```
   [otel.javaagent 2026-08-10 14:20:03:112 +0000] [main] INFO io.opentelemetry.javaagent.tooling.VersionLogger - opentelemetry-javaagent - version: 2.6.0
   ```

2. Do the same for Python, which uses a bootstrap step plus a launcher wrapper:

   ```bash
   pip install opentelemetry-distro opentelemetry-exporter-otlp
   opentelemetry-bootstrap -a install          # detects libraries, installs matching instrumentations
   OTEL_SERVICE_NAME=cart \
   OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
   opentelemetry-instrument python app.py
   ```

3. In Kubernetes, stop editing pod specs by hand. Install the [Operator](https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/), then declare an `Instrumentation` resource pointing at *your node agent*:

   ```yaml
   # 05-instrumentation.yaml
   apiVersion: opentelemetry.io/v1alpha1
   kind: Instrumentation
   metadata:
     name: default-instr
     namespace: shop
   spec:
     exporter:
       endpoint: http://otel-agent.observability:4317   # or the node agent via HOST_IP
     propagators: [tracecontext, baggage]
     sampler:
       type: parentbased_traceidratio
       argument: "0.25"
     java:
       image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:latest
   ```

   ```bash
   kubectl apply -f 05-instrumentation.yaml
   ```

4. Opt a workload in with a single annotation — the Operator's mutating webhook injects an init container that copies the agent in and sets the `JAVA_TOOL_OPTIONS`/env for you:

   ```yaml
   # in the Deployment's pod template:
   metadata:
     annotations:
       instrumentation.opentelemetry.io/inject-java: "true"
   ```

   Verify the injection:

   ```bash
   kubectl -n shop get pod checkout-xxxx -o jsonpath='{.spec.initContainers[*].name}'
   # -> opentelemetry-auto-instrumentation-java
   kubectl -n shop exec checkout-xxxx -- printenv JAVA_TOOL_OPTIONS
   # -> -javaagent:/otel-auto-instrumentation-java/javaagent.jar
   ```

> **Comprehension check**
>
> **Q12.** In one sentence each, contrast the *two* "agents" that now coexist in this pod: the injected **Java agent** and the **node Collector agent**. What flows between them?
>
> **Q13.** Zero-code agents are configured only through environment variables / system properties following the OTel spec. Write the four env vars that set: service name, OTLP endpoint, sampler, and sampler ratio — using the standard `OTEL_*` names.
>
> **Q14.** The Operator's `Instrumentation` CRD uses a *mutating admission webhook* plus an *init container*. What does each of those two mechanisms contribute to getting the agent into the running process?
>
> **Q15.** A teammate sets `OTEL_TRACES_SAMPLER=traceidratio` (not `parentbased_traceidratio`) on a downstream service. Why can this fragment traces, and which value keeps a distributed trace all-or-nothing?

---

## Exercise 5 — Diagnosing a silent agent

**Goal:** an agent is "Running" but no data reaches the backend. Localize the fault using the Collector's own telemetry, health/zpages extensions, and a debug exporter.

### Steps

1. Add diagnostic extensions and a local debug exporter to the agent config (temporarily), then reload:

   ```yaml
   extensions:
     health_check: { endpoint: 0.0.0.0:13133 }
     zpages:       { endpoint: 0.0.0.0:55679 }
     pprof:        { endpoint: 0.0.0.0:1777 }
   exporters:
     debug: { verbosity: detailed }
   service:
     extensions: [health_check, zpages, pprof]
   # add `debug` alongside `otlp` in each pipeline's exporters list
   ```

2. Port-forward and read the agent's **own** Prometheus metrics (default `:8888/metrics`):

   ```bash
   kubectl -n observability port-forward ds/otel-agent 8888:8888 &
   curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|processor|exporter)'
   ```

   A healthy-ingest / failing-egress pattern looks like:

   ```
   otelcol_receiver_accepted_spans{...}       124301
   otelcol_receiver_refused_spans{...}        0
   otelcol_exporter_sent_spans{exporter="otlp",...}         0
   otelcol_exporter_send_failed_spans{exporter="otlp",...}  124301
   otelcol_exporter_queue_size{exporter="otlp",...}         5000
   ```

3. Interpret: data is *accepted* by the receiver but every span *fails to export*. That points downstream — the gateway is unreachable or rejecting TLS. Confirm connectivity from the agent pod:

   ```bash
   kubectl -n observability exec ds/otel-agent -- \
     nc -zv otel-gateway.observability.svc.cluster.local 4317
   ```

4. Cross-check with `zpages`:

   ```bash
   kubectl -n observability port-forward ds/otel-agent 55679:55679 &
   curl -s localhost:55679/debug/pipelinez     # pipelines, per-signal
   curl -s localhost:55679/debug/tracez        # sampled recent spans + errors
   ```

5. Now flip the symptom: `otelcol_receiver_refused_spans` is climbing and logs show `data refused due to high memory usage`. That is `memory_limiter` applying **backpressure** — the fix is more memory / a lower `limit_percentage`, or reducing incoming volume, not a networking change.

> **Comprehension check**
>
> **Q16.** `accepted_spans` is high, `sent_spans` is zero, `send_failed_spans` tracks `accepted_spans`, and `queue_size` is pinned at its max. In which tier is the fault, and what are two likely root causes?
>
> **Q17.** A different agent shows rising `otelcol_receiver_refused_spans` and `memory_limiter` log lines. Why is *refusing at the receiver* the intended behaviour rather than a bug, and what protects the node if you ignore it?
>
> **Q18.** Which endpoints do `health_check`, `zpages` and the `:8888` telemetry address expose, and which of the three tells you whether *individual spans* are erroring versus whether the *process* is alive?

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** `memory_limiter` must run first so it can inspect and, under pressure, *refuse* incoming data before any downstream processor has allocated memory for it — it applies backpressure to the receiver. `batch` runs last (just before the exporter) so batches are assembled from data that already survived limiting and enrichment, maximizing export efficiency. Swapping them means `batch` accumulates large in-memory batches that `memory_limiter` can no longer prevent, defeating the memory guard and inviting OOM kills; you'd also be spending CPU enriching/batching data that then gets dropped.

**Q2.** A per-node agent is reachable at its node's IP; sending to a cluster `Service` would round-robin across *all* nodes' agents, adding a network hop, breaking node-local locality (host metrics/log correlation, lowest latency) and defeating the DaemonSet design. `status.hostIP` gives each pod the IP of the node it runs on, and `hostPort: 4317` binds the agent's OTLP port on the node so `HOST_IP:4317` reaches the local agent. Result: every pod talks to the agent on its own node.

**Q3.** The `hostmetrics` receiver. Inside a container it would otherwise read the *container's* view of `/proc` and `/sys`, reporting the container's cgroup-limited CPU/memory/filesystem rather than the node's. Mounting host `/` at `/hostfs` with `root_path: /hostfs` makes it read the real host metrics.

**Q4.** Any two of: (a) **Kubernetes attributes** (`k8s.pod.name`, `k8s.namespace.name`, `k8s.node.name`) via `k8sattributes` — the app doesn't reliably know its own pod metadata, and centralizing it avoids per-app RBAC; (b) **host/node resource detection** (`resourcedetection`) — infra identity belongs to the platform, not the app; (c) **container log collection** (`filelog`) — the app can't tail sibling containers' logs; (d) **host metrics** — infrastructure signals no single app owns. The agent is the right place because it runs with node-level access and one config governs every workload, so enrichment is uniform and apps stay thin.

**Q5.** Examples: **tail-based sampling**, **cross-source aggregation/deduplication**, **trace-ID-aware load balancing / fan-in**, **sensitive-data scrubbing at an egress choke point**, **backend-specific export & retry with large queues**. Shared reason: they need a **global or aggregated view** of telemetry (or a stable central choke point), which a per-node agent — seeing only its node's slice — structurally cannot provide.

**Q6.** Tail-based sampling decides *after* seeing the whole trace (e.g. "keep if any span errored or is slow"), so it requires **all spans of a trace in one place**. With per-node agents, spans of a distributed request are split across the nodes where each service runs, so no single agent sees the full trace and decisions are inconsistent/incorrect. Head-based sampling (`parentbased_traceidratio`) decides at trace start from the trace ID and **propagates that decision** via context to every service, so each node independently makes the *same* keep/drop choice — no global view needed.

**Q7.** A trace's spans are still being spread across the three gateway replicas by round-robin, so each replica sees a partial trace — the same problem, one tier up. Fix: put a **trace-ID-aware layer** in front using the **`loadbalancing` exporter** with `routing_key: traceID` (a first tier of gateways routes by trace ID to a second tier that does `tail_sampling`), guaranteeing all spans of a trace reach one sampling instance.

**Q8.** Advantage: the agent **decouples the app from the backend** — apps do a fast local hand-off, and the agent buffers/retries during backend or network outages, so a slow backend doesn't stall the app or lose data. Disadvantage: it costs a Collector **on every node** (CPU/memory footprint × node count) even when nodes are lightly loaded, whereas app-direct-to-gateway needs no per-node process.

**Q9.** The **Collector** does the telemetry work (receive/process/export); the **Supervisor** is a lightweight manager that maintains the OpAMP connection, applies remote config to disk, (re)starts and health-checks the Collector, and reports status. Keeping OpAMP in the Supervisor means the management channel survives Collector restarts/crashes and config swaps, config can be validated and rolled back around the Collector process, and the Collector binary stays focused — you can manage a Collector you didn't build OpAMP into.

**Q10.** `reports_remote_config` tells the server whether the pushed config was **accepted or rejected** (with a hash and error), i.e. the *outcome of the delivery*. `reports_effective_config` reports the config the Collector is **actually running** after merges/defaults, i.e. *reality*. You need both because a config can be delivered/accepted yet not be what's effectively loaded (merge order, local overrides, fallback to last-known-good) — only comparing "what I sent / what was accepted" against "what is actually running" proves the fleet converged.

**Q11.** Any two: (a) **atomic, auditable fleet-wide rollouts with reported status and hashes** instead of hoping N ConfigMap edits all applied; (b) **safe failure handling** — a bad config is reported `FAILED` and the agent keeps the last-known-good running, versus a hand edit that can silently break an agent; (c) **live health, effective-config and own-metrics reporting** from thousands of agents over one channel; (d) **coordinated upgrades** of the agent binary. Manual ConfigMap editing gives no rollout status, no automatic rollback, and no fleet-wide health/inventory.

**Q12.** The **Java agent** is a zero-code instrumentation library attached to the *application JVM* that generates spans/metrics/logs from that one process. The **node Collector agent** is a separate process that *receives* telemetry from many local pods and processes/forwards it. Flow: the Java agent exports OTLP to the node Collector agent (`OTEL_EXPORTER_OTLP_ENDPOINT` → `HOST_IP:4317`), which enriches and forwards to the gateway.

**Q13.**
```
OTEL_SERVICE_NAME=checkout
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
```

**Q14.** The **mutating admission webhook** intercepts the pod at creation and rewrites its spec — adding the init container, a shared volume, and the env (`JAVA_TOOL_OPTIONS=-javaagent:...`) — so no one hand-edits deployments. The **init container** ships the agent binary/jar and copies it into the shared volume before the app starts, so the agent files are present on the app container's filesystem for the JVM to load at launch.

**Q15.** `traceidratio` makes an **independent** keep/drop decision at each service using only the local trace-ID hash, ignoring the parent's decision; so a parent may keep a trace while a child drops it (or vice-versa), producing broken, partial traces. `parentbased_traceidratio` **respects the sampling decision propagated in the context** and only applies the ratio at the root, so the whole distributed trace is sampled all-or-nothing.

**Q16.** The fault is **downstream of this agent — in export / the gateway**: the receiver accepts data (`accepted_spans` high) but the exporter can't deliver it (`send_failed_spans` ≈ `accepted_spans`, `sent_spans` = 0) and the sending queue is saturated. Two likely causes: the gateway endpoint is **unreachable** (wrong DNS/Service, gateway down, NetworkPolicy) or the connection is **rejected** (TLS misconfiguration/cert mismatch, or the gateway is refusing/overloaded).

**Q17.** `memory_limiter` refusing at the receiver is deliberate **backpressure**: rather than buffering unbounded data and being OOM-killed (losing *everything* and restarting), it returns errors to senders so they retry/slow down, keeping the Collector alive and shedding the excess load gracefully. Ignoring it risks the agent breaching its container memory limit and being OOM-killed by the kubelet, taking down telemetry for the whole node.

**Q18.** `health_check` (`:13133`) exposes **process liveness/readiness** (used by the k8s probe). `zpages` (`:55679`, e.g. `/debug/tracez`, `/debug/pipelinez`) exposes **in-process traces of recent spans and pipeline state**, including per-span errors. The `:8888/metrics` telemetry address exposes the Collector's **own Prometheus counters** (`otelcol_receiver_*`, `otelcol_exporter_*`, etc.). To see whether *individual spans* are erroring, use **`zpages` (`/debug/tracez`)** together with the `:8888` failure counters; `health_check` only tells you the *process* is alive.

</details>

---

**Sources**

- OpenTelemetry Collector — Agent deployment: https://opentelemetry.io/docs/collector/deployment/agent/
- OpenTelemetry Collector — Gateway deployment: https://opentelemetry.io/docs/collector/deployment/gateway/
- Collector configuration & processors: https://opentelemetry.io/docs/collector/configuration/
- Scaling the Collector (agent/gateway, trace-ID load balancing): https://opentelemetry.io/docs/collector/scaling/
- OpAMP specification: https://opentelemetry.io/docs/specs/opamp/ · Supervisor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/opampsupervisor
- Zero-code instrumentation: https://opentelemetry.io/docs/zero-code/ · Java agent: https://opentelemetry.io/docs/zero-code/java/agent/
- SDK environment variables: https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- Kubernetes Operator — automatic instrumentation: https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/