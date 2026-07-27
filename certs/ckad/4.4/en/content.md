# 4.4 — Define resource requirements

**Exam Weight: 3** · Domain: Application Environment, Configuration and Security

## Why Resources Matter

Kubernetes cannot know how much CPU or memory your application needs unless declared. **Resource requirements** are declared per container inside a Pod and serve two distinct roles:

- **`requests`**: The *guaranteed* amount the container needs. The **scheduler** uses this value to decide on which node to place the Pod. If no node has sufficient free capacity to satisfy `requests`, the Pod remains in `Pending` state.
- **`limits`**: The maximum upper cap the container can consume. Enforced by **kubelet** in coordination with container runtime.

Behavior when exceeding limits differs by resource:

| Resource | If Exceeding `limit` |
|---|---|
| `cpu` | **Throttling** is applied (slowed down, not killed) |
| `memory` | Container is terminated with **OOMKilled** (exit code 137) |
| `ephemeral-storage` | Pod is **evicted** from node |

## Units

**CPU** is measured in cores or *millicores*:

- `1` = 1 core (1 vCPU) · `500m` = 0.5 cores · `0.1` = `100m`
- Fractions smaller than `1m` do not exist.

**Memory** is measured in bytes using binary (`Ki`, `Mi`, `Gi`) or decimal (`K`, `M`, `G`) suffixes:

- `128Mi` = 128 × 2²⁰ bytes · `1Gi` = 1024 Mi

> ⚠️ Classic exam pitfall: writing `400m` for memory intending "400 Megabytes". `400m` of memory means **0.4 bytes**. For memory always use `Mi`, `Gi`, `M`, or `G`.

## Declaring Requests and Limits in a Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
  - name: app
    image: nginx:1.27
    resources:
      requests:
        cpu: 250m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi
```

Key points:

- Resources are defined **per container**, not per Pod. Effective Pod `requests` equal the sum across all its containers (including init containers, calculated separately: taking max between init requirement vs sum of standard containers).
- If you declare `limits` without `requests`, Kubernetes automatically assigns `requests = limits`.
- If you declare nothing, the container can consume all available node capacity, but becomes prime candidate for eviction under node memory pressure.

### Rapid Exam Generation

```bash
kubectl run app --image=nginx:1.27 \
  --dry-run=client -o yaml > pod.yaml
# edit and add resources block

# Or directly on an existing Deployment:
kubectl set resources deployment/web \
  --requests=cpu=250m,memory=128Mi \
  --limits=cpu=500m,memory=256Mi
```

`kubectl set resources` is one of the biggest time-savers on the exam: modifies Deployment live and triggers a rollout.

## QoS Classes (Quality of Service)

Based on how resources are declared, Kubernetes assigns the Pod a **QoS class** determining eviction order when node runs out of memory:

| Class | Condition | Eviction Priority |
|---|---|---|
| `Guaranteed` | Every container has `requests` = `limits` for CPU **and** memory | Last to be evicted |
| `Burstable` | At least one container specifies `requests` or `limits` (without meeting Guaranteed) | Intermediate priority |
| `BestEffort` | No container declares requests or limits | First to be evicted |

Verification:

```bash
kubectl get pod app -o jsonpath='{.status.qosClass}'
```
```
Burstable
```

## Troubleshooting: What Happens When Things Fail?

**Pod Not Scheduling** (requests exceed free capacity on all nodes):

```bash
kubectl describe pod app
```
```
Events:
  Warning  FailedScheduling  ...  0/3 nodes are available:
  3 Insufficient memory. preemption: 0/3 nodes are available...
```

**Container Exceeding Memory Limit:**

```bash
kubectl describe pod app
```
```
Last State:  Terminated
  Reason:    OOMKilled
  Exit Code: 137
```

**Viewing Actual Usage and Node Capacity:**

```bash
kubectl top pod app            # requires metrics-server
kubectl top node
kubectl describe node node01   # "Allocated resources" section
```
```
Allocated resources:
  Resource   Requests      Limits
  cpu        1150m (57%)   2 (100%)
  memory     980Mi (25%)   2Gi (54%)
```

## LimitRange: Namespace Defaults

A **LimitRange** defines default, minimum, and maximum values for containers within a namespace. If a Pod omits resources, admission controller injects defaults:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: dev
spec:
  limits:
  - type: Container
    default:            # default limit
      cpu: 500m
      memory: 256Mi
    defaultRequest:     # default request
      cpu: 100m
      memory: 128Mi
    max:
      cpu: "1"
      memory: 1Gi
```

If a Pod violates `max`/`min`, creation is **rejected** immediately (admission error, not Pending).

## ResourceQuota: Namespace Cumulative Cap

While LimitRange operates per container, **ResourceQuota** limits overall namespace consumption:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: dev
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
```

```bash
kubectl describe quota team-quota -n dev
```
```
Resource         Used   Hard
--------         ----   ----
limits.cpu       2      8
limits.memory    4Gi    16Gi
pods             5      20
requests.cpu     1      4
requests.memory  2Gi    8Gi
```

> Important: When a ResourceQuota exists on `requests`/`limits`, **every new Pod must declare those resources** (or inherit from LimitRange), otherwise creation is rejected.

## Exam Checklist

- `requests` → scheduling; `limits` → runtime enforcement.
- CPU exceeded = throttling; memory exceeded = `OOMKilled` (137).
- Memory always with `Mi`/`Gi`; never `m` suffix.
- `kubectl set resources` to edit Deployments rapidly.
- QoS: `requests = limits` across all → `Guaranteed`.
- `FailedScheduling: Insufficient cpu/memory` → lower requests or node capacity exhausted.
- LimitRange = per container (defaults/min/max); ResourceQuota = namespace cumulative total.

## References

- Resource Management for Pods and Containers — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Assign Memory Resources to Containers and Pods — https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/
- Assign CPU Resources to Containers and Pods — https://kubernetes.io/docs/tasks/configure-pod-container/assign-cpu-resource/
- Pod Quality of Service Classes — https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Limit Ranges — https://kubernetes.io/docs/concepts/policy/limit-range/
- Resource Quotas — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- CKAD Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
