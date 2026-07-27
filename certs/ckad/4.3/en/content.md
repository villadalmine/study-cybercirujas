# 4.3 Understand requests, limits, quotas

## Introduction

In Kubernetes, managing compute resources (CPU and memory) is essential for maintaining a stable and predictable cluster. This topic covers three distinct yet interconnected mechanisms:

- **Requests and Limits**: Defined per container, determining reserved capacity and maximum consumption caps.
- **LimitRange**: A namespace-scoped object enforcing default values and valid request/limit ranges for Pods/Containers created within that namespace.
- **ResourceQuota**: A namespace-scoped object limiting aggregated resource consumption (CPU, memory, object counts, etc.) across that entire namespace.

Mastering how these three concepts interact is vital for the exam, as troubleshooting questions frequently combine them (e.g. Pods failing creation due to exceeded quota, or remaining in `Pending` state due to insufficient node capacity).

---

## Requests and Limits

### Concept

Each container within a Pod can declare, under `spec.containers[].resources`:

- **requests**: Amount of CPU/memory guaranteed by `kube-scheduler` on the node where the Pod is placed. `kube-scheduler` sums requests of all Pods on a node to verify it does not exceed the node's allocatable capacity.
- **limits**: Maximum consumption cap a container can reach. The `kubelet` (via container runtime) enforces this ceiling.

### Units

- **CPU** is measured in "cores". `1` equals 1 vCPU/physical/virtual core. Represented in millicores: `500m` = 0.5 core.
- **Memory** is measured in bytes, with binary suffixes such as `Mi` (mebibytes), `Gi` (gibibytes), `M`, `G`, etc. Standard practice recommends binary suffixes (`Mi`, `Gi`) matching Kubernetes internal representations.

### Behavior When Exceeding Limits

- **CPU**: A *compressible* resource. If a container attempts to use more CPU than its limit, the kernel *throttles* it (slows process execution), but does not terminate it.
- **Memory**: An *incompressible* resource. If a container exceeds its memory limit, the kernel terminates it with **OOMKilled** (`OOMKilled`, exit code 137).

### Manifest Example

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-resources
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

Apply and inspect:

```bash
kubectl apply -f demo-resources.yaml
kubectl describe pod demo-resources
```

Relevant snippet:

```
Containers:
  app:
    Image:      nginx:1.27
    Limits:
      cpu:     500m
      memory:  256Mi
    Requests:
      cpu:        250m
      memory:     128Mi
```

### Simulating an OOMKill Event

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: oom-demo
spec:
  containers:
  - name: stress
    image: polinux/stress
    resources:
      limits:
        memory: "50Mi"
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "200M", "--vm-hang", "1"]
```

```bash
kubectl get pod oom-demo -w
```

```
NAME       READY   STATUS      RESTARTS   AGE
oom-demo   0/1     OOMKilled   0          8s
oom-demo   0/1     CrashLoopBackOff   1     20s
```

```bash
kubectl describe pod oom-demo | grep -A5 "Last State"
```

```
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

### Quality of Service (QoS) Classes

Kubernetes assigns a QoS class to every Pod based on configured requests and limits, determining eviction priority when nodes experience resource pressure.

| Class | Condition | Eviction Priority |
|---|---|---|
| `Guaranteed` | Every container has `requests == limits` for both CPU **and** memory | Last to be evicted |
| `Burstable` | At least one container specifies requests, but does not meet `Guaranteed` criteria | Intermediate priority |
| `BestEffort` | No containers specify requests or limits | First to be evicted |

```bash
kubectl get pod demo-resources -o jsonpath='{.status.qosClass}'
```

```
Burstable
```

---

## LimitRange

### Concept

A `LimitRange` is a namespace-scoped resource that allows administrators to:

- Enforce **default** request/limit values for containers omitting explicit configurations.
- Impose **minimum and maximum** bounds per container (or Pod, PVC).
- Define a **maximum ratio** between limit and request (`maxLimitRequestRatio`).

If a Pod violates `LimitRange` restrictions (e.g. requesting below minimum or exceeding maximum), API server rejects creation at admission time.

### Example

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: cpu-mem-limit-range
  namespace: dev
spec:
  limits:
  - type: Container
    default:
      cpu: "500m"
      memory: "256Mi"
    defaultRequest:
      cpu: "250m"
      memory: "128Mi"
    min:
      cpu: "100m"
      memory: "64Mi"
    max:
      cpu: "1"
      memory: "512Mi"
    maxLimitRequestRatio:
      cpu: "4"
```

```bash
kubectl apply -f limitrange.yaml -n dev
kubectl describe limitrange cpu-mem-limit-range -n dev
```

```
Type        Resource  Min    Max    Default Request  Default Limit  Max Limit/Request Ratio
----        --------  ---    ---    ---------------  -------------  -----------------------
Container   cpu       100m   1      250m             500m           4
Container   memory    64Mi   512Mi  128Mi            256Mi          -
```

A Pod omitting `resources` receives default `requests`/`limits` automatically:

```bash
kubectl run test-pod --image=nginx -n dev
kubectl get pod test-pod -n dev -o jsonpath='{.spec.containers[0].resources}'
```

```
{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"250m","memory":"128Mi"}}
```

A Pod exceeding maximums is rejected:

```bash
kubectl run big-pod --image=nginx -n dev --requests=cpu=2 --limits=cpu=2
```

```
Error from server (Forbidden): pods "big-pod" is forbidden: maximum cpu usage per Container is 1, but limit is 2
```

---

## ResourceQuota

### Concept

A `ResourceQuota` limits **aggregated consumption** of resources inside a namespace: total sum of CPU/memory (requests and limits), maximum object count (Pods, Services, PVCs, ConfigMaps, Secrets, etc.), and supports scopes (e.g., matching specific `priorityClass`).

Important: If a namespace has an active `ResourceQuota` tracking `requests.cpu`, `requests.memory`, `limits.cpu`, or `limits.memory`, **every Pod created in that namespace must explicitly declare those resource fields** (or the namespace must feature a `LimitRange` providing defaults), otherwise Pod creation fails.

### Example: Compute Quota

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: dev
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "10"
```

```bash
kubectl apply -f resourcequota.yaml
kubectl describe resourcequota compute-quota -n dev
```

```
Name:            compute-quota
Namespace:       dev
Resource         Used   Hard
--------         ----   ----
limits.cpu       500m   4
limits.memory    256Mi  4Gi
pods             1      10
requests.cpu     250m   2
requests.memory  128Mi  2Gi
```

### Example: Object Count Quota

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: object-quota
  namespace: dev
spec:
  hard:
    configmaps: "10"
    secrets: "10"
    services: "5"
    persistentvolumeclaims: "4"
```

### Rejection for Exceeding Quota

```bash
kubectl run overquota --image=nginx -n dev --requests=cpu=3
```

```
Error from server (Forbidden): pods "overquota" is forbidden: exceeded quota: compute-quota, requested: requests.cpu=3, used: requests.cpu=250m, limited: requests.cpu=2
```

### Rejection for Missing Requests/Limits Under Active Quota

If `compute-quota` exists and a Pod is created without `resources` (and no `LimitRange` defaults exist):

```
Error from server (Forbidden): pods "no-resources" is forbidden: failed quota: compute-quota: must specify limits.cpu,limits.memory,requests.cpu,requests.memory
```

This explains why namespaces typically pair `LimitRange` (to inject default values) with `ResourceQuota` (to enforce upper cumulative caps).

---

## Interaction Between Requests, LimitRange, ResourceQuota, and Scheduler

1. A Pod is created omitting `resources`.
2. If a `LimitRange` exists, the `LimitRanger` admission controller injects defaults.
3. If a `ResourceQuota` exists, `ResourceQuota` admission controller verifies cumulative namespace consumption (including new Pod) does not exceed `hard` caps; if missing required requests/limits under active quota, it rejects the Pod.
4. If Pod passes admission, `kube-scheduler` searches for a node where **allocatable** capacity minus existing Pod requests satisfies new Pod requests. If no node qualifies, Pod remains in `Pending`.

```bash
kubectl get pod pending-pod
```

```
NAME          READY   STATUS    RESTARTS   AGE
pending-pod   0/1     Pending   0          30s
```

```bash
kubectl describe pod pending-pod | grep -A3 Events
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  30s   default-scheduler  0/3 nodes are available: 3 Insufficient cpu.
```

---

## Useful Exam Commands

```bash
# View configured requests/limits on a Pod
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].resources}'

# View actual vs allocatable capacity on a node
kubectl describe node <node> | grep -A5 "Allocated resources"

# View real-time consumption (requires metrics-server)
kubectl top pod
kubectl top node

# Set requests/limits on a Deployment imperatively
kubectl set resources deployment <name> --requests=cpu=200m,memory=256Mi --limits=cpu=500m,memory=512Mi

# List all ResourceQuotas and LimitRanges in a namespace
kubectl get resourcequota,limitrange -n dev
```

---

## References

- Resource Management for Pods and Containers: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Assign Memory Resources to Containers and Pods: https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/
- Assign CPU Resources to Containers and Pods: https://kubernetes.io/docs/tasks/configure-pod-container/assign-cpu-resource/
- Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-range/
- Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Configure Default Memory/CPU Requests and Limits for a Namespace: https://kubernetes.io/docs/tasks/administer-cluster/manage-resources/memory-default-namespace/
- Pod Quality of Service Classes: https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
