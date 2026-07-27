# 3.5 Configure Pod Admission and Scheduling

## Overview

*Scheduling* in Kubernetes is the process by which the `kube-scheduler` determines which `Node` should execute a `Pod` lacking a specified `nodeName`. In contrast, Pod "admission" occurs within the `kube-apiserver` prior to object persistence in `etcd`: during admission, *admission controllers* validate, mutate, or reject Pod creation requests (e.g. enforcing `ResourceQuota` or `LimitRange` rules).

This topic combines both scheduling policies and admission controls: **resource requests/limits**, **node and pod affinity**, **taints/tolerations**, **topology spread constraints**, and **PriorityClass** definitions.

---

## 1. Resource Requests and Limits

Containers declare resource needs (`requests`, evaluated by schedulers during node assignment) and upper usage ceilings (`limits`, enforced by `kubelet`/`cgroups`).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-limitado
spec:
  containers:
  - name: app
    image: nginx:1.27
    resources:
      requests:
        cpu: "250m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "256Mi"
```

- Schedulers filter candidate nodes exclusively using `requests` (ignoring `limits`).
- Exceeding container memory `limits` triggers `OOMKilled` container terminations. Exceeding CPU `limits` results in CPU throttling rather than container eviction.
- Pods omitting memory `limits` face higher eviction risks during node resource pressure depending on QoS classification.

### Quality of Service (QoS) Classes

Kubernetes assigns QoS classes based on resource requests and limits:

| QoS Class | Criteria |
|---|---|
| `Guaranteed` | Every container specifies `requests == limits` for both CPU and memory |
| `Burstable` | At least one container specifies requests or limits without meeting `Guaranteed` criteria |
| `BestEffort` | No container specifies resource requests or limits |

```bash
kubectl get pod app-limitado -o jsonpath='{.status.qosClass}'
# Burstable
```

Under node memory pressure, `kubelet` evicts `BestEffort` Pods first, followed by `Burstable` Pods, preserving `Guaranteed` Pods last.

---

## 2. LimitRange

A `LimitRange` establishes default resource values and minimum/maximum boundaries **per namespace** for Pods or containers omitting explicit resource requests. The `LimitRanger` admission controller evaluates resources during object creation.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: limites-default
  namespace: equipo-a
spec:
  limits:
  - type: Container
    default:
      cpu: "500m"
      memory: "256Mi"
    defaultRequest:
      cpu: "250m"
      memory: "128Mi"
    max:
      cpu: "1"
      memory: "512Mi"
    min:
      cpu: "100m"
      memory: "64Mi"
```

```bash
kubectl apply -f limitrange.yaml
kubectl describe limitrange limites-default -n equipo-a
```

```
Type        Resource  Min   Max    Default Request  Default Limit
----        --------  ---   ---    ---------------  -------------
Container   cpu       100m  1      250m             500m
Container   memory    64Mi  512Mi  128Mi            256Mi
```

Creating Pods specifying resources exceeding `max` caps or below `min` thresholds results in API server rejection:

```
Error from server (Forbidden): error when creating "pod.yaml":
pods "app" is forbidden: maximum cpu usage per Container is 1, but limit is 2
```

---

## 3. ResourceQuota

While `LimitRange` applies per Pod/container, a `ResourceQuota` constrains **aggregate consumption** across an entire namespace (total CPU/memory, object counts for Pods, Services, PVCs, etc.).

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota-equipo-a
  namespace: equipo-a
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 4Gi
    limits.cpu: "8"
    limits.memory: 8Gi
    pods: "20"
    count/deployments.apps: "10"
```

```bash
kubectl apply -f resourcequota.yaml
kubectl describe resourcequota quota-equipo-a -n equipo-a
```

```
Name:            quota-equipo-a
Namespace:       equipo-a
Resource         Used  Hard
--------         ----  ----
limits.cpu       500m  8
limits.memory    256Mi 8Gi
pods             1     20
requests.cpu     250m  4
requests.memory  128Mi 4Gi
```

**Key Exam Rule**: If a namespace configures a `ResourceQuota` targeting `requests.cpu` or `requests.memory`, **every Pod created within that namespace must explicitly declare `requests` and `limits`** (or be rejected by admission controllers), unless a namespace `LimitRange` supplies defaults automatically.

---

## 4. nodeSelector

The simplest method to restrict Pod scheduling: Pods schedule exclusively onto nodes carrying **all** specified key-value labels.

```bash
kubectl label node worker-2 disk=ssd
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-ssd
spec:
  nodeSelector:
    disk: ssd
  containers:
  - name: app
    image: nginx:1.27
```

---

## 5. Node Affinity

Node affinity extends `nodeSelector` with expressive operators and enforcement modes:

- `requiredDuringSchedulingIgnoredDuringExecution`: Mandatory scheduling rule ("hard" requirement).
- `preferredDuringSchedulingIgnoredDuringExecution`: Weighted preference rule (weight 1–100; "soft" requirement evaluated by schedulers).

"IgnoredDuringExecution" indicates that modifying node labels post-scheduling does not evict running Pods.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-afinidad
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disk
            operator: In
            values: ["ssd"]
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 80
        preference:
          matchExpressions:
          - key: zone
            operator: In
            values: ["us-east-1a"]
  containers:
  - name: app
    image: nginx:1.27
```

Valid `matchExpressions` operators: `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`.

```bash
kubectl get pod app-afinidad -o wide
kubectl describe pod app-afinidad | grep -A5 Events
```

Unfulfilled `required` node affinity rules leave Pods in `Pending` status:

```
Warning  FailedScheduling  0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector.
```

---

## 6. Pod Affinity and Anti-Affinity

Pod affinity and anti-affinity schedule Pods relative to **other Pods running on candidate nodes** (or matching topology domains defined by `topologyKey`, such as `kubernetes.io/hostname` or `topology.kubernetes.io/zone`).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
  labels:
    app: web
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values: ["cache"]
        topologyKey: kubernetes.io/hostname
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
            - key: app
              operator: In
              values: ["web"]
          topologyKey: kubernetes.io/hostname
  containers:
  - name: web
    image: nginx:1.27
```

Use cases:
- **Pod affinity**: Co-locate application Pods alongside cache instances on identical nodes/zones to minimize network latency.
- **Pod anti-affinity**: Spread Deployment replicas across distinct nodes or availability zones to improve fault tolerance.

---

## 7. Taints and Tolerations

Taints are assigned to **nodes** to repel Pods, unless Pod specs configure matching **tolerations**. Taints repel Pods by default.

```bash
kubectl taint nodes worker-3 gpu=true:NoSchedule
kubectl describe node worker-3 | grep Taints
# Taints: gpu=true:NoSchedule
```

Taint effects:
- `NoSchedule`: Blocks new Pods lacking matching tolerations from scheduling onto the node; existing Pods remain unaffected.
- `PreferNoSchedule`: Schedulers attempt to avoid assigning Pods to the node, but rules are non-binding.
- `NoExecute`: Blocks new Pod scheduling and **evicts existing Pods** lacking matching tolerations (used by Kubernetes for automatic node conditions `node.kubernetes.io/not-ready` and `node.kubernetes.io/unreachable`).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-gpu
spec:
  tolerations:
  - key: "gpu"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
  containers:
  - name: app
    image: cuda-app:1.0
```

Tolerations using `tolerationSeconds` defer eviction when nodes transition to `NoExecute` taint states:

```yaml
tolerations:
- key: "node.kubernetes.io/not-ready"
  operator: "Exists"
  effect: "NoExecute"
  tolerationSeconds: 300
```

Remove node taints:

```bash
kubectl taint nodes worker-3 gpu=true:NoSchedule-
```

**Exam Note**: Taints and tolerations permit Pods to schedule onto tainted nodes, but **do not guarantee** placement on those nodes. Combine tolerations with `nodeAffinity` or `nodeSelector` to force node binding.

---

## 8. Topology Spread Constraints

Topology spread constraints distribute Pods evenly across topology domains (zones, nodes, regions) independent of affinity rules.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-spread
  labels:
    app: web
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: web
  containers:
  - name: web
    image: nginx:1.27
```

- `maxSkew`: Maximum allowed Pod count variance between topology domains.
- `whenUnsatisfiable`: Enforces mandatory (`DoNotSchedule`) or best-effort (`ScheduleAnyway`) distribution behavior.

---

## 9. PriorityClass and Preemption

PriorityClass resources assign relative priority rankings to Pods. Under resource deficits, schedulers **preempt (evict)** lower-priority Pods to schedule higher-priority Pods stuck in `Pending` states.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: alta-prioridad
value: 1000000
globalDefault: false
description: "High priority production workloads"
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-critica
spec:
  priorityClassName: alta-prioridad
  containers:
  - name: app
    image: nginx:1.27
```

```bash
kubectl get pod app-critica -o jsonpath='{.spec.priority}'
# 1000000
```

Setting `preemptionPolicy: Never` on a PriorityClass prevents Pods from evicting lower-priority workloads.

---

## 10. Key Admission Controllers

The `kube-apiserver` runs an admission controller pipeline enabled via `--enable-admission-plugins`:

```bash
# View enabled admission plugins on static control plane manifests
grep enable-admission-plugins /etc/kubernetes/manifests/kube-apiserver.yaml
```

- `LimitRanger`: Enforces namespace `LimitRange` defaults and bounds.
- `ResourceQuota`: Validates aggregate resource limits (evaluates at end of validation pipelines).
- `DefaultTolerationSeconds`: Configures 300s default tolerations for `not-ready` and `unreachable` node taints.

---

## Quick Reference Commands

```bash
# Inspect scheduling failure event details
kubectl describe pod <pod> | grep -A10 Events

# View taints across all cluster nodes
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# Display node labels
kubectl get nodes --show-labels

# Inspect namespace quotas and limit ranges
kubectl get resourcequota,limitrange -n <ns>

# View QoS class and assigned container resources
kubectl get pod <pod> -o jsonpath='{.status.qosClass}{"\n"}{.spec.containers[*].resources}'
```

---

## References

- Assigning Pods to Nodes (Affinity): https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Taints and Tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Managing Container Resources: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- LimitRange Overview: https://kubernetes.io/docs/concepts/policy/limit-range/
- ResourceQuota Overview: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Pod Priority and Preemption: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Pod Quality of Service Classes: https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Admission Controllers Reference: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
