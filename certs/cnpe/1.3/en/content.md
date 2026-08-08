# Optimizing Multi-Tenancy Resource Usage

> **CNPE Domain 1.3** — Platform engineering track. This module treats the cluster as a *shared substrate* that many independent teams draw from, and asks the harder question that follows: once you have isolated tenants, how do you make them *cheap* without making them *fragile*? Isolation and utilization pull in opposite directions; this is the engineering of that tension.

---

## 1. Motivation: the architectural problem

A multi-tenant platform exists to amortize fixed cost. Instead of every team running its own cluster — each with its own control plane, its own idle headroom, its own on-call — you consolidate onto a shared fleet and sell *slices* of it. The economic promise is **statistical multiplexing**: tenant A's peak rarely coincides with tenant B's peak, so the sum of their reservations can exceed the metal, and the platform pockets the difference.

That promise is also the whole problem. The moment you overcommit, three failure classes appear that a single-tenant cluster never sees:

- **The noisy neighbor.** A batch job in `team-analytics` saturates the memory bandwidth or the page cache on a node it shares with a latency-critical API in `team-payments`. CPU is *compressible* — the kernel throttles it via CFS quota and everyone limps along. Memory is *incompressible* — when a node runs out, the kernel OOM killer picks a victim, and QoS decides who dies. Getting this wrong means one tenant's cost optimization becomes another tenant's SLO breach.
- **The quota-vs-utilization gap.** Tenants reserve for their worst case and run at their average. On a real platform, cluster-wide `requests` sit at 40–60% of `allocatable` while *actual usage* sits at 15–25%. You are paying for capacity that is reserved-but-idle. Closing that gap is the entire game — but close it too far and the next section's failure modes fire.
- **The fairness/starvation axis.** Under contention, who wins? Without explicit priority and quota, the scheduler's answer is "whoever's pod arrived first," which is not a policy any platform team can defend to a paying tenant.

The **central trade-off** of this domain, stated once:

```
        high utilization  ◄──────────────────────────────►  strong isolation
        (dense bin-pack,      the platform engineer's         (spread, reserved
         overcommit, VPA)         dial lives here             headroom, no overcommit)
```

Every mechanism below — QoS, `ResourceQuota`, `LimitRange`, `PriorityClass`, scheduler scoring, VPA, the descheduler, overprovisioning pods — is a way of positioning that dial *per class of workload* rather than globally. The skill this domain tests is knowing which knob moves the dial in which direction, and by how much.

---

## 2. Technical comparisons and trade-offs

### 2.1 Tenancy isolation models

Resource optimization means something different at each isolation tier, because the shared fault domain is different.

| Model | Isolation boundary | Resource-sharing granularity | Bin-packing efficiency | Blast radius | Typical use |
|---|---|---|---|---|---|
| **Namespace (soft)** | RBAC + NetworkPolicy + Quota | Per-namespace `ResourceQuota` on a shared node pool | **Highest** — all tenants pack onto the same nodes | Kernel + node shared; a kernel CVE or node OOM hits all co-tenants | Internal teams, trusted tenants |
| **Node-pool pinning** | Taints/tolerations + `nodeSelector` per tenant | Dedicated nodes per tenant, shared control plane | Medium — stranded capacity inside each pool | Node-level isolation; control plane shared | Tenants with compliance or noisy-neighbor risk |
| **Virtual cluster (vcluster)** | Syncer + tenant API server in a pod | Tenant workloads still land on host nodes | High — host nodes are shared under the hood | Tenant API server isolated; host kernel shared | Many small tenants needing CRD/API isolation |
| **Cluster-per-tenant (hard)** | Separate cluster | None shared | **Lowest** — every cluster carries its own idle headroom + control-plane cost | Fully isolated | Regulatory hard walls, hostile tenants |

**Reading the table:** utilization is inversely proportional to isolation, and the cost of a control plane (managed: ~$70–150/mo each; self-run: 3 nodes of overhead) is what makes hard multi-tenancy expensive at scale. The platform-engineering default is **soft multi-tenancy with node-pool escape hatches**: pack everyone by default, pin the noisy or the regulated onto dedicated pools via taints.

### 2.2 Quality of Service (QoS) classes

QoS is derived, not declared — the kubelet computes it from `requests`/`limits` and it drives both eviction ranking and the kernel `oom_score_adj`.

| QoS class | How it is triggered | `oom_score_adj` | Eviction order under node pressure | CPU behavior | Use for |
|---|---|---|---|---|---|
| **Guaranteed** | `requests == limits` for **cpu and memory**, on **every** container | `-997` | Last | Pinned to a CFS quota; can be given exclusive cores via `static` CPU manager | Latency-critical, single-tenant-SLO workloads |
| **Burstable** | At least one request/limit set, but not Guaranteed | `2…999`, scaled by memory request | Middle — victims chosen among those *exceeding* requests | Can burst above request up to limit (or node capacity if no limit) | The default for most services |
| **BestEffort** | No requests or limits anywhere | `1000` | **First** | Uses whatever is left after everyone else | Truly interruptible batch only |

The Burstable `oom_score_adj` formula (kubelet) is worth memorizing — it is why a Burstable pod requesting *more* memory is *safer*:

```
oom_score_adj = 1000 - (1000 * memoryRequestBytes / machineMemoryCapacityBytes)
              clamped to the range [2, 999]
```

A pod requesting 90% of node memory gets `oom_score_adj ≈ 100` (survives); one requesting nothing tends toward `1000` (dies first). **Optimization consequence:** setting realistic memory requests is not just a scheduling hint — it is a survival ranking.

### 2.3 Guardrails: `ResourceQuota` vs `LimitRange`

These are constantly confused. They operate at different scopes and are complementary, not alternatives.

| Dimension | `ResourceQuota` | `LimitRange` |
|---|---|---|
| Scope | **Namespace aggregate** (sum across all pods) | **Per-object** (each container/pod/PVC) |
| Enforces | Total cpu/memory/storage, object *counts*, per-`PriorityClass` slices | Min, max, default request, default limit, max limit:request ratio |
| Failure mode | Pod rejected at admission if the *sum* would exceed | Pod rejected/mutated if a *single* container violates bounds |
| Key gotcha | If quota covers `requests.cpu`/`limits.memory`, **every** pod must set them | Supplies the defaults that let quota-covered pods be admitted at all |

The two are designed to be deployed **together**: `LimitRange` injects sane defaults so developers who forget to set requests don't get rejected by the quota, and `ResourceQuota` caps the tenant's aggregate. Deploy quota without a `LimitRange` and you break every un-annotated deployment in the namespace; deploy a `LimitRange` without quota and a tenant can still consume the whole cluster one small pod at a time.

### 2.4 Scheduler scoring: pack vs spread

The `NodeResourcesFit` plugin's `scoringStrategy` is the single biggest lever on cluster density.

| Strategy | Node score favors | Result | When to use |
|---|---|---|---|
| `LeastAllocated` (default) | Emptiest node | **Spread** — resilient, but many half-full nodes | Availability over cost; small clusters |
| `MostAllocated` | Fullest node that still fits | **Bin-pack** — fewer nodes, autoscaler can drain the rest | Cost optimization with a cluster autoscaler / Karpenter consolidation |
| `RequestedToCapacityRatio` | Custom utilization curve | Tunable pack/spread per resource | Heterogeneous nodes (e.g. pack GPUs hard, spread CPU) |

**The pairing that matters:** `MostAllocated` scoring is only a *cost win* if something removes the emptied nodes. On its own it just concentrates pods. Paired with Cluster Autoscaler `scale-down` or Karpenter `consolidation`, it lets the fleet shrink to fit real demand.

---

## 3. Complete manifests

### 3.1 Tenant namespace with quota + limits + priority

A production-grade tenant bootstrap. This is what a platform's onboarding automation applies per team.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-payments
  labels:
    tenant: payments
    pod-security.kubernetes.io/enforce: restricted
---
# Aggregate cap for the whole namespace.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: team-payments
spec:
  hard:
    requests.cpu: "32"
    requests.memory: 64Gi
    limits.cpu: "64"
    limits.memory: 128Gi
    pods: "150"
    count/deployments.apps: "40"
    persistentvolumeclaims: "20"
    requests.storage: 500Gi
---
# A SEPARATE quota that only counts high-priority pods, so a tenant
# cannot starve the cluster by marking everything critical.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: high-priority-slice
  namespace: team-payments
spec:
  hard:
    cpu: "16"
    memory: 32Gi
    pods: "30"
  scopeSelector:
    matchExpressions:
      - operator: In
        scopeName: PriorityClass
        values: ["payments-high"]
---
# Per-container defaults + bounds. Without this, the quotas above reject
# any pod that omits requests/limits.
apiVersion: v1
kind: LimitRange
metadata:
  name: container-defaults
  namespace: team-payments
spec:
  limits:
    - type: Container
      default:               # applied as limit if unset
        cpu: 500m
        memory: 512Mi
      defaultRequest:        # applied as request if unset
        cpu: 100m
        memory: 128Mi
      min:
        cpu: 50m
        memory: 64Mi
      max:
        cpu: "4"
        memory: 8Gi
      maxLimitRequestRatio:  # caps overcommit per container
        cpu: "4"
        memory: "2"
    - type: PersistentVolumeClaim
      min:
        storage: 1Gi
      max:
        storage: 100Gi
```

### 3.2 PriorityClasses for the fleet

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: payments-high
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "Latency-critical payment path. May preempt lower-priority pods."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: standard
value: 100000
globalDefault: true
preemptionPolicy: PreemptLowerPriority
description: "Default for all workloads that do not specify a class."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: batch-preemptible
value: 10000
globalDefault: false
preemptionPolicy: Never          # can be preempted, never preempts others
description: "Interruptible batch. Yields to everything above it."
```

### 3.3 Capacity reservation via overprovisioning ("balloon") pods

The idiom for absorbing scale-up latency: low-priority pause pods that hold real headroom and are instantly preempted when a genuine workload needs the room — which *also* signals the autoscaler to add a node ahead of demand.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: overprovisioning
value: -10                        # negative → below every real workload
globalDefault: false
description: "Placeholder headroom. First to be preempted."
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: overprovisioning
  namespace: platform-system
spec:
  replicas: 4
  selector:
    matchLabels: { app: overprovisioning }
  template:
    metadata:
      labels: { app: overprovisioning }
    spec:
      priorityClassName: overprovisioning
      terminationGracePeriodSeconds: 0     # evict instantly, no drain wait
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:                       # this is the reserved headroom
              cpu: "2"
              memory: 4Gi
            limits:
              cpu: "2"
              memory: 4Gi
```

### 3.4 Bin-packing scheduler profile

Applied to `kube-scheduler` via `--config`. Flips the fleet from spread to pack so the autoscaler can consolidate.

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
  - schedulerName: default-scheduler
    pluginConfig:
      - name: NodeResourcesFit
        args:
          scoringStrategy:
            type: MostAllocated
            resources:
              - name: cpu
                weight: 1
              - name: memory
                weight: 1
```

### 3.5 VerticalPodAutoscaler for right-sizing

VPA observes real usage and corrects the requests developers guessed at — the single most effective tool for closing the reserved-but-idle gap. Use `Off` mode first to *recommend* without disrupting, then graduate to `Auto`.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: checkout-api
  namespace: team-payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  updatePolicy:
    updateMode: "Auto"          # Off | Initial | Recreate | Auto
  resourcePolicy:
    containerPolicies:
      - containerName: '*'
        minAllowed:
          cpu: 100m
          memory: 128Mi
        maxAllowed:
          cpu: "4"
          memory: 8Gi
        controlledResources: ["cpu", "memory"]
```

> **Hard constraint:** do **not** run VPA and HPA on the *same* resource metric (both on CPU) for the same workload — they fight. Pattern: HPA on a custom/RPS metric, VPA on memory; or HPA on CPU, VPA in `Off`/recommendation mode only.

### 3.6 Descheduler for continuous rebalancing

The scheduler only decides placement at admission time. As nodes drain and pods churn, the packing degrades. The descheduler runs as a `CronJob` and evicts pods off hot/cold nodes so the scheduler can re-place them optimally.

```yaml
apiVersion: descheduler/v1alpha2
kind: DeschedulerPolicy
profiles:
  - name: rebalance
    pluginConfig:
      - name: LowNodeUtilization
        args:
          thresholds:            # nodes under this are "underutilized"
            cpu: 20
            memory: 20
            pods: 20
          targetThresholds:      # nodes over this are "overutilized"
            cpu: 70
            memory: 70
            pods: 70
    plugins:
      balance:
        enabled: ["LowNodeUtilization"]
```

---

## 4. CLI commands and terminal output

**Confirm derived QoS class per pod** (the fastest audit of eviction risk):

```console
$ kubectl get pods -n team-payments \
    -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass,PRIO:.spec.priorityClassName'
NAME                          QOS          PRIO
checkout-api-6b9c4f7d8-2xk4   Guaranteed   payments-high
ledger-worker-77f5c9-abcde    Burstable    standard
report-batch-29387461-qz7lp   BestEffort   batch-preemptible
```

**Inspect quota consumption** — the `Used / Hard` ratio is your utilization headroom:

```console
$ kubectl describe resourcequota compute-quota -n team-payments
Name:            compute-quota
Namespace:       team-payments
Resource         Used   Hard
--------         ----   ----
limits.cpu       22     64
limits.memory    46Gi   128Gi
pods             83     150
requests.cpu     14500m 32
requests.memory  29Gi   64Gi
requests.storage 180Gi  500Gi
```

**A quota rejection at admission** — note it fails *before* the pod is ever scheduled:

```console
$ kubectl apply -f big-deploy.yaml
Error from server (Forbidden): error when creating "big-deploy.yaml":
pods "analytics-xl" is forbidden: exceeded quota: compute-quota,
requested: requests.memory=48Gi, used: requests.memory=29Gi, limited: requests.memory=64Gi
```

**Node allocatable vs capacity** — the gap is what kube/system-reserved + eviction thresholds carve out; you schedule against *Allocatable*, never Capacity:

```console
$ kubectl describe node ip-10-0-3-14 | sed -n '/Capacity:/,/Allocated resources:/p'
Capacity:
  cpu:                16
  memory:             65014Mi
  pods:               110
Allocatable:
  cpu:                15890m
  memory:             62918Mi        # ~2Gi reserved for kubelet/system + eviction
  pods:               110
Allocated resources:
  Resource           Requests       Limits
  --------           --------       ------
  cpu                12100m (76%)   28 (176%)     # limits overcommitted 1.76x — expected
  memory             41200Mi (65%)  58Gi (94%)
```

**Watch preemption in action** — a `payments-high` pod evicting an overprovisioning pause pod:

```console
$ kubectl get events -n platform-system --field-selector reason=Preempted
LAST SEEN   TYPE      REASON      OBJECT                             MESSAGE
12s         Normal    Preempted   pod/overprovisioning-5d8c-nk29l    Preempted by team-payments/checkout-api-6b9c4f7d8-9wc2m on node ip-10-0-3-14
```

**Pull VPA recommendations** — the delta between `Target` and the deployed request is your right-sizing opportunity:

```console
$ kubectl describe vpa checkout-api -n team-payments | sed -n '/Recommendation/,/Events/p'
  Recommendation:
    Container Recommendations:
      Container Name:  checkout-api
      Lower Bound:
        Cpu:     180m
        Memory:  240Mi
      Target:
        Cpu:     250m
        Memory:  312Mi          # was requesting 500m/512Mi → ~40% reclaimable
      Upper Bound:
        Cpu:     410m
        Memory:  480Mi
```

**Confirm CPU throttling** (compressible-resource symptom — high latency, no restarts) directly from the cgroup:

```console
$ kubectl exec -n team-payments checkout-api-6b9c4f7d8-2xk4 -- \
    cat /sys/fs/cgroup/cpu.stat
usage_usec 84213330
nr_periods 512340
nr_throttled 48120           # ~9.4% of periods throttled → limit too low
throttled_usec 9123400
```

---

## 5. Verification and failure diagnosis

A decision tree for the incidents this domain produces, keyed by observable symptom.

### 5.1 Pod stuck `Pending`

```console
$ kubectl describe pod ledger-worker-77f5c9-xyz -n team-payments | grep -A4 Events
  Warning  FailedScheduling  38s  default-scheduler
    0/12 nodes are available: 4 Insufficient cpu, 8 node(s) had untolerated taint {tenant: analytics}.
```

- `Insufficient cpu/memory` → the **sum of requests** exceeds allocatable on every candidate node. Either the request is bloated (check VPA `Target`), the fleet needs a node (autoscaler), or `MostAllocated` scoring has packed too tight with no headroom pod.
- `untolerated taint` → tenant node-pool pinning is working as designed; the pod lacks the toleration.
- `exceeded quota` in the *pod* events (not the deployment) → replica set can't create pods; check `kubectl describe rs`.

### 5.2 Pod `OOMKilled` (incompressible-resource failure)

```console
$ kubectl get pod ledger-worker-77f5c9-abcde -n team-payments \
    -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
OOMKilled
```

Diagnosis order: (1) real leak vs under-provision — compare working-set to the memory *limit*; (2) QoS — a `BestEffort`/low-request Burstable pod is being chosen by the OOM killer even when *it* isn't the offender, because its `oom_score_adj` is high. **Fix by raising the memory request** (which lowers `oom_score_adj`), not just the limit. Memory is incompressible: there is no throttling equivalent, so the request is your only survival lever.

### 5.3 High latency, zero restarts (compressible-resource failure)

The signature of CPU throttling, not memory. Confirm via `cpu.stat` (§4) or the `container_cpu_cfs_throttled_periods_total` metric. **Fix:** raise the CPU *limit* (or remove it for Burstable and rely on requests for fair-share), never the request alone. This is the opposite prescription from OOM — knowing which resource you're contending on is the whole diagnosis.

### 5.4 Cluster is "full" but nodes look empty

The reserved-vs-used gap. `kubectl describe node` shows `requests` near 100% but `kubectl top node` shows 25% actual usage.

```console
$ kubectl top nodes
NAME           CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
ip-10-0-3-14   3820m        24%    21Gi            34%
```

Requests are oversized relative to reality. This is the primary target of §3.5 (VPA) and is where most platform cost is trapped. Verify the fix by re-checking `requests` shrink toward `top` after VPA `Auto` cycles the pods.

### 5.5 One tenant starves the cluster

If a tenant marks everything `payments-high` and preempts other tenants, the **per-PriorityClass scoped quota** (§3.1, `high-priority-slice`) is the containment. Verify it's biting:

```console
$ kubectl describe resourcequota high-priority-slice -n team-payments
Resource  Used   Hard
--------  ----   ----
cpu       16     16     # tenant has hit its high-priority ceiling
memory    30Gi   32Gi
pods      28     30
```

Once `Used == Hard` on the scoped quota, further high-priority pods are rejected at admission — the tenant can still schedule work, but only at `standard` priority, so cross-tenant preemption stops.

### 5.6 Verification checklist (run after any tenant onboarding)

1. `kubectl get resourcequota,limitrange -n <ns>` — both present.
2. `kubectl run probe --image=nginx -n <ns> --dry-run=server -o yaml` — LimitRange defaults are injected (proves quota won't reject un-annotated pods).
3. `kubectl get pods -n <ns> -o custom-columns=...qosClass` — no unintended `BestEffort` in latency-critical services.
4. `kubectl describe node` — `limits` may exceed 100% (overcommit is fine), `requests` should not exceed ~85% cluster-wide (leave headroom for reschedule during a node drain).
5. `kubectl get priorityclass` — the tenant's classes exist and the scoped quota caps the high tier.

---

## 6. References

- Kubernetes — *Resource Management for Pods and Containers* (requests, limits, cgroup mapping): https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes — *Pod Quality of Service Classes* (Guaranteed/Burstable/BestEffort, `oom_score_adj`): https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Kubernetes — *Resource Quotas* (aggregate limits, scopes, PriorityClass scoping): https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes — *Limit Ranges* (per-object defaults and bounds): https://kubernetes.io/docs/concepts/policy/limit-range/
- Kubernetes — *Pod Priority and Preemption*: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Kubernetes — *Node-pressure Eviction* (kubelet eviction thresholds, ranking): https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Kubernetes — *Reserve Compute Resources for System Daemons* (Allocatable formula): https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/
- Kubernetes — *Scheduler Configuration* (`NodeResourcesFit`, `MostAllocated`, `RequestedToCapacityRatio`): https://kubernetes.io/docs/reference/scheduling/config/
- Kubernetes — *Multi-tenancy* concept guide: https://kubernetes.io/docs/concepts/security/multi-tenancy/
- Kubernetes Autoscaler — *Vertical Pod Autoscaler*: https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- Kubernetes SIG Scheduling — *Descheduler*: https://github.com/kubernetes-sigs/descheduler
- Kubernetes SIG Multi-Tenancy — *Hierarchical Namespace Controller (HNC)*: https://github.com/kubernetes-sigs/hierarchical-namespaces
- Cluster Autoscaler — *Overprovisioning with placeholder pods* (FAQ): https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md#how-can-i-configure-overprovisioning-with-cluster-autoscaler
- OpenCost (CNCF) — cost allocation, showback/chargeback for shared clusters: https://www.opencost.io/docs/
- CNCF — *CNPE Curriculum*: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf