# KCSA Study Guide: Section 2.2 — Controller Manager Security & Hardening

---

## 1. Motivation and Production Architectural Problem

### Control Loop Architecture and Threat Vector Landscape
The Kubernetes Control Plane relies on the declarative reconciliation model. The `kube-controller-manager` daemon acts as a monolithic binary encapsulating dozens of distinct, asynchronous control loops (such as the `NodeController`, `ServiceAccountController`, `JobController`, `EndpointSliceController`, and `GarbageCollector`). Each controller continuously watches the API server for the current state of cluster resources and drives the cluster toward the desired state defined in the manifests.

```
+-----------------------------------------------------------------------------------------+
|                                  kube-controller-manager                                |
|                                                                                         |
|  +-------------------+  +------------------------+  +--------------------------------+  |
|  |   NodeController  |  | ServiceAccountController| | PersistentVolumeBinderController| |
|  +---------+---------+  +-----------+------------+  +---------------+----------------+  |
|            |                        |                           |                       |
|            +------------------------+---------------------------+                       |
|                                     |                                                   |
|                        Shared Informers & WorkQueues                                    |
|                                     |                                                   |
+-------------------------------------+---------------------------------------------------+
                                      |
                      gRPC / mTLS (Port 6443 / HTTPS)
                                      |
                                      v
+-----------------------------------------------------------------------------------------+
|                                   kube-apiserver                                        |
|  +---------------------+   +--------------------------+   +--------------------------+  |
|  | Authentication     |   | RBAC Authorization       |   | Admission Controllers    |  |
|  +---------------------+   +--------------------------+   +--------------------------+  |
+-----------------------------------------------------------------------------------------+
```

From a security perspective, `kube-controller-manager` represents one of the most critical threat surfaces in the Kubernetes control plane:

1. **Privilege Escalation via Shared Identity**: Historically, all internal control loops in `kube-controller-manager` authenticated to `kube-apiserver` using a single, monolithic X.509 client certificate bound to the `system:kube-controller-manager` user. If a vulnerability in a low-trust controller loop (e.g., custom CRD handling or pod garbage collection) was exploited via arbitrary memory modification or prompt/data injection into resource annotations, the attacker gained full `cluster-admin`-equivalent permissions across all API groups.
2. **Secret Generation and Signing Key Exposure**: The `ServiceAccountController` and `TokenController` inside `kube-controller-manager` require access to the RSA/ECDSA private key (`--service-account-private-key-file`) used to sign legacy ServiceAccount tokens. Compromise of the process filesystem allows an attacker to steal this key and forge valid JWT tokens for any ServiceAccount, granting cluster-wide persistence.
3. **Control Plane Denial of Service (DoS)**: Malicious or misconfigured workloads creating millions of short-lived objects (e.g., completed jobs, dangling endpoints) can trigger unbound reconciliation loops in `kube-controller-manager`, consuming node CPU/memory and starving critical infrastructure controllers (e.g., node lifecycle eviction).
4. **Unencrypted HTTP / Unauthenticated Metrics Endpoints**: Running `kube-controller-manager` with legacy `--port=10252` opens an unauthenticated HTTP port exposing internal runtime metrics, pprof debugging dumps, and thread stacks to the node network layer.

### Security Remediation Architecture
To satisfy CNCF KCSA hardening requirements and CIS Kubernetes Benchmark recommendations, `kube-controller-manager` must be configured with:
- **Fine-Grained RBAC Isolation**: Enabling `--use-service-account-credentials=true` forces each internal controller loop to authenticate to `kube-apiserver` using its own dedicated ServiceAccount token (located under `system:serviceaccount:kube-system:pvc-protection-controller`, `node-controller`, etc.), minimizing the blast radius of a single controller exploit.
- **Delegated Authentication and Authorization**: Requesting auth via `--authentication-kubeconfig` and `--authorization-kubeconfig` forces incoming HTTPS queries (metrics, healthz) to be verified against `kube-apiserver` RBAC rules.
- **Strict Cryptographic Boundaries**: Restricting non-secure ports (`--secure-port=10257`, `--bind-address=127.0.0.1`), enforcing TLS 1.3, and protecting private signing keys via strict OS file permissions (`0400`).

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 Monolithic Credentials vs. Individual ServiceAccount Credentials

| Metric / Dimension | Monolithic (`--use-service-account-credentials=false`) | Per-Controller SA (`--use-service-account-credentials=true`) |
| :--- | :--- | :--- |
| **Authentication Identity** | Single X.509 Cert (`system:kube-controller-manager`) | Individual ServiceAccount JWTs per control loop |
| **Blast Radius** | **Critical**: Compromise of 1 controller grants access to all APIs | **Low**: Compromise is restricted strictly to the RBAC rules of that specific controller |
| **RBAC Audit Visibility** | API Server logs show `system:kube-controller-manager` for all mutations | Audit logs specify exact origin (e.g., `system:serviceaccount:kube-system:job-controller`) |
| **API Server Load** | Low overhead (single TLS connection multiplexed) | Slightly higher token verification overhead on `kube-apiserver` |
| **Configuration Complexity** | Simple single client certificate in kubeconfig | Requires pre-created system ServiceAccounts and RBAC bindings |

### 2.2 Leader Election & High Availability Modes

| Architecture Feature | Single Instance | Multi-Node Leader Election (`Lease` locks) |
| :--- | :--- | :--- |
| **Availability / SLA** | Single Point of Failure (SPOF) | Active-Passive High Availability |
| **Mechanism** | Standard daemon execution | Coordinated via `coordination.k8s.io/v1` `Lease` object in `kube-system` |
| **Split-Brain Protection** | N/A | Secured via distributed optimistic locking and API server timestamp checks |
| **Flag Configuration** | `--leader-elect=false` | `--leader-elect=true --leader-elect-resource-lock=leases` |
| **RBAC Requirement** | Basic read/write permissions | Requires `get, update, create` on `leases.coordination.k8s.io` in `kube-system` |

---

## 3. Production Manifests & Infrastructure Configurations

### 3.1 Hardened Static Pod Manifest: `kube-controller-manager.yaml`
Path: `/etc/kubernetes/manifests/kube-controller-manager.yaml`
This manifest enforces NIST SP 800-190, CIS Benchmark v1.8, and KCSA security requirements.

```yaml
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    component: kube-controller-manager
    tier: control-plane
  name: kube-controller-manager
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-controller-manager
    - --allocate-node-cidrs=true
    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --bind-address=127.0.0.1
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --cluster-cidr=10.244.0.0/16
    - --cluster-name=production-cluster
    - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
    - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
    - --controllers=*
    - --feature-gates=RotateKubeletServerCertificate=true
    - --kubeconfig=/etc/kubernetes/controller-manager.conf
    - --leader-elect=true
    - --leader-elect-resource-lock=leases
    - --leader-elect-retry-period=2s
    - --leader-elect-lease-duration=15s
    - --leader-elect-renew-deadline=10s
    - --node-cidr-mask-size=24
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --root-ca-file=/etc/kubernetes/pki/ca.crt
    - --secure-port=10257
    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    - --service-cluster-ip-range=10.96.0.0/12
    - --terminated-pod-gc-threshold=1250
    - --tls-cert-file=/etc/kubernetes/pki/kube-controller-manager.crt
    - --tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256
    - --tls-min-version=VersionTLS13
    - --tls-private-key-file=/etc/kubernetes/pki/kube-controller-manager.key
    - --use-service-account-credentials=true
    image: registry.k8s.io/kube-controller-manager:v1.30.0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10257
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10257
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 2Gi
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 10001
      runAsGroup: 10001
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
    - mountPath: /etc/pki
      name: ca-certs-etc-pki
      readOnly: true
    - mountPath: /etc/kubernetes/controller-manager.conf
      name: kubeconfig
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
  hostNetwork: true
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: /etc/ssl/certs
      type: DirectoryOrCreate
    name: ca-certs
  - hostPath:
      path: /etc/pki
      type: DirectoryOrCreate
    name: ca-certs-etc-pki
  - hostPath:
      path: /etc/kubernetes/controller-manager.conf
      type: FileOrCreate
    name: kubeconfig
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
```

### 3.2 Kubeconfig Configuration: `/etc/kubernetes/controller-manager.conf`
This configuration file establishes mTLS authentication for `kube-controller-manager` to communicate with `kube-apiserver`.

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: https://127.0.0.1:6443
  name: production-cluster
contexts:
- context:
    cluster: production-cluster
    user: system:kube-controller-manager
  name: system:kube-controller-manager@production-cluster
current-context: system:kube-controller-manager@production-cluster
users:
- name: system:kube-controller-manager
  user:
    client-certificate: /etc/kubernetes/pki/kube-controller-manager.crt
    client-key: /etc/kubernetes/pki/kube-controller-manager.key
```

### 3.3 Dedicated RBAC Configuration for Per-Controller Authentication
When `--use-service-account-credentials=true` is set, `kube-controller-manager` uses internal ServiceAccounts for each loop. Below is an explicit RBAC manifest showing how `system:kube-controller-manager` delegates control for the Deployment Controller loop.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deployment-controller
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:controller:deployment-controller
rules:
- apiGroups: ["apps"]
  resources: ["deployments", "deployments/rollback", "deployments/scale"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["replicasets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:controller:deployment-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:controller:deployment-controller
subjects:
- kind: ServiceAccount
  name: deployment-controller
  namespace: kube-system
```

---

## 4. Real CLI Execution Commands & Terminal Outputs

### 4.1 Verifying Process Flags and Non-Root Runtime Execution
Validate that the process is running on the host/container without high-risk insecure flags (`--port=0` or absence of legacy HTTP ports).

```bash
$ ps aux | grep kube-controller-manager | grep -v grep
```
```output
10001    14201  3.2  2.1 743120 178200 ?        Ssl  18:22   0:14 kube-controller-manager --allocate-node-cidrs=true --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf --bind-address=127.0.0.1 --client-ca-file=/etc/kubernetes/pki/ca.crt --cluster-cidr=10.244.0.0/16 --cluster-name=production-cluster --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt --cluster-signing-key-file=/etc/kubernetes/pki/ca.key --controllers=* --feature-gates=RotateKubeletServerCertificate=true --kubeconfig=/etc/kubernetes/controller-manager.conf --leader-elect=true --leader-elect-resource-lock=leases --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt --root-ca-file=/etc/kubernetes/pki/ca.crt --secure-port=10257 --service-account-private-key-file=/etc/kubernetes/pki/sa.key --service-cluster-ip-range=10.96.0.0/12 --terminated-pod-gc-threshold=1250 --tls-cert-file=/etc/kubernetes/pki/kube-controller-manager.crt --tls-min-version=VersionTLS13 --tls-private-key-file=/etc/kubernetes/pki/kube-controller-manager.key --use-service-account-credentials=true
```

### 4.2 Auditing Leader Election Status via `Lease` API
Verify which instance of `kube-controller-manager` currently holds the distributed lock.

```bash
$ kubectl get lease kube-controller-manager -n kube-system -o yaml
```
```yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  creationTimestamp: "2026-08-07T12:00:00Z"
  name: kube-controller-manager
  namespace: kube-system
  resourceVersion: "48201"
spec:
  acquireTime: "2026-08-07T14:10:05.122849Z"
  holderIdentity: master-node-01_fa82910c-391a-4d6b-b4a1-09852f10214a
  leaseDurationSeconds: 15
  leaseTransitions: 1
  renewTime: "2026-08-07T19:31:30.984120Z"
```

### 4.3 Verifying Per-Controller ServiceAccount RBAC Enforceability
Check if the individual service accounts exist and can perform their explicit reconciliations.

```bash
$ kubectl auth can-i create deployments --as=system:serviceaccount:kube-system:deployment-controller -n default
```
```output
yes
```

```bash
$ kubectl auth can-i delete secrets --as=system:serviceaccount:kube-system:deployment-controller -n default
```
```output
no
```

### 4.4 Inspecting TLS Endpoint with Authorized Client Certificates
Test the secure healthz and metrics endpoints over port 10257 using mTLS.

```bash
$ curl -s --cacert /etc/kubernetes/pki/ca.crt \
        --cert /etc/kubernetes/pki/kube-controller-manager.crt \
        --key /etc/kubernetes/pki/kube-controller-manager.key \
        https://127.0.0.1:10257/healthz
```
```output
ok
```

---

## 5. Verification & Failure Troubleshooting Guide

```
                      Troubleshooting Flowchart: kube-controller-manager
                                                |
                                    Is Process Running?
                                    /                 \
                                  YES                  NO
                                  /                     \
                      Check Health Endpoint          Check Container Logs
                   https://127.0.0.1:10257/healthz     (crictl logs / journalctl)
                            /         \                         |
                         HTTP 200    HTTP 500 / Timeout     Look for startup flags,
                            |             |               PKI permissions, or missing
                     Controller OK   Inspect Logs        sa.key path issues
                                          |
                        +-----------------+-----------------+
                        |                                   |
              RBAC Authorization Error             Leader Election Blocked
                        |                                   |
              Check --use-service-account         Check clock synchronization (NTP)
              -credentials RBAC bindings          & Lease object ownership in kube-system
```

### 5.1 Diagnostic Scenarios & Remediation Protocols

#### Scenario A: Pods stuck in `Pending` / ServiceAccount Tokens Not Provisioned
* **Symptom**: Pod creation hangs; secrets of type `kubernetes.io/service-account-token` are not populated, or pod volume mounts fail with `token-request-denied`.
* **Root Cause**: `--service-account-private-key-file` on `kube-controller-manager` is missing, misconfigured, or inaccessible due to OS permissions.
* **Diagnostic Command**:
  ```bash
  $ crictl logs $(crictl ps --name=kube-controller-manager -q) 2>&1 | grep -i "token"
  ```
* **Sample Log Output**:
  ```output
  E0807 19:15:02.102941 1 sa_token_controller.go:143] Cannot start ServiceAccountTokenController: open /etc/kubernetes/pki/sa.key: permission denied
  ```
* **Remediation**:
  Ensure the host path `/etc/kubernetes/pki/sa.key` has strict file ownership matching the user defined in `securityContext` (`runAsUser: 10001` or `root` depending on configuration) and permissions set to `0400` or `0600`.

#### Scenario B: Controller Loop Authorization Failure (`--use-service-account-credentials=true`)
* **Symptom**: Deployment state changes in `kube-apiserver` are ignored; `ReplicaSet` objects fail to scale down or create pods.
* **Root Cause**: The system cluster roles bound to `system:serviceaccount:kube-system:deployment-controller` (or another controller) were modified or deleted.
* **Diagnostic Command**:
  ```bash
  $ kubectl logs -n kube-system static-pod-kube-controller-manager-master-node-01 | grep "Forbidden"
  ```
* **Sample Log Output**:
  ```output
  E0807 19:22:11.892014 1 replica_set.go:312] Failed to create pod for replicaset frontend-6b478848c4: pods is forbidden: User "system:serviceaccount:kube-system:deployment-controller" cannot create resource "pods" in API group "" in the namespace "default"
  ```
* **Remediation**:
  Re-apply the standard Kubernetes system RBAC manifests or run `kubeadm init phase rbac bootstrap-roles` to restore default permissions.

#### Scenario C: Leader Election Deadlock / Split-Brain
* **Symptom**: Multiple control plane nodes attempting to perform reconciliations simultaneously, resulting in duplicate resources or rapid object churn.
* **Root Cause**: NTP skew across control plane nodes exceeding `--leader-elect-lease-duration` or network partitions blocking update operations on `coordination.k8s.io/v1 Lease`.
* **Diagnostic Command**:
  ```bash
  $ kubectl get events -n kube-system --field-selector involvedObject.name=kube-controller-manager
  ```
* **Sample Log Output**:
  ```output
  LAST SEEN   TYPE      REASON            OBJECT                        MESSAGE
  12s         Warning   FailedToRenew     lease/kube-controller-manager master-node-02 failed to renew lease: leaderelection lost
  2s          Normal    LeaderElection    lease/kube-controller-manager master-node-01 became leader
  ```
* **Remediation**:
  1. Verify clock drift using `chronyc tracking` across all control plane instances. Drift must remain below 500ms.
  2. Verify network connectivity between all control plane nodes and local/remote API server load balancers.

---

## 6. References

- [Kubernetes Official Documentation: kube-controller-manager CLI Reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/)
- [Kubernetes Official Documentation: Securing the Control Plane](https://kubernetes.io/docs/concepts/security/controlling-access/)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [CNCF KCSA Exam Curriculum Repository](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)