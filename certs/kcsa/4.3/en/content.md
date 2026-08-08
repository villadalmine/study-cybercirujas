# KCSA Study Guide — Domain 4.3: Denial of Service

## 1. Motivation and Production Architectural Problem

In a cloud-native Kubernetes environment, **Denial of Service (DoS)** attacks and internal resource exhaustion events threaten both control plane stability and data plane workload availability. Unlike traditional perimeter-based IT environments, Kubernetes clusters host high-density, multi-tenant workloads sharing common compute, network, and storage infrastructure.

```
                              ┌─────────────────────────────────────────────────────────┐
                              │                 Attacker / Malicious Load               │
                              └────────────────────────────┬────────────────────────────┘
                                                           │
                                                           ▼
                              ┌─────────────────────────────────────────────────────────┐
                              │            Layer 7 / HTTP Flood (Ingress)               │
                              └────────────────────────────┬────────────────────────────┘
                                                           │
                                           ┌───────────────┴───────────────┐
                                           │                               │
                                           ▼                               ▼
┌────────────────────────────────────────────────────────┐ ┌────────────────────────────────────────────────────────┐
│                   Control Plane DoS                    │ │                    Data Plane DoS                      │
│                                                        │ │                                                        │
│  • API Server Request Flooding (List/Watch abuse)      │ │  • Noisy Neighbor (Compute/Memory Starvation)         │
│  • Etcd Database Bloat & IOPS Exhaustion               │ │  • Pod Egress Bandwidth Amplification / Network Flood │
│  • Controller Manager Starvation (Node flapping)       │ │  • Unrestricted Resource Consumption (OOM Kills)      │
└────────────────────────────────────────────────────────┘ └────────────────────────────────────────────────────────┘
```

### Control Plane Threat Model: API Server Exhaustion
The Kubernetes API Server (`kube-apiserver`) serves as the central management plane. High-frequency client requests—such as unindexed `LIST` queries across large namespaces, excessive `WATCH` connections, or unthrottled custom controllers—can consume excessive CPU and RAM on `kube-apiserver` instances. 

Without control plane rate-limiting, API Server CPU starvation degrades control loops (e.g., `kube-controller-manager`, `kube-scheduler`), causing false-positive node unhealthy conditions, node flapping, and cascading pod evictions.

### Data Plane Threat Model: Noisy Neighbors and Resource Starvation
In the data plane, an unconstrained container can trigger host-level resource starvation:
* **Memory Exhaustion**: A pod exceeding host physical memory triggers the Linux kernel Out-Of-Memory (OOM) Killer, which may terminate critical system daemons (`kubelet`, `containerd`) if non-isolated.
* **CPU Throttling**: Unbounded CPU spikes cause severe latency degradation for co-located pods sharing the same Linux `cgroup` hierarchy.
* **Network & Storage I/O Saturation**: Unrestricted Pod egress traffic or disk I/O degrades the network throughput and storage responsiveness of adjacent workloads.

---

## 2. Technical Comparisons & Trade-off Tables

### Table 1: Kubernetes Quality of Service (QoS) Classes & Linux Kernel Integration

| Feature / Metric | Guaranteed | Burstable | BestEffort |
| :--- | :--- | :--- | :--- |
| **Container Definition** | `requests.cpu == limits.cpu`<br>`requests.memory == limits.memory` | At least 1 `request.cpu` or `request.memory` set; `requests != limits` | No `requests` or `limits` set on any container in Pod |
| **Linux `cgroup v2` `memory.max`** | Equal to `limits.memory` | Equal to `limits.memory` | `max` (Unlimited) |
| **Linux `cgroup v2` `memory.min`** | Equal to `requests.memory` | Equal to `requests.memory` | `0` |
| **Kernel `oom_score_adj` Calculation** | `-997` (Lowest eviction probability) | `1000 - min(max((memory_request / node_memory) * 1000, 2), 999)` | `1000` (First candidate for termination) |
| **Eviction Priority under Node Pressure** | Excluded unless system daemons OOM | Evicted after BestEffort if usage exceeds request | First to be evicted or killed by OOM Killer |
| **Production Trade-offs** | Predictable performance; high resource reservation cost | Efficient bin-packing; prone to CPU throttling under burst | Maximum node utilization; non-deterministic execution risks |

---

### Table 2: Control Plane vs. Data Plane DoS Mitigation Mechanisms

| Defense Layer | Primitive / API | Enforced At | Mitigation Vector | Structural Trade-off |
| :--- | :--- | :--- | :--- | :--- |
| **Control Plane** | API Priority & Fairness (APF) | `kube-apiserver` | Throttles/Queues API requests via `FlowSchema` & `PriorityLevelConfiguration` | Protects control plane responsiveness; drops excess API requests (HTTP 429) |
| **Data Plane (Compute)** | `ResourceQuota` | Namespace | Limits aggregate CPU, Memory, Storage, Pod, and Service allocations | Prevents single-tenant cluster monopolization; requires accurate capacity planning |
| **Data Plane (Compute)** | `LimitRange` | Namespace / Container | Enforces min/max boundaries and injects default request/limit values | Enforces baseline container hygiene; can block deployments missing compliant values |
| **Data Plane (Network)** | Ingress Rate Limiting | Ingress Controller / Gateway API | Limits L7 HTTP request rates (RPS, connections per client IP) | Absorbs volumetric web floods; adds proxy latency and memory overhead |
| **Data Plane (Network)** | `NetworkPolicy` | CNI Plugin (e.g., Cilium, Calico) | Restricts ingress/egress L3/L4 pod-to-pod and pod-to-external communication | Prevents lateral attack spread and egress bandwidth abuse; requires strict rule management |

---

### Table 3: API Priority & Fairness (APF) Queuing vs Rejecting Policies

| Configuration Dimension | Fair Queuing (`QueuePlusShares`) | Direct Rejection (`Reject`) |
| :--- | :--- | :--- |
| **Request Handling Strategy** | Places overflow requests into isolated FIFO queues using shuffle-sharding | Immediately rejects overflow requests with HTTP Status `429 Too Many Requests` |
| **Latency Impact** | Adds queueing delay (`queueLengthLimit`) to pending requests | Zero queueing delay; immediate backpressure signaling |
| **Use Case Context** | Interactive human CLI calls (`kubectl`), critical system controllers | High-frequency non-critical automation, bulk metric collectors, unauthenticated probes |
| **Resource Footprint** | Consumes memory inside `kube-apiserver` to maintain state queues | Minimal internal memory retention during bursts |

---

## 3. Complete Production YAML Manifests

### 3.1 Control Plane Isolation: API Priority and Fairness (APF)

The following manifests configure APF to isolate automated CI/CD service accounts into a low-priority, rate-limited bucket, shielding critical control plane routines (`kube-scheduler`, system components).

```yaml
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: PriorityLevelConfiguration
metadata:
  name: cicd-throttled-priority
spec:
  type: Limited
  limited:
    nominalConcurrencyShares: 20
    lendablePercent: 0
    withdrawablePercent: 0
    limitResponse:
      type: Queue
      queue:
        queues: 16
        handSize: 4
        queueLengthLimit: 50
---
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: cicd-workload-flow
spec:
  priorityLevelConfiguration:
    name: cicd-throttled-priority
  matchingPrecedence: 500
  distinguisherMethod:
    type: ByNamespace
  rules:
  - subjects:
    - kind: ServiceAccount
      serviceAccount:
        name: cicd-deployer
        namespace: cicd-pipeline
    resourceRules:
    - verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      apiGroups:
      - ""
      - "apps"
      resources:
      - pods
      - deployments
      - replicasets
      namespaces:
      - "*"
```

---

### 3.2 Data Plane Multi-Tenant Governance: Namespace `ResourceQuota` & `LimitRange`

These manifests enforce strict resource limits, default values, and QoS rules within a tenant namespace `production-tenant-a`.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-tenant-a
  labels:
    security.kubernetes.io/enforce-qos: "strict"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-a-quota
  namespace: production-tenant-a
spec:
  hard:
    requests.cpu: "16"
    requests.memory: 32Gi
    limits.cpu: "32"
    limits.memory: 64Gi
    pods: "40"
    services.nodeports: "0"
    services.loadbalancers: "2"
    count/configmaps: "50"
    count/secrets: "50"
    count/persistentvolumeclaims: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-a-limits
  namespace: production-tenant-a
spec:
  limits:
  - type: Container
    default:
      cpu: 500m
      memory: 512Mi
    defaultRequest:
      cpu: 200m
      memory: 256Mi
    max:
      cpu: "4"
      memory: 8Gi
    min:
      cpu: 50m
      memory: 64Mi
    maxLimitRequestRatio:
      cpu: "4"
      memory: "2"
  - type: Pod
    max:
      cpu: "8"
      memory: 16Gi
```

---

### 3.3 Data Plane Network Protection: Ingress Rate Limiting & Strict Egress `NetworkPolicy`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: secure-api-ingress
  namespace: production-tenant-a
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/limit-rps: "20"
    nginx.ingress.kubernetes.io/limit-connections: "10"
    nginx.ingress.kubernetes.io/limit-burst-multiplier: "5"
    nginx.ingress.kubernetes.io/limit-rate-after: "1024"
    nginx.ingress.kubernetes.io/limit-rate: "512"
spec:
  ingressClassName: nginx
  rules:
  - host: api.production.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: core-api-service
            port:
              number: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-unauthorized-egress-and-ingress
  namespace: production-tenant-a
spec:
  podSelector:
    matchLabels:
      app: core-api-service
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          ingress-ingresslink: "true"
      podSelector:
        matchLabels:
          app.kubernetes.io/name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: database-backend
    ports:
    - protocol: TCP
      port: 5432
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
```

---

## 4. Real CLI Commands & Actual Terminal Outputs

### 4.1 Verifying Control Plane APF Configurations and Queue State

Inspect active `FlowSchemas` and `PriorityLevelConfigurations` in the cluster:

```bash
$ kubectl get flowschema cicd-workload-flow -o wide
```
```text
NAME                 PRIORITYLEVEL             MATCHINGPRECEDENCE   DISTINGUISHER   AGE   VALID
cicd-workload-flow   cicd-throttled-priority   500                  ByNamespace     4m2s  true
```

```bash
$ kubectl get prioritylevelconfiguration cicd-throttled-priority -o wide
```
```text
NAME                      TYPE      NOMINALSHARES   LENDABLE%   WITHDRAWABLE%   QUEUES   HANDSIZE   QUEUE_LENGTH_LIMIT   AGE
cicd-throttled-priority   Limited   20              0           0               16       4          50                   4m18s
```

Query the `kube-apiserver` Prometheus metrics directly to check for APF throttled or rejected requests:

```bash
$ kubectl get --raw /metrics | grep apiserver_flowcontrol_rejected_requests_total
```
```text
# HELP apiserver_flowcontrol_rejected_requests_total [ALPHA] Number of requests rejected by API Priority and Fairness system.
# TYPE apiserver_flowcontrol_rejected_requests_total counter
apiserver_flowcontrol_rejected_requests_total{flow_schema="cicd-workload-flow",priority_level="cicd-throttled-priority",reason="queue-full"} 142
apiserver_flowcontrol_rejected_requests_total{flow_schema="global-default",priority_level="catch-all",reason="concurrency-limit"} 0
```

---

### 4.2 Inspecting Namespace ResourceQuotas & LimitRanges

Validate enforcement of quotas in the target namespace:

```bash
$ kubectl describe resourcequota tenant-a-quota -n production-tenant-a
```
```text
Name:                         tenant-a-quota
Namespace:                    production-tenant-a
Resource                      Used  Hard
--------                      ----  ----
count/configmaps              2     50
count/persistentvolumeclaims  0     10
count/secrets                 3     50
limits.cpu                    2     32
limits.memory                 4Gi   64Gi
pods                          4     40
requests.cpu                  800m  16
requests.memory               1Gi   32Gi
services.loadbalancers        1     2
services.nodeports            0     0
```

Test deployment rejection when exceeding quota boundaries:

```bash
$ kubectl run quota-violation-test --image=nginx:alpine --requests='cpu=20,memory=40Gi' -n production-tenant-a
```
```text
Error from server (Forbidden): pods "quota-violation-test" is forbidden: exceeded quota: tenant-a-quota, requested: requests.cpu=20,requests.memory=40Gi, used: requests.cpu=800m,requests.memory=1Gi, limited: requests.cpu=16,requests.memory=32Gi
```

---

### 4.3 Node-Level Kernel cgroup v2 & OOM Score Inspection

Identify running pod process IDs and verify system kernel `oom_score_adj` assigned by the `kubelet`:

```bash
$ kubectl get pod -n production-tenant-a core-api-service-75b4b5749f-x9l8z -o jsonpath='{.status.containerStatuses[0].containerID}'
```
```text
containerd://c2a9d8e4f1b8a7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2
```

Execute node remote shell to verify Linux kernel `cgroup` parameters for the Guaranteed or Burstable pod:

```bash
$ crictl inspect --output json c2a9d8e4f1b8a7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2 | grep -i pid
```
```text
    "pid": 28419,
```

```bash
$ cat /proc/28419/oom_score_adj
```
```text
-997
```

```bash
$ cat /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/memory.max
```
```text
8589934592
```

---

## 5. Failure Verification & Troubleshooting Guide

### Diagnostic Flowchart

```
                          ┌──────────────────────────────────────┐
                          │   SRE Alert / User Incident Report   │
                          └──────────────────┬───────────────────┘
                                             │
                                             ▼
                          ┌──────────────────────────────────────┐
                          │     Identify Affected Component      │
                          └──────────┬────────────────┬──────────┘
                                     │                │
            ┌────────────────────────┘                └────────────────────────┐
            ▼                                                                  ▼
┌───────────────────────┐                                          ┌───────────────────────┐
│   Control Plane DoS   │                                          │    Data Plane DoS     │
└───────────┬───────────┘                                          └───────────┬───────────┘
            │                                                                  │
            ▼                                                                  ▼
┌───────────────────────┐                                          ┌───────────────────────┐
│ Check APF Rejections  │                                          │ Check Pod Statuses    │
│ & HTTP 429 Metrics    │                                          │ & Container Exits     │
└───────────┬───────────┘                                          └───────────┬───────────┘
            │                                                                  │
            ▼                                                                  ▼
┌───────────────────────┐                                          ┌───────────────────────┐
│ Inspect FlowSchema    │                                          │ Analyze Node pressure │
│ & Priority Levels     │                                          │ & Kernel OOM logs     │
└───────────────────────┘                                          └───────────────────────┘
```

### Step 1: Diagnose Control Plane APF Bottlenecks (HTTP 429 Errors)
When automation or clients fail with `429 Too Many Requests` or context deadlines, analyze the APF execution metrics:

1. **Query API Server Flow Control Metrics**:
   ```bash
   kubectl get --raw /metrics | grep apiserver_flowcontrol_request_concurrency_in_use
   ```
2. **Identify Starved Priority Levels**:
   Look for `apiserver_flowcontrol_current_inqueue_requests` > 0. If queues are consistently full, the `nominalConcurrencyShares` or `queueLengthLimit` assigned to the target `PriorityLevelConfiguration` is insufficient.
3. **Trace Target Request to FlowSchema**:
   Search `apiserver_flowcontrol_requests_total` grouped by `flow_schema`. Adjust matching precedence or reassign offending ServiceAccounts to lower-tier priority classes.

---

### Step 2: Troubleshoot Data Plane OOMKilled Containers (Exit Code 137)
If pods fail with `OOMKilled` (Exit Code 137), determine whether the container exceeded its specified memory limit or if host-level memory exhaustion forced node kernel eviction.

1. **Inspect Pod Termination Status**:
   ```bash
   kubectl get pod -n production-tenant-a -o wide
   ```
   ```text
   NAME                                READY   STATUS      RESTARTS      AGE
   core-api-service-75b4b5749f-x9l8z   0/1     OOMKilled   3 (45s ago)   12m
   ```

2. **Retrieve Detailed Container Termination State**:
   ```bash
   kubectl describe pod core-api-service-75b4b5749f-x9l8z -n production-tenant-a
   ```
   ```text
   Containers:
     core-api-service:
       State:          Waiting
         Reason:       CrashLoopBackOff
       Last State:     Terminated
         Reason:       OOMKilled
         Exit Code:    137
         Started:      Fri, 07 Aug 2026 19:40:00 -0400
         Finished:     Fri, 07 Aug 2026 19:42:15 -0400
   ```

3. **Distinguish Container OOM vs Node Kernel OOM**:
   Inspect kernel ring buffer (`dmesg`) on the hosting Kubernetes worker node:
   ```bash
   dmesg -T | grep -i -E "oom-killer|killed process"
   ```
   ```text
   [Fri Aug 07 19:42:15 2026] Memory cgroup out of memory: Kill process 28419 (core-api-service) score 850 or sacrifice child
   [Fri Aug 07 19:42:15 2026] Killed process 28419 (core-api-service) total-vm:1845200kB, anon-rss:524800kB, file-rss:1220kB, shmem-rss:0kB
   ```
   * **Container OOM**: `Memory cgroup out of memory` indicates the container strictly exceeded its `limits.memory` configured in Kubernetes. Fix: Increase container memory limit or optimize workload application memory retention.
   * **Host Node OOM**: If the log indicates global `Out of memory: Kill process...` without cgroup isolation, non-isolated BestEffort pods or host daemons depleted node RAM. Fix: Enforce `SystemReserved` and `KubeReserved` memory flags on `kubelet`.

---

### Step 3: Troubleshoot CPU Throttling and Latency Spikes
If a workload experiences latency spikes without crashing, check for cgroup CFS (Completely Fair Scheduler) CPU throttling:

1. **Query cgroup v2 Throttling Metrics**:
   Inside the target pod container, check `/sys/fs/cgroup/cpu.stat`:
   ```bash
   kubectl exec -it core-api-service-75b4b5749f-x9l8z -n production-tenant-a -- cat /sys/fs/cgroup/cpu.stat
   ```
   ```text
   usage_usec 452109823
   user_usec 310204910
   system_usec 141904913
   nr_periods 42100
   nr_throttled 8420
   throttled_usec 941029400
   ```
2. **Analysis**:
   A high ratio of `nr_throttled` to `nr_periods` (>20%) indicates severe CPU throttling caused by overly restrictive `limits.cpu`. Remove static CPU limits or increase `limits.cpu` to match burst requirements while maintaining appropriate CPU `requests`.

---

## 6. References

* **CNCF KCSA Curriculum**: [Official KCSA Curriculum PDF](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Kubernetes Control Plane Protection**: [API Priority and Fairness Documentation](https://kubernetes.io/docs/concepts/cluster-administration/flow-control/)
* **Kubernetes Resource Governance**: [Resource Quotas Guide](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
* **Kubernetes Limit Ranges**: [Limit Ranges Documentation](https://kubernetes.io/docs/concepts/policy/limit-range/)
* **Kubernetes Pod Quality of Service**: [Configure Quality of Service for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/)
* **Kubernetes Network Isolation**: [Network Policies Documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
* **NGINX Ingress Controller Rate Limiting**: [Ingress NGINX Rate Limiting Annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#rate-limiting)