# 352.4 Container Orchestration Platforms

> **Exam context** — LPIC-3 305-300, Topic 352, weight **5**. This objective covers Kubernetes architecture, the CRI/CNI/CSI interface contracts, the core workload objects (Pods, ReplicaSets, Deployments, Services, labels), `kubelet`/`kube-proxy`, Docker Swarm (services, tasks, nodes, stacks), and awareness of Helm, OpenShift, Rancher and OKD.

---

## 1. The architectural problem: why orchestration exists

A single container runtime (`containerd`, Docker Engine, CRI-O) solves *packaging and isolation on one host*. It answers "run this image with these namespaces and cgroups." It does **not** answer any of the questions a production platform actually has:

- **Placement** — which of my 40 nodes has enough allocatable CPU/memory, the right topology (zone, GPU, local SSD), and no anti-affinity conflict?
- **Desired state** — I asked for 6 replicas; a node just died taking 2 of them. Who notices, and who replaces them?
- **Service discovery & load balancing** — replicas are ephemeral and get new IPs on every restart. How does a client reach "the payment service" without knowing IPs?
- **Rollout & rollback** — how do I move from `v1.4.2` to `v1.5.0` without dropping traffic, and revert in seconds when error rate spikes?
- **Config & secret distribution** — how do 200 pods get the same TLS cert and DB password without baking them into images?
- **Bin-packing & fault domains** — how do I keep utilization high *and* survive a rack/zone loss?

Orchestration is the **control loop** that continuously drives observed cluster state toward a declared desired state. The mental model is a thermostat, not a script: you declare `replicas: 6`, and controllers *reconcile* forever — on node loss, on process crash, on manual `kill`. This is the single most important production concept in the objective:

```
        declare desired state (etcd)
                   │
                   ▼
   ┌──────────► reconcile loop ──────────┐
   │      (observe actual vs desired)     │
   │                                      ▼
observed state  ◄──────────────  act to close the gap
(kubelet, CRI, CNI)              (create/delete Pods, program routes)
```

Everything below is a variation on this loop.

---

## 2. Kubernetes architecture

A Kubernetes cluster splits into a **control plane** (the brain: decides *what should be*) and **worker nodes** (the muscle: run the containers). The only stateful component is `etcd`; every other control-plane process is stateless and reconstructs its view by watching the API server.

```
                       ┌──────────────────────── CONTROL PLANE ───────────────────────────┐
                       │                                                                    │
   kubectl / clients   │   ┌──────────────┐        ┌───────────────────────────────────┐   │
        │              │   │    etcd      │◄──────►│           kube-apiserver          │   │
        ▼   (HTTPS 6443)│   │ (raft, 2379) │        │  (REST, authN/authZ, admission,   │   │
   ┌─────────────┐      │   └──────────────┘        │   the ONLY thing that talks to etcd)│  │
   │ kube-apiserver│◄───┼──────────────────────────►└───────▲───────────▲──────────▲─────┘  │
   └─────────────┘      │                                   │ watch/act  │          │        │
                       │   ┌──────────────┐  ┌──────────────┴──┐  ┌──────┴───────┐  │        │
                       │   │ kube-scheduler│  │ kube-controller-│  │cloud-controller│ │       │
                       │   │  (binds Pod   │  │    manager      │  │   -manager    │ │        │
                       │   │   → Node)     │  │ (Node,ReplicaSet,│ │ (LB,routes,   │ │        │
                       │   └──────────────┘  │  Deployment,...) │  │  volumes)     │ │        │
                       │                     └─────────────────┘  └───────────────┘ │        │
                       └────────────────────────────────────────────────────────────┼───────┘
                                                                                     │
   ┌──────────────────────────── WORKER NODE (×N) ───────────────────────────────────┼──────┐
   │  ┌─────────┐   CRI    ┌───────────────┐   CNI    ┌──────────┐                    │      │
   │  │ kubelet │◄────────►│ container      │◄────────►│ CNI plugin│  (pod networking) │      │
   │  │(10250)  │ gRPC     │ runtime        │          └──────────┘                    │      │
   │  └────┬────┘          │(containerd/CRIO)│    CSI   ┌──────────┐                    │      │
   │       │               └───────────────┘◄────────►│CSI driver │  (volumes)         │      │
   │  ┌────▼─────┐                                     └──────────┘                    │      │
   │  │kube-proxy│  (programs iptables/IPVS/nftables for Service VIPs)                  │      │
   │  └──────────┘                                                                      │      │
   └────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Control-plane components

| Component | Listens | Statefulness | Responsibility | If it dies… |
|---|---|---|---|---|
| **kube-apiserver** | `:6443` (HTTPS) | Stateless (horizontally scalable) | Front door for all reads/writes; authN → authZ → admission → persist to etcd. The **only** component that touches etcd. | Cluster becomes read-only from the outside; running Pods keep running, but no changes, no self-healing. |
| **etcd** | `:2379` (client), `:2380` (peer) | **The** stateful store; Raft-replicated | Consistent, watchable key-value store of all cluster objects. | Full outage of state; loss of quorum = no writes. Back it up. |
| **kube-scheduler** | `:10259` (HTTPS, metrics/health) | Stateless | Watches unscheduled Pods, scores nodes (filters + priorities), writes `.spec.nodeName`. | New Pods stay `Pending`; existing Pods unaffected. |
| **kube-controller-manager** | `:10257` | Stateless (leader-elected) | Runs the built-in controllers: Node, ReplicaSet, Deployment, Job, EndpointSlice, ServiceAccount, etc. Each is a reconcile loop. | Self-healing stops: dead Pods aren't replaced, Deployments don't roll. |
| **cloud-controller-manager** | `:10258` | Stateless (leader-elected) | Cloud-specific loops: provision LoadBalancers, attach volumes, label nodes with zone/instance-type, remove Node objects for deleted VMs. | Cloud LBs and routes stop being reconciled. |

**Key exam point — everything goes through the API server.** `kubelet` does not read etcd. The scheduler does not read etcd. They all `watch` the API server, and the API server serializes to etcd. This is why the API server is the trust boundary (RBAC, admission webhooks, quotas) and the scaling bottleneck.

**etcd internals worth knowing for production:**
- Consensus via **Raft**; you need an **odd** number of members (3 or 5) so a quorum (`N/2 + 1`) survives failures. 3 members tolerate 1 loss; 5 tolerate 2.
- Objects are stored under keys like `/registry/pods/<namespace>/<name>` as Protobuf.
- The default DB size limit is **2 GiB** (`--quota-backend-bytes`); exceeding it puts etcd into a read-only alarm state — a classic production incident. Compact and defrag on a schedule.

### 2.2 Node components

- **kubelet** — the node agent. It is *not* a controller in the API sense; it is the thing that makes reality match a Pod spec on **its** node. It watches the API server for Pods bound to its `nodeName`, calls the **CRI** to create sandboxes and containers, invokes the **CNI** to wire networking, mounts volumes via **CSI**, runs probes (liveness/readiness/startup), and reports node/Pod status back. It also manages static Pods from `/etc/kubernetes/manifests` (how the control plane itself is bootstrapped in `kubeadm`).
- **kube-proxy** — implements the *Service* abstraction on each node. It watches Services and EndpointSlices and programs the kernel dataplane so that traffic to a Service `ClusterIP:port` is DNAT'd/load-balanced to a healthy backend Pod IP. Modes: `iptables` (default, O(n) rule chains), `IPVS` (hash tables, scales to thousands of Services), and newer `nftables`. Note: with eBPF dataplanes (Cilium) kube-proxy can be *replaced* entirely.
- **container runtime** — the CRI implementation (`containerd`, `CRI-O`) that actually creates the containers via an OCI runtime (`runc`, `crun`, `gVisor`, `Kata`).

---

## 3. The interface contracts: CRI, CNI, CSI

Kubernetes deliberately does not implement runtime, networking, or storage. It defines **three pluggable contracts** so vendors compete behind stable interfaces. This is the "understand the role of CRI/CNI/CSI" objective, and it is heavily tested.

| Interface | Full name | Transport | Consumer | Config location | Example implementations |
|---|---|---|---|---|---|
| **CRI** | Container Runtime Interface | **gRPC** over a Unix socket | `kubelet` | `--container-runtime-endpoint` | containerd, CRI-O, (Docker via cri-dockerd) |
| **CNI** | Container Network Interface | **exec** of a binary + JSON on stdin/stdout | kubelet/runtime | `/etc/cni/net.d/*.conf`, bins in `/opt/cni/bin` | Calico, Cilium, Flannel, Weave, AWS VPC CNI |
| **CSI** | Container Storage Interface | **gRPC** (sidecar + node driver) | kube-controller-manager + kubelet | driver `Deployment`/`DaemonSet` + `StorageClass` | AWS EBS, Ceph-CSI, Longhorn, local-path |

### 3.1 CRI — and the dockershim removal

The kubelet speaks CRI (two gRPC services: `RuntimeService` and `ImageService`) to a socket:

```
$ crictl --runtime-endpoint unix:///run/containerd/containerd.sock version
Version:  0.1.0
RuntimeName:  containerd
RuntimeVersion:  1.7.13
RuntimeApiVersion:  v1
```

**Historical exam trap:** the kubelet originally special-cased Docker Engine via an in-tree adapter called **dockershim**. Because Docker Engine is not CRI-native, dockershim was **deprecated in Kubernetes 1.20 and removed in 1.24** (Dec 2021 / May 2022). Docker *images* (OCI) still run fine — you just point the kubelet at `containerd` (which Docker uses under the hood) or install `cri-dockerd`. "Kubernetes dropped Docker" only ever meant "dropped dockershim."

The runtime stack, top to bottom:

```
kubelet ──CRI/gRPC──► containerd ──OCI──► runc ──clone(2)/cgroups──► your container
```

### 3.2 CNI — the pod network

CNI is invoked as a **binary**, not a daemon call: the runtime execs `/opt/cni/bin/<plugin>` with a JSON config on stdin and the verb (`ADD`/`DEL`/`CHECK`) in an env var, and the plugin returns the assigned IP as JSON. Kubernetes' network model requires three invariants: **every Pod gets its own IP, all Pods can reach all Pods without NAT, and the node can reach all Pods**.

| Plugin | Dataplane | Encapsulation | NetworkPolicy | Notable for |
|---|---|---|---|---|
| **Flannel** | Linux bridge | VXLAN (overlay) | ❌ (needs add-on) | Simplicity; dev clusters |
| **Calico** | iptables/eBPF | None (BGP) or VXLAN/IPIP | ✅ (rich, incl. global) | BGP-native, no-overlay perf, mature policy |
| **Cilium** | **eBPF** | VXLAN/Geneve or native | ✅ (L3–L7, identity-based) | eBPF dataplane, kube-proxy replacement, Hubble observability |
| **Weave Net** | userspace/kernel | VXLAN | ✅ | Ease of use (project now EOL) |
| **AWS VPC CNI** | native VPC ENIs | None (real VPC IPs) | via Calico | Pods get routable VPC IPs |

A minimal CNI config on disk:

```json
{
  "cniVersion": "1.0.0",
  "name": "k8s-pod-network",
  "plugins": [
    {
      "type": "calico",
      "datastore_type": "kubernetes",
      "ipam": { "type": "calico-ipam" },
      "policy": { "type": "k8s" },
      "kubernetes": { "kubeconfig": "/etc/cni/net.d/calico-kubeconfig" }
    },
    { "type": "portmap", "capabilities": { "portMappings": true } }
  ]
}
```

A cluster with **no** CNI installed leaves every node `NotReady` and Pods stuck `ContainerCreating` — the single most common "fresh cluster won't start" incident.

### 3.3 CSI — storage

CSI decouples volume lifecycle (provision, attach, mount, snapshot, resize) from the Kubernetes core. A driver ships as a **controller Deployment** (with `external-provisioner`, `external-attacher`, `external-resizer` sidecars) plus a **node DaemonSet**. Consumers declare a `StorageClass`; a `PersistentVolumeClaim` triggers dynamic provisioning of a `PersistentVolume`.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com          # the CSI driver name
parameters:
  type: gp3
  iops: "6000"
  throughput: "250"
  encrypted: "true"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer   # bind PV in the same zone as the scheduled Pod
```

---

## 4. Core workload objects

The objective names **Pods, Services, ReplicaSets, Deployments and labels**. Understand them as a layered stack, each adding one capability:

```
Deployment  ─ declarative rollout, rollback, revision history
   └─ owns ReplicaSet(s)  ─ maintains N identical Pod replicas
          └─ owns Pods    ─ smallest schedulable unit (1+ containers, shared net/IPC/volumes)
Service     ─ stable VIP + DNS + load-balancing over a label-selected set of Pods
Labels      ─ the glue: selectors on every object above resolve to a set of Pods
```

### 4.1 Pod — the atom

A Pod is a set of co-scheduled containers sharing a network namespace (one IP, shared `localhost`), IPC, and volumes. The lifecycle is `Pending → Running → Succeeded/Failed`, governed by init containers, probes and restart policy.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-probe-demo
  labels:
    app: web
    tier: frontend
spec:
  # An init container runs to completion BEFORE app containers start.
  initContainers:
    - name: wait-for-db
      image: busybox:1.36
      command: ['sh', '-c', 'until nc -z db 5432; do echo waiting; sleep 2; done']
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      ports:
        - containerPort: 80
      resources:
        requests:            # used by the scheduler for bin-packing
          cpu: "100m"
          memory: "128Mi"
        limits:              # enforced by the kubelet/cgroups; exceed mem => OOMKilled
          cpu: "500m"
          memory: "256Mi"
      livenessProbe:         # restart the container if this fails
        httpGet: { path: /healthz, port: 80 }
        initialDelaySeconds: 10
        periodSeconds: 10
        failureThreshold: 3
      readinessProbe:        # remove from Service endpoints if this fails (no restart)
        httpGet: { path: /ready, port: 80 }
        periodSeconds: 5
      startupProbe:          # protects slow-starting apps from the liveness probe
        httpGet: { path: /healthz, port: 80 }
        failureThreshold: 30
        periodSeconds: 10
  restartPolicy: Always
```

**Requests vs limits** is the most misunderstood production knob: `requests` drive scheduling and are the guaranteed floor; `limits` are the ceiling enforced by cgroups. CPU over-limit → *throttled*; memory over-limit → *OOMKilled*. Setting `requests == limits` yields the `Guaranteed` QoS class (last to be evicted under node pressure).

### 4.2 ReplicaSet — the replica maintainer

Rarely created directly, but it is the reconcile loop behind Deployments: keep exactly `.spec.replicas` Pods matching `.spec.selector` alive.

```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: web-rs
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:                # a Pod template; label MUST satisfy the selector
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
```

The selector is **immutable** and label-based — this is why labels are a first-class objective. If a stray Pod happens to carry `app: web`, the ReplicaSet will *adopt* it and count it toward the replica total.

### 4.3 Deployment — declarative rollouts

The object you almost always use. It manages ReplicaSets to give you rolling updates, revision history, and one-command rollback.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 4
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: web
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1      # at most 1 Pod down during the roll
      maxSurge: 1            # at most 1 extra Pod above desired during the roll
  minReadySeconds: 10
  template:
    metadata:
      labels:
        app: web
    spec:
      topologySpreadConstraints:      # spread replicas across zones for fault tolerance
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app: web }
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet: { path: /, port: 80 }
            periodSeconds: 5
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
```

**Rollout mechanics:** on a template change the Deployment controller creates a *new* ReplicaSet and scales it up while scaling the old one down, respecting `maxSurge`/`maxUnavailable`. `readinessProbe` is what makes this safe — a new Pod receives traffic only once Ready. `revisionHistoryLimit` keeps old ReplicaSets around (scaled to 0) so `kubectl rollout undo` is instant.

### 4.4 Service — stable networking

Pods are cattle: they die and get new IPs. A Service gives a **stable ClusterIP + DNS name** and load-balances across the Pods its selector matches (via EndpointSlices maintained by the endpoint controller and programmed by kube-proxy).

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: ClusterIP           # ClusterIP | NodePort | LoadBalancer | ExternalName
  selector:
    app: web                # matches the Deployment's Pod labels
  ports:
    - name: http
      port: 80              # the Service's stable port
      targetPort: 80        # the container's port
---
# NodePort exposes the Service on every node's IP at a high port (30000-32767)
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
spec:
  type: NodePort
  selector: { app: web }
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
```

| Service type | Reachable from | Backed by | Typical use |
|---|---|---|---|
| **ClusterIP** | inside cluster only | kube-proxy VIP | East-west traffic, the default |
| **NodePort** | `<anyNodeIP>:30000-32767` | ClusterIP + node port | Bare-metal, quick external test |
| **LoadBalancer** | external LB IP | cloud-controller-manager provisions an LB | Cloud north-south |
| **ExternalName** | CNAME to external DNS | kube-dns CNAME | Alias external services |
| **Headless (`clusterIP: None`)** | direct Pod IPs via DNS | no VIP | StatefulSets, client-side LB |

DNS resolution: a Service `web` in namespace `prod` is reachable at `web.prod.svc.cluster.local` (CoreDNS). **Ingress** (an L7 HTTP router) and the newer **Gateway API** sit *in front of* Services for host/path routing and TLS termination — worth being aware of, though the core objects above are the tested atoms.

---

## 5. `kubectl` — real terminal sessions

`kubectl` is the primary client; it talks HTTPS to the API server using the context in `~/.kube/config`. Real output below (line-wrapped as a terminal shows it):

```
$ kubectl apply -f deployment.yaml
deployment.apps/web created

$ kubectl get deploy,rs,pods -l app=web
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   4/4     4            4           38s

NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/web-6d4b9c8f7c   4         4         4       38s

NAME                   READY   STATUS    RESTARTS   AGE
pod/web-6d4b9c8f7c-2xk9p   1/1   Running   0          38s
pod/web-6d4b9c8f7c-8wq4d   1/1   Running   0          38s
pod/web-6d4b9c8f7c-lm7rv   1/1   Running   0          38s
pod/web-6d4b9c8f7c-t9c2z   1/1   Running   0          38s
```

Trigger and watch a rolling update:

```
$ kubectl set image deployment/web nginx=nginx:1.27.1-alpine
deployment.apps/web image updated

$ kubectl rollout status deployment/web
Waiting for deployment "web" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 3 of 4 updated replicas are available...
deployment "web" successfully rolled out

$ kubectl rollout history deployment/web
deployment.apps/web
REVISION  CHANGE-CAUSE
1         <none>
2         <none>

$ kubectl rollout undo deployment/web --to-revision=1
deployment.apps/web rolled back
```

Inspect where a Pod landed and why, then read control-plane component health:

```
$ kubectl get pods -o wide
NAME                   READY   STATUS    RESTARTS   AGE   IP            NODE       
web-6d4b9c8f7c-2xk9p   1/1     Running   0          4m    10.244.2.15   worker-02  

$ kubectl get componentstatuses
NAME                 STATUS    MESSAGE   ERROR
scheduler            Healthy   ok
controller-manager   Healthy   ok
etcd-0               Healthy   ok

$ kubectl get nodes
NAME          STATUS   ROLES           AGE   VERSION
cp-01         Ready    control-plane   21d   v1.30.2
worker-01     Ready    <none>          21d   v1.30.2
worker-02     Ready    <none>          21d   v1.30.2
```

---

## 6. Docker Swarm

Swarm mode is Docker Engine's built-in orchestrator: no separate control-plane install, one binary, `docker-compose`-compatible. The objective asks for **swarm services, tasks, nodes and stacks**.

### 6.1 Concepts

- **Node** — a Docker Engine in the swarm; a **manager** (participates in the Raft-based control plane) or a **worker** (runs tasks only). Managers should be odd-numbered (3/5) for quorum, exactly like etcd.
- **Service** — the declarative unit: an image + desired replica count (or `global` = one per node) + network/port config. The Swarm analogue of a Deployment.
- **Task** — a single container instance of a service, scheduled onto a node. The atomic unit; a service with `replicas: 3` produces 3 tasks. (A Swarm *task* ≈ a Kubernetes *Pod*.)
- **Stack** — a group of services defined in a Compose file and deployed together (`docker stack deploy`). The Swarm analogue of a Helm release / a bundle of manifests.

Swarm's built-in **routing mesh** publishes a service port on **every** node; traffic hitting any node is forwarded (via IPVS on the `ingress` overlay network) to a healthy task, giving you a virtual IP (VIP) per service for free.

### 6.2 Bootstrapping and operating a swarm

```
$ docker swarm init --advertise-addr 192.168.10.11
Swarm initialized: current node (kf3d9a...) is now a manager.

To add a worker to this swarm, run the following command:
    docker swarm join --token SWMTKN-1-49nj1... 192.168.10.11:2377

$ docker swarm join-token worker
To add a worker to this swarm, run the following command:
    docker swarm join --token SWMTKN-1-49nj1c8ax... 192.168.10.11:2377

# ── on each worker ──
$ docker swarm join --token SWMTKN-1-49nj1c8ax... 192.168.10.11:2377
This node joined a swarm as a worker.

$ docker node ls
ID              HOSTNAME    STATUS   AVAILABILITY   MANAGER STATUS   ENGINE VERSION
kf3d9a... *     mgr-01      Ready    Active         Leader           27.1.1
q1p8s2...       wrk-01      Ready    Active                          27.1.1
z7c4v9...       wrk-02      Ready    Active                          27.1.1
```

Create, inspect and scale a **service**:

```
$ docker service create --name web --replicas 3 -p 8080:80 nginx:1.27-alpine
x8f2q9v1k3n5
overall progress: 3 out of 3 tasks
1/3: running   [==================================================>]
2/3: running   [==================================================>]
3/3: running   [==================================================>]
verify: Service converged

$ docker service ls
ID             NAME   MODE         REPLICAS   IMAGE               PORTS
x8f2q9v1k3n5   web    replicated   3/3        nginx:1.27-alpine   *:8080->80/tcp

$ docker service ps web
ID          NAME    IMAGE               NODE     DESIRED STATE  CURRENT STATE
a1b2c3d4    web.1   nginx:1.27-alpine   wrk-01   Running        Running 2 min ago
e5f6g7h8    web.2   nginx:1.27-alpine   wrk-02   Running        Running 2 min ago
i9j0k1l2    web.3   nginx:1.27-alpine   mgr-01   Running        Running 2 min ago

$ docker service scale web=5
web scaled to 5
$ docker service update --image nginx:1.27.1-alpine web   # rolling update
```

Deploy a **stack** from a Compose file:

```yaml
# stack.yml
version: "3.9"
services:
  web:
    image: nginx:1.27-alpine
    ports:
      - "8080:80"
    deploy:
      replicas: 4
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.role == worker
    networks: [appnet]
  redis:
    image: redis:7-alpine
    deploy:
      replicas: 1
      placement:
        constraints: [node.labels.storage == ssd]
    networks: [appnet]
networks:
  appnet:
    driver: overlay
```

```
$ docker stack deploy -c stack.yml myapp
Creating network myapp_appnet
Creating service myapp_web
Creating service myapp_redis

$ docker stack services myapp
ID       NAME         MODE         REPLICAS   IMAGE
7hq2..   myapp_web    replicated   4/4        nginx:1.27-alpine
9kd8..   myapp_redis  replicated   1/1        redis:7-alpine

$ docker stack ps myapp
$ docker stack rm myapp        # tear the whole stack down
```

### 6.3 Swarm vs Kubernetes — trade-off table

| Dimension | Docker Swarm | Kubernetes |
|---|---|---|
| Install / operate | Trivial (built into Docker) | Complex (kubeadm, or managed) |
| Scheduling unit | Task (single container) | Pod (1+ co-scheduled containers) |
| Control-plane store | Raft (built-in) | etcd (Raft) |
| Declarative file | Compose (`docker stack`) | Manifests / Helm / Kustomize |
| Load balancing | Routing mesh (IPVS VIP) | Services + kube-proxy + Ingress |
| Autoscaling | ❌ (manual `scale`) | ✅ HPA / VPA / Cluster Autoscaler |
| Ecosystem / extensibility | Minimal | Vast (CRDs, operators, CNI/CSI/CRI) |
| Rolling update / rollback | ✅ (`update_config`) | ✅ (richer, revision history) |
| Multi-container primitives | ❌ | ✅ (sidecars, init containers) |
| Production trajectory | Stable but low momentum | Industry standard (CNCF) |

**Verdict for the exam:** Swarm wins on *simplicity and time-to-first-service*; Kubernetes wins on *extensibility, ecosystem, and complex production topologies*. Swarm is the pragmatic choice for a small homogeneous fleet; Kubernetes is the default for anything that needs autoscaling, operators, or a large team.

---

## 7. Helm — the package manager (awareness)

Helm packages a set of manifests as a **chart** (templated YAML + a `values.yaml`), which you install as a named **release**. It solves "I have 30 interrelated manifests with the same 8 values duplicated across them" and provides versioned, revertible releases.

Chart layout:

```
mychart/
├── Chart.yaml          # name, version, appVersion, dependencies
├── values.yaml         # default parameter values
├── templates/
│   ├── deployment.yaml # Go-templated: {{ .Values.replicaCount }}
│   ├── service.yaml
│   └── _helpers.tpl
└── charts/             # vendored sub-charts (dependencies)
```

```
$ helm repo add bitnami https://charts.bitnami.com/bitnami
$ helm install my-nginx bitnami/nginx --set replicaCount=3
NAME: my-nginx
STATUS: deployed
REVISION: 1

$ helm list
NAME       NAMESPACE  REVISION  STATUS     CHART         APP VERSION
my-nginx   default    1         deployed   nginx-18.1.0  1.27.0

$ helm upgrade my-nginx bitnami/nginx --set replicaCount=5
$ helm rollback my-nginx 1
$ helm template my-nginx bitnami/nginx | kubectl apply --dry-run=server -f -
```

Helm 3 is **client-only** (no in-cluster "Tiller"); release state is stored as Secrets in the release namespace.

---

## 8. Distribution awareness: OpenShift, Rancher, OKD

The objective asks for **awareness** of these — know what each *is* relative to upstream Kubernetes.

| Product | Vendor | What it is | Distinguishing features |
|---|---|---|---|
| **OpenShift (OCP)** | Red Hat | Enterprise, opinionated, *supported* Kubernetes distribution | Built-in image registry, source-to-image (S2I) builds, `Route` objects (integrated HAProxy ingress), stricter security defaults (SCCs, non-root by default), `oc` CLI, integrated CI/CD; runs on RHCOS. |
| **OKD** | Community | The upstream, free community distribution that OpenShift is built from | Same architecture as OCP without Red Hat support/subscription; the "Fedora to OpenShift's RHEL." |
| **Rancher** | SUSE | A **multi-cluster management** platform *on top of* Kubernetes | Provisions and manages many clusters (RKE2/K3s, EKS, AKS, GKE) from one UI/API; centralized RBAC, catalog, fleet GitOps. K3s (its lightweight distro) is a single ~60 MB binary for edge/IoT. |

Mental model: **OKD → OpenShift** is upstream → enterprise-supported; **Rancher** is a fleet manager sitting above clusters rather than a distribution you run workloads directly against.

---

## 9. Verification and failure diagnosis

Production orchestration debugging is a **top-down walk of the reconcile loop**: is the object accepted? scheduled? pulled? networked? ready?

### 9.1 The universal first four commands

```
$ kubectl get pods -A -o wide                # what state is everything in?
$ kubectl describe pod <pod>                 # Events at the bottom are gold
$ kubectl logs <pod> [-c <container>] --previous   # --previous = last crashed instance
$ kubectl get events --sort-by=.lastTimestamp     # cluster-wide timeline
```

### 9.2 Symptom → cause → command

| Pod status | Likely cause | Diagnostic |
|---|---|---|
| `Pending` | No node fits requests/affinity/taints; no CNI; unbound PVC | `kubectl describe pod` → *FailedScheduling*; `kubectl describe node` for allocatable |
| `ContainerCreating` (stuck) | CNI not installed/broken; volume won't mount; image pull slow | `kubectl describe pod`; check `/etc/cni/net.d`; `journalctl -u kubelet` |
| `ImagePullBackOff` / `ErrImagePull` | Wrong image name/tag; private registry, no `imagePullSecret` | `kubectl describe pod` → pull error; verify secret |
| `CrashLoopBackOff` | App exits/panics; failing liveness probe; bad config | `kubectl logs --previous`; check probe path/port |
| `OOMKilled` (in RESTARTS reason) | Memory usage > `limits.memory` | `kubectl describe pod` → *Last State: OOMKilled*; raise limit or fix leak |
| `Running` but `0/1 READY` | readinessProbe failing → not in Service endpoints | `kubectl describe pod`; `kubectl get endpointslices` |

### 9.3 Worked examples

**A Pod won't schedule:**

```
$ kubectl describe pod web-6d4b9c8f7c-2xk9p
...
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  12s   default-scheduler  0/3 nodes are available:
           1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
           2 Insufficient cpu. preemption: 0/3 nodes are available.
```

→ The two workers lack free CPU (`requests.cpu` too high) and the control-plane node is tainted. Lower requests, add capacity, or add a toleration.

**Service returns no backends:**

```
$ kubectl get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS   AGE
web-abc12   IPv4          80      <unset>     3m       # empty = selector/label mismatch
```

→ The Service `selector` doesn't match the Pods' labels, or all Pods are `NotReady`. Cross-check `kubectl get pods --show-labels` against `kubectl get svc web -o yaml`.

### 9.4 Control-plane and node-level checks

```
# Is the kubelet healthy on a NotReady node?
$ systemctl status kubelet
$ journalctl -u kubelet -f --no-pager

# Is the CRI up? (list containers the runtime actually sees)
$ sudo crictl ps
$ sudo crictl images

# etcd health and quorum (from a control-plane node)
$ ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key endpoint health
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 3.1ms

# Raw API-server reachability, bypassing kubectl niceties
$ kubectl get --raw='/readyz?verbose'
[+]ping ok
[+]etcd ok
[+]poststarthook/start-kube-apiserver-admission-initializer ok
readyz check passed
```

### 9.5 Swarm-side verification

```
$ docker node ls                       # all managers Reachable, one Leader?
$ docker service ps web --no-trunc      # per-task error messages, un-truncated
$ docker service inspect web --pretty
$ docker service logs web
$ docker events --filter 'type=service' # live control-plane events
```

If tasks flap between `Ready` and `Shutdown`, read `docker service ps --no-trunc` for the *CURRENT STATE* error column (image pull failure, health-check failure, placement constraint with no matching node).

---

## 10. References

- LPI — Exam 305-300 Objectives (topic 352.4): https://www.lpi.org/our-certifications/exam-305-objectives/
- Kubernetes — Cluster Architecture: https://kubernetes.io/docs/concepts/architecture/
- Kubernetes — Control plane components: https://kubernetes.io/docs/concepts/overview/components/
- Kubernetes — Pods: https://kubernetes.io/docs/concepts/workloads/pods/
- Kubernetes — Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes — ReplicaSet: https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- Kubernetes — Service: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes — Labels and Selectors: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Kubernetes — Container Runtime Interface (CRI): https://kubernetes.io/docs/concepts/architecture/cri/
- Kubernetes — Dockershim removal FAQ: https://kubernetes.io/dockershim/
- CNI specification (CNCF): https://github.com/containernetworking/cni/blob/main/SPEC.md
- Kubernetes — Network Plugins (CNI): https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
- Container Storage Interface (CSI) spec: https://github.com/container-storage-interface/spec/blob/master/spec.md
- Kubernetes — kubelet: https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
- Kubernetes — kube-proxy / Service dataplane: https://kubernetes.io/docs/reference/networking/virtual-ips/
- etcd — operating documentation: https://etcd.io/docs/latest/op-guide/
- Docker — Swarm mode overview: https://docs.docker.com/engine/swarm/
- Docker — How swarm mode works (nodes, services, tasks): https://docs.docker.com/engine/swarm/how-swarm-mode-works/nodes/
- Docker — Deploy a stack to a swarm: https://docs.docker.com/engine/swarm/stack-deploy/
- Helm — Documentation: https://helm.sh/docs/
- Red Hat OpenShift — Documentation: https://docs.openshift.com/
- OKD — Community distribution: https://www.okd.io/
- Rancher (SUSE) — Documentation: https://ranchermanager.docs.rancher.com/