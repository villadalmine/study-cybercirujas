# 3.2 Scheduling

## What is scheduling?

**Scheduling** is the process by which Kubernetes decides on which **node** of the cluster a newly created **Pod** should run. The component responsible for this is the **kube-scheduler**, one of the control plane components.

It is important to understand that the scheduler **does not run** the Pods, it only decides *where* they should run. Once it makes the decision, it writes the name of the chosen node in the Pod's `spec.nodeName` field (via the API server). After that, the **kubelet** on the assigned node is the one that actually creates the containers.

The basic lifecycle is:
1. A Pod is created without `spec.nodeName` (it stays in `Pending` state).
2. The kube-scheduler detects the unassigned Pod (watch on the API server).
3. It selects the most suitable node through a two‑phase process: **filtering** and **scoring**.
4. It performs the *binding*: assigns the Pod to the chosen node.
5. The kubelet on that node takes the Pod and runs it.

```bash
kubectl get pods -o wide
# NAME       READY   STATUS    NODE
# my-pod     1/1     Running   worker-node-2
```

If a Pod remains in `Pending` for a long time, it usually means the scheduler could not find a node that meets the requirements:

```bash
kubectl describe pod my-pod
# Events:
#   Warning  FailedScheduling  0/3 nodes are available: 3 Insufficient cpu.
```

## The two phases of scheduling

### 1. Filtering (formerly called "predicates")

The scheduler discards all nodes that **cannot** run the Pod. Examples of filters:
- Does the node have enough free resources (CPU, memory)?
- Does the Pod have a `nodeSelector` or `nodeAffinity` that the node does not satisfy?
- Are there **taints** on the node that the Pod does not tolerate?
- Does the node have ports already in use that the Pod needs (`hostPort`)?
- Is the required volume available in the node's zone?

If no node passes the filter, the Pod stays in `Pending`.

### 2. Scoring (formerly called "priorities")

For the nodes that passed the filter, the scheduler assigns a score to each one based on criteria such as:
- Resource balancing (avoid concentrating load on few nodes).
- Pod affinity/anti‑affinity.
- Spreading across availability zones.

The node with the highest score is chosen for binding.

## Mechanisms to influence scheduling

### nodeSelector

The simplest way to restrict which nodes a Pod can run on, using labels.

```bash
kubectl label nodes worker-node-1 disktype=ssd
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx
  nodeSelector:
    disktype: ssd
```

### Node Affinity

A more expressive version of `nodeSelector`, with operators (`In`, `NotIn`, `Exists`, etc.) and two modes:
- `requiredDuringSchedulingIgnoredDuringExecution`: mandatory rule ("hard" equivalent).
- `preferredDuringSchedulingIgnoredDuringExecution`: preferred rule ("soft", the scheduler tries to satisfy it but is not blocking).

```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disktype
            operator: In
            values: ["ssd"]
```

### Pod Affinity / Anti-Affinity

Allows deciding the placement of a Pod in relation to **other Pods** (not nodes). Useful for:
- Co‑locating Pods that communicate heavily with each other (affinity), reducing latency.
- Separating replicas of the same application across different nodes or zones (anti‑affinity), improving resilience.

```yaml
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values: ["web"]
        topologyKey: "kubernetes.io/hostname"
```

This example prevents two Pods with label `app=web` from running on the same node.

### Taints and Tolerations

While `nodeAffinity` is a Pod property that "attracts" toward certain nodes, **taints** are a **node** property that "repels" Pods, unless those Pods declare an explicit **toleration**.

```bash
kubectl taint nodes worker-node-3 key=value:NoSchedule
```

Possible effects of a taint:
- `NoSchedule`: new Pods without toleration are not scheduled (existing ones are not affected).
- `PreferNoSchedule`: "soft" variant, the scheduler avoids the node if possible.
- `NoExecute`: besides not scheduling new Pods, it **evicts** existing Pods that do not tolerate the taint.

```yaml
spec:
  tolerations:
  - key: "key"
    operator: "Equal"
    value: "value"
    effect: "NoSchedule"
```

A very common use case: control‑plane nodes usually have a taint (`node-role.kubernetes.io/control-plane:NoSchedule`) so that application Pods are not scheduled there by default.

### Resource Requests and Limits

The scheduler uses the `resources.requests` field of each container to decide whether a node has enough capacity. The `limits`, on the other hand, are enforced by the kubelet/runtime at runtime, not by the scheduler.

```yaml
resources:
  requests:
    cpu: "250m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "256Mi"
```

If the sum of the `requests` of Pods already assigned to a node plus the new Pod's requests exceeds the node's allocatable capacity, that node is discarded in the filtering phase.

### nodeName (manual scheduling)

It is possible to bypass the scheduler entirely by specifying the node directly:

```yaml
spec:
  nodeName: worker-node-1
```

This is uncommon in production; it is mainly used for debugging or very specific cases.

### Pod Topology Spread Constraints

Allows distributing Pods evenly across "topology domains" (zones, regions, nodes), generalising what was previously achieved only with anti‑affinity.

```yaml
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: web
```

### Multiple Schedulers

Kubernetes allows running more than one scheduler simultaneously (the default `kube-scheduler` plus custom schedulers), and each Pod can choose which one will schedule it via `spec.schedulerName`.

```yaml
spec:
  schedulerName: my-custom-scheduler
```

## Descheduler

A related project (not part of the core, but a sub‑project of `kubernetes-sigs`) is the **Descheduler**, which evaluates already running Pods and evicts them (so that the scheduler can re‑place them) if conditions have changed — for example, if a node has become unbalanced or is violating an anti‑affinity rule that was added later.

## Summary of key concepts

| Mechanism | Acts on | Type of rule |
|---|---|---|
| `nodeSelector` | Pod → Node | Hard (simple) |
| `nodeAffinity` | Pod → Node | Hard or soft, expressive |
| `podAffinity`/`podAntiAffinity` | Pod → Pod | Hard or soft |
| Taints/Tolerations | Node repels Pods | `NoSchedule`, `PreferNoSchedule`, `NoExecute` |
| `resources.requests` | Node capacity | Mandatory filter |
| Topology Spread Constraints | Distribution across zones/nodes | Configurable (`DoNotSchedule` or `ScheduleAnyway`) |

## References

- CNCF KCNA Curriculum: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes Docs — Kubernetes Scheduler: https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/
- Kubernetes Docs — Assigning Pods to Nodes: https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Kubernetes Docs — Taints and Tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Kubernetes Docs — Pod Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes Docs — Scheduling Framework: https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/
- Kubernetes SIGs — Descheduler: https://github.com/kubernetes-sigs/descheduler