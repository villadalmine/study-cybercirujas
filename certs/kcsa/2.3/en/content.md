# Domain 2.3: Kube-Scheduler Security & Workload Isolation Mechanics

## 1. Production Architecture & Technical Motivation

In a production Kubernetes cluster, `kube-scheduler` acts as the control plane's deterministic placement engine. It evaluates unassigned Pods (`spec.nodeName == ""`) and selects optimal worker nodes based on resource availability, policy constraints, and topological requirements. From a Cloud Native Security Associate (KCSA) perspective, the scheduler represents both a critical **control plane security boundary** and the primary mechanism for enforcing **workload isolation and multi-tenancy policies**.

```
                           +-------------------------------------------------------+
                           |              KUBERNETES CONTROL PLANE                 |
                           |                                                       |
                           |   +-----------------------+     +-----------------+   |
                           |   |   kube-apiserver      |     |  etcd Database  |   |
                           |   | (Authentication/RBAC) |     |  (Etcd Encrypt) |   |
                           |   +-----------+-----------+     +-----------------+   |
                           |               |                                       |
                           |               | Watch / Watch Pods (spec.nodeName="") |
                           |               v                                       |
                           |   +-----------------------------------------------+   |
                           |   |             kube-scheduler                    |   |
                           |   |  - mTLS Endpoint (Port 10259)                 |   |
                           |   |  - TLS 1.3 Strict Ciphers                     |   |
                           |   |  - Scheduling Framework Profiles              |   |
                           |   +-------------------+---------------------------+   |
                           +-----------------------|-------------------------------+
                                                   |
                                                   | POST /api/v1/namespaces/$NS/pods/$POD/binding
                                                   v
                           +-------------------------------------------------------+
                           |                WORKLOAD ISOLATION LAYER               |
                           |                                                       |
                           |  +------------------------+  +---------------------+  |
                           |  | PCI-DSS Node Pool      |  | Shared Tenant Pool  |  |
                           |  | - Taint: pci=true:NoSched|  | - Untrusted Workload|  |
                           |  | - Restricted NodeLabels|  | - Standard Labels   |  |
                           |  +-----------+------------+  +----------+----------+  |
                           |              |                          |             |
                           |              v                          v             |
                           |  +------------------------+  +---------------------+  |
                           |  | Dedicated Worker Node  |  | Shared Worker Node  |  |
                           |  +------------------------+  +---------------------+  |
                           +-------------------------------------------------------+
```

### Technical Attack Vectors & Security Risks

1. **Control Plane Compromise via Unsecured Scheduler Endpoints:**
   Historically, `kube-scheduler` exposed unauthenticated HTTP metrics on port `10251`. In hardened clusters, exposing `kube-scheduler` endpoints over unencrypted or weakly authenticated interfaces allows unauthorized actors to scrape sensitive metadata or manipulate scheduler configuration. Hardening requires strictly binding to `127.0.0.1` or forcing authenticated mTLS on port `10259`.

2. **Cross-Tenant Co-location & Container Breakout Escalation:**
   In multi-tenant clusters, placing a low-trust container (e.g., public web application) on the same physical host as a high-security container (e.g., payment processing service, vault agent) opens severe side-channel attack vectors. Vulnerabilities such as CPU Spectre/Meltdown, L1 Terminal Fault (L1TF), or container runtime breakouts (e.g., `CVE-2019-5736`, `CVE-2024-21626`) can allow an attacker on a shared node to access secrets across namespace boundaries.

3. **Node Label Tampering & Boundary Bypass:**
   If worker nodes (via compromised Kubelets) can mutate their own node labels (e.g., changing `environment=untrusted` to `environment=pci-dss`), they could trick `kube-scheduler` into scheduling high-privilege, sensitive Pods onto an attacker-controlled worker node. Mitigating this vector requires enforcing the `NodeRestriction` admission controller alongside strict scheduler affinity rules.

4. **Resource Exhaustion & Single-Point-of-Failure DoS:**
   Without Pod Topology Spread Constraints or Anti-Affinity rules, `kube-scheduler` may place all replicas of a critical security microservice (e.g., open-policy agent validator) onto a single worker node or failure domain. A host failure or targeted noisy-neighbor attack causes a total denial of service for security controls across the cluster.

---

## 2. Technical Comparatives & Trade-off Tables

### Workload Isolation Primitives Comparative

| Isolation Primitive | Enforcement Mechanism | Hard vs. Soft Control | Security Boundary Level | Operational & SRE Overhead |
| :--- | :--- | :--- | :--- | :--- |
| **`nodeSelector`** | Matches exact Key-Value pairs on Node labels. | Hard constraint (`DoNotSchedule`). | Basic host selection; no logical separation logic. | Low. Minimal maintenance, but inflexible for complex rules. |
| **`nodeAffinity`** | Matches expressible selector operations (`In`, `NotIn`, `Exists`). | Supports both Hard (`requiredDuringScheduling...`) and Soft (`preferredDuringScheduling...`). | Medium. Prevents placement on unauthorized node groups. | Medium. Requires standardized node labeling schemes across infra. |
| **`Taints & Tolerations`** | Nodes push unwanted Pods away unless Pod explicitly tolerates taint. | Hard (`NoSchedule`, `NoExecute`) or Soft (`PreferNoSchedule`). | High. Repels non-compliant workloads from dedicated nodes. | Medium-High. Requires taint lifecycle management on node pools. |
| **`PodAntiAffinity`** | Evaluates co-located Pod labels on nodes within topology domain. | Hard (`requiredDuringScheduling...`) or Soft (`preferredDuringScheduling...`). | High. Prevents cross-tenant co-location on shared kernels. | High. Increases scheduler algorithm complexity ($O(N \times M)$ scale). |
| **`TopologySpreadConstraints`** | Controls distribution of Pods across failure-domains/zones. | Hard (`whenUnsatisfiable: DoNotSchedule`) or Soft (`ScheduleAnyway`). | High. Guarantees high availability and blast radius isolation. | Medium. Depends on accurate node topology key labeling (`topology.kubernetes.io/zone`). |

### `kube-scheduler` Hardening Configuration Modes

| Hardening Parameter | Default / Legacy Mode | Enterprise Hardened SRE Standard | Security Impact & Trade-offs |
| :--- | :--- | :--- | :--- |
| **Listen Address (`--bind-address`)** | `0.0.0.0` (Exposed on all interfaces). | `127.0.0.1` (Localhost loopback only). | Reduces attack surface; prevents network-level access to health/metrics from outside node. |
| **Secure Port (`--secure-port`)** | `10259` (Exposed with default certs). | `10259` enforced with mTLS and dedicated CA. | Protects metric endpoint data integrity and endpoint authentication. |
| **TLS Cipher Suites (`--tls-cipher-suites`)** | Standard Go cipher suite list. | Restricted to TLS 1.3 & forward-secrecy TLS 1.2 ciphers. | Mitigates TLS downgrade attacks; enforces compliance with NIST SP 800-52 Rev. 2. |
| **Authentication & Authorization** | Delegated via kubeconfig token. | Dedicated mTLS client CA + RBAC Token Review. | Prevents anonymous access; restricts `pods/binding` RBAC permissions strictly to scheduler identity. |
| **Scheduling Profiles (`KubeSchedulerConfiguration`)** | Single default monolithic profile. | Multi-profile separation (`default` vs. `hardened-pci`). | Enables granular plugin execution filters for different security tiers without running multiple binaries. |

---

## 3. Production-Grade Manifests & Infrastructure Configurations

### 3.1 Hardened `kube-scheduler` Static Pod Manifest
File: `/etc/kubernetes/manifests/kube-scheduler.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    component: kube-scheduler
    tier: control-plane
  name: kube-scheduler
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-scheduler
    - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
    - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
    - --bind-address=127.0.0.1
    - --secure-port=10259
    - --config=/etc/kubernetes/scheduler-config.yaml
    - --tls-cert-file=/etc/kubernetes/pki/scheduler.crt
    - --tls-private-key-file=/etc/kubernetes/pki/scheduler.key
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256
    - --tls-min-version=VersionTLS12
    - --v=2
    image: registry.k8s.io/kube-scheduler:v1.30.0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10259
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10259
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: kube-scheduler
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      readOnlyRootFilesystem: true
      runAsGroup: 65534
      runAsNonRoot: true
      runAsUser: 65534
      seccompProfile:
        type: RuntimeDefault
    volumeMounts:
    - mountPath: /etc/kubernetes/scheduler.conf
      name: kubeconfig
      readOnly: true
    - mountPath: /etc/kubernetes/scheduler-config.yaml
      name: scheduler-config
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
  hostNetwork: true
  priorityClassName: system-node-critical
  securityContext: {}
  volumes:
  - hostPath:
      path: /etc/kubernetes/scheduler.conf
      type: FileOrCreate
    name: kubeconfig
  - hostPath:
      path: /etc/kubernetes/scheduler-config.yaml
      type: FileOrCreate
    name: scheduler-config
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
```

### 3.2 Advanced `KubeSchedulerConfiguration` Configuration File
File: `/etc/kubernetes/scheduler-config.yaml`

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
leaderElection:
  leaderElect: true
  resourceName: kube-scheduler
  resourceNamespace: kube-system
  leaseDuration: 15s
  renewDeadline: 10s
  retryPeriod: 2s
clientConnection:
  kubeconfig: "/etc/kubernetes/scheduler.conf"
  acceptContentTypes: "application/vnd.kubernetes.protobuf,application/json"
  contentType: "application/vnd.kubernetes.protobuf"
  qps: 100
  burst: 200
profiles:
  - schedulerName: default-scheduler
    plugins:
      multiPoint:
        enabled:
          - name: NodeResourcesFit
          - name: NodeName
          - name: NodePorts
          - name: NodeAffinity
          - name: PodTopologySpread
          - name: TaintToleration
          - name: ImageLocality
          - name: DefaultBinder
    pluginConfig:
      - name: PodTopologySpread
        args:
          defaultConstraints:
            - maxSkew: 1
              topologyKey: "topology.kubernetes.io/zone"
              whenUnsatisfiable: DoNotSchedule
          defaultingType: List
  - schedulerName: hardened-high-security-scheduler
    plugins:
      filter:
        enabled:
          - name: NodeResourcesFit
          - name: NodeAffinity
          - name: TaintToleration
          - name: PodTopologySpread
        disabled:
          - name: "*"
      score:
        enabled:
          - name: NodeResourcesBalancedAllocation
            weight: 100
          - name: PodTopologySpread
            weight: 200
        disabled:
          - name: "*"
```

### 3.3 Strict Workload Isolation Pod Manifest (PCI-DSS Compliant)
File: `pci-isolated-workload.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pci-payment-processor
  namespace: payment-secure
  labels:
    app.kubernetes.io/name: payment-processor
    security.tier: pci-dss
    tenant: sensitive-data
spec:
  schedulerName: default-scheduler
  priorityClassName: high-priority-service
  containers:
  - name: processor
    image: internal-registry.enterprise.io/finance/processor:v2.4.1
    imagePullPolicy: Always
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 10001
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
    resources:
      requests:
        cpu: "2"
        memory: 4Gi
      limits:
        cpu: "4"
        memory: 8Gi
  # 1. Node Selection Criteria: Restrict to dedicated physical hardware
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: environment.zone/security-tier
            operator: In
            values:
            - pci-dss-isolated
          - key: kubernetes.io/arch
            operator: In
            values:
            - amd64
    # 2. Prevent co-location with any untrusted or generic workloads on the same physical host
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: security.tier
            operator: NotIn
            values:
            - pci-dss
        topologyKey: "kubernetes.io/hostname"
  # 3. Taints & Tolerations: Repel all non-PCI workloads from these nodes
  tolerations:
  - key: "dedicated.workload/pci-dss"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
  - key: "dedicated.workload/pci-dss"
    operator: "Equal"
    value: "true"
    effect: "NoExecute"
  # 4. Topology Spread: Guarantee multi-AZ redundancy without single-node blast radius
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: "topology.kubernetes.io/zone"
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: payment-processor
  - maxSkew: 1
    topologyKey: "kubernetes.io/hostname"
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: payment-processor
```

### 3.4 Minimal RBAC ClusterRole for `system:kube-scheduler`
File: `kube-scheduler-rbac.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:kube-scheduler-custom
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["", "events.k8s.io"]
  resources: ["events"]
  verbs: ["create", "patch", "update"]
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["endpoints"]
  resourceNames: ["kube-scheduler"]
  verbs: ["get", "update"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["delete", "get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/binding", "pods/status"]
  verbs: ["create", "patch", "update"]
- apiGroups: [""]
  resources: ["persistentvolumeclaims", "persistentvolumes"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses", "csinodes", "csidrivers", "csistoragecapacities"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["create"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  resourceNames: ["kube-scheduler"]
  verbs: ["get", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-scheduler-custom
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-scheduler-custom
subjects:
- kind: ServiceAccount
  name: kube-scheduler
  namespace: kube-system
```

---

## 4. Real CLI Commands & Expected Terminal Outputs

### 4.1 Auditing `kube-scheduler` Control Plane Security Flags
Execute on control plane node to verify binding address, mTLS parameters, and cipher suites:

```bash
$ ps aux | grep kube-scheduler | tr ' ' '\n' | grep -E '^--'
```

**Expected Output:**
```text
--authentication-kubeconfig=/etc/kubernetes/scheduler.conf
--authorization-kubeconfig=/etc/kubernetes/scheduler.conf
--bind-address=127.0.0.1
--secure-port=10259
--config=/etc/kubernetes/scheduler-config.yaml
--tls-cert-file=/etc/kubernetes/pki/scheduler.crt
--tls-private-key-file=/etc/kubernetes/pki/scheduler.key
--client-ca-file=/etc/kubernetes/pki/ca.crt
--tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256
--tls-min-version=VersionTLS12
--v=2
```

### 4.2 Verifying `kube-scheduler` Localhost mTLS Endpoint
Verify that the HTTPS metric endpoint requires valid mTLS client certificates and refuses non-TLS HTTP traffic:

```bash
$ curl -k -s -o /dev/null -w "%{http_code}\n" https://127.0.0.1:10259/healthz
```

**Expected Output:**
```text
401
```

Now authenticate using the authorized scheduler client certs:

```bash
$ curl -s --cacert /etc/kubernetes/pki/ca.crt \
    --cert /etc/kubernetes/pki/scheduler.crt \
    --key /etc/kubernetes/pki/scheduler.key \
    https://127.0.0.1:10259/healthz
```

**Expected Output:**
```text
ok
```

### 4.3 Auditing Node Taints, Labels, and Workload Distribution
Inspect worker node pools to verify taint configuration for dedicated isolation zones:

```bash
$ kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
SECURITY_ZONE:.metadata.labels.'environment\.zone/security-tier',\
TAINTS:.spec.taints
```

**Expected Output:**
```text
NAME           SECURITY_ZONE      TAINTS
worker-node-1  pci-dss-isolated   [map[effect:NoSchedule key:dedicated.workload/pci-dss value:true] map[effect:NoExecute key:dedicated.workload/pci-dss value:true]]
worker-node-2  pci-dss-isolated   [map[effect:NoSchedule key:dedicated.workload/pci-dss value:true] map[effect:NoExecute key:dedicated.workload/pci-dss value:true]]
worker-node-3  general-shared     <none>
worker-node-4  general-shared     <none>
```

### 4.4 Inspecting Scheduling Decision Events for Unsatisfied Constraints
Trigger a deployment with non-matching tolerations to verify scheduler enforcement:

```bash
$ kubectl get events -n payment-secure --field-selector reason=FailedScheduling --sort-by='.metadata.creationTimestamp'
```

**Expected Output:**
```text
LAST SEEN   TYPE      REASON             OBJECT                       MESSAGE
12s         Warning   FailedScheduling   pod/untrusted-app-7d9f-x82   0/4 nodes are available: 2 node(s) had untolerated taint {dedicated.workload/pci-dss: true}, 2 node(s) didn't match Pod's node affinity label selector. preemption: 0/4 nodes are available: 4 Preemption is not helpful for scheduling..
```

### 4.5 Testing Direct Pod Binding Subresource Authorization (RBAC Bypass Defense)
Attempt to send a raw `Binding` API request directly to `kube-apiserver` using an unauthorized service account token to verify RBAC protection on the `pods/binding` subresource:

```bash
$ curl -k -X POST https://127.0.0.1:6443/api/v1/namespaces/payment-secure/pods/pci-payment-processor/binding \
  -H "Authorization: Bearer $UNAUTHORIZED_SA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "v1",
    "kind": "Binding",
    "metadata": { "name": "pci-payment-processor" },
    "target": { "apiVersion": "v1", "kind": "Node", "name": "worker-node-3" }
  }'
```

**Expected Output:**
```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "pods \"pci-payment-processor/binding\" is forbidden: User \"system:serviceaccount:payment-secure:unauthorized-sa\" cannot create resource \"pods/binding\" in API group \"\" in the namespace \"payment-secure\"",
  "reason": "Forbidden",
  "details": {
    "name": "pci-payment-processor/binding",
    "kind": "pods"
  },
  "code": 403
}
```

---

## 5. SRE Verification & Troubleshooting Guide

```
+-----------------------------------------------------------------------------------+
|                         SCHEDULER TROUBLESHOOTING FLOWCHART                      |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
                              [Pod stuck in Pending state]
                                          |
                                          v
                       +-------------------------------------+
                       | Run `kubectl describe pod <pod-name>`|
                       +------------------+------------------+
                                          |
                        +-----------------+-----------------+
                        |                                   |
                        v                                   v
             [FailedScheduling Event]               [No Events / Unknown]
                        |                                   |
          +-------------+-------------+                     v
          |                           |         +-----------------------+
          v                           v         | Check Scheduler Pod   |
  [Taint / Affinity]       [Topology / Skew]    | Health & Logs         |
          |                           |         +-----------+-----------+
          v                           v                     |
+-------------------+   +--------------------+              v
| Verify Node       |   | Check Zone Labels  |   +--------------------------+
| Labels & Taints   |   | & Node Topology    |   | Check APIServer RBAC &   |
+-------------------+   +--------------------+   | Client Certificate Expiry|
                                                 +--------------------------+
```

### Diagnostic Procedure 1: Pod stuck in `Pending` due to `FailedScheduling`

**Symptom:** Pod remains in `Pending` state indefinitely. `kubectl get pod` shows 0 nodes available.

**Step-by-step SRE Investigation:**

1. **Extract detailed scheduler reason:**
   ```bash
   $ kubectl describe pod <pod-name> -n <namespace> | grep -A 10 "Events:"
   ```
2. **Analyze Predicate Failures:**
   * `untolerated taint`: Indicates the destination node has a taint (`spec.taints`) that the Pod does not explicitly match in `spec.tolerations`. Verify node taints using:
     ```bash
     $ kubectl get node <node-name> -o jsonpath='{.spec.taints}' | jq .
     ```
   * `node(s) didn't match Pod's node affinity label selector`: The node lacks required labels listed in `spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution`.
3. **Verify Node Labels against NodeRestriction Admission Plugin:**
   * If a Kubelet tried to self-label a node to attract a Pod but the label was rejected, check `kube-apiserver` audit logs for `NodeRestriction` denials:
     ```bash
     $ grep "NodeRestriction" /var/log/kubernetes/kube-apiserver-audit.log | grep "denied"
     ```

### Diagnostic Procedure 2: `kube-scheduler` Unhealthy / Control Plane Degradation

**Symptom:** Pods created in the cluster are not being assigned to nodes. `spec.nodeName` remains empty, and `kubectl get componentstatuses` or health checks fail.

1. **Check Static Pod Logs for `kube-scheduler`:**
   ```bash
   $ crictl logs $(crictl ps --name kube-scheduler -q)
   ```
2. **Common Root Cause 1: Certificate Expiration or Authorization Failure:**
   * *Log Signature:* `http: TLS handshake error` or `Unauthorized` / `403 Forbidden` calling `kube-apiserver`.
   * *Resolution:* Verify validity of `/etc/kubernetes/scheduler.conf` client certificate:
     ```bash
     $ openssl x509 -in /etc/kubernetes/pki/scheduler.crt -noout -dates -issuer -subject
     ```
3. **Common Root Cause 2: Leadership Election Lockout:**
   * *Log Signature:* `failed to acquire lease kube-system/kube-scheduler: leader election lost`
   * *Resolution:* Check control plane clock drift across master nodes using `chronyc tracking` or `ntpstat`. Verify connectivity to `coordination.k8s.io/leases` via `kube-apiserver`.

### Key Production Prometheus Metrics for SRE Monitoring

* `scheduler_scheduling_attempt_duration_seconds_bucket`: Latency distribution of scheduling cycles. High latency indicates overly complex PodAntiAffinity or TopologySpread constraints.
* `scheduler_pod_scheduling_attempts_count{result="unschedulable"}`: Counter of unschedulable Pod attempts. Spikes indicate resource saturation or policy misconfigurations.
* `scheduler_leader_election_master_status`: Binary gauge (1/0) indicating active leadership state per scheduler instance.

---

## 6. Referencias

* **Official Kubernetes Documentation - kube-scheduler Reference:**  
  https://kubernetes.io/docs/reference/command-line-tools-reference/kube-scheduler/
* **Official Kubernetes Documentation - Hardening Kube-Scheduler:**  
  https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/
* **Official Kubernetes Documentation - KubeSchedulerConfiguration (v1):**  
  https://kubernetes.io/docs/reference/config-api/kube-scheduler-config.v1/
* **Official Kubernetes Documentation - Assigning Pods to Nodes:**  
  https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
* **Official Kubernetes Documentation - Taints and Tolerations:**  
  https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
* **Official Kubernetes Documentation - Pod Topology Spread Constraints:**  
  https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
* **Official Kubernetes Documentation - Node Restriction Admission Plugin:**  
  https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
* **CNCF KCSA Exam Curriculum:**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf