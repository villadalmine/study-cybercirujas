# CNCF KCSA Study Guide: Domain 4 – Threat Analysis | Topic 4.3: Denial of Service

## 1. Architectural Foundations & Threat Vectors

Kubernetes clusters operate as multi-tenant, distributed systems where shared hardware, network interfaces, and control plane endpoints create potential vectors for Denial of Service (DoS) attacks. A DoS condition in Kubernetes occurs when an attacker or misconfigured workload exhausts system resources—such as CPU cycles, RAM, PID tables, storage bandwidth, open socket file descriptors, or API Server worker threads—thereby degrading or crashing control plane components or neighboring workload pods.

```
+-----------------------------------------------------------------------------------+
|                            KUBERNETES ATTACK SURFACE                              |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  [ Ingress Traffic / L7 Flood ]                                                   |
|                |                                                                  |
|                v                                                                  |
|  +---------------------------+   Unthrottled API Calls   +---------------------+  |
|  | NGINX / Gateway Ingress   | ------------------------> | kube-apiserver      |  |
|  +---------------------------+                           +---------------------+  |
|                |                                                    |             |
|                v                                                    v             |
|  +---------------------------+                           +---------------------+  |
|  | Pod (Compute Exhaustion)  |                           | etcd Database       |  |
|  | cgroups: Memory/CPU/PIDs  |                           | Storage / I/O Sat.  |  |
|  +---------------------------+                           +---------------------+  |
|                |                                                                  |
|                v                                                                  |
|  +---------------------------+                                                    |
|  | Linux Kernel Node Level   |                                                    |
|  | OOM Eviction / Conntrack  |                                                    |
|  +---------------------------+                                                    |
+-----------------------------------------------------------------------------------+
```

### Primary Kubernetes DoS Vectors

1. **Compute & Memory Starvation (Noise Neighbor Effect):**
   Containers without explicitly defined resource requests and limits can consume unrestricted host CPU and RAM. Memory exhaustion forces the Linux Kernel Out-Of-Memory (OOM) killer to execute (`oom_score_adj`), terminating process trees. Unrestricted CPU usage leads to thread starvation across co-located pods.
2. **Process ID (PID) Fork Bombs:**
   A process inside a container can execute recursive fork calls (`fork()`), exhausting the node's PID space (`/proc/sys/kernel/pid_max`). When the host PID table saturates, the Kubelet, container runtime (`containerd`/`CRI-O`), and system daemons fail to execute new processes, causing node-wide instability.
3. **Ephemeral Storage & Log Flooding:**
   Workloads writing un-rotated logs to `stdout`/`stderr` or writing directly to the container root filesystem can fill host disk partitions (`/var/lib/docker` or `/var/lib/containerd`). Disk pressure triggers Kubelet eviction loops and corrupts local persistent storage.
4. **Control Plane API Server Exhaustion:**
   High-frequency un-indexed queries (`kubectl get pods -A` executed repeatedly by compromised service accounts or runaway controllers) degrade `kube-apiserver` CPU/RAM and overwhelm `etcd` disk I/O, disrupting state management cluster-wide.
5. **Network Layer Exhaustion & Connection Tracking Saturation:**
   Layer 4/Layer 7 floods saturate host Network Interface Cards (NICs) and fill the Netfilter connection tracking table (`nf_conntrack_max`). Saturation causes silent packet dropping for legitimate cluster communication.

---

### Official Reference Documentation
- [Kubernetes Resource Management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [API Priority and Fairness (APF)](https://kubernetes.io/docs/concepts/api-extension/apf/)
- [Node-pressure Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [Process ID Limits & Constraints](https://kubernetes.io/docs/concepts/policy/pid-limiter/)
- [Kubernetes Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

---

## 2. Exercise 1: Preventing Node & Container Compute Starvation

### Objective & Mechanics
Understand cgroups v2 resource boundaries, Kubelet eviction logic, and configure declarative safety nets (`LimitRange` and `ResourceQuota`) to isolate workloads.

```
                    cgroups v2 Kernel Enforcement Hierarchy
                    
                        [ Root /sys/fs/cgroup ]
                                   |
           +-----------------------+-----------------------+
           |                                               |
  [ kubepods.slice ]                              [ system.slice ]
           |                                     (Kubelet, containerd)
   +-------+-------+
   |               |
[ pod_UID1 ]    [ pod_UID2 ]
   |               |
[ container ]   [ container ]
  memory.max      memory.max
  cpu.max         cpu.max
  pids.max        pids.max
```

When a container exceeds its memory limit, Linux cgroups enforce termination via the OOM Killer. The Kubelet calculates `oom_score_adj` based on Quality of Service (QoS) classes:
- **Guaranteed:** `oom_score_adj = -997` (Highest protection)
- **Burstable:** `oom_score_adj = min(max(2, 1000 - (1000 * memory_requests) / node_memory), 999)`
- **BestEffort:** `oom_score_adj = 1000` (First to be terminated during host memory pressure)

---

### Step-by-Step Guided Exercise

#### Step 1: Create the Target Namespace and Define Base Enforcements
Execute the following command to create a isolated namespace for testing:

```bash
kubectl create namespace dos-mitigation-lab
```

*Expected Output:*
```text
namespace/dos-mitigation-lab created
```

#### Step 2: Apply Namespace-Wide `LimitRange` and `ResourceQuota`
Save the manifest below to `resource-controls.yaml` and apply it. This configuration enforces mandatory default limits for containers missing explicit resource definitions and restricts namespace aggregate consumption.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: dos-prevention-limits
  namespace: dos-mitigation-lab
spec:
  limits:
    - type: Container
      default:
        cpu: 250m
        memory: 256Mi
        ephemeral-storage: 500Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
        ephemeral-storage: 250Mi
      max:
        cpu: 1000m
        memory: 1Gi
        ephemeral-storage: 2Gi
      min:
        cpu: 50m
        memory: 64Mi
        ephemeral-storage: 100Mi
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: dos-prevention-quota
  namespace: dos-mitigation-lab
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "10"
    count/ephemeral-storage: 5Gi
```

Apply the manifest:

```bash
kubectl apply -f resource-controls.yaml
```

*Expected Output:*
```text
limitrange/dos-prevention-limits created
resourcequota/dos-prevention-quota created
```

#### Step 3: Deploy a Vulnerable Memory-Leaking Workload
Deploy a pod that allocates memory sequentially beyond its container boundary. Save to `memory-stress-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: memory-leak-simulator
  namespace: dos-mitigation-lab
  labels:
    app: memory-test
spec:
  containers:
    - name: stress
      image: vish/stress
      args:
        - "-mem-total"
        - "400MB"
        - "-mem-alloc-size"
        - "10MB"
        - "-mem-alloc-gap"
        - "500ms"
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 250m
          memory: 256Mi
```

Apply the pod manifest:

```bash
kubectl apply -f memory-stress-pod.yaml
```

*Expected Output:*
```text
pod/memory-leak-simulator created
```

#### Step 4: Inspect Diagnostic Logs and OOM Eviction Mechanics
Monitor the pod lifecycle as memory allocation reaches the 256Mi boundary:

```bash
kubectl get pod memory-leak-simulator -n dos-mitigation-lab --watch
```

*Expected Output:*
```text
NAME                     READY   STATUS    RESTARTS   AGE
memory-leak-simulator   1/1     Running   0          5s
memory-leak-simulator   0/1     OOMKilled 0          12s
memory-leak-simulator   1/1     Running   1 (2s ago) 14s
```

Inspect detailed status to observe container termination details:

```bash
kubectl describe pod memory-leak-simulator -n dos-mitigation-lab | grep -A 8 "Last State:"
```

*Expected Output:*
```text
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Fri, 07 Aug 2026 20:10:00 -0400
      Finished:     Fri, 07 Aug 2026 20:10:12 -0400
    Ready:          True
    Restart Count:  1
```

Verify `ResourceQuota` status consumption:

```bash
kubectl get resourcequota dos-prevention-quota -n dos-mitigation-lab -o yaml
```

*Expected Output:*
```text
status:
  hard:
    count/ephemeral-storage: 5Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "10"
    requests.cpu: "2"
    requests.memory: 2Gi
  used:
    count/ephemeral-storage: 0
    limits.cpu: 250m
    limits.memory: 256Mi
    pods: "1"
    requests.cpu: 100m
    requests.memory: 128Mi
```

---

### Check for Understanding: Exercise 1

1. **Question 1.1:** Why did the Linux kernel terminate the container with Exit Code 137 rather than letting the host operating system allocate swap memory when the container reached 256Mi memory usage?
2. **Question 1.2:** If a container definition in namespace `dos-mitigation-lab` omits `resources.requests` and `resources.limits`, what Quality of Service (QoS) class will it receive, and what will its `oom_score_adj` be?
3. **Question 1.3:** How does configuring `LimitRange` protect the Kubernetes control plane against pod deployment Denial of Service attacks?

---

## 3. Exercise 2: Safeguards Against API Server Starvation via API Priority & Fairness (APF)

### Objective & Mechanics
Understand API Server Priority & Fairness (APF), configure custom `FlowSchema` and `PriorityLevelConfiguration` objects, and mitigate control plane resource saturation caused by automated service account requests.

```
                             API PRIORITY & FAIRNESS (APF)
                             
 Incoming Requests ---> [ Authentication & Authorization ]
                                      |
                                      v
                            [ FlowSchema Matching ]
                                      |
                                      v
                        [ PriorityLevelConfiguration ]
                                      |
               +----------------------+----------------------+
               |                                             |
   [ Concurrency Seats Available ]                [ Concurrency Exhausted ]
               |                                             |
               v                                             v
     [ Execute in apiserver ]                     [ Fair Queuing Engine ]
                                                 (Shuffle Sharding: Queues)
                                                             |
                                            +----------------+----------------+
                                            |                                 |
                                    [ Seat Becomes Available ]      [ Queue Full / Timeout ]
                                            |                                 |
                                            v                                 v
                                    [ Dispatch Request ]              [ HTTP 429 Rejected ]
```

APF replaces old global max-in-flight limits with explicit concurrency management:
- **FlowSchema:** Classifies incoming HTTP requests based on attributes (User, ServiceAccount, Verb, Resource, Namespace) and maps them to a Priority Level.
- **PriorityLevelConfiguration:** Defines concurrency shares (`nominalConcurrencyShares`), queue parameters (`queues`, `handSize`, `queueLengthLimit`), and throttling policies (`Queue` vs `Reject`).

---

### Step-by-Step Guided Exercise

#### Step 1: Inspect Cluster Default APF Configurations
Query the existing `FlowSchema` and `PriorityLevelConfiguration` definitions active in the cluster:

```bash
kubectl get flowschemas.flowcontrol.apiserver.k8s.io
```

*Expected Output:*
```text
NAME                        PRIORITYLEVEL     MATCHINGPRECEDENCE   DISTINGUISHERMETHOD   AGE
exempt                      exempt            1                    <none>                45d
probes                      exempt            2                    <none>                45d
system-leader-election      leader-election   100                  ByUser                45d
workload-high               workload-high     400                  ByNamespace           45d
global-default              global-default    9999                 ByUser                45d
```

#### Step 2: Create a Constrained Priority Level for Automated Service Accounts
Deploy a `PriorityLevelConfiguration` that throttles batch processes to a strict concurrency bucket. Save to `apf-priority-level.yaml`:

```yaml
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: PriorityLevelConfiguration
metadata:
  name: restricted-batch-priority
spec:
  type: Limited
  limited:
    nominalConcurrencyShares: 5
    lendablePercent: 0
    limitResponse:
      type: Queue
      queue:
        queues: 8
        handSize: 2
        queueLengthLimit: 10
```

Apply the PriorityLevelConfiguration:

```bash
kubectl apply -f apf-priority-level.yaml
```

*Expected Output:*
```text
prioritylevelconfiguration.flowcontrol.apiserver.k8s.io/restricted-batch-priority created
```

#### Step 3: Define a FlowSchema Mapping Service Account Requests
Create a `FlowSchema` targeting a specific automation ServiceAccount (`batch-automation-sa`). Save to `apf-flow-schema.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: batch-automation-sa
  namespace: dos-mitigation-lab
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: batch-automation-binding
subjects:
  - kind: ServiceAccount
    name: batch-automation-sa
    namespace: dos-mitigation-lab
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: isolate-batch-automation
spec:
  priorityLevelConfiguration:
    name: restricted-batch-priority
  matchingPrecedence: 500
  distinguisherMethod:
    type: ByUser
  rules:
    - resourceRules:
        - apiGroups: ["*"]
          resources: ["*"]
          verbs: ["*"]
      subjects:
        - kind: ServiceAccount
          serviceAccount:
            name: batch-automation-sa
            namespace: dos-mitigation-lab
```

Apply the manifest:

```bash
kubectl apply -f apf-flow-schema.yaml
```

*Expected Output:*
```text
serviceaccount/batch-automation-sa created
clusterrolebinding.rbac.authorization.k8s.io/batch-automation-binding created
flowschema.flowcontrol.apiserver.k8s.io/isolate-batch-automation created
```

#### Step 4: Verify APF Matching and Metrics Endpoint
Generate a bearer token for `batch-automation-sa` and query API Server metrics to confirm flow classification:

```bash
kubectl get flowschema isolate-batch-automation -o yaml | grep -A 5 "status:"
```

*Expected Output:*
```text
status:
  conditions:
  - lastTransitionTime: "2026-08-07T20:12:00Z"
    message: This FlowSchema references the PriorityLevelConfiguration object "restricted-batch-priority"
      and it exists
    reason: PriorityLevelConfigurationFound
    status: "True"
    type: Dangling
```

Query the API Server raw metrics to inspect rejected or queued requests under this priority level:

```bash
kubectl get --raw /metrics | grep 'apiserver_flowcontrol_rejected_requests_total{priority_level="restricted-batch-priority"}'
```

*Expected Output:*
```text
# HELP apiserver_flowcontrol_rejected_requests_total [ALPHA] Number of requests rejected by API Priority and Fairness system.
# TYPE apiserver_flowcontrol_rejected_requests_total counter
apiserver_flowcontrol_rejected_requests_total{reason="queue-full",priority_level="restricted-batch-priority"} 0
```

---

### Check for Understanding: Exercise 2

1. **Question 2.1:** What HTTP status code does `kube-apiserver` return to a client when APF rejects a request due to a saturated queue (`queue-full`) in a `PriorityLevelConfiguration`?
2. **Question 2.2:** What is the technical function of **Shuffle Sharding** (`handSize` and `queues`) inside a `PriorityLevelConfiguration` queue definition during a high-volume DoS attempt?
3. **Question 2.3:** If two `FlowSchema` objects match the same incoming request, how does `kube-apiserver` determine which `FlowSchema` takes precedence?

---

## 4. Exercise 3: Network & Ingress Layer DoS Defenses

### Objective & Mechanics
Mitigate Layer 7 HTTP floods and Layer 4 cluster lateral expansion using Ingress rate limiting (leaky bucket algorithm) and zero-trust `NetworkPolicy` perimeter rules.

```
                           INGRESS & NETWORK DEFENSE
                           
 [ External Traffic / Attacker ]
                |
                v
  +-----------------------------------------------------------+
  | NGINX Ingress Controller                                  |
  | Annotation Enforcement:                                   |
  |   - limit-rps: "5"      ==> Leaky Bucket Rate Limiter    |
  |   - limit-connections: "10"                              |
  +-----------------------------------------------------------+
                |
       (Allowed Traffic Only)
                |
                v
  +-----------------------------------------------------------+
  | Pod Network Boundary (NetworkPolicy)                      |
  | Ingress Rule: Allow ONLY from 'ingress-nginx' namespace   |
  | Egress Rule:  Allow ONLY UDP 53 to 'kube-system' (DNS)    |
  +-----------------------------------------------------------+
                |
                v
   [ Target Application Pod ]
```

Ingress Controllers enforce HTTP rate limiting via NGINX memory zones using the leaky bucket algorithm. Excess requests above configured limits are rejected instantly, protecting downstream pod application threads from web-layer saturation.

---

### Step-by-Step Guided Exercise

#### Step 1: Deploy Target Backend Workload
Create a target HTTP backend service. Save to `target-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: target-web-app
  namespace: dos-mitigation-lab
  labels:
    app: target-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: target-app
  template:
    metadata:
      labels:
        app: target-app
    spec:
      containers:
        - name: web
          image: hashicorp/http-echo
          args:
            - "-text=Production Application Ready"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: target-app-service
  namespace: dos-mitigation-lab
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 5678
      protocol: TCP
  selector:
    app: target-app
```

Apply the backend deployment:

```bash
kubectl apply -f target-app.yaml
```

*Expected Output:*
```text
deployment.apps/target-web-app created
service/target-app-service created
```

#### Step 2: Implement Ingress Resource with Rate Limiting Annotations
Create an Ingress resource enforcing strict rate limits per client IP. Save to `protected-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: protected-app-ingress
  namespace: dos-mitigation-lab
  annotations:
    nginx.ingress.kubernetes.io/limit-rps: "5"
    nginx.ingress.kubernetes.io/limit-connections: "10"
    nginx.ingress.kubernetes.io/limit-burst-multiplier: "2"
spec:
  ingressClassName: nginx
  rules:
    - host: app.dos-lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: target-app-service
                port:
                  number: 80
```

Apply the Ingress manifest:

```bash
kubectl apply -f protected-ingress.yaml
```

*Expected Output:*
```text
ingress.networking.k8s.io/protected-app-ingress created
```

#### Step 3: Configure Strict Zero-Trust NetworkPolicy
Isolate `target-app` pods so they reject direct container-to-container connections and allow ingress *only* from the `ingress-nginx` namespace. Save to `network-policy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-target-app
  namespace: dos-mitigation-lab
spec:
  podSelector:
    matchLabels:
      app: target-app
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 5678
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
```

Apply the NetworkPolicy:

```bash
kubectl apply -f network-policy.yaml
```

*Expected Output:*
```text
networkpolicy.networking.k8s.io/isolate-target-app created
```

#### Step 4: Simulate Layer 7 HTTP Load Flood & Verify Throttling
Simulate an automated HTTP request burst against the ingress endpoint:

```bash
kubectl run load-tester --image=curlimages/curl --rm -it --restart=Never -n dos-mitigation-lab -- \
  sh -c 'for i in $(seq 1 15); do curl -s -o /dev/null -w "%{http_code}\n" http://target-app-service.dos-mitigation-lab.svc.cluster.local; done'
```

*Expected Output (Simulating direct unthrottled internal service bypass prevented by NetworkPolicy / ingress verification):*
```text
503
503
503
...
```

Now execute the request through the rate-limited Ingress endpoint:

```bash
kubectl run ingress-tester --image=curlimages/curl --rm -it --restart=Never -n dos-mitigation-lab -- \
  sh -c 'for i in $(seq 1 15); do curl -s -o /dev/null -w "%{http_code}\n" -H "Host: app.dos-lab.local" http://ingress-nginx-controller.ingress-nginx.svc.cluster.local; done'
```

*Expected Output:*
```text
200
200
200
200
200
503
503
503
503
503
503
503
503
503
503
```
*(Note: 503 Service Temporarily Unavailable or 429 Too Many Requests is generated by NGINX rate-limiting engine when burst thresholds are exceeded).*

---

### Check for Understanding: Exercise 3

1. **Question 3.1:** How does `nginx.ingress.kubernetes.io/limit-rps` calculate request rates across a cluster running multiple distributed NGINX Ingress Controller pod replicas?
2. **Question 3.2:** If an attacker bypasses the Ingress controller and attempts a direct TCP SYN flood attack against pod IP addresses inside the overlay network, how does the applied `NetworkPolicy` stop the attack at the Linux kernel layer?
3. **Question 3.3:** Why is setting an `egress` restriction in `NetworkPolicy` considered an effective defense against Denial of Service reflection/amplification attacks originating from compromised pods?

---

<details>
<summary><b>Click to Expand: Answers & Detailed Explanations</b></summary>

### Exercise 1 Answers

* **Answer 1.1:**
  Linux cgroups enforce hard memory limits (`memory.max` in cgroups v2). When a container process attempts to allocate memory beyond its configured limit, kernel space memory allocation fails. If the process cannot release memory, the Linux kernel OOM Killer is invoked to immediately terminate the process tree within that cgroup, returning Exit Code 137 (`128 + SIGKILL (9)`). By default, Kubernetes disables swap on nodes (or isolates cgroups from node swap) to maintain deterministic performance and prevent severe disk I/O thrashing.

* **Answer 1.2:**
  If a container specifies no explicit requests or limits, Kubernetes assigns it the **BestEffort** Quality of Service (QoS) class. BestEffort pods receive an `oom_score_adj` value of **1000**. Under host memory pressure, the Linux Kernel OOM killer selects processes with the highest `oom_score_adj` first, making BestEffort containers the primary candidates for eviction and termination.

* **Answer 1.3:**
  `LimitRange` injects default resource requests and limits into pod manifests created without them. Without a `LimitRange`, unconfigured pods can consume arbitrary node resources. Additionally, `LimitRange` sets minimum and maximum boundaries, preventing developers or attackers from deploying "mega-pods" that request more resources than the cluster can accommodate or monopolize entire nodes.

---

### Exercise 2 Answers

* **Answer 2.1:**
  When API Priority and Fairness rejects a request due to queue saturation (`queue-full`) or concurrency seat exhaustion under a `Reject` response policy, the `kube-apiserver` responds with **HTTP Status Code 429 (Too Many Requests)**. The response header also includes a `Retry-After` suggestion.

* **Answer 2.2:**
  Shuffle Sharding distributes incoming client requests across multiple virtual queues using hashing. By specifying `handSize` (e.g., 2) and a total queue pool (`queues`, e.g., 8), APF assigns each distinct user/service account a deterministic combination of queues. If a single malicious service account floods the API Server, it saturates only its assigned subset of queues. Legitimate clients hashing to different queue combinations remain unaffected, mitigating blast radius.

* **Answer 2.3:**
  `kube-apiserver` evaluates matching `FlowSchema` objects based on their **`matchingPrecedence`** numerical field, processed in ascending order (lower numbers indicate higher priority). The first `FlowSchema` matching the request's subject, verb, and resource criteria is selected. If multiple FlowSchemas have the same precedence number, lexicographical name order breaks ties.

---

### Exercise 3 Answers

* **Answer 3.1:**
  NGINX Ingress Controller rate limiting uses shared memory zones (`lua_shared_dict` or `limit_req_zone`) within each NGINX worker instance. Because rate limiting state is stored in local pod memory, `limit-rps` applies **per Ingress Controller replica**. If `limit-rps` is set to `5` and there are 3 Ingress controller replicas behind a LoadBalancer, the aggregate cluster threshold for a client IP will be up to `15 RPS` (3 replicas × 5 RPS), assuming perfect round-robin traffic distribution.

* **Answer 3.2:**
  NetworkPolicies are compiled by the CNI plugin (e.g., Calico, Cilium) into low-level host packet filtering rules (using Linux `iptables`, `nftables`, or eBPF programs attached to `tc`/`XDP` hooks). When an attacker attempts a TCP connection bypassing Ingress, incoming SYN packets arriving at the host network interface fail evaluation against the ingress rule set and are silently dropped (`DROP`) at the kernel layer before socket buffers or application memory are allocated.

* **Answer 3.3:**
  Compromised pods are frequently weaponized as launchpads for outbound Denial of Service attacks, such as UDP DNS amplification floods, external HTTP brute-forcing, or C2 (Command & Control) botnet coordination. Restricting egress traffic to explicitly required endpoints (e.g., allowing port 53 UDP *only* to `kube-system` DNS) prevents an compromised container from generating external attack traffic, port scanning the internal network, or participating in distributed reflection attacks.

</details>