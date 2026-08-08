# Topic 1.1 — Applying Platform Architecture Best Practices for Networking, Storage, and Compute

**Domain 1: Platform Architecture · Exam weight: 5%**

---

## 1. The architectural problem: the platform is the substrate everyone else stands on

A platform engineering team does not ship a feature; it ships a **substrate** on which dozens of stream-aligned teams ship features. That inversion is the whole discipline. When an application team makes a wrong choice, one service degrades. When the platform team makes a wrong choice about the CNI dataplane, the StorageClass default, or the compute topology, **every** workload inherits it — and the decision is load-bearing under hundreds of Deployments before anyone notices it was wrong.

The three pillars in this topic — networking, storage, compute — are the three physical realities Kubernetes abstracts but never eliminates. The platform's job is to expose them as *golden paths*: opinionated, paved defaults that are correct for 90% of workloads, with documented escape hatches for the other 10%. The failure mode this topic guards against is the opposite of both extremes:

- **Under-abstraction** — every team writes its own `NetworkPolicy`, picks its own `StorageClass`, tunes its own resource requests. The platform is just raw Kubernetes with a wiki. Drift is guaranteed; the blast radius of a mistake is per-team; nothing is auditable centrally.
- **Over-abstraction** — the platform hides so much that the 10% of workloads with legitimate needs (a database that needs local NVMe, a latency-sensitive service that needs `ClusterFirst` DNS bypassed) cannot express them, and teams route around the platform entirely, which is worse than no platform.

The best-practice posture, per the CNCF Platforms White Paper, is **capabilities exposed through interfaces with sane defaults**. Networking, storage, and compute each become a *capability* the platform provides, versioned and observable, not a pile of primitives the tenant must assemble.

> **Architectural axiom for this topic:** every one of the three pillars is a decision about a **binding time** and a **blast radius**. Networking binds at pod-attach and Service-resolution time. Storage binds at PVC-provision time (`volumeBindingMode` literally names this). Compute binds at schedule time. Get the binding time wrong and you get the classic production incidents: a pod scheduled onto a node in a zone where its EBS volume cannot attach; a `ReadWriteOnce` volume that pins a StatefulSet replica to a dead node; a `Burstable` workload throttled into cascading latency because CPU limits were copied from a template.

---

## 2. Networking: the dataplane is a platform-wide decision

### 2.1 The CNI decision and why it is nearly irreversible

The CNI (Container Network Interface) plugin is chosen once, at cluster creation, and is *extraordinarily* expensive to change on a running cluster because it owns pod IP allocation and the packet path. This is the single most consequential networking decision the platform team makes.

The axis that matters in production is the **dataplane implementation**: `iptables`/`ipvs` (linear or hash rule chains in the kernel netfilter path) versus **eBPF** (programmable hooks that bypass much of the netfilter stack). At scale — thousands of Services, tens of thousands of endpoints — `iptables` rule evaluation and `kube-proxy` sync latency become a measurable tax; eBPF dataplanes (Cilium, Calico-eBPF) replace `kube-proxy` entirely and hold roughly O(1) lookup cost against Service count.

| Dimension | Calico (iptables/eBPF) | Cilium (eBPF) | AWS VPC CNI | Flannel (VXLAN) |
|---|---|---|---|---|
| Dataplane | iptables *or* eBPF | eBPF (native) | ENI / native VPC routing | VXLAN overlay |
| Pod IP model | Overlay (IPIP/VXLAN) or BGP native routing | Overlay (VXLAN/Geneve) or native routing | **Real VPC IPs** (routable) | Overlay |
| NetworkPolicy | Full (L3/L4) + Calico L7 | Full L3/L4 **+ L7 (HTTP/gRPC/Kafka)** via Envoy | Requires add-on (needs Calico or VPC-CNI policy agent) | **None** (needs add-on) |
| kube-proxy replacement | Yes (eBPF mode) | Yes | No | No |
| Observability | Flow logs | **Hubble** (L3–L7 flow visibility) | VPC Flow Logs (external) | Minimal |
| IP exhaustion risk | Low (own CIDR) | Low (own CIDR) | **High** — pods consume VPC subnet IPs | Low |
| Multi-cluster | Calico federation | **Cluster Mesh** | Transit Gateway (external) | None |
| Best fit | On-prem, BGP fabrics, portability | Zero-trust, L7 policy, mesh-lite, scale | AWS-native, needs real VPC IPs / SG-per-pod | Dev/simple, no policy needs |

**Platform guidance:** default to an **eBPF dataplane with a full NetworkPolicy engine and L7 observability** (Cilium or Calico-eBPF) for any multi-tenant platform, because (a) you will need default-deny network segmentation as a platform-enforced control, not a tenant opt-in, and (b) L3–L7 flow visibility (Hubble) is the difference between "some pod can't reach the database" being a 5-minute or a 5-hour incident. Reserve Flannel for throwaway/dev clusters — its lack of NetworkPolicy support disqualifies it from any tenant-isolation posture. Choose AWS VPC CNI only when you specifically need pods to hold routable VPC IPs or per-pod security groups, and budget for **subnet IP exhaustion** — the classic AWS-CNI production incident is `failed to assign an IP address to container` under node scale-up because the subnet ran dry.

### 2.2 Default-deny as a platform-enforced baseline

The platform, not the tenant, owns the *baseline* posture. Every tenant namespace should ship with a default-deny ingress-and-egress policy at provision time, so that connectivity is explicitly granted, never accidentally open. DNS must be explicitly re-allowed or the whole namespace breaks in a way that looks like a CNI bug.

```yaml
# platform-baseline/default-deny.yaml — applied by the platform to every tenant namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-payments        # templated per tenant at provision time
  labels:
    platform.example.com/managed-by: platform-team
    platform.example.com/baseline: "true"
spec:
  podSelector: {}                    # selects every pod in the namespace
  policyTypes:
    - Ingress
    - Egress
  # No ingress/egress rules => deny all in both directions
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: tenant-payments
  labels:
    platform.example.com/managed-by: platform-team
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

The tenant then layers their own *allow* policies on top. Because NetworkPolicies are additive (union of all matching allow rules), the platform baseline can never be weakened by a tenant — a critical property for multi-tenancy.

### 2.3 North-south: Gateway API is the platform-native ingress abstraction

`Ingress` is frozen; **Gateway API** (`gateway.networking.k8s.io`, GA since v1.0) is the successor and is explicitly designed for the platform/tenant split via **role-oriented resources**:

- `GatewayClass` — the **platform team** owns this (which controller/dataplane implements gateways).
- `Gateway` — the **cluster operator** owns this (listeners, ports, TLS termination).
- `HTTPRoute` — the **application team** owns this (routing rules), and can be delegated per-namespace.

This maps *exactly* onto the platform-engineering ownership boundary, which `Ingress` never expressed.

| | Ingress | Gateway API |
|---|---|---|
| Role separation | None (one resource, all concerns) | **GatewayClass / Gateway / *Route** — explicit personas |
| Protocols | HTTP(S) only (L7) | HTTP, HTTPS, TCP, UDP, TLS, gRPC |
| Cross-namespace routing | Annotation hacks | `ReferenceGrant` (explicit, auditable) |
| Traffic splitting / weights | Vendor annotations | Native `backendRefs` weights |
| Portability | Annotation-locked per controller | Portable core API, conformance-tested |
| Status quo | Frozen | Actively evolved (the future) |

```yaml
# Platform owns the class + gateway; tenants attach routes.
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: platform-external
spec:
  controllerName: cilium.io/gateway-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-external-gw
  namespace: platform-gateways
spec:
  gatewayClassName: platform-external
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.apps.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: wildcard-apps-example-com
      allowedRoutes:
        namespaces:
          from: Selector           # only namespaces the platform blesses may attach
          selector:
            matchLabels:
              platform.example.com/gateway-access: "external"
---
# Tenant-owned, in tenant-payments namespace, with canary split
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: payments-api
  namespace: tenant-payments
spec:
  parentRefs:
    - name: shared-external-gw
      namespace: platform-gateways
  hostnames:
    - "payments.apps.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1
      backendRefs:
        - name: payments-stable
          port: 8080
          weight: 90
        - name: payments-canary
          port: 8080
          weight: 10
```

---

## 3. Storage: the binding-time decision

### 3.1 CSI, StorageClass, and the two failure-prone knobs

All modern Kubernetes storage flows through **CSI** (Container Storage Interface). The platform's job is to curate a small set of `StorageClass`es — the golden paths for storage — and set exactly one as default. Two fields on the StorageClass cause the majority of production storage incidents:

- **`volumeBindingMode`** — `Immediate` provisions the volume the moment the PVC is created, *before* the pod is scheduled. On a zonal backend (EBS, GCE PD, Azure Disk) this is a landmine: the volume is created in zone A, then the scheduler places the pod in zone B, and the volume can never attach. The fix, and the platform default, is **`WaitForFirstConsumer`**, which delays provisioning until the scheduler has chosen a node, so the volume is created in the right topology.
- **`reclaimPolicy`** — `Delete` (destroy the backing volume when the PVC is deleted) versus `Retain` (keep it). For stateful data the platform default should be `Retain` on the data-tier class to survive an accidental `kubectl delete pvc`.

```yaml
# Golden-path StorageClass: topology-aware, expandable, retain-by-default for data
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-data
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer   # bind AFTER scheduling — topology-correct
allowVolumeExpansion: true                 # let PVCs grow without recreate
reclaimPolicy: Retain                      # data survives PVC deletion
parameters:
  type: gp3
  iops: "6000"
  throughput: "250"
  encrypted: "true"
  kmsKeyId: "arn:aws:kms:eu-west-1:111122223333:key/abcd-...."
---
# General-purpose default for stateless scratch: delete-on-release is fine here
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-general
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: gp3
  encrypted: "true"
```

### 3.2 Access modes drive the topology of the whole workload

| Access mode | Meaning | Backend examples | Consequence for architecture |
|---|---|---|---|
| `ReadWriteOnce` (RWO) | One **node** mounts read-write | Block: EBS, GCE PD, Azure Disk, local NVMe | Ties a replica to a node/zone; **StatefulSet, not Deployment** |
| `ReadWriteOncePod` (RWOP) | Exactly one **pod** mounts RW | CSI block (v1.27+) | Strong single-writer guarantee (leader-election-free databases) |
| `ReadWriteMany` (RWX) | Many nodes mount RW | File: EFS, Azure Files, CephFS, NFS | Enables scale-out shared filesystems; **higher latency** |
| `ReadOnlyMany` (ROX) | Many nodes mount RO | Content, config blobs | Fan-out of immutable assets |

The platform-architecture lesson: **the access mode is not a storage detail, it dictates the compute topology.** An RWO block volume forces a StatefulSet with per-replica volumes and anti-affinity; it can never be an RWX shared mount for a horizontally scaled Deployment. Teams that try to scale a Deployment with an RWO PVC hit `Multi-Attach error for volume` the moment a second replica lands on another node.

| Backend class | Latency | IOPS ceiling | Sharable (RWX) | Best fit |
|---|---|---|---|---|
| Local NVMe (`local` PV) | **Lowest** (µs) | **Highest** | No (RWO, node-pinned) | Kafka, Cassandra, high-IOPS DBs; app handles replication |
| Network block (EBS gp3/io2) | Low (ms) | High (tunable) | No (RWO/RWOP) | Postgres, MySQL, per-replica state |
| Network file (EFS/Filestore/CephFS) | Higher | Moderate | **Yes (RWX)** | Shared assets, CMS, ML datasets, scale-out reads |
| Object (S3 via CSI/mountpoint) | Highest (throughput-oriented) | N/A (throughput) | Yes | Data lakes, backups, immutable blobs |

### 3.3 StatefulSet with `volumeClaimTemplates` — the canonical stateful golden path

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pg
  namespace: tenant-payments
spec:
  serviceName: pg-headless
  replicas: 3
  podManagementPolicy: OrderedReady
  selector:
    matchLabels: { app: pg }
  template:
    metadata:
      labels: { app: pg }
    spec:
      # Spread replicas across zones so a zonal outage loses at most one
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app: pg }
      containers:
        - name: postgres
          image: postgres:16.4
          ports: [{ containerPort: 5432, name: pg }]
          resources:
            requests: { cpu: "1", memory: 2Gi }
            limits:   { memory: 2Gi }          # memory limit == request; NO cpu limit (see §4.2)
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "postgres"] }
            periodSeconds: 10
  volumeClaimTemplates:                          # one PVC per replica, bound at schedule time
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3-data               # the Retain + WaitForFirstConsumer class
        resources:
          requests:
            storage: 100Gi
```

### 3.4 Data protection is a platform capability, not a tenant chore

Snapshots are a first-class CSI resource. The platform should provide a `VolumeSnapshotClass` and a scheduled snapshot mechanism so tenants get point-in-time recovery for free.

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ebs-snapshots
driver: ebs.csi.aws.com
deletionPolicy: Retain
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: pg-data-0-pre-migration
  namespace: tenant-payments
spec:
  volumeSnapshotClassName: ebs-snapshots
  source:
    persistentVolumeClaimName: data-pg-0
```

---

## 4. Compute: scheduling, QoS, and the autoscaling stack

### 4.1 Requests, limits, and QoS classes — the most misunderstood knobs on the platform

The scheduler places pods on **requests**, never on limits or actual usage. `requests` is a *reservation* that subtracts from allocatable capacity; `limits` is an *enforcement ceiling*. The relationship between them assigns each pod a **QoS class**, which decides eviction order under node pressure:

| QoS class | Condition | Eviction priority | Use for |
|---|---|---|---|
| `Guaranteed` | requests == limits, for **both** cpu and memory, on every container | Evicted **last** | Databases, latency-critical singletons |
| `Burstable` | at least one request set, but not Guaranteed | Evicted **middle** | Most services |
| `BestEffort` | no requests/limits at all | Evicted **first** | Batch, throwaway |

### 4.2 The CPU-limit trap (a platform-wide anti-pattern)

The most damaging default a platform can ship is **cluster-wide CPU limits**. A CPU limit is enforced by CFS (Completely Fair Scheduler) quota throttling: once a container consumes its quota within the 100 ms period, it is **throttled** until the next period — even if the node has idle CPU. This manifests as p99 latency spikes and `container_cpu_cfs_throttled_periods_total` climbing, on a node that is 30% utilized. The best-practice consensus (and what the platform should encode in its `LimitRange` defaults) is:

- **Always set memory `requests == limits`** (memory is incompressible; OOM-kill is the only enforcement, so make the reservation truthful).
- **Set CPU `requests` (for scheduling/fair-share) but usually omit CPU `limits`** — let bursting use idle capacity; rely on requests for weighted fair-share under contention.

```yaml
# Platform-provided LimitRange: sane defaults so BestEffort pods can't happen by accident
apiVersion: v1
kind: LimitRange
metadata:
  name: platform-defaults
  namespace: tenant-payments
spec:
  limits:
    - type: Container
      default:               # applied as limit if none specified
        memory: 512Mi
      defaultRequest:        # applied as request if none specified
        cpu: 100m
        memory: 256Mi
      max:
        memory: 8Gi
      min:
        cpu: 10m
        memory: 16Mi
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-quota
  namespace: tenant-payments
spec:
  hard:
    requests.cpu: "50"
    requests.memory: 100Gi
    limits.memory: 100Gi
    persistentvolumeclaims: "20"
    requests.storage: 2Ti
```

### 4.3 The autoscaling stack: three independent loops

Autoscaling is **three orthogonal controllers**, and confusing them is a common architecture error:

| Controller | Axis | Scales | Signal | Conflict to avoid |
|---|---|---|---|---|
| **HPA** | Horizontal (pods) | replica count | CPU/mem/custom metrics | — |
| **VPA** | Vertical (pod size) | requests/limits | historical usage | **Never run VPA + HPA on the same CPU/mem metric** |
| **Cluster Autoscaler / Karpenter** | Nodes | node count/shape | unschedulable pods | — |

The clean composition: **HPA scales replicas → replicas become unschedulable → node autoscaler adds nodes.** VPA right-sizes requests for workloads HPA does *not* manage on the same metric.

### 4.4 Cluster Autoscaler vs Karpenter — the node-provisioning decision

| Dimension | Cluster Autoscaler | Karpenter |
|---|---|---|
| Model | Scales pre-defined node **groups** (ASGs/MIGs) | **Groupless** — provisions right-sized nodes just-in-time |
| Instance selection | Fixed per node group | Chooses instance type/size/zone per pending-pod shape |
| Scale-up latency | Minutes (ASG round-trip) | Seconds–low minutes (direct EC2 fleet) |
| Bin-packing | Limited (group granularity) | **Strong** — consolidates continuously |
| Spot/diversification | Manual per group | Native, dozens of types in one NodePool |
| Cost optimization | Coarse | **Consolidation** actively repacks & terminates underused nodes |
| Portability | Cloud-agnostic (many providers) | AWS-mature; other clouds emerging |

```yaml
# Karpenter v1: NodePool + EC2NodeClass — the platform's compute golden path
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general-purpose
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]     # prefer spot, fall back to on-demand
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h                       # recycle nodes weekly for patching
  limits:
    cpu: "1000"
    memory: 4000Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s                      # aggressively repack to cut cost
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2023
  role: "KarpenterNodeRole-prod"
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags: { karpenter.sh/discovery: "prod" }
  securityGroupSelectorTerms:
    - tags: { karpenter.sh/discovery: "prod" }
```

### 4.5 Topology spread and taints — placing compute correctly

```yaml
# Deployment fragment: spread across zones AND nodes for real HA
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule          # hard: never pile a zone
    labelSelector: { matchLabels: { app: payments } }
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway         # soft: prefer node spread
    labelSelector: { matchLabels: { app: payments } }
---
# Dedicated node pool for a noisy tenant, protected by a taint
# NodePool sets: taints: [{ key: dedicated, value: batch, effect: NoSchedule }]
tolerations:
  - key: dedicated
    operator: Equal
    value: batch
    effect: NoSchedule
nodeSelector:
  workload-class: batch
```

---

## 5. Verification and failure diagnosis

### 5.1 Networking

```bash
# Confirm the dataplane is actually eBPF and kube-proxy is replaced (Cilium)
$ kubectl -n kube-system exec ds/cilium -- cilium status | grep -E 'KubeProxy|Mode'
KubeProxyReplacement:    True   [eth0 10.0.12.31 (Direct Routing)]
Host Firewall:           Disabled
CNI Chaining:            none

# Test a NetworkPolicy is actually denying (expect timeout, not refused)
$ kubectl -n tenant-payments run probe --rm -it --image=nicolaka/netshoot --restart=Never \
    -- curl -m 3 http://billing.tenant-other.svc.cluster.local
curl: (28) Connection timed out after 3001 milliseconds
pod "probe" deleted

# Prove DNS still works after default-deny (the classic self-inflicted outage)
$ kubectl -n tenant-payments run probe --rm -it --image=nicolaka/netshoot --restart=Never \
    -- nslookup kubernetes.default
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local
Name:      kubernetes.default
Address 1: 10.96.0.1 kubernetes.default.svc.cluster.local

# Live L3-L7 flow view — which policy verdict hit which flow (Hubble)
$ hubble observe --namespace tenant-payments --verdict DROPPED --last 5
Jul 21 09:14:02.114  tenant-payments/api-7c...:53344  tenant-other/billing:8080  policy-verdict:none  DROPPED  TCP Flags: SYN
```

| Symptom | Likely cause | Confirm | Fix |
|---|---|---|---|
| Pods `ContainerCreating`, `failed to assign an IP` | CNI IP/subnet exhaustion (AWS VPC CNI) | `kubectl describe node` events; check subnet free IPs | Add subnet/CIDR, prefix delegation, or migrate CNI |
| Whole namespace loses all egress | default-deny with no DNS allow | `hubble observe --verdict DROPPED` shows :53 drops | Add `allow-dns-egress` policy |
| Service unreachable at scale, high latency | kube-proxy iptables sync lag | `kubectl -n kube-system logs ds/kube-proxy` sync durations | Move to eBPF/IPVS dataplane |

### 5.2 Storage

```bash
# The #1 stateful incident: PVC stuck Pending on WaitForFirstConsumer + unschedulable pod
$ kubectl get pvc -n tenant-payments data-pg-0
NAME        STATUS    VOLUME  CAPACITY  ACCESS MODES  STORAGECLASS  AGE
data-pg-0   Pending                                   gp3-data      3m

$ kubectl describe pvc -n tenant-payments data-pg-0 | tail -3
  Normal  WaitForFirstConsumer  3m   persistentvolume-controller
          waiting for first consumer to be created before binding
# => This is EXPECTED. The real problem is the POD is unschedulable. Look there:
$ kubectl describe pod -n tenant-payments pg-0 | grep -A3 Events
  Warning  FailedScheduling  2m  default-scheduler
    0/6 nodes are available: 3 node(s) had untolerated taint, 3 Insufficient cpu.

# Multi-Attach: an RWO volume being pulled to a second node (StatefulSet done wrong / node NotReady)
$ kubectl describe pod -n tenant-payments pg-1 | grep Multi-Attach
  Warning  FailedAttachVolume  1m  attachdetach-controller
    Multi-Attach error for volume "pvc-8a..": Volume is already exclusively attached to one node

# Verify expansion actually propagated to the filesystem
$ kubectl get pvc -n tenant-payments data-pg-0 -o jsonpath='{.status.capacity.storage}'
100Gi
```

| Symptom | Likely cause | Confirm | Fix |
|---|---|---|---|
| PVC `Pending`, pod `FailedScheduling` | Topology mismatch masked by `WaitForFirstConsumer` | describe the **pod**, not the PVC | Fix taints/requests so a node in the right zone is schedulable |
| `Multi-Attach error` | RWO volume, node NotReady, pod rescheduled before detach | `kubectl get nodes`; check attach-detach controller | Wait for detach / force-delete stuck volumeattachment; use `ReadWriteOncePod` |
| Data gone after `delete pvc` | `reclaimPolicy: Delete` on data class | `kubectl get sc gp3-data -o yaml` | Restore from `VolumeSnapshot`; set `Retain` on data classes |

### 5.3 Compute

```bash
# Detect CFS throttling — the invisible latency killer on an "idle" node
$ kubectl exec -n tenant-payments deploy/api -- \
    cat /sys/fs/cgroup/cpu.stat | grep throttled
nr_throttled 84213
throttled_usec 561230000        # 561s of throttling => remove the CPU limit

# Confirm QoS class of a critical pod
$ kubectl get pod -n tenant-payments pg-0 -o jsonpath='{.status.qosClass}{"\n"}'
Guaranteed

# Watch Karpenter provision a right-sized node for pending pods
$ kubectl logs -n kube-system deploy/karpenter -c controller | tail -2
{"level":"INFO","message":"found provisionable pod(s)","Pods":"tenant-payments/api-xxx","count":6}
{"level":"INFO","message":"launched nodeclaim","instance-type":"c7g.2xlarge","capacity-type":"spot","zone":"eu-west-1b"}

# Node pressure / eviction ordering check
$ kubectl get events -A --field-selector reason=Evicted -o wide | head
LAST SEEN  TYPE     REASON   OBJECT           MESSAGE
30s        Warning  Evicted  pod/batch-9d..   The node was low on resource: memory. BestEffort pods evicted first.
```

| Symptom | Likely cause | Confirm | Fix |
|---|---|---|---|
| p99 latency spikes on underutilized node | CPU limit → CFS throttling | `cpu.stat` `nr_throttled` climbing | Remove CPU limit; keep CPU request |
| Pods `Pending`, no scale-up | Node autoscaler can't fit requests / no matching NodePool | Karpenter/CA logs; pod requests vs NodePool limits | Widen `requirements` or raise NodePool `limits` |
| Critical pod OOM-killed first | Wrong QoS (Burstable/BestEffort) | `.status.qosClass` | Set memory `requests==limits` → Guaranteed |
| All replicas die in one AZ outage | No zone topology spread | `kubectl get pods -o wide` all one zone | `topologySpreadConstraints` with `topology.kubernetes.io/zone` |

---

## 6. References

- CNCF — *Cloud Native Platform Engineering* certification (CNPE) program page: https://www.cncf.io/training/certification/
- CNCF — *Platforms White Paper* (platform-as-product, capabilities & interfaces): https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Curriculum repository: https://github.com/cncf/curriculum
- Kubernetes — Cluster Networking concepts: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Gateway API (SIG-Network): https://gateway-api.sigs.k8s.io/
- Kubernetes — Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Kubernetes — Persistent Volumes & access modes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Kubernetes — Volume Snapshots (CSI): https://kubernetes.io/docs/concepts/storage/volume-snapshots/
- Container Storage Interface (CSI) spec: https://github.com/container-storage-interface/spec
- Kubernetes — Managing Resources & QoS classes: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/ and https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Kubernetes — Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Kubernetes — Pod Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Cluster Autoscaler: https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
- Karpenter: https://karpenter.sh/docs/
- Cilium & Hubble documentation: https://docs.cilium.io/
- Project Calico documentation: https://docs.tigera.io/calico/latest/about/