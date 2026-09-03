# 702.2 Container Orchestration

**LPI DevOps Tools Engineer — Exam 701-100, v2.0.0**
**Topic weight: 5** · Advanced SRE / Platform Architect profile

---

## 1. Motivation: the architectural problem orchestration actually solves

### 1.1 The point where "run the container" stops working

A single container is a process with a private view of the filesystem, network and PID namespaces, constrained by cgroups. Running one is trivial: `podman run`, `docker run`, or a systemd unit wrapping either. The operational model breaks at a specific, identifiable threshold — when **any two** of the following become true at the same time:

1. The workload must survive the loss of the machine it runs on.
2. More than one replica of the workload exists, so *something* must decide which replica receives a given request.
3. The set of machines changes (autoscaling, hardware replacement, kernel patching) faster than a human can update inventory.
4. Deployments must happen without a maintenance window.

Below that threshold, `systemd` + Podman Quadlets + a static reverse-proxy config is a perfectly defensible production architecture, and it is materially cheaper to operate. Above it, you are re-implementing a scheduler, a health-checking service registry, and a rollout state machine in shell — badly, and without tests.

### 1.2 The imperative trap

The naive fleet automation is a push model: a configuration-management run enumerates hosts, copies a container spec, and restarts a unit.

```
$ ansible-playbook -i inventory/prod deploy-api.yml
PLAY RECAP ****************************************************************
node-07   : ok=12  changed=3  unreachable=0  failed=0
node-08   : ok=12  changed=3  unreachable=0  failed=0
node-09   : ok=0   changed=0  unreachable=1  failed=0
```

`node-09` was unreachable. The playbook exits, the operator moves on, and the cluster now has a **split state**: two nodes on `v2.4.1`, one node on `v2.4.0` — and nothing in the system is aware of it or responsible for fixing it. Convergence happened once, at 14:02, and then stopped. Worse, when `node-09` returns at 03:10, it comes back running the *old* image and immediately receives traffic from the load balancer, because the LB's health check only tests TCP:8080.

This is the core failure: **push automation converges at execution time; production diverges continuously.**

### 1.3 The control-loop answer

An orchestrator inverts the model. You submit a *declaration* of intent to an API. Independent controllers watch that declaration and the observed world, and continuously drive the difference to zero:

```
        ┌──────────────────────────────────────────────┐
        │  Declared state (API objects, persisted)     │
        │  replicas: 3, image: api:v2.4.1              │
        └───────────────┬──────────────────────────────┘
                        │ WATCH (long-lived, incremental)
                        ▼
        ┌──────────────────────────────────────────────┐
        │  Controller: diff(declared, observed) → act   │
        │  level-triggered, idempotent, re-entrant      │
        └───────────────┬──────────────────────────────┘
                        │ CREATE / DELETE / PATCH
                        ▼
        ┌──────────────────────────────────────────────┐
        │  Observed state (kubelet-reported, /status)   │
        └──────────────────────────────────────────────┘
```

Three properties are non-negotiable and worth naming precisely, because they are what you are actually buying:

- **Level-triggered, not edge-triggered.** A controller does not react to "a pod died" events. It reacts to "the current count is 2, the desired count is 3". A missed event is therefore not a lost update — the next resync recomputes the same diff. This is why orchestrators recover from their own outages.
- **Idempotent reconciliation.** Running the loop body twice with the same inputs produces the same result. This is what makes controllers safely restartable mid-action.
- **Separation of desired and observed state into distinct sub-resources.** In Kubernetes, `spec` is written by users, `status` is written by controllers. They are separate write paths (`/status` subresource) with separate RBAC, which is why a compromised workload cannot lie about its own desired configuration.

### 1.4 The five sub-problems an orchestrator must solve

| Sub-problem | Naive answer | Orchestrated answer |
|---|---|---|
| **Placement** | Static host assignment in inventory | Scheduler: filter feasible nodes, score them, bind |
| **Lifecycle** | `systemd` `Restart=always` per host | Controller recreates the workload *anywhere* in the fleet |
| **Discovery** | Static upstreams in HAProxy / DNS with TTL | Virtual IP + continuously-updated endpoint set |
| **Rollout** | Serial playbook run, no rollback state | State machine with surge/unavailability budget and revision history |
| **Resource arbitration** | Hope | Requests/limits, QoS classes, quotas, preemption |

Everything else in this topic is a detail of one of those five.

---

## 2. Orchestrator landscape and trade-offs

### 2.1 The field

The 701 objectives require *understanding of container orchestration concepts* and working familiarity with Kubernetes and Docker Swarm. In production architecture terms, the real decision matrix is wider.

| | **Kubernetes** | **Docker Swarm (classic mode)** | **HashiCorp Nomad** | **Systemd + Podman Quadlets** |
|---|---|---|---|---|
| **State store** | etcd (Raft), external to components | Built-in Raft in managers | Raft (servers), plus Consul optionally | None (host-local unit files) |
| **API surface** | Declarative REST, extensible via CRDs | Docker Engine API + `stack deploy` | HTTP API + HCL job spec | systemd D-Bus |
| **Scheduler model** | Pluggable framework, ~20 default plugins | Spread / bin-pack strategies over services | Bin-pack / spread, multi-workload (also VMs, raw exec) | Operator's brain |
| **Networking** | CNI plugin required, flat pod network | Built-in overlay (VXLAN) + routing mesh | CNI, or host/bridge; Consul Connect for mesh | Host / bridge / `podman network` |
| **Service discovery** | ClusterIP VIP + CoreDNS + EndpointSlice | Embedded DNS + VIP per service | Consul catalog / Nomad DNS | Static config |
| **Extensibility** | CRD + controller = first-class API objects | Effectively none | Task drivers, plugins | Anything, unmanaged |
| **Multi-tenancy** | Namespaces, RBAC, ResourceQuota, NetworkPolicy | Weak (no namespaces) | Namespaces + ACLs (Enterprise for full) | None |
| **Stateful workloads** | StatefulSet + CSI (per-replica PVC) | Volumes are node-local unless plugin | Host volumes / CSI | Local |
| **Operational cost** | High: control plane, CNI, CSI, upgrades, CRD sprawl | Low: one binary, `swarm init` | Medium: single binary, few moving parts | Very low |
| **Rollback semantics** | Revision history, `rollout undo`, PDB-aware drain | `service rollback`, previous spec only | `job revert` to any prior version | Manual |
| **Ecosystem gravity** | Overwhelming (CNCF, operators, Helm) | Maintenance mode | Modest | N/A |

### 2.2 Choosing, with the trade-off stated honestly

- **Kubernetes** wins when you need extensibility (operators encoding domain knowledge), hard multi-tenancy, or the ecosystem. It costs you a permanent platform team. The API is the product; the pods are incidental.
- **Swarm** wins for a 3–20 node estate with stateless services and a small team. `docker swarm init` to a working overlay network is under a minute. It loses when you need per-replica persistent volumes, real network policy, or anything the built-in objects do not model — there is no extension point.
- **Nomad** wins in heterogeneous estates (containers *and* JVM jars *and* QEMU VMs) and where operational simplicity is weighted heavily. It loses the ecosystem.
- **Quadlets/systemd** wins for single-node appliances and edge deployments. Podman generates systemd units from `.container` files; you get restart policies, dependency ordering and journald integration for free, and you get *nothing* about placement or discovery.

> **Architectural rule of thumb:** if your answer to "what happens when this node dies at 04:00" is "the workload restarts elsewhere automatically", you need an orchestrator. If it is "the standby takes over" or "we page someone", you may not.

---

## 3. Kubernetes architecture: the mechanics

### 3.1 Component topology

```
CONTROL PLANE (typically 3 or 5 nodes, tainted NoSchedule)
┌──────────────────────────────────────────────────────────────┐
│  kube-apiserver   ── the ONLY component that talks to etcd   │
│      │  authn → authz (RBAC) → admission (mutating,          │
│      │  then validating) → schema validation → persist       │
│      ▼                                                       │
│  etcd  (Raft consensus, quorum = floor(N/2)+1)               │
│                                                              │
│  kube-controller-manager  ── ~40 controllers in one process  │
│      (deployment, replicaset, node, endpointslice, job,      │
│       pv-binder, ttl-after-finished, …) leader-elected       │
│                                                              │
│  kube-scheduler   ── binds unscheduled Pods to Nodes         │
│  cloud-controller-manager (optional, out-of-tree providers)  │
└──────────────────────────────────────────────────────────────┘
                    ▲ watch/list + PATCH status
                    │
WORKER NODE (every node, including control plane)
┌──────────────────────────────────────────────────────────────┐
│  kubelet ── the node agent. Owns the Pod lifecycle.          │
│     ├── CRI  → containerd / CRI-O  → runc / crun / kata      │
│     ├── CNI  → Calico / Cilium / Flannel (pod networking)    │
│     └── CSI  → volume attach/mount via node-driver-registrar │
│  kube-proxy ── programs Service VIP dataplane (or replaced   │
│                entirely by an eBPF CNI such as Cilium)       │
└──────────────────────────────────────────────────────────────┘
```

Two facts that repeatedly matter in incident review:

- **Only the apiserver writes to etcd.** Every other component is an API client. Therefore etcd latency is apiserver latency is *everything* latency. `etcd_disk_wal_fsync_duration_seconds` p99 above ~25 ms is the earliest reliable warning of a cluster in trouble.
- **The kubelet is authoritative for what is actually running.** If the apiserver disappears, running pods keep running — the kubelet does not kill them. This is deliberate: a control-plane outage must not be a data-plane outage.

### 3.2 The watch mechanism and optimistic concurrency

Controllers do not poll. They `LIST` once to build a local cache (an *informer*), record the returned `resourceVersion`, then open a `WATCH` from that version and receive an incremental event stream. Writes use optimistic concurrency: the client submits the object with the `resourceVersion` it read; the apiserver rejects the write with `409 Conflict` if the stored version has moved.

```
$ kubectl get deployment api -o jsonpath='{.metadata.resourceVersion}{"\n"}'
48211937

$ kubectl get --raw '/apis/apps/v1/namespaces/prod/deployments?watch=1&resourceVersion=48211937' | head -2
{"type":"MODIFIED","object":{"kind":"Deployment","apiVersion":"apps/v1","metadata":{"name":"api","namespace":"prod","resourceVersion":"48211944", ...
{"type":"MODIFIED","object":{"kind":"Deployment","apiVersion":"apps/v1","metadata":{"name":"api","namespace":"prod","resourceVersion":"48211952", ...
```

The consequence for you: **write conflicts are normal and must be retried, not treated as errors**. Any controller or CI job that patches Kubernetes objects and does not retry on 409 will flake under load.

### 3.3 The scheduler, precisely

`kube-scheduler` runs a per-Pod cycle built from framework extension points. The two phases that matter operationally:

1. **Filter (feasibility).** Each plugin answers yes/no per node. Failing here yields `Pending` with a message enumerating *why each node was rejected*. Principal filters: `NodeResourcesFit` (requests vs allocatable), `NodeAffinity`, `TaintToleration`, `PodTopologySpread` (when `whenUnsatisfiable: DoNotSchedule`), `NodePorts`, `VolumeBinding`, `NodeUnschedulable`.
2. **Score (preference).** Surviving nodes are scored 0–100 per plugin and weighted. Principal scorers: `NodeResourcesBalancedAllocation`, `ImageLocality`, `InterPodAffinity`, `PodTopologySpread`, `TaintToleration`.

If filtering leaves zero nodes, **PostFilter** runs preemption: the scheduler looks for a node where evicting lower-`PriorityClass` pods would make the pending pod fit, and if found, deletes the victims (respecting their `terminationGracePeriodSeconds`) and *nominates* the node.

Critically: **the scheduler decides on `requests`, the kernel enforces `limits`.** A node whose pods request 2 CPU total but burn 30 CPU is, to the scheduler, nearly empty. Requests that do not reflect reality are the single most common root cause of "the cluster is on fire but the dashboard says 20% allocated".

### 3.4 Quality of Service and eviction order

| QoS class | Condition | `oom_score_adj` | Eviction order under node pressure |
|---|---|---|---|
| **Guaranteed** | Every container sets requests == limits for both CPU and memory | −997 | Last |
| **Burstable** | At least one request set, but not Guaranteed | 2…999, scaled by memory request vs node capacity | Second |
| **BestEffort** | No requests or limits at all | 1000 | First |

Under memory pressure, the kubelet ranks candidates by QoS class and then by usage *above requests*. This is why a Burstable pod with a large, honest memory request survives longer than one with a token `64Mi` request — the request is the protection.

---

## 4. Workload controllers

### 4.1 Comparison

| Controller | Identity | Ordering | Storage | Scaling | Typical use |
|---|---|---|---|---|---|
| **Deployment** → ReplicaSet | Random suffix, interchangeable | None | Shared or ephemeral | `replicas`, HPA | Stateless services |
| **StatefulSet** | Stable ordinal `web-0…web-N`, stable DNS | Ordered create/delete/update (configurable) | `volumeClaimTemplates`: one PVC per ordinal, retained | `replicas`, HPA (careful) | Databases, quorum systems, brokers |
| **DaemonSet** | One pod per matching node | N/A | `hostPath` typically | Implicit: node count | Log shippers, CNI agents, node exporters |
| **Job** | Run-to-completion | Parallelism controlled | Ephemeral | `completions`/`parallelism` | Migrations, batch |
| **CronJob** → Job | Schedule-driven | Concurrency policy | Ephemeral | N/A | Backups, reconciliation |
| **ReplicaSet** (bare) | Random | None | — | `replicas` | Almost never directly |

### 4.2 A complete, production-shaped Deployment

This manifest is intentionally not trimmed. Every field present is one you would be asked to justify in a design review.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api
  namespace: prod
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-config
  namespace: prod
data:
  LOG_LEVEL: "info"
  UPSTREAM_TIMEOUT_MS: "2500"
  application.yaml: |
    server:
      port: 8080
      shutdownGracePeriodMs: 20000
    metrics:
      path: /metrics
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: prod
  labels:
    app.kubernetes.io/name: api
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: storefront
    app.kubernetes.io/version: "2.4.1"
spec:
  replicas: 6
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 600
  minReadySeconds: 15
  selector:
    matchLabels:
      app.kubernetes.io/name: api
      app.kubernetes.io/component: backend
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2          # absolute or percentage; rounded UP
      maxUnavailable: 0    # zero-downtime posture: never dip below replicas
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api
        app.kubernetes.io/component: backend
        app.kubernetes.io/version: "2.4.1"
      annotations:
        # Forces a rollout when the ConfigMap content changes. Without this,
        # editing a ConfigMap changes nothing for already-running Pods that
        # consume it through env vars.
        checksum/config: "9f2c4d1e7a8b30f5c6d2e1a4b7c9d0e3f1a2b3c4"
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: api
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 45
      # Give the scheduler a chance to place pods on separate failure domains.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: api
              app.kubernetes.io/component: backend
          matchLabelKeys:
            - pod-template-hash        # spread each ReplicaSet independently
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: api
              app.kubernetes.io/component: backend
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        # Native sidecar: an initContainer with restartPolicy Always starts
        # before the app containers, keeps running alongside them, and is
        # terminated only after they exit. This solves the classic
        # "Job never completes because the proxy never exits" problem.
        - name: log-shipper
          image: registry.internal/fluent-bit:3.1.9
          restartPolicy: Always
          resources:
            requests: { cpu: "50m",  memory: "64Mi" }
            limits:   { memory: "128Mi" }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - { name: varlog, mountPath: /var/log/app, readOnly: true }
      containers:
        - name: api
          image: registry.internal/storefront/api:2.4.1@sha256:5d3b0f2ac71e8fbd4a9c60e2b1d7f38c92a4e5610bc7d8a3f2e9014c6b5d7a8e
          imagePullPolicy: IfNotPresent
          ports:
            - { name: http,    containerPort: 8080, protocol: TCP }
            - { name: metrics, containerPort: 9090, protocol: TCP }
          envFrom:
            - configMapRef:
                name: api-config
          env:
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: POD_IP
              valueFrom: { fieldRef: { fieldPath: status.podIP } }
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: api-db
                  key: password
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
              ephemeral-storage: "256Mi"
            limits:
              memory: "512Mi"          # == request → protects QoS on memory
              ephemeral-storage: "1Gi"
              # CPU limit deliberately omitted: CFS throttling on a latency
              # sensitive service costs more than the noisy-neighbour risk,
              # which requests already bound. Set one only where you must
              # guarantee determinism.
          startupProbe:
            httpGet: { path: /healthz/started, port: http }
            periodSeconds: 5
            failureThreshold: 60        # tolerate up to 300 s cold start
          readinessProbe:
            httpGet: { path: /healthz/ready, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 3         # out of rotation after ~15 s
          livenessProbe:
            httpGet: { path: /healthz/live, port: http }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6         # restart only after ~60 s of failure
          lifecycle:
            preStop:
              exec:
                # Deregistration race: endpoint removal and SIGTERM are
                # concurrent. Sleep long enough for every kube-proxy /
                # ingress controller to observe the endpoint deletion.
                command: ["/bin/sh", "-c", "sleep 8"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - { name: config,  mountPath: /etc/api,  readOnly: true }
            - { name: tmp,     mountPath: /tmp }
            - { name: varlog,  mountPath: /var/log/app }
      volumes:
        - name: config
          configMap:
            name: api-config
            items:
              - { key: application.yaml, path: application.yaml }
        - name: tmp
          emptyDir:
            sizeLimit: 256Mi
        - name: varlog
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: prod
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: api
    app.kubernetes.io/component: backend
  ports:
    - { name: http, port: 80, targetPort: http, protocol: TCP }
  # Keep a client pinned to one backend for the life of its source IP.
  # Default is None (per-connection hashing).
  sessionAffinity: None
  internalTrafficPolicy: Cluster
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api
  namespace: prod
spec:
  # minAvailable is evaluated against the *current* replica count, so with
  # an HPA prefer maxUnavailable to avoid deadlocking drains at low scale.
  maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: api
      app.kubernetes.io/component: backend
  unhealthyPodEvictionPolicy: AlwaysAllow
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
  namespace: prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 6
  maxReplicas: 40
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70      # % of the *request*, not of the node
    - type: Pods
      pods:
        metric:
          name: http_requests_inflight
        target:
          type: AverageValue
          averageValue: "30"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
      policies:
        - { type: Percent, value: 100, periodSeconds: 30 }
        - { type: Pods,    value: 8,   periodSeconds: 30 }
    scaleDown:
      stabilizationWindowSeconds: 600   # damp flapping; default is 300
      selectPolicy: Min
      policies:
        - { type: Percent, value: 20, periodSeconds: 120 }
```

**Design notes you should be able to defend:**

- `maxUnavailable: 0` + `maxSurge: 2` gives strictly zero-capacity-loss rollouts, at the cost of needing headroom for 2 extra pods and a slower rollout. The inverse (`maxUnavailable: 1, maxSurge: 0`) is correct when the workload holds an exclusive resource (a node-local port, a licence seat).
- `minReadySeconds: 15` prevents the classic fast-rollout disaster: the new pod passes readiness, the controller immediately terminates an old one, and *then* the new pod's JIT compiles / connection pool warms and it starts erroring. It converts "ready" into "ready and stable for 15 s".
- The `preStop` sleep is not superstition. Endpoint removal propagates asynchronously to every kube-proxy and ingress controller; SIGTERM is delivered concurrently. Without the delay, in-flight requests are routed to a socket that is already closing. Sleep ≥ your dataplane's convergence time.
- Pinning the image by digest (`@sha256:…`) alongside the tag makes the rollout reproducible even if the tag is overwritten upstream.

### 4.3 Rolling update mechanics, computed

With `replicas: 6`, `maxSurge: 2`, `maxUnavailable: 0`:

- Upper bound on total pods: `6 + 2 = 8`
- Lower bound on available pods: `6 − 0 = 6`

The Deployment controller therefore scales the new ReplicaSet to 2, waits for both to be Available (`Ready` for `minReadySeconds`), then scales the old ReplicaSet to 4, then the new to 4, and so on. Percentages: `maxSurge` rounds **up**, `maxUnavailable` rounds **down** — the pair is deliberately biased toward availability. Note that both cannot be zero; the API rejects it, because the rollout could never make progress.

`progressDeadlineSeconds: 600` means: if the rollout makes no forward progress for 10 minutes, the Deployment gets `Progressing=False` with reason `ProgressDeadlineExceeded`. **It does not roll back automatically.** It marks the condition, and `kubectl rollout status` exits non-zero — which is exactly the hook your CI pipeline should be gating on.

```
$ kubectl -n prod set image deployment/api api=registry.internal/storefront/api:2.5.0
deployment.apps/api image updated

$ kubectl -n prod rollout status deployment/api --timeout=10m
Waiting for deployment "api" rollout to finish: 2 out of 6 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 4 out of 6 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 2 old replicas are pending termination...
deployment "api" successfully rolled out

$ kubectl -n prod rollout history deployment/api
deployment.apps/api
REVISION  CHANGE-CAUSE
3         <none>
4         <none>
5         <none>

$ kubectl -n prod rollout undo deployment/api --to-revision=4
deployment.apps/api rolled back
```

A failed rollout, and how it reads:

```
$ kubectl -n prod rollout status deployment/api --timeout=2m
Waiting for deployment "api" rollout to finish: 2 out of 6 new replicas have been updated...
error: timed out waiting for the condition

$ kubectl -n prod get deployment api -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'
Available       True    MinimumReplicasAvailable
Progressing     False   ProgressDeadlineExceeded
```

`Available=True` with `Progressing=False` is the signature of a *safe* failed rollout: the surge pods never became ready, so the old ReplicaSet was never scaled down. Traffic is fine. This is precisely what `maxUnavailable: 0` bought you.

### 4.4 StatefulSet: identity, ordering, and partitioned canaries

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: pg-headless
  namespace: data
  labels:
    app.kubernetes.io/name: postgres
spec:
  clusterIP: None                 # headless: DNS returns pod IPs, no VIP
  publishNotReadyAddresses: true  # peers must resolve each other pre-readiness
  selector:
    app.kubernetes.io/name: postgres
  ports:
    - { name: pg, port: 5432, targetPort: pg }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pg
  namespace: data
spec:
  serviceName: pg-headless        # MUST match the headless Service name
  replicas: 3
  podManagementPolicy: OrderedReady   # or Parallel for non-quorum systems
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0                # ordinals >= partition are updated
      maxUnavailable: 1
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain
  selector:
    matchLabels:
      app.kubernetes.io/name: postgres
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postgres
    spec:
      terminationGracePeriodSeconds: 120
      securityContext:
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      containers:
        - name: postgres
          image: registry.internal/postgres:16.4
          ports:
            - { name: pg, containerPort: 5432 }
          env:
            - name: POD_ORDINAL
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: { name: pg-superuser, key: password }
          resources:
            requests: { cpu: "1",  memory: "4Gi" }
            limits:   { memory: "4Gi" }
          readinessProbe:
            exec:
              command: ["/bin/sh","-c","pg_isready -U postgres -h 127.0.0.1"]
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            exec:
              command: ["/bin/sh","-c","pg_isready -U postgres -h 127.0.0.1"]
            initialDelaySeconds: 60
            periodSeconds: 15
            failureThreshold: 6
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: ssd-retain
        resources:
          requests:
            storage: 200Gi
```

Behaviour to internalise:

- Pod DNS is `pg-0.pg-headless.data.svc.cluster.local` — **stable across reschedules**, which is what quorum protocols require.
- PVCs are named `data-pg-0`, `data-pg-1`, `data-pg-2` and are **not** deleted when the pod is deleted. `persistentVolumeClaimRetentionPolicy` controls what happens on StatefulSet deletion and scale-down; `Retain` is the safe default for databases.
- Updates proceed **from the highest ordinal downward**. `partition: 2` on a 3-replica set updates only `pg-2` — a genuine canary. Verify it, then set `partition: 0` to complete. This is the closest thing to a built-in progressive delivery primitive in core Kubernetes.

```
$ kubectl -n data patch statefulset pg --type=merge \
    -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'
statefulset.apps/pg patched

$ kubectl -n data set image statefulset/pg postgres=registry.internal/postgres:16.5
statefulset.apps/pg image updated

$ kubectl -n data get pods -l app.kubernetes.io/name=postgres \
    -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[0].image,REV:.metadata.labels.controller-revision-hash'
NAME   IMAGE                                  REV
pg-0   registry.internal/postgres:16.4        pg-6c47d9f8b4
pg-1   registry.internal/postgres:16.4        pg-6c47d9f8b4
pg-2   registry.internal/postgres:16.5        pg-7f9a1c2e05
```

### 4.5 DaemonSet, Job, CronJob

```yaml
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: observability
spec:
  selector:
    matchLabels: { app.kubernetes.io/name: node-exporter }
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%
      maxSurge: 0
  template:
    metadata:
      labels: { app.kubernetes.io/name: node-exporter }
    spec:
      hostNetwork: true
      hostPID: true
      dnsPolicy: ClusterFirstWithHostNet
      priorityClassName: system-node-critical
      # Run everywhere, including tainted control-plane and cordoned nodes.
      tolerations:
        - operator: Exists
      containers:
        - name: node-exporter
          image: quay.io/prometheus/node-exporter:v1.8.2
          args:
            - --path.rootfs=/host
            - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)
          ports:
            - { name: metrics, containerPort: 9100, hostPort: 9100 }
          resources:
            requests: { cpu: "20m", memory: "48Mi" }
            limits:   { memory: "128Mi" }
          securityContext:
            runAsUser: 65534
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: rootfs, mountPath: /host, readOnly: true, mountPropagation: HostToContainer }
      volumes:
        - name: rootfs
          hostPath: { path: /, type: Directory }
---
apiVersion: batch/v1
kind: Job
metadata:
  name: schema-migrate-2-5-0
  namespace: prod
spec:
  backoffLimit: 3
  completions: 1
  parallelism: 1
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 86400   # GC the Job object after 24 h
  podFailurePolicy:
    rules:
      # A non-retryable application error: stop immediately, do not burn
      # the backoffLimit on a migration that will never succeed.
      - action: FailJob
        onExitCodes:
          containerName: migrate
          operator: In
          values: [42]
      # Node preemption is infrastructure noise: retry without counting it.
      - action: Ignore
        onPodConditions:
          - type: DisruptionTarget
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: registry.internal/storefront/migrate:2.5.0
          args: ["--target-version", "2.5.0", "--lock-timeout", "60s"]
          env:
            - name: DATABASE_URL
              valueFrom: { secretKeyRef: { name: api-db, key: url } }
          resources:
            requests: { cpu: "200m", memory: "256Mi" }
            limits:   { memory: "512Mi" }
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-basebackup
  namespace: data
spec:
  schedule: "17 2 * * *"
  timeZone: "Europe/Madrid"       # without this, the schedule is controller-local time
  concurrencyPolicy: Forbid       # Allow | Forbid | Replace
  startingDeadlineSeconds: 600
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 7200
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: basebackup
              image: registry.internal/postgres:16.4
              command:
                - /bin/sh
                - -c
                - |
                  set -euo pipefail
                  TS="$(date -u +%Y%m%dT%H%M%SZ)"
                  pg_basebackup -h pg-0.pg-headless.data.svc.cluster.local \
                                -U replicator -D - -Ft -X stream -z \
                    | aws s3 cp - "s3://backups-prod/pg/${TS}.tar.gz"
              env:
                - name: PGPASSWORD
                  valueFrom: { secretKeyRef: { name: pg-replicator, key: password } }
              resources:
                requests: { cpu: "500m", memory: "512Mi" }
                limits:   { memory: "1Gi" }
```

`startingDeadlineSeconds` deserves a warning: if the CronJob controller is down for longer than this, the missed run is **skipped**, not queued. And if you omit it entirely while the controller is down for hours, the controller may count more than 100 missed schedules and refuse to schedule at all, logging `Cannot determine if job needs to be started: too many missed start times`.

---

## 5. Networking and service discovery

### 5.1 The network model, as a set of invariants

Kubernetes does not specify *how* to implement networking; it specifies constraints that a CNI plugin must satisfy:

1. Every Pod gets a unique, routable IP address in a flat network.
2. Pods can reach all other Pods without NAT.
3. Node agents (kubelet, daemons) can reach all Pods on that node.

That last one is why `hostNetwork` DaemonSets work. Point 2 is why "just use `hostPort`" is a design smell — it re-introduces the port-allocation problem orchestration removed.

### 5.2 Service types

| Type | Allocates | Reachable from | Typical use |
|---|---|---|---|
| `ClusterIP` | Virtual IP from the service CIDR | Inside the cluster only | East-west traffic; the default |
| `ClusterIP: None` (headless) | Nothing | DNS returns pod IPs directly | StatefulSet peers, client-side LB, gRPC |
| `NodePort` | ClusterIP + a port (30000–32767) on **every** node | Anything that can reach a node IP | Bare metal ingress entry point |
| `LoadBalancer` | NodePort + external LB via cloud-controller / MetalLB | Internet / VPC | Public entry points |
| `ExternalName` | Nothing; CoreDNS returns a CNAME | Inside cluster | Aliasing an off-cluster dependency |

`externalTrafficPolicy` is the field people forget:

- `Cluster` (default): a node receiving external traffic may SNAT and forward to a pod on another node. Even load distribution, **client source IP is lost**.
- `Local`: only pods on the receiving node are eligible. Source IP is preserved, and the node fails its LB health check when it has no local endpoint — but distribution becomes uneven and depends on pod placement per node.

### 5.3 EndpointSlice: what the Service selector actually produces

```
$ kubectl -n prod get endpointslices -l kubernetes.io/service-name=api
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                                   AGE
api-7fk2x   IPv4          8080    10.244.3.17,10.244.1.44,10.244.2.9 + 3      41d

$ kubectl -n prod get endpointslice api-7fk2x -o yaml | sed -n '1,40p'
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
addressType: IPv4
metadata:
  name: api-7fk2x
  namespace: prod
  labels:
    kubernetes.io/service-name: api
endpoints:
- addresses:
  - 10.244.3.17
  conditions:
    ready: true
    serving: true
    terminating: false
  nodeName: node-07
  targetRef:
    kind: Pod
    name: api-6c47d9f8b4-x9pql
    namespace: prod
  zone: eu-west-1a
- addresses:
  - 10.244.1.44
  conditions:
    ready: false
    serving: true
    terminating: true
  nodeName: node-08
  targetRef:
    kind: Pod
    name: api-5b9f0c1a22-mn4tv
    namespace: prod
  zone: eu-west-1b
ports:
- name: http
  port: 8080
  protocol: TCP
```

The `ready` / `serving` / `terminating` triple is the mechanism behind graceful shutdown: a terminating pod has `ready: false` (new connections stop) but `serving: true` (dataplanes that support connection draining can finish in-flight work). EndpointSlices replace the legacy single `Endpoints` object precisely because a 5000-endpoint Service produced a multi-megabyte object rewritten on every pod change — an apiserver and etcd hazard. Slices cap at 100 endpoints by default.

### 5.4 kube-proxy dataplane modes

| Mode | Rule structure | Rule update cost | Load-balancing | Notes |
|---|---|---|---|---|
| `iptables` | Linear chains per Service, DNAT in `KUBE-SERVICES` | O(n) rule set rewrite; degrades past a few thousand Services | Random with probability weights | Historical default; well understood |
| `ipvs` | In-kernel hash table, one virtual server per Service | O(1) per Service update | rr, lc, dh, sh, sed, nq | Best for large Service counts; needs `ip_vs*` modules |
| `nftables` | Native nftables sets/maps, kernel-side map lookup | O(1)-ish; far cheaper incremental updates | Map-based | Introduced alpha in v1.29, beta in v1.31; check your release notes for the current graduation level and default |
| *(none)* | eBPF programs at tc/XDP hooks (Cilium `kubeProxyReplacement`) | Per-entry map update | Maglev / random | kube-proxy removed entirely |

Inspecting the programmed dataplane on a node:

```
$ sudo iptables -t nat -L KUBE-SERVICES -n | head -8
Chain KUBE-SERVICES (2 references)
target            prot opt source     destination
KUBE-SVC-NPX46M4PTMTKRN6Y  tcp  --  0.0.0.0/0  10.96.0.1     /* default/kubernetes:https cluster IP */ tcp dpt:443
KUBE-SVC-TCOU7JCQXEZGVUNU  udp  --  0.0.0.0/0  10.96.0.10    /* kube-system/kube-dns:dns cluster IP */ udp dpt:53
KUBE-SVC-QMWWTXBG7KFJQKLO  tcp  --  0.0.0.0/0  10.107.44.19  /* prod/api:http cluster IP */ tcp dpt:80

$ sudo ipvsadm -Ln | sed -n '/10.107.44.19/,+7p'
TCP  10.107.44.19:80 rr
  -> 10.244.1.44:8080             Masq    1      12         3
  -> 10.244.2.9:8080              Masq    1      15         1
  -> 10.244.3.17:8080             Masq    1      11         4
```

### 5.5 DNS

CoreDNS resolves `<service>.<namespace>.svc.cluster.local` to the ClusterIP; for headless Services it returns the set of pod A records. Every pod gets a `resolv.conf` with a `search` list and `ndots:5`:

```
$ kubectl -n prod exec -it deploy/api -- cat /etc/resolv.conf
search prod.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

**`ndots:5` is a real performance trap.** Any lookup with fewer than five dots — which is essentially every external hostname, e.g. `api.stripe.com` — is first tried against all three search domains, producing three NXDOMAIN round-trips before the absolute query. On a chatty service this triples DNS QPS. Two fixes: append a trailing dot to external names in configuration (`api.stripe.com.`), or set a per-pod `dnsConfig`:

```yaml
      dnsPolicy: ClusterFirst
      dnsConfig:
        options:
          - { name: ndots, value: "2" }
          - { name: single-request-reopen }
```

### 5.6 Ingress and Gateway API

```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: storefront
  namespace: prod
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "16m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["shop.example.com"]
      secretName: shop-example-com-tls
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api
                port:
                  name: http
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  name: http
```

Ingress is deliberately minimal, which is why every real deployment escapes into vendor annotations — and those annotations are not portable. The Gateway API is the successor, modelling the same problem with role separation (`GatewayClass` = infrastructure provider, `Gateway` = cluster operator, `HTTPRoute` = application team) and typed fields instead of annotations:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge
  namespace: infra
spec:
  gatewayClassName: envoy
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - { kind: Secret, name: wildcard-example-com-tls }
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels: { gateway-access: "true" }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api
  namespace: prod
spec:
  parentRefs:
    - { name: edge, namespace: infra, sectionName: https }
  hostnames: ["shop.example.com"]
  rules:
    # Weighted canary: 5 % of /api traffic to the v2 Service.
    - matches:
        - path: { type: PathPrefix, value: /api }
      backendRefs:
        - { name: api,    port: 80, weight: 95 }
        - { name: api-v2, port: 80, weight: 5 }
      timeouts:
        request: 30s
        backendRequest: 10s
```

Traffic splitting by weight is a first-class field here, where in Ingress it is an nginx-specific annotation. That is the whole argument for migrating.

### 5.7 NetworkPolicy

The pod network is flat and fully open by default. NetworkPolicy is additive-allow: once *any* policy selects a pod for a direction, that direction becomes default-deny for that pod.

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: prod
spec:
  podSelector: {}                 # every pod in the namespace
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: api
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
        - podSelector:
            matchLabels: { app.kubernetes.io/name: frontend }
      ports:
        - { protocol: TCP, port: 8080 }
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: observability }
      ports:
        - { protocol: TCP, port: 9090 }
  egress:
    # DNS must be allowed explicitly or every lookup fails, which presents
    # as a total, confusing outage.
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
          podSelector:
            matchLabels: { k8s-app: kube-dns }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: data }
          podSelector:
            matchLabels: { app.kubernetes.io/name: postgres }
      ports:
        - { protocol: TCP, port: 5432 }
    # Egress to an off-cluster payment provider, minus internal RFC1918.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - { protocol: TCP, port: 443 }
```

Three traps: (1) **NetworkPolicy is enforced by the CNI plugin** — Flannel alone ignores it entirely, and the manifest applies successfully while enforcing nothing; (2) forgetting DNS egress is the single most common self-inflicted outage; (3) in `from:`/`to:`, a `namespaceSelector` and `podSelector` in the **same list element** are ANDed, while separate list elements are ORed. That indentation difference changes the policy completely.

---

## 6. Configuration, secrets and storage

### 6.1 ConfigMap and Secret propagation semantics

| Consumption method | Updates when the object changes? | Latency | Notes |
|---|---|---|---|
| `env` / `envFrom` | **No** | never | Environment is fixed at container start. Requires a pod restart. |
| Volume mount (whole object) | Yes | ~ kubelet sync period + cache TTL (about a minute) | Atomic symlink swap of the whole directory |
| Volume mount with `subPath` | **No** | never | The single most common configuration surprise |
| `projected` volume | Yes | as above | Combines ConfigMap + Secret + downwardAPI + SA token |

Because env vars never update, and because a mounted config that hot-reloads silently may be worse than an explicit rollout, the `checksum/config` annotation pattern in §4.2 is the standard: change the ConfigMap content → change the annotation → the pod template hash changes → a normal, observable, rollback-able rolling update happens.

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: api-db
  namespace: prod
type: Opaque
stringData:
  password: "REPLACED-BY-EXTERNAL-SECRETS-OPERATOR"
  url: "postgres://api@pg-0.pg-headless.data.svc.cluster.local:5432/store"
```

`Secret` data is base64-encoded, **not encrypted** — it is stored in etcd in plaintext unless the apiserver is configured with an `EncryptionConfiguration`, and anyone with `get secrets` RBAC in the namespace can read it. Treat "it's a Secret" as "it is separated from ConfigMaps for RBAC and audit purposes", nothing more.

### 6.2 Storage

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ssd-retain
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "6000"
  throughput: "250"
  encrypted: "true"
reclaimPolicy: Retain
allowVolumeExpansion: true
# Delay binding until a Pod is scheduled, so the volume is created in the
# zone the Pod actually landed in. Omitting this on a multi-AZ cluster
# produces Pods that are permanently unschedulable.
volumeBindingMode: WaitForFirstConsumer
```

| Access mode | Meaning | Backed by |
|---|---|---|
| `ReadWriteOnce` (RWO) | Mountable read-write by **one node** | Block storage (EBS, RBD, iSCSI, LVM) |
| `ReadWriteOncePod` | Mountable read-write by exactly **one Pod** | CSI drivers that support it; the correct choice for a single-writer database |
| `ReadOnlyMany` (ROX) | Read-only by many nodes | Snapshots, shared images |
| `ReadWriteMany` (RWX) | Read-write by many nodes | NFS, CephFS, EFS |

`ReadWriteOnce` is *per node*, not per pod — two pods on the same node can both mount an RWO volume. If your database's correctness depends on a single writer, `ReadWriteOncePod` is what you want.

---

## 7. Docker Swarm

Swarm mode remains in the exam objectives and is a genuinely reasonable choice for small estates. The design is a deliberate simplification of the same concepts.

### 7.1 Architecture

Managers form a Raft cluster and hold the desired state; workers run tasks. A *service* declares a desired state; the orchestrator creates *tasks* (each task is one container plus its lifecycle state), and the scheduler assigns tasks to nodes. Node-to-node traffic is encrypted with mutual TLS using an internal CA, rotated automatically.

The **routing mesh**: every node listens on the published port of every service, regardless of whether a task of that service runs locally, and forwards via the `ingress` overlay network. This means a bare TCP load balancer in front of *any* node works.

### 7.2 Cluster bootstrap

```
$ docker swarm init --advertise-addr 192.168.178.11 --data-path-port 4789
Swarm initialized: current node (k1r8mv3xq2nz7f5d0plw9aycb) is now a manager.

To add a worker to this swarm, run the following command:

    docker swarm join --token SWMTKN-1-2y8w1kq9x0fj3mvz6bd7hn4pgs5cta0lre8u1o9y3wq7k2m4x-9djv02hbfqz7wsn1xtp3ykgra 192.168.178.11:2377

To add a manager to this swarm, run 'docker swarm join-token manager' and follow the instructions.

$ docker node ls
ID                            HOSTNAME    STATUS    AVAILABILITY   MANAGER STATUS   ENGINE VERSION
k1r8mv3xq2nz7f5d0plw9aycb *   swarm-01    Ready     Active         Leader           27.3.1
p7t2ye9nc4bl6hkza0dvxrguj     swarm-02    Ready     Active         Reachable        27.3.1
w3q8fjm1odsx5vbc2rntyk0ap     swarm-03    Ready     Active         Reachable        27.3.1
z6h4bdvq0ntms8xge1rykpc7l     swarm-04    Ready     Active                          27.3.1
z9c1xkte5rwo3fnbj7mhqva28     swarm-05    Ready     Active                          27.3.1
```

Manager count follows Raft: 3 managers tolerate 1 failure, 5 tolerate 2. **Never run an even number** — 4 managers tolerate the same single failure as 3 while adding a failure mode.

```
$ docker node update --label-add tier=edge swarm-04
swarm-04
$ docker node update --availability drain swarm-03
swarm-03
```

`drain` is the Swarm analogue of `kubectl drain`: existing tasks are rescheduled elsewhere and no new ones are placed.

### 7.3 A complete stack file

```yaml
# docker-stack.yml — deploy with: docker stack deploy -c docker-stack.yml storefront
version: "3.9"

services:
  api:
    image: registry.internal/storefront/api:2.4.1
    networks:
      - backend
      - frontend
    ports:
      - target: 8080
        published: 8080
        protocol: tcp
        mode: ingress          # ingress = routing mesh; host = bypass it
    environment:
      LOG_LEVEL: info
      UPSTREAM_TIMEOUT_MS: "2500"
    secrets:
      - source: db_password
        target: /run/secrets/db_password
        mode: 0400
    configs:
      - source: api_config_v3
        target: /etc/api/application.yaml
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8080/healthz/ready"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 40s
    stop_grace_period: 45s
    deploy:
      mode: replicated
      replicas: 6
      endpoint_mode: vip       # vip (default) or dnsrr for client-side LB
      update_config:
        parallelism: 2
        delay: 20s
        order: start-first     # surge, like maxSurge>0 / maxUnavailable=0
        failure_action: rollback
        monitor: 60s
        max_failure_ratio: 0.1
      rollback_config:
        parallelism: 2
        delay: 10s
        order: stop-first
        failure_action: pause
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 5
        window: 120s
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
        reservations:
          cpus: "0.25"
          memory: 512M
      placement:
        max_replicas_per_node: 2
        constraints:
          - node.role == worker
          - node.labels.tier == edge
        preferences:
          - spread: node.labels.zone
      labels:
        com.example.service: api

  pg:
    image: registry.internal/postgres:16.4
    networks: [backend]
    volumes:
      - pgdata:/var/lib/postgresql/data
    secrets:
      - db_password
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
      PGDATA: /var/lib/postgresql/data/pgdata
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.labels.storage == local-ssd
      restart_policy:
        condition: any
        delay: 10s
      resources:
        limits:
          memory: 4G
        reservations:
          memory: 4G

  node-agent:
    image: quay.io/prometheus/node-exporter:v1.8.2
    command:
      - --path.rootfs=/host
    networks: [backend]
    volumes:
      - type: bind
        source: /
        target: /host
        read_only: true
    deploy:
      mode: global            # the Swarm equivalent of a DaemonSet
      resources:
        limits:
          memory: 128M

networks:
  frontend:
    driver: overlay
    attachable: false
  backend:
    driver: overlay
    driver_opts:
      encrypted: "true"       # IPsec on the VXLAN data path; costs throughput
    attachable: false

volumes:
  pgdata:
    driver: local

secrets:
  db_password:
    external: true

configs:
  api_config_v3:              # configs are immutable: version the NAME
    file: ./config/application.yaml
```

Deployment and inspection:

```
$ echo -n 'S3cr3t-Rot4ted-2026Q3' | docker secret create db_password -
u8kq2mzx0v7ndprty1achw3fe

$ docker stack deploy -c docker-stack.yml storefront
Creating network storefront_backend
Creating network storefront_frontend
Creating config storefront_api_config_v3
Creating service storefront_api
Creating service storefront_pg
Creating service storefront_node-agent

$ docker stack services storefront
ID             NAME                       MODE         REPLICAS   IMAGE                                  PORTS
9v0kxq2mzt4a   storefront_api             replicated   6/6        registry.internal/storefront/api:2.4.1 *:8080->8080/tcp
c3n7yfdb1lo8   storefront_node-agent      global       5/5        quay.io/prometheus/node-exporter:v1.8.2
x1p4wsjr6heu   storefront_pg              replicated   1/1        registry.internal/postgres:16.4

$ docker service ps storefront_api --no-trunc --filter desired-state=running
ID             NAME                IMAGE                                     NODE       DESIRED STATE   CURRENT STATE            ERROR   PORTS
q7m2v8x1cnwr   storefront_api.1    registry.internal/storefront/api:2.4.1    swarm-04   Running         Running 4 minutes ago
b4t9zf0kdslp   storefront_api.2    registry.internal/storefront/api:2.4.1    swarm-05   Running         Running 4 minutes ago
h1c6yrn3axkv   storefront_api.3    registry.internal/storefront/api:2.4.1    swarm-04   Running         Running 3 minutes ago
m8w0dqlt2feb   storefront_api.4    registry.internal/storefront/api:2.4.1    swarm-05   Running         Running 3 minutes ago
n5j3xghp7oyu   storefront_api.5    registry.internal/storefront/api:2.4.1    swarm-02   Running         Running 3 minutes ago
r2k9lbvs4ndc   storefront_api.6    registry.internal/storefront/api:2.4.1    swarm-02   Running         Running 3 minutes ago
```

Rolling update and rollback:

```
$ docker service update --image registry.internal/storefront/api:2.5.0 storefront_api
storefront_api
overall progress: 6 out of 6 tasks
1/6: running   [==================================================>]
2/6: running   [==================================================>]
3/6: running   [==================================================>]
4/6: running   [==================================================>]
5/6: running   [==================================================>]
6/6: running   [==================================================>]
verify: Service storefront_api converged

$ docker service inspect storefront_api \
    --format '{{.UpdateStatus.State}} {{.UpdateStatus.Message}}'
completed update completed

$ docker service rollback storefront_api
storefront_api
rollback: manually requested rollback
overall progress: rolling back update: 6 out of 6 tasks
verify: Service storefront_api converged
```

An automatic rollback triggered by `failure_action: rollback` reads:

```
$ docker service inspect storefront_api --format '{{json .UpdateStatus}}' | jq
{
  "State": "rollback_completed",
  "StartedAt": "2026-09-03T09:14:02.118374Z",
  "CompletedAt": "2026-09-03T09:16:47.902551Z",
  "Message": "rollback completed"
}
```

### 7.4 Kubernetes ↔ Swarm concept map

| Concept | Kubernetes | Swarm |
|---|---|---|
| Declarative unit | Deployment / StatefulSet / DaemonSet | Service (`mode: replicated` / `global`) |
| Group of files | Helm chart / Kustomize | Stack (`docker stack deploy -c`) |
| Instance | Pod (may hold several containers) | Task (exactly one container) |
| Surge rollout | `maxSurge > 0`, `maxUnavailable: 0` | `order: start-first` |
| Rollout batch size | derived from surge/unavailable | `parallelism` |
| Auto-rollback | none built in (CI gate on `rollout status`) | `failure_action: rollback` |
| Discovery | ClusterIP VIP + CoreDNS | Service VIP + embedded DNS |
| Anti-affinity | `topologySpreadConstraints` / podAntiAffinity | `placement.preferences: spread` |
| Disruption budget | PodDisruptionBudget | none |
| Node quiesce | `kubectl drain` | `docker node update --availability drain` |
| Config object | ConfigMap (mutable) | Config (**immutable**, version the name) |

---

## 8. Infrastructure: bootstrapping a Kubernetes cluster with kubeadm

### 8.1 Node preparation

```bash
# --- Kernel modules and sysctls required by the CNI and kube-proxy --------
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.rp_filter         = 1
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
EOF
sudo sysctl --system

# --- Swap must be off (or the kubelet configured to tolerate it) ---------
sudo swapoff -a
sudo sed -i '/\sswap\s/ s/^/#/' /etc/fstab
```

### 8.2 containerd

```toml
# /etc/containerd/config.toml  (containerd 1.7.x; containerd 2.x uses version = 3)
version = 2

[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.10"

  [plugins."io.containerd.grpc.v1.cri".containerd]
    default_runtime_name = "runc"
    discard_unpacked_layers = true

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      runtime_type = "io.containerd.runc.v2"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
        # MUST match the kubelet cgroup driver. Mismatch => pods that start
        # and are then killed with confusing OOM/cgroup errors.
        SystemdCgroup = true

  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
```

```
$ sudo systemctl restart containerd && sudo systemctl is-active containerd
active

$ sudo ctr version
Client:
  Version:  1.7.22
  Revision: c4e9c0d0e3b1a4f0f1e2d3a5b6c7d8e9f0a1b2c3
  Go version: go1.22.7

Server:
  Version:  1.7.22
  UUID: 3f9c1a2e-7d84-4b60-9e15-2c8a0d6f4b71
```

### 8.3 Control-plane initialisation, fully declarative

```yaml
# kubeadm-config.yaml
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.178.11
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - { name: node-ip, value: "192.168.178.11" }
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.33.2
clusterName: leloir-prod
controlPlaneEndpoint: "k8s-api.internal:6443"   # a VIP or LB, set it NOW
networking:
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
  dnsDomain: cluster.local
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      - { name: quota-backend-bytes, value: "8589934592" }   # 8 GiB
      - { name: auto-compaction-retention, value: "1h" }
apiServer:
  certSANs:
    - k8s-api.internal
    - 192.168.178.10
    - 192.168.178.11
  extraArgs:
    - { name: audit-log-path,      value: /var/log/kubernetes/audit.log }
    - { name: audit-log-maxage,    value: "30" }
    - { name: audit-log-maxbackup, value: "10" }
    - { name: audit-log-maxsize,   value: "100" }
    - { name: audit-policy-file,   value: /etc/kubernetes/audit-policy.yaml }
    - { name: encryption-provider-config, value: /etc/kubernetes/encryption.yaml }
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit-policy.yaml
      mountPath: /etc/kubernetes/audit-policy.yaml
      readOnly: true
      pathType: File
    - name: audit-logs
      hostPath: /var/log/kubernetes
      mountPath: /var/log/kubernetes
      pathType: DirectoryOrCreate
    - name: encryption-config
      hostPath: /etc/kubernetes/encryption.yaml
      mountPath: /etc/kubernetes/encryption.yaml
      readOnly: true
      pathType: File
controllerManager:
  extraArgs:
    - { name: bind-address, value: "0.0.0.0" }
    - { name: node-monitor-period, value: "5s" }
    - { name: node-monitor-grace-period, value: "40s" }
scheduler:
  extraArgs:
    - { name: bind-address, value: "0.0.0.0" }
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: true
rotateCertificates: true
maxPods: 110
# Reserve capacity so a runaway pod cannot starve kubelet/containerd/sshd.
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
evictionSoft:
  memory.available: "1Gi"
evictionSoftGracePeriod:
  memory.available: "2m"
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
ipvs:
  scheduler: rr
  strictARP: true          # required by MetalLB in L2 mode
```

```
$ sudo kubeadm init --config kubeadm-config.yaml --upload-certs
[init] Using Kubernetes version: v1.33.2
[preflight] Running pre-flight checks
[preflight] Pulling images required for setting up a Kubernetes cluster
[certs] Using certificateDir folder "/etc/kubernetes/pki"
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [cp-01 k8s-api.internal kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local] and IPs [10.96.0.1 192.168.178.11 192.168.178.10]
[certs] Generating "etcd/ca" certificate and key
[certs] Generating "etcd/server" certificate and key
[certs] Generating "sa" key and public key
[kubeconfig] Writing "admin.conf" kubeconfig file
[kubeconfig] Writing "super-admin.conf" kubeconfig file
[kubeconfig] Writing "kubelet.conf" kubeconfig file
[kubeconfig] Writing "controller-manager.conf" kubeconfig file
[kubeconfig] Writing "scheduler.conf" kubeconfig file
[control-plane] Creating static Pod manifest for "kube-apiserver"
[control-plane] Creating static Pod manifest for "kube-controller-manager"
[control-plane] Creating static Pod manifest for "kube-scheduler"
[etcd] Creating static Pod manifest for local etcd in "/etc/kubernetes/manifests"
[kubelet-start] Starting the kubelet
[wait-control-plane] Waiting for the kubelet to boot up the control plane as static Pods from directory "/etc/kubernetes/manifests"
[apiclient] All control plane components are healthy after 9.503816 seconds
[upload-config] Storing the configuration used in ConfigMap "kubeadm-config" in the "kube-system" Namespace
[kubelet] Creating a ConfigMap "kubelet-config" in namespace kube-system
[upload-certs] Using certificate key: 4a2f9c1e7b53d8064af1c2e93b07d5486ea19f2c3d0b7845e6a1c9f30b2d5e74
[mark-control-plane] Marking the node cp-01 as control-plane by adding the taints [node-role.kubernetes.io/control-plane:NoSchedule]
[bootstrap-token] Using token: 8j3k2q.4mv7z0xd1pqrt6bn
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy

Your Kubernetes control-plane has initialized successfully!

You can now join any number of control-plane nodes running the following command on each as root:

  kubeadm join k8s-api.internal:6443 --token 8j3k2q.4mv7z0xd1pqrt6bn \
        --discovery-token-ca-cert-hash sha256:1f9d0c73a248e6b5f01c93da7e2b48605cf1a739e0b6d2843c5f7a109e4b2d68 \
        --control-plane --certificate-key 4a2f9c1e7b53d8064af1c2e93b07d5486ea19f2c3d0b7845e6a1c9f30b2d5e74

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join k8s-api.internal:6443 --token 8j3k2q.4mv7z0xd1pqrt6bn \
        --discovery-token-ca-cert-hash sha256:1f9d0c73a248e6b5f01c93da7e2b48605cf1a739e0b6d2843c5f7a109e4b2d68

$ mkdir -p "$HOME/.kube" && sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config" \
    && sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

$ kubectl get nodes
NAME    STATUS     ROLES           AGE   VERSION
cp-01   NotReady   control-plane   62s   v1.33.2
```

`NotReady` is **expected** here: no CNI is installed, so the kubelet reports `NetworkReady=false`.

```
$ kubectl -n kube-system describe node cp-01 | grep -A2 'Ready '
  Ready   False   Fri, 03 Sep 2026 09:41:12  KubeletNotReady
    container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady
    message:Network plugin returns error: cni plugin not initialized
```

Install the CNI (matching `podSubnet` from the config), then re-check:

```
$ helm repo add cilium https://helm.cilium.io/ && helm repo update
$ helm install cilium cilium/cilium --version 1.16.3 \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set ipv4NativeRoutingCIDR=10.244.0.0/16 \
    --set kubeProxyReplacement=false \
    --set k8sServiceHost=k8s-api.internal --set k8sServicePort=6443

$ kubectl get nodes -o wide
NAME      STATUS   ROLES           AGE     VERSION   INTERNAL-IP       OS-IMAGE            KERNEL-VERSION      CONTAINER-RUNTIME
cp-01     Ready    control-plane   6m18s   v1.33.2   192.168.178.11    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
cp-02     Ready    control-plane   4m02s   v1.33.2   192.168.178.12    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
cp-03     Ready    control-plane   3m47s   v1.33.2   192.168.178.13    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
node-07   Ready    <none>          2m11s   v1.33.2   192.168.178.17    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
node-08   Ready    <none>          2m09s   v1.33.2   192.168.178.18    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
node-09   Ready    <none>          2m05s   v1.33.2   192.168.178.19    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
```

### 8.4 Upgrades and etcd backup

```
$ sudo kubeadm upgrade plan
[upgrade/config] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[upgrade] Fetching available versions to upgrade to
[upgrade/versions] Cluster version: v1.33.2
[upgrade/versions] kubeadm version: v1.34.0

Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   CURRENT       TARGET
kubelet     6 x v1.33.2   v1.34.0

Upgrade to the latest stable version:

COMPONENT                 CURRENT   TARGET
kube-apiserver            v1.33.2   v1.34.0
kube-controller-manager   v1.33.2   v1.34.0
kube-scheduler            v1.33.2   v1.34.0
kube-proxy                v1.33.2   v1.34.0
CoreDNS                   v1.11.3   v1.11.3
etcd                      3.5.16    3.5.16

You can now apply the upgrade by executing the following command:

        kubeadm upgrade apply v1.34.0
```

The per-node worker sequence — this is the loop that must respect PodDisruptionBudgets:

```
$ kubectl drain node-07 --ignore-daemonsets --delete-emptydir-data --timeout=600s
node/node-07 cordoned
Warning: ignoring DaemonSet-managed Pods: observability/node-exporter-4xk9d, kube-system/cilium-p2m7v
evicting pod prod/api-6c47d9f8b4-x9pql
evicting pod prod/api-6c47d9f8b4-tz84r
error when evicting pods/"api-6c47d9f8b4-tz84r" -n "prod" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/api-6c47d9f8b4-x9pql evicted
pod/api-6c47d9f8b4-tz84r evicted
node/node-07 drained

$ sudo kubeadm upgrade node && \
  sudo apt-get install -y --allow-change-held-packages kubelet=1.34.0-1.1 kubectl=1.34.0-1.1 && \
  sudo systemctl daemon-reload && sudo systemctl restart kubelet

$ kubectl uncordon node-07
node/node-07 uncordoned
```

The retry on `Cannot evict pod as it would violate the pod's disruption budget` is the PDB doing exactly its job: serialising the drain against the rollout.

```
$ sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/backups/etcd-$(date -u +%Y%m%dT%H%M%SZ).db
{"level":"info","msg":"created temporary db file","path":"/var/backups/etcd-20260903T094812Z.db.part"}
{"level":"info","msg":"fetching snapshot","endpoint":"https://127.0.0.1:2379"}
{"level":"info","msg":"fetched snapshot","endpoint":"https://127.0.0.1:2379","size":"142 MB","took":"1.884 s"}
Snapshot saved at /var/backups/etcd-20260903T094812Z.db
```

**An untested etcd backup is not a backup.** Restore drill: `etcdutl snapshot restore <file> --data-dir /var/lib/etcd-restore`, repoint the static pod manifest, restart the kubelet on every control-plane node.

---

## 9. Verification and failure diagnosis

### 9.1 The diagnostic ladder

Work top-down; do not skip rungs. Each rung answers a different question, and the answer determines whether you descend further.

```
1. kubectl get <kind> -o wide          → what does the API believe?
2. kubectl describe <kind>/<name>      → what do controllers say (Events, Conditions)?
3. kubectl get events --sort-by=...    → cluster-wide ordering of what happened
4. kubectl logs [-p] [-c]              → what did the application say (and the PREVIOUS instance)?
5. kubectl exec / kubectl debug        → interactive, inside the failure domain
6. ssh node → journalctl -u kubelet    → what does the node agent say?
7. ssh node → crictl ps/logs/inspect   → below the kubelet, at the runtime
```

```
$ kubectl -n prod get events --sort-by=.lastTimestamp | tail -12
LAST SEEN   TYPE      REASON              OBJECT                        MESSAGE
3m12s       Normal    Scheduled           pod/api-7f9a1c2e05-k4pmz      Successfully assigned prod/api-7f9a1c2e05-k4pmz to node-08
3m10s       Normal    Pulling             pod/api-7f9a1c2e05-k4pmz      Pulling image "registry.internal/storefront/api:2.5.0"
2m58s       Warning   Failed              pod/api-7f9a1c2e05-k4pmz      Failed to pull image "registry.internal/storefront/api:2.5.0": rpc error: code = NotFound desc = failed to pull and unpack image: not found
2m58s       Warning   Failed              pod/api-7f9a1c2e05-k4pmz      Error: ErrImagePull
2m31s       Normal    BackOff             pod/api-7f9a1c2e05-k4pmz      Back-off pulling image "registry.internal/storefront/api:2.5.0"
2m31s       Warning   Failed              pod/api-7f9a1c2e05-k4pmz      Error: ImagePullBackOff
```

Note that Events are stored in etcd with a **1-hour TTL by default**. An incident reviewed the next morning has no Events. Ship them to your log store, or you are debugging blind.

### 9.2 Failure catalogue

| Symptom | Most probable causes | First command | Decisive evidence |
|---|---|---|---|
| `Pending`, no node assigned | Insufficient allocatable; taints without toleration; topology spread unsatisfiable; unbound PVC | `kubectl describe pod` | `0/6 nodes are available: 3 Insufficient cpu, 3 node(s) had untolerated taint {...}` |
| `Pending` with `WaitForFirstConsumer` | Normal — PVC binds after scheduling. If stuck: no CSI driver, or no capacity in the zone | `kubectl describe pvc` | `waiting for first consumer to be created` / `ProvisioningFailed` |
| `ImagePullBackOff` / `ErrImagePull` | Wrong tag; private registry without `imagePullSecrets`; registry down; rate limit | `kubectl describe pod` | `not found`, `401 Unauthorized`, `toomanyrequests` |
| `CrashLoopBackOff` | App exits on start; missing config; failing liveness; wrong entrypoint | `kubectl logs --previous` | The application's own stack trace |
| `CreateContainerConfigError` | Referenced ConfigMap/Secret or key does not exist | `kubectl describe pod` | `secret "api-db" not found` |
| `CreateContainerError` | Bad command/args; read-only rootfs where the app writes; bad securityContext | `kubectl describe pod` | `exec: "/app/serve": stat ... no such file` |
| `RunContainerError` | Runtime/cgroup driver mismatch; hook failure | `journalctl -u kubelet` | `failed to create containerd task` |
| `OOMKilled` (exit 137) | Memory limit below working set; JVM/Go heap unaware of the cgroup | `kubectl describe pod` | `Last State: Terminated, Reason: OOMKilled` |
| `Init:CrashLoopBackOff` | Init container dependency not ready | `kubectl logs -c <init>` | Init container output |
| Pod Ready but Service returns nothing | Selector does not match labels; `targetPort` wrong; readiness never true | `kubectl get endpointslices` | `ENDPOINTS: <none>` |
| Intermittent 502/504 during rollout | No `preStop` drain; readiness too optimistic; `minReadySeconds: 0` | Load test during rollout | Errors correlate exactly with pod terminations |
| `Terminating` forever | Finalizer not removed; volume detach hung; node NotReady | `kubectl get pod -o yaml` | `metadata.finalizers` populated |
| Node `NotReady` | kubelet down; CNI down; disk/memory pressure; clock skew | `kubectl describe node` | `KubeletNotReady`, `DiskPressure=True` |
| `Evicted` pods appearing | Node under `evictionHard` pressure | `kubectl describe node` | `The node was low on resource: ephemeral-storage` |
| DNS resolution fails cluster-wide | CoreDNS pods down; NetworkPolicy blocking UDP/53; conntrack table full | `kubectl -n kube-system logs -l k8s-app=kube-dns` | `SERVFAIL`, `i/o timeout` |
| Drain never completes | PDB cannot be satisfied; unmanaged (bare) pod | `kubectl get pdb -A` | `ALLOWED DISRUPTIONS: 0` |
| `429 Too Many Requests` from the API | A controller hot-looping; APF flow starved | `kubectl get --raw /metrics \| grep apiserver_flowcontrol` | Rejected request counters climbing |

### 9.3 Worked diagnosis: unschedulable pod

```
$ kubectl -n prod get pods -o wide
NAME                    READY   STATUS    RESTARTS   AGE   IP       NODE     NOMINATED NODE   READINESS GATES
api-7f9a1c2e05-b3nqz    0/1     Pending   0          4m8s  <none>   <none>   <none>           <none>

$ kubectl -n prod describe pod api-7f9a1c2e05-b3nqz | sed -n '/^Events/,$p'
Events:
  Type     Reason            Age                  From               Message
  ----     ------            ----                 ----               -------
  Warning  FailedScheduling  4m2s                 default-scheduler  0/6 nodes are available: 3 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }, 2 Insufficient cpu, 1 node(s) didn't match pod topology spread constraints. preemption: 0/6 nodes are available: 3 Preemption is not helpful for scheduling, 3 No preemption victims found for incoming pod.

$ kubectl describe node node-08 | sed -n '/Allocated resources/,/^Events/p'
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests      Limits
  --------           --------      ------
  cpu                7250m (96%)   4200m (56%)
  memory             13Gi (89%)    15Gi (102%)
  ephemeral-storage  6Gi (12%)     18Gi (37%)

$ kubectl get nodes -L topology.kubernetes.io/zone
NAME      STATUS   ROLES           AGE   VERSION   ZONE
node-07   Ready    <none>          41d   v1.33.2   eu-west-1a
node-08   Ready    <none>          41d   v1.33.2   eu-west-1a
node-09   Ready    <none>          41d   v1.33.2   eu-west-1b
```

Reading: node-09 (`eu-west-1b`) is the only node with capacity, but placing the pod there would push the zone skew past `maxSkew: 1`, and the constraint is `DoNotSchedule`. The correct fix is capacity in `eu-west-1a`, **not** relaxing the constraint — the constraint is expressing a real availability requirement.

### 9.4 Worked diagnosis: CrashLoopBackOff

```
$ kubectl -n prod get pod api-7f9a1c2e05-q8wmr
NAME                   READY   STATUS             RESTARTS      AGE
api-7f9a1c2e05-q8wmr   0/1     CrashLoopBackOff   5 (48s ago)   4m12s

$ kubectl -n prod logs api-7f9a1c2e05-q8wmr --previous --tail=20
2026-09-03T10:02:41.118Z INFO  storefront.api  starting, version=2.5.0
2026-09-03T10:02:41.402Z INFO  storefront.db   connecting host=pg-0.pg-headless.data.svc.cluster.local port=5432
2026-09-03T10:02:46.409Z ERROR storefront.db   dial tcp: lookup pg-0.pg-headless.data.svc.cluster.local: i/o timeout
2026-09-03T10:02:46.410Z FATAL storefront      cannot start without database, exiting

$ kubectl -n prod describe pod api-7f9a1c2e05-q8wmr | sed -n '/Last State/,/Ready/p'
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Thu, 03 Sep 2026 10:02:41 +0200
      Finished:     Thu, 03 Sep 2026 10:02:46 +0200
    Ready:          False
```

Exit 1 with a clean application message: this is not an infrastructure crash, it is a dependency failure. DNS timed out. Confirm from inside the same network namespace using an ephemeral debug container — which avoids the trap of `exec`ing into a distroless image that has no shell:

```
$ kubectl -n prod debug -it api-7f9a1c2e05-q8wmr \
    --image=registry.internal/netshoot:0.13 \
    --target=api --profile=netadmin -- bash
Targeting container "api". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-9mtqx.

debugger:~# dig +short +time=2 +tries=1 pg-0.pg-headless.data.svc.cluster.local
;; communications error to 10.96.0.10#53: timed out

debugger:~# nc -vz 10.96.0.10 53
nc: connect to 10.96.0.10 port 53 (tcp) failed: Connection timed out
```

DNS itself is unreachable from this pod. Since CoreDNS is healthy cluster-wide, suspect policy:

```
$ kubectl -n prod get networkpolicy
NAME               POD-SELECTOR                    AGE
default-deny-all   <none>                          9m
api-allow          app.kubernetes.io/name=api      9m

$ kubectl -n prod get networkpolicy api-allow -o jsonpath='{.spec.egress[*].ports[*].port}{"\n"}'
5432
```

Root cause: `default-deny-all` closed egress, and `api-allow` grants egress to PostgreSQL but **not to kube-dns on UDP/53**. The policy in §5.7 includes that rule for exactly this reason.

### 9.5 Worked diagnosis: Service with no endpoints

```
$ kubectl -n prod get svc api
NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
api    ClusterIP   10.107.44.19    <none>        80/TCP    41d

$ kubectl -n prod get endpointslices -l kubernetes.io/service-name=api
NAME        ADDRESSTYPE   PORTS   ENDPOINTS   AGE
api-7fk2x   IPv4          <unset> <unset>     41d

$ kubectl -n prod get svc api -o jsonpath='{.spec.selector}{"\n"}'
{"app.kubernetes.io/component":"backend","app.kubernetes.io/name":"api"}

$ kubectl -n prod get pods --show-labels | head -3
NAME                   READY   STATUS    RESTARTS   AGE   LABELS
api-6c47d9f8b4-x9pql   1/1     Running   0          22m   app.kubernetes.io/name=api,app.kubernetes.io/component=api-backend,pod-template-hash=6c47d9f8b4

$ kubectl -n prod get pods -l 'app.kubernetes.io/name=api,app.kubernetes.io/component=backend'
No resources found in prod namespace.
```

The Service selects `component=backend`; the pods carry `component=api-backend`. The API accepted both objects — a Service selector that matches nothing is perfectly valid. **`ENDPOINTS: <none>` on a Service whose pods are Running is always one of: label mismatch, readiness never true, or `targetPort` naming a port the container does not declare.** Check in that order.

### 9.6 Below the kubelet

```
$ ssh node-08 'sudo journalctl -u kubelet --since "10 min ago" --no-pager | tail -6'
Sep 03 10:07:12 node-08 kubelet[1187]: E0903 10:07:12.443901    1187 pod_workers.go:1301] "Error syncing pod, skipping" err="failed to \"StartContainer\" for \"api\" with CrashLoopBackOff: \"back-off 2m40s restarting failed container=api pod=api-7f9a1c2e05-q8wmr_prod(3f2c...)\"" pod="prod/api-7f9a1c2e05-q8wmr"
Sep 03 10:07:19 node-08 kubelet[1187]: I0903 10:07:19.008233    1187 kubelet_node_status.go:497] "Recording event message for node" node="node-08" event="NodeHasNoDiskPressure"

$ ssh node-08 'sudo crictl ps -a --name api --no-trunc | head -3'
CONTAINER                                                           IMAGE                                                               CREATED             STATE      NAME   ATTEMPT   POD ID
a1f4c9d02b7e3856f0c1a2b3d4e5f60718293a4b5c6d7e8f9012a3b4c5d6e7f80   registry.internal/storefront/api@sha256:5d3b0f2ac71e8fbd...          2 minutes ago       Exited     api    6         9c2e1f7a0d5b3

$ ssh node-08 'sudo crictl logs --tail 5 a1f4c9d02b7e3856f0c1a2b3d4e5f60718293a4b5c6d7e8f9012a3b4c5d6e7f80'
2026-09-03T10:07:10.882Z FATAL storefront      cannot start without database, exiting

$ ssh node-08 'sudo crictl stats --output table | head -4'
CONTAINER           CPU %     MEM       DISK      INODES
0d5b3c2e1f7a9       0.42      182.4MB   28.1MB    142
3e8f1a0c7d2b4       11.83     498.2MB   96.7MB    511
```

`crictl` talks directly to the CRI socket, bypassing the kubelet and the apiserver. It is the correct tool when the kubelet itself is suspect, or when a pod's containers exist at the runtime but never appear in the API.

### 9.7 Swarm-side diagnosis

```
$ docker service ps storefront_api --no-trunc
ID             NAME                 IMAGE                                    NODE       DESIRED STATE   CURRENT STATE             ERROR                                                                                          PORTS
k9m2p0x7vzqt   storefront_api.3     registry.internal/storefront/api:2.5.0   swarm-04   Ready           Rejected 2 seconds ago    "No such image: registry.internal/storefront/api:2.5.0"
b7f1n4dwsylc    \_ storefront_api.3 registry.internal/storefront/api:2.5.0   swarm-04   Shutdown        Rejected 12 seconds ago   "No such image: registry.internal/storefront/api:2.5.0"
q3h8zkr0tabm    \_ storefront_api.3 registry.internal/storefront/api:2.4.1   swarm-04   Shutdown        Shutdown 15 seconds ago

$ docker service logs --tail 20 --timestamps storefront_api
storefront_api.5.n5j3xghp7oyu@swarm-02 | 2026-09-03T10:11:04.221Z INFO  listening on :8080
storefront_api.6.r2k9lbvs4ndc@swarm-02 | 2026-09-03T10:11:04.918Z INFO  listening on :8080

$ docker inspect --format '{{json .Status}}' $(docker ps -aq --filter label=com.docker.swarm.service.name=storefront_api | head -1) | jq
{
  "State": "failed",
  "Timestamp": "2026-09-03T10:11:31.442017Z",
  "Message": "started",
  "Err": "task: non-zero exit (1)",
  "ContainerStatus": { "ExitCode": 1 }
}
```

The Swarm-specific gotcha visible here: `Rejected` with `No such image` means the *worker node* could not pull. Managers do not distribute images. Either every node can reach the registry with valid credentials (`docker service create --with-registry-auth` propagates them), or nothing schedules.

### 9.8 A verification checklist that actually catches regressions

```bash
#!/usr/bin/env bash
# verify-rollout.sh — gate a deployment in CI. Exits non-zero on any failure.
set -euo pipefail

NS="${1:?namespace}"; DEPLOY="${2:?deployment}"; TIMEOUT="${3:-600s}"

echo "==> 1. Server-side validation without applying"
kubectl -n "$NS" apply --dry-run=server -f manifests/ >/dev/null

echo "==> 2. Rollout reaches completion within the progress deadline"
kubectl -n "$NS" rollout status "deployment/$DEPLOY" --timeout="$TIMEOUT"

echo "==> 3. Every replica is Ready (guards against a stale Available condition)"
desired=$(kubectl -n "$NS" get "deployment/$DEPLOY" -o jsonpath='{.spec.replicas}')
ready=$(kubectl -n "$NS" get "deployment/$DEPLOY" -o jsonpath='{.status.readyReplicas}')
[[ "${ready:-0}" == "$desired" ]] || { echo "FAIL: ready=${ready:-0}/$desired"; exit 1; }

echo "==> 4. No container has restarted since the rollout"
restarts=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$DEPLOY" \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' \
  | awk '{s+=$1} END {print s+0}')
[[ "$restarts" -eq 0 ]] || { echo "FAIL: $restarts restarts observed"; exit 1; }

echo "==> 5. The Service actually has ready endpoints"
eps=$(kubectl -n "$NS" get endpointslices -l "kubernetes.io/service-name=$DEPLOY" \
  -o jsonpath='{range .items[*]}{range .endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{"\n"}{end}{end}' \
  | grep -c . || true)
[[ "$eps" -ge 1 ]] || { echo "FAIL: Service $DEPLOY has no ready endpoints"; exit 1; }
echo "    $eps ready endpoints"

echo "==> 6. The PDB can still tolerate a node drain"
allowed=$(kubectl -n "$NS" get "pdb/$DEPLOY" -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || echo 0)
[[ "$allowed" -ge 1 ]] || { echo "FAIL: PDB allows 0 disruptions; the next drain will hang"; exit 1; }

echo "==> 7. No Warning events in the namespace in the last 5 minutes"
if kubectl -n "$NS" get events --field-selector type=Warning \
     -o go-template='{{range .items}}{{.lastTimestamp}} {{.reason}} {{.message}}{{"\n"}}{{end}}' | grep -q .; then
  kubectl -n "$NS" get events --field-selector type=Warning
  echo "FAIL: warning events present"; exit 1
fi

echo "ALL CHECKS PASSED"
```

```
$ ./verify-rollout.sh prod api
==> 1. Server-side validation without applying
==> 2. Rollout reaches completion within the progress deadline
deployment "api" successfully rolled out
==> 3. Every replica is Ready (guards against a stale Available condition)
==> 4. No container has restarted since the rollout
==> 5. The Service actually has ready endpoints
    6 ready endpoints
==> 6. The PDB can still tolerate a node drain
==> 7. No Warning events in the namespace in the last 5 minutes
ALL CHECKS PASSED
```

Step 5 is the one most pipelines omit, and it is the one that catches the §9.5 class of bug: a rollout that "succeeds" while serving zero traffic.

### 9.9 Control-plane health

```
$ kubectl get --raw '/livez?verbose' | head -14
[+]ping ok
[+]log ok
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
[+]poststarthook/start-apiserver-admission-initializer ok
[+]poststarthook/generic-apiserver-start-informers ok
[+]poststarthook/priority-and-fairness-config-consumer ok
[+]poststarthook/start-kube-apiserver-identity-lease-controller ok
[+]poststarthook/rbac/bootstrap-roles ok
[+]poststarthook/scheduling/bootstrap-system-priority-classes ok
[+]shutdown ok
livez check passed

$ sudo ETCDCTL_API=3 etcdctl --endpoints=https://192.168.178.11:2379,https://192.168.178.12:2379,https://192.168.178.13:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table
+------------------------------+------------------+---------+---------+-----------+-----------+------------+
|           ENDPOINT           |        ID        | VERSION | DB SIZE | IS LEADER | RAFT TERM | RAFT INDEX |
+------------------------------+------------------+---------+---------+-----------+-----------+------------+
| https://192.168.178.11:2379  | 8e9c1f0a2b3d4e57 |  3.5.16 |  142 MB |      true |        14 |   48211952 |
| https://192.168.178.12:2379  | 1a2b3c4d5e6f7081 |  3.5.16 |  142 MB |     false |        14 |   48211952 |
| https://192.168.178.13:2379  | 9f8e7d6c5b4a3928 |  3.5.16 |  141 MB |     false |        14 |   48211951 |
+------------------------------+------------------+---------+---------+-----------+-----------+------------+

$ kubectl get --raw /metrics | grep -E '^apiserver_request_duration_seconds_bucket\{.*verb="LIST".*le="1"' | head -2
apiserver_request_duration_seconds_bucket{component="apiserver",group="",resource="pods",scope="cluster",subresource="",verb="LIST",version="v1",le="1"} 41283
```

Four control-plane signals worth alerting on, in priority order: `etcd_disk_wal_fsync_duration_seconds` p99 > 25 ms; `etcd_server_leader_changes_seen_total` increasing; `apiserver_request_total{code=~"5.."}` rate; `apiserver_flowcontrol_rejected_requests_total` non-zero.

### 9.10 Certificate expiry — the scheduled outage

kubeadm-issued client and serving certificates are valid for one year and renew on `kubeadm upgrade`. A cluster that is never upgraded therefore dies on its first birthday.

```
$ sudo kubeadm certs check-expiration
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Sep 03, 2027 07:41 UTC   364d            ca                      no
apiserver                  Sep 03, 2027 07:41 UTC   364d            ca                      no
apiserver-etcd-client      Sep 03, 2027 07:41 UTC   364d            etcd-ca                  no
apiserver-kubelet-client   Sep 03, 2027 07:41 UTC   364d            ca                      no
controller-manager.conf    Sep 03, 2027 07:41 UTC   364d            ca                      no
etcd-healthcheck-client    Sep 03, 2027 07:41 UTC   364d            etcd-ca                  no
etcd-peer                  Sep 03, 2027 07:41 UTC   364d            etcd-ca                  no
etcd-server                Sep 03, 2027 07:41 UTC   364d            etcd-ca                  no
front-proxy-client         Sep 03, 2027 07:41 UTC   364d            front-proxy-ca           no
scheduler.conf             Sep 03, 2027 07:41 UTC   364d            ca                      no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Sep 01, 2036 07:41 UTC   9y              no
etcd-ca                 Sep 01, 2036 07:41 UTC   9y              no
front-proxy-ca          Sep 01, 2036 07:41 UTC   9y              no
```

Note that kubelet *client* certificates rotate automatically (`rotateCertificates: true`); the control-plane certificates above do not.

---

## 10. Consolidated operator reference

```
# --- Kubernetes: state and topology -------------------------------------
kubectl get pods -A -o wide --field-selector status.phase!=Running
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail -20
kubectl get events -A --sort-by=.lastTimestamp --field-selector type=Warning
kubectl top nodes ; kubectl top pods -A --sort-by=memory
kubectl describe node <node> | sed -n '/Allocated resources/,/^Events/p'
kubectl api-resources --verbs=list --namespaced -o name
kubectl explain deployment.spec.strategy.rollingUpdate --recursive

# --- Kubernetes: rollout control ----------------------------------------
kubectl rollout status  deployment/<d> -n <ns> --timeout=10m
kubectl rollout history deployment/<d> -n <ns> --revision=4
kubectl rollout pause   deployment/<d> -n <ns>     # batch several edits
kubectl rollout resume  deployment/<d> -n <ns>
kubectl rollout undo    deployment/<d> -n <ns> --to-revision=4
kubectl rollout restart deployment/<d> -n <ns>     # re-pull, re-read secrets

# --- Kubernetes: diagnosis ----------------------------------------------
kubectl logs <pod> -c <ctr> --previous --timestamps --tail=200
kubectl logs -f -l app.kubernetes.io/name=api --max-log-requests=10
kubectl debug -it <pod> --image=netshoot --target=<ctr> --profile=netadmin
kubectl debug node/<node> -it --image=busybox --profile=sysadmin
kubectl auth can-i --list --as=system:serviceaccount:prod:api -n prod
kubectl get --raw '/livez?verbose'
kubectl port-forward -n prod svc/api 8080:80

# --- Kubernetes: node lifecycle -----------------------------------------
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=600s
kubectl uncordon <node>
kubectl taint nodes <node> workload=batch:NoSchedule

# --- CRI (on the node, below the kubelet) -------------------------------
sudo crictl pods ; sudo crictl ps -a ; sudo crictl images
sudo crictl logs <container-id> ; sudo crictl inspectp <pod-id> | jq .status
sudo journalctl -u kubelet -f --no-pager

# --- Docker Swarm --------------------------------------------------------
docker swarm init --advertise-addr <ip> ; docker swarm join-token worker
docker node ls ; docker node ps <node> ; docker node update --availability drain <node>
docker stack deploy -c docker-stack.yml <stack> --with-registry-auth
docker stack services <stack> ; docker stack ps <stack> --no-trunc
docker service scale <svc>=10
docker service update --image <img> --update-order start-first <svc>
docker service rollback <svc>
docker service logs -f --tail 100 <svc>
docker service inspect <svc> --format '{{json .UpdateStatus}}'
```

---

## 11. Exam-focused summary of decisive facts

- The orchestration model is **level-triggered reconciliation**, not event-driven imperative execution. Missed events do not corrupt state.
- Only the **apiserver** speaks to etcd. Etcd quorum is `floor(N/2)+1`; use 3 or 5 members, never an even number.
- The **scheduler places pods using `requests`; the kernel enforces `limits`.** Wrong requests produce a cluster that is simultaneously "empty" and overloaded.
- **QoS class** (Guaranteed / Burstable / BestEffort) determines eviction order under node pressure.
- `maxSurge` rounds **up**, `maxUnavailable` rounds **down**; both cannot be zero.
- `progressDeadlineSeconds` marks a rollout failed — **it does not roll back**. Gate CI on `kubectl rollout status`.
- **StatefulSets** give stable network identity and one PVC per ordinal; updates run from the highest ordinal downward, and `partition` is a built-in canary.
- **Native sidecars** are `initContainers` with `restartPolicy: Always`: started first, stopped last, and they let Jobs complete.
- ConfigMap/Secret consumed as **env vars never update**; nor do `subPath` mounts. Volume mounts do.
- A Service with `ENDPOINTS: <none>` while pods are Running is a **label-selector mismatch, a readiness failure, or a wrong `targetPort`** — in that order of likelihood.
- **NetworkPolicy is default-allow until a policy selects the pod**, then default-deny for the selected direction. Always allow egress to kube-dns explicitly.
- `ReadWriteOnce` is per **node**; `ReadWriteOncePod` is per **pod**.
- **PodDisruptionBudget** governs voluntary disruption (`drain`, eviction API) only. It does not protect against a node crashing.
- In **Swarm**: managers run Raft, `mode: global` ≈ DaemonSet, `order: start-first` ≈ surge rollout, Configs are **immutable** so version the name, and images are pulled by each worker (`--with-registry-auth`).
- Cluster **Events have a 1-hour TTL**. Ship them off-cluster or lose your post-mortem.

---

## Referencias

**LPI**
- LPI DevOps Tools Engineer — Exam 701 objectives: https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI DevOps Tools Engineer certification overview: https://www.lpi.org/our-certifications/devops-overview/

**Kubernetes — concepts and architecture**
- Kubernetes cluster architecture: https://kubernetes.io/docs/concepts/architecture/
- Controllers and the reconciliation loop: https://kubernetes.io/docs/concepts/architecture/controller/
- Nodes and node conditions: https://kubernetes.io/docs/concepts/architecture/nodes/
- Container Runtime Interface (CRI): https://kubernetes.io/docs/concepts/architecture/cri/
- Objects, names and labels: https://kubernetes.io/docs/concepts/overview/working-with-objects/
- API concepts (list, watch, resourceVersion): https://kubernetes.io/docs/reference/using-api/api-concepts/

**Kubernetes — workloads**
- Pod lifecycle: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- StatefulSets: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- DaemonSet: https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Jobs: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- CronJob: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Sidecar containers: https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- Configure liveness, readiness and startup probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/

**Kubernetes — scheduling and resources**
- Kubernetes scheduler: https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/
- Assigning Pods to Nodes: https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Taints and tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Pod topology spread constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Pod priority and preemption: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Node-pressure eviction: https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Resource management for Pods and containers: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Pod Quality of Service classes: https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Disruptions and PodDisruptionBudget: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/

**Kubernetes — networking**
- Cluster networking model: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Service: https://kubernetes.io/docs/concepts/services-networking/service/
- EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Virtual IPs and Service proxies (kube-proxy modes): https://kubernetes.io/docs/reference/networking/virtual-ips/
- DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Ingress: https://kubernetes.io/docs/concepts/services-networking/ingress/
- Gateway API: https://kubernetes.io/docs/concepts/services-networking/gateway/
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/

**Kubernetes — configuration and storage**
- ConfigMap: https://kubernetes.io/docs/concepts/configuration/configmap/
- Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Encrypting confidential data at rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/

**Kubernetes — cluster administration**
- Creating a cluster with kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- Container runtimes (containerd, cgroup drivers): https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- kubeadm configuration reference: https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
- kubelet configuration reference: https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Upgrading kubeadm clusters: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Safely drain a node: https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Operating etcd clusters for Kubernetes: https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Certificate management with kubeadm: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- API Priority and Fairness: https://kubernetes.io/docs/concepts/cluster-administration/flow-control/

**Kubernetes — troubleshooting**
- Debug Pods: https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
- Debug running Pods (ephemeral containers): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Troubleshooting clusters: https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Debugging Kubernetes nodes with crictl: https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
- kubectl reference: https://kubernetes.io/docs/reference/kubectl/

**Docker Swarm**
- Swarm mode overview: https://docs.docker.com/engine/swarm/
- Swarm mode key concepts: https://docs.docker.com/engine/swarm/key-concepts/
- How services work: https://docs.docker.com/engine/swarm/how-swarm-mode-works/services/
- Raft consensus in Swarm: https://docs.docker.com/engine/swarm/raft/
- Deploy services to a swarm: https://docs.docker.com/engine/swarm/services/
- Rolling updates on a swarm: https://docs.docker.com/engine/swarm/swarm-tutorial/rolling-update/
- Deploy a stack to a swarm: https://docs.docker.com/engine/swarm/stack-deploy/
- Compose Deploy specification: https://docs.docker.com/reference/compose-file/deploy/
- Manage swarm secrets: https://docs.docker.com/engine/swarm/secrets/
- Manage swarm configs: https://docs.docker.com/engine/swarm/configs/
- Networking with overlay networks: https://docs.docker.com/engine/network/drivers/overlay/

**Runtimes, CNI and related projects**
- containerd documentation: https://containerd.io/docs/
- CRI-O: https://cri-o.io/
- Container Network Interface specification: https://www.cni.dev/docs/spec/
- Kubernetes CSI documentation: https://kubernetes-csi.github.io/docs/
- CoreDNS Kubernetes plugin: https://coredns.io/plugins/kubernetes/
- etcd operations guide: https://etcd.io/docs/v3.5/op-guide/
- Gateway API project: https://gateway-api.sigs.k8s.io/
- Podman Quadlet (systemd integration): https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
- HashiCorp Nomad documentation: https://developer.hashicorp.com/nomad/docs