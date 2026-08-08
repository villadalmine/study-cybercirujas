# KCSA Study Guide: Topic 2.3 – Kubernetes Scheduler Mechanics & Security Hardening

**Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain 2.0:** Kubernetes Architecture & Security  
**Topic 2.3:** Scheduler  
**Weight:** 2.0%  

---

## Official Reference Documentation
- **CNCF KCSA Curriculum:** [KCSA Curriculum v1.0.0](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Kubernetes Scheduler Architecture:** [kube-scheduler Concepts](https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/)
- **Node Isolation with Taints & Tolerations:** [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- **Node Affinity & Selection:** [Assigning Pods to Nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- **Pod Anti-Affinity & Skew Distribution:** [Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- **Pod Priority & Preemption Security:** [Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
- **Kube-Scheduler Security Configuration:** [Scheduler Configuration API (v1)](https://kubernetes.io/docs/reference/scheduling/config/)
- **NodeRestriction Admission Plugin:** [NodeRestriction Reference](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction)

---

## Architectural & Security Overview

The `kube-scheduler` is a core control plane component responsible for assigning unscheduled Pods (`spec.nodeName: ""`) to optimal worker nodes based on resource availability, policy constraints, security affinities, and node taints.

```
                  +-------------------------------------------------------+
                  |                  kube-apiserver                       |
                  +-------------------------------------------------------+
                                   ^                    |
                   Watch Unbound   |                    | Bind Pod to Node
                   Pods            |                    v
             +-----------------------------------------------------------------+
             |                        kube-scheduler                           |
             |                                                                 |
             |  +-----------------------------------------------------------+  |
             |  |                     Scheduling Cycle                      |  |
             |  |                                                           |  |
             |  |  +---------------+    +---------------+    +-----------+  |  |
             |  |  | Filter Phase  | -> | Scoring Phase | -> |  Reserve  |  |  |
             |  |  | (Node fit?)   |    | (Rank nodes)  |    |  Plugin   |  |  |
             |  |  +---------------+    +---------------+    +-----------+  |  |
             |  +-----------------------------------------------------------+  |
             |                                 |                               |
             |  +------------------------------v----------------------------+  |
             |  |                       Binding Cycle                       |  |
             |  |  +---------------+    +---------------+    +-----------+  |  |
             |  |  |  Permit/Pre   | -> |  Bind Plugin  | -> | Post-Bind |  |  |
             |  |  |  Bind Plugins |    | (Set nodeName)|    |   Plugin  |  |  |
             |  |  +---------------+    +---------------+    +-----------+  |  |
             |  +-----------------------------------------------------------+  |
             +-----------------------------------------------------------------+
```

### Security Implications in Multi-Tenant Clusters
1. **Workload Co-location Risks:** Malicious or untrusted containers co-located on the same physical node as sensitive workloads can attempt side-channel attacks (e.g., Spectre/Meltdown, noisy-neighbor DoS, local IPC/filesystem exploits).
2. **Resource Exhaustion & Uncontrolled Preemption:** High-priority malicious pods can force the preemption of critical security or system pods if `PriorityClass` and `preemptionPolicy` are unmanaged.
3. **Kubelet Identity Spoofing:** Compromised worker nodes attempting to alter node labels to attract high-security pods are thwarted by the `NodeRestriction` admission controller.
4. **Control Plane Exposure:** Unsecured `kube-scheduler` metrics endpoints (`10259/tcp`) can leak sensitive workload topology metadata if unauthenticated.

---

## Hands-on Guided Lab Exercises

### Prerequisites
A running Kubernetes cluster (v1.28+) with at least 3 worker nodes. Ensure `kubectl` is configured with `cluster-admin` privileges.

---

### Module 1: Hardening Multi-Tenant Node Isolation via Taints, Tolerations, and Node Affinity

#### Scenario
Deploy a dedicated, PCI-DSS compliant node pool. Ensure that only Payment Gateway workloads with explicit tolerations can run on these nodes, while also enforcing hard node affinity so PCI workloads never land on non-secure nodes.

#### Step 1.1: Label and Taint the Dedicated Secure Node
Apply a security taint and a node label to `worker-node-01`.

```bash
kubectl label node worker-node-01 security-zone=pci-dss --overwrite
kubectl taint nodes worker-node-01 security-zone=pci-dss:NoSchedule --overwrite
```

**Expected Output:**
```text
node/worker-node-01 labeled
node/worker-node-01 tainted
```

Verify the taint configuration:
```bash
kubectl get node worker-node-01 -o jsonpath='{.spec.taints}' | jq .
```

**Expected Output:**
```json
[
  {
    "effect": "NoSchedule",
    "key": "security-zone",
    "value": "pci-dss"
  }
]
```

#### Step 1.2: Deploy an Untrusted Workload to Verify Rejection
Create `untrusted-app.yaml` to ensure standard workloads cannot schedule on `worker-node-01`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: untrusted-app
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: untrusted
  template:
    metadata:
      labels:
        app: untrusted
    spec:
      containers:
      - name: nginx
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
```

Apply and verify pod placement:
```bash
kubectl apply -f untrusted-app.yaml
kubectl get pods -o wide -l app=untrusted
```

**Expected Output:**
```text
NAME                             READY   STATUS    RESTARTS   AGE   IP           NODE            NOMINATED NODE   READINESS GATES
untrusted-app-76b9f485b-24g8q    1/1     Running   0          5s    10.244.1.5   worker-node-02   <none>           <none>
untrusted-app-76b9f485b-9jxlp    1/1     Running   0          5s    10.244.2.8   worker-node-03   <none>           <none>
untrusted-app-76b9f485b-kld92    1/1     Running   0          5s    10.244.2.9   worker-node-03   <none>           <none>
```
*Notice that `worker-node-01` was completely excluded by the scheduler filtering plugin (`TaintToleration`).*

#### Step 1.3: Deploy a Hardened Payment Pod using Two-Way Isolation
Two-way isolation requires:
1. **Tolerations**: Allows the pod to tolerate the node's taint (allows scheduling on `worker-node-01`).
2. **Node Affinity (`requiredDuringSchedulingIgnoredDuringExecution`)**: Prevents the pod from scheduling on any node *other* than `worker-node-01`.

Create `payment-processor.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
        tier: secure
    spec:
      tolerations:
      - key: "security-zone"
        operator: "Equal"
        value: "pci-dss"
        effect: "NoSchedule"
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: security-zone
                operator: In
                values:
                - pci-dss
      containers:
      - name: payment-app
        image: registry.k8s.io/pause:3.9
        resources:
          limits:
            cpu: 200m
            memory: 256Mi
          requests:
            cpu: 200m
            memory: 256Mi
```

Apply the deployment and check status:
```bash
kubectl apply -f payment-processor.yaml
kubectl get pods -o wide -l app=payment-processor
```

**Expected Output:**
```text
NAME                                 READY   STATUS    RESTARTS   AGE   IP           NODE            NOMINATED NODE   READINESS GATES
payment-processor-6df958c89b-8vkw2   1/1     Running   0          12s   10.244.1.80  worker-node-01   <none>           <none>
payment-processor-6df958c89b-x9pz4   1/1     Running   0          12s   10.244.1.81  worker-node-01   <none>           <none>
```

#### Questions for Module 1
1. **Question 1.1:** If a deployment specifies the correct `tolerations` for `security-zone=pci-dss:NoSchedule` but does NOT specify `nodeAffinity`, where can the scheduler place its pods?
2. **Question 1.2:** What is the critical security operational risk of using `preferredDuringSchedulingIgnoredDuringExecution` instead of `requiredDuringSchedulingIgnoredDuringExecution` for node affinity on regulated workloads?

---

### Module 2: Mitigating Co-Location Blast Radius via Pod Anti-Affinity & Topology Spread Constraints

#### Scenario
Enforce strict physical isolation between pods of different security tiers using `podAntiAffinity`, and guarantee balanced high-availability skew across nodes using `topologySpreadConstraints` to mitigate Denial-of-Service (DoS) risks.

#### Step 2.1: Enforce Hard Pod Anti-Affinity
Create a secure vault service deployment (`vault-service.yaml`) that rejects running on any node that already runs another instance of `vault-service` or any untrusted app pod.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault-service
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: vault-service
  template:
    metadata:
      labels:
        app: vault-service
        security-level: high
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - vault-service
                - untrusted
            topologyKey: "kubernetes.io/hostname"
      containers:
      - name: vault
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
```

Apply the deployment:
```bash
kubectl apply -f vault-service.yaml
kubectl get pods -o wide -l app=vault-service
```

#### Step 2.2: Diagnose Scheduler Anti-Affinity Filtering Failures
Inspect the pods when available nodes are insufficient to satisfy hard anti-affinity constraints.

```bash
kubectl scale deployment vault-service --replicas=5
kubectl get pods -l app=vault-service
```

**Expected Output:**
```text
NAME                             READY   STATUS    RESTARTS   AGE
vault-service-595b76686-2nm49    1/1     Running   0          40s
vault-service-595b76686-7x9kl    1/1     Running   0          40s
vault-service-595b76686-m9z8p    0/1     Pending   0          10s
vault-service-595b76686-q4w12    0/1     Pending   0          10s
vault-service-595b76686-v8p5x    0/1     Pending   0          10s
```

Run `kubectl describe` to extract the scheduler filter plugin event logs:
```bash
kubectl describe pod -l app=vault-service --field-selector status.phase=Pending | grep -A 5 "Events:"
```

**Expected Output:**
```text
Events:
  Type     Reason            Age   From              Message
  ----     ------            ----  ----              -------
  Warning  FailedScheduling  24s   default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint {security-zone: pci-dss}, 2 node(s) didn't match pod anti-affinity rules. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

Scale back down:
```bash
kubectl scale deployment vault-service --replicas=2
```

#### Step 2.3: Enforce Secure Topology Spread Constraints
Create a multi-zone fault-tolerant security agent deployment using `topologySpreadConstraints` to ensure strict skew distribution and prevent single-node blast radius failure.

Create `security-agent.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: security-agent
  namespace: default
spec:
  replicas: 4
  selector:
    matchLabels:
      app: security-agent
  template:
    metadata:
      labels:
        app: security-agent
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: "kubernetes.io/hostname"
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: security-agent
      containers:
      - name: agent
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
```

Apply and inspect node distribution:
```bash
kubectl apply -f security-agent.yaml
kubectl get pods -o wide -l app=security-agent
```

#### Questions for Module 2
1. **Question 2.1:** What is the difference in scheduler evaluation between `whenUnsatisfiable: DoNotSchedule` and `whenUnsatisfiable: ScheduleAnyway` in `topologySpreadConstraints` from an availability vs security boundary standpoint?
2. **Question 2.2:** Why is `topologyKey: "kubernetes.io/hostname"` critical when configuring anti-affinity against untrusted tenant pods?

---

### Module 3: PriorityClasses, Preemption Security, and DoS Mitigation

#### Scenario
Prevent untrusted tenant pods from preempting critical cluster security components during node resource starvation events.

#### Step 3.1: Create Standard Security PriorityClasses
Define two `PriorityClasses`:
1. `critical-security-sys`: High priority, permits preemption of lower priority pods.
2. `untrusted-tenant-workload`: Low priority, explicitly disables preemption to avoid triggering eviction cascades.

Create `priority-classes.yaml`:

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical-security-sys
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "Used exclusively for mission-critical security controllers and daemonsets."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: untrusted-tenant-workload
value: 5000
globalDefault: false
preemptionPolicy: Never
description: "Non-critical tenant workloads. Cannot trigger preemption of existing pods."
```

Apply the manifests:
```bash
kubectl apply -f priority-classes.yaml
kubectl get priorityclasses | grep -E "critical-security-sys|untrusted-tenant-workload"
```

**Expected Output:**
```text
critical-security-sys      1000000     false   10s
untrusted-tenant-workload  5000        false   10s
```

#### Step 3.2: Verify Preemption Security Behavior
Deploy a tenant pod with `preemptionPolicy: Never` requesting high CPU during node capacity limits.

Create `high-resource-tenant.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: high-resource-tenant
  namespace: default
spec:
  priorityClassName: untrusted-tenant-workload
  containers:
  - name: stress
    image: registry.k8s.io/pause:3.9
    resources:
      requests:
        cpu: "32"
```

Apply and verify:
```bash
kubectl apply -f high-resource-tenant.yaml
kubectl get pod high-resource-tenant
```

Inspect event details to confirm preemption behavior:
```bash
kubectl describe pod high-resource-tenant | grep -A 4 "Events:"
```

**Expected Output:**
```text
Events:
  Type     Reason            Age   From              Message
  ----     ------            ----  ----              -------
  Warning  FailedScheduling  5s    default-scheduler  0/3 nodes are available: 3 Insufficient cpu. preemption: 0/3 nodes are available: 3 Preemption is not eligible due to preemptionPolicy=Never.
```

Clean up the test pod:
```bash
kubectl delete pod high-resource-tenant
```

#### Questions for Module 3
1. **Question 3.1:** What security vulnerability is introduced if all tenant workloads are allowed to use the built-in `system-cluster-critical` or `system-node-critical` PriorityClasses?
2. **Question 3.2:** How does setting `preemptionPolicy: Never` on a `PriorityClass` protect a cluster from noisy-neighbor Denial of Service (DoS)?

---

### Module 4: Kube-Scheduler Security Hardening & Diagnostic Auditing

#### Scenario
Audit the `kube-scheduler` control plane component configuration, verify metric endpoint authentication/authorization, and debug scheduler framework plugin execution.

#### Step 4.1: Inspect Control Plane Component Security Parameters
Access the control plane node (or examine `/etc/kubernetes/manifests/kube-scheduler.yaml`) to verify command-line hardening parameters.

```bash
kubectl get pod -n kube-system -l component=kube-scheduler -o yaml | grep -A 20 "command:"
```

**Expected Output:**
```yaml
    - command:
      - kube-scheduler
      - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
      - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
      - --bind-address=127.0.0.1
      - --kubeconfig=/etc/kubernetes/scheduler.conf
      - --leader-elect=true
      - --config=/etc/kubernetes/kube-scheduler.yaml
```

**Security Auditing Checklist:**
- `--bind-address=127.0.0.1`: Ensures the unauthenticated healthz/metrics endpoints are not exposed publicly.
- `--authentication-kubeconfig` & `--authorization-kubeconfig`: Enforces RBAC on the HTTPS metrics endpoint (`10259/tcp`).

#### Step 4.2: Inspect KubeSchedulerConfiguration (v1 API)
Examine the `KubeSchedulerConfiguration` ConfigMap or control plane config file to understand plugin pipeline execution.

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
leaderElection:
  leaderElect: true
clientConnection:
  kubeconfig: "/etc/kubernetes/scheduler.conf"
profiles:
  - schedulerName: default-scheduler
    plugins:
      filter:
        enabled:
          - name: NodeResourcesFit
          - name: NodeName
          - name: NodePorts
          - name: NodeAffinity
          - name: VolumeRestrictions
          - name: TaintToleration
        disabled:
          - name: "*"
      score:
        enabled:
          - name: NodeResourcesBalancedAllocation
            weight: 1
          - name: ImageLocality
            weight: 1
```

#### Step 4.3: Query Scheduler Metrics for Diagnostic Auditing
Fetch scheduler diagnostic metrics over the secure HTTPS interface using service account credentials or local control plane certificates.

Execute locally on the control plane node:
```bash
sudo curl -k --cert /etc/kubernetes/pki/scheduler.crt --key /etc/kubernetes/pki/scheduler.key \
  https://127.0.0.1:10259/metrics | grep -E "scheduler_scheduling_attempt_attempts_total|scheduler_pod_scheduling_duration_seconds"
```

**Expected Output:**
```text
# HELP scheduler_scheduling_attempt_attempts_total [ALPHA] Number of attempts to schedule pods, broken down by result (scheduled, unschedulable, error).
# TYPE scheduler_scheduling_attempt_attempts_total counter
scheduler_scheduling_attempt_attempts_total{result="scheduled"} 42
scheduler_scheduling_attempt_attempts_total{result="unschedulable"} 3
```

#### Questions for Module 4
1. **Question 4.1:** Which phase of the `kube-scheduler` Extension Points framework determines whether a node has sufficient capacity and satisfies all security rules (NodeAffinity, TaintToleration)?
2. **Question 4.2:** Why is exposing `kube-scheduler` metrics on `0.0.0.0:10251` (unauthenticated HTTP) considered a high-risk security issue?

---

### Module 5: Security Boundaries & NodeRestriction Admission Controller

#### Scenario
Evaluate the security boundary between Kubelet node labels and the Kube-Scheduler. Understand how the `NodeRestriction` admission controller prevents compromised worker node kubelets from modifying labels used by the scheduler for node isolation.

```
+------------------+         Modified Node Labels       +-------------------+
| Compromised Node | ---------------------------------> |  kube-apiserver   |
|     Kubelet      |   (e.g., security-zone=pci-dss)    +-------------------+
+------------------+                                              |
                                                                  v
                                                        +-------------------+
                                                        |  NodeRestriction  |
                                                        |    Admission      |
                                                        +-------------------+
                                                                  |
                                              REJECTED 403        |  (Kubelets cannot
                                          <-----------------------+   modify node labels
                                                                      in node.kubernetes.io/
                                                                      or restricted prefixes)
```

#### Step 5.1: Understand NodeRestriction Label Rules
The `NodeRestriction` admission plugin prevents Kubelets from creating or modifying labels under the reserved prefix `node.kubernetes.io/` or `node-role.kubernetes.io/`, as well as modifying their own node taints.

Verify that `NodeRestriction` is active in the API Server:
```bash
kubectl get pod -n kube-system -l component=kube-apiserver -o yaml | grep -- "--enable-admission-plugins"
```

**Expected Output:**
```text
    - --enable-admission-plugins=NodeRestriction,NamespaceLifecycle,LimitRanger,ServiceAccount,ResourceQuota
```

#### Questions for Module 5
1. **Question 5.1:** If a worker node's kubelet credentials (`system:node:<node-name>`) are compromised by an attacker, can the attacker manually label their own node with `node-role.kubernetes.io/infrastructure=""` or `node.kubernetes.io/secure="true"` to intercept sensitive pods via NodeAffinity?
2. **Question 5.2:** Which specific label prefixes are protected by `NodeRestriction` against unauthorized Kubelet modifications?

---

## Solutions & Answers

<details>
<summary>Click to expand answers for all modules</summary>

### Module 1 Answers
- **1.1 Answer:** If a pod has `tolerations` for a node's taint but lacks `nodeAffinity` (or `nodeSelector`), the scheduler can place the pod on **any node** in the cluster that meets its resource requirements, including untainted general-purpose nodes or the tainted node. Tolerations do **not** force scheduling onto tainted nodes; they merely remove the exclusion filter.
- **1.2 Answer:** Using `preferredDuringSchedulingIgnoredDuringExecution` (soft affinity) means that if the target secure node pool is at full resource capacity or temporarily unavailable, the scheduler will fallback to placing the pod on **untrusted, non-secure worker nodes**. For regulated workloads (PCI-DSS, HIPAA), this breaches compliance boundaries.

---

### Module 2 Answers
- **2.1 Answer:**
  - `whenUnsatisfiable: DoNotSchedule` (Hard requirement): Keeps the pod in `Pending` state if the skew constraint cannot be satisfied. This prioritizes security isolation and fault tolerance boundaries over pod availability.
  - `whenUnsatisfiable: ScheduleAnyway` (Soft requirement): Forces the scheduler to schedule the pod on nodes that increase skew skewness if no ideal node exists. This prioritizes availability over strict topology isolation.
- **2.2 Answer:** `topologyKey: "kubernetes.io/hostname"` evaluates pod anti-affinity at the **individual physical/virtual node level**. If `topologyKey` were set to `topology.kubernetes.io/zone`, the scheduler would prevent pods from running in the same *cloud availability zone*, rather than preventing them from running on the exact same physical node host.

---

### Module 3 Answers
- **3.1 Answer:** Allowing untrusted tenant pods to inherit `system-cluster-critical` or `system-node-critical` enables a **Denial of Service (DoS)** vector. An attacker can deploy high-priority pods requesting large resources, causing the scheduler to preempt and terminate critical cluster services (such as CoreDNS, Calico/Cilium CNI plugins, or ingress controllers).
- **3.2 Answer:** Setting `preemptionPolicy: Never` ensures that when a tenant pod cannot be scheduled due to insufficient cluster resources, it remains in `Pending` state **without triggering eviction** or preemption of lower-priority pods.

---

### Module 4 Answers
- **4.1 Answer:** The **Filter Phase** (Plugins implementing the `FilterPlugin` interface, such as `NodeAffinity`, `TaintToleration`, `NodeResourcesFit`). If any Filter plugin returns a non-Success status, the node is removed from the candidate list before scoring.
- **4.2 Answer:** Unauthenticated HTTP metrics endpoints expose detailed metadata about running workloads, namespace names, pod scheduling volume, node capacity metrics, and internal IP topology. Attackers can leverage this internal reconnaissance data for targeted exploitation.

---

### Module 5 Answers
- **5.1 Answer:** **No.** The `NodeRestriction` admission controller validates requests from node credentials (`system:nodes`) and blocks any attempt by a kubelet to add or modify labels prefixed with `node.kubernetes.io/` or `node-role.kubernetes.io/`, as well as modifying node taints.
- **5.2 Answer:** `NodeRestriction` restricts kubelet self-labeling for:
  - Labels prefixed with `node.kubernetes.io/`
  - Labels prefixed with `node-role.kubernetes.io/`
  - Specific labels like `kubernetes.io/hostname` and `kubernetes.io/arch`
  - Kubelet modification of node taints (`spec.taints`)

</details>

---

## Key Takeaways for KCSA Exam
1. **Two-Way Node Isolation:** Require BOTH Taints/Tolerations AND Hard Node Affinity (`requiredDuringSchedulingIgnoredDuringExecution`) for complete multi-tenant node isolation.
2. **Anti-Affinity Topology:** `topologyKey: "kubernetes.io/hostname"` prevents node-level co-location; `topologySpreadConstraints` with `DoNotSchedule` enforces strict HA distribution.
3. **Preemption Hardening:** Use `preemptionPolicy: Never` on untrusted priority classes to mitigate pod eviction DoS attacks.
4. **Scheduler Control Plane Security:** Always bind `--bind-address=127.0.0.1` and enforce RBAC authentication/authorization for metrics on port `10259/tcp`.
5. **NodeRestriction Boundary:** Kubelet node credentials cannot modify reserved `node.kubernetes.io/` labels or taints.