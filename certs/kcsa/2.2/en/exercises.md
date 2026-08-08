# CNCF KCSA Study Guide: Topic 2.2 – Controller Manager Security

## 1. Deep Technical Architecture & Security Mechanics

The `kube-controller-manager` is a core control plane binary that embeds core control loops (controllers) shipped with Kubernetes. Each controller continuously monitors the cluster state via the `kube-apiserver` and makes or requests changes to reconcile the current state toward the desired state.

```
+-----------------------------------------------------------------------------------+
|                            kube-controller-manager                                |
|                                                                                   |
|  +-------------------------+  +-------------------------+  +-------------------+  |
|  | node-lifecycle-controller|  | job-controller          |  | serviceaccount-   |  |
|  |                         |  |                         |  | token-controller  |  |
|  +------------+------------+  +------------+------------+  +---------+---------+  |
|               |                            |                         |            |
|               +----------------------------+-------------------------+            |
|                                            |                                      |
|                 [ In-Process Client / SharedInformerFactory ]                    |
+--------------------------------------------+--------------------------------------+
                                             |  (HTTPS 6443 / Mutual TLS)
                                             v
+-----------------------------------------------------------------------------------+
|                                 kube-apiserver                                    |
|                                                                                   |
|  +--------------------+    +---------------------------+    +------------------+  |
|  | Authentication     | -> | Authorization (RBAC)      | -> | Admission Control|  |
|  +--------------------+    +---------------------------+    +------------------+  |
+-----------------------------------------------------------------------------------+
```

### Core Security Vectors & Flags

1. **Principle of Least Privilege (`--use-service-account-credentials`)**:
   - **Default/Insecure Mode (`false`)**: All internal loops share a single high-privileged client credential (the `kube-controller-manager` client certificate), which grants near-`cluster-admin` privileges across all resources.
   - **Hardened Mode (`true`)**: The controller manager creates individual `ServiceAccount` credentials per control loop (e.g., `system:serviceaccount:kube-system:node-controller`, `system:serviceaccount:kube-system:job-controller`). RBAC permissions are strictly evaluated for each specific loop, limiting blast radius if a single controller process or token is compromised.

2. **Cryptographic Key Management for ServiceAccounts**:
   - `--service-account-private-key-file`: Specifies the RSA or ECDSA private key used by the `TokenController` to sign ServiceAccount JWT tokens.
   - `--root-ca-file`: Specifies the Root CA bundle injected into Pods' ServiceAccount secret volume mounts (`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`) to allow in-cluster workloads to verify the API server's TLS certificate.

3. **Transport Layer Security & Metric Hardening**:
   - `--secure-port=10257` (default secure port): Encrypts incoming HTTP traffic for health probes (`/healthz`) and Prometheus metrics (`/metrics`).
   - `--bind-address=127.0.0.1` or internal control-plane IP: Restricts network listening interfaces.
   - `--authorization-always-allow-paths=/healthz,/metrics`: Controls unauthenticated endpoint access. Setting authentication/authorization flags (`--authentication-kubeconfig` and `--authorization-kubeconfig`) ensures metrics endpoints require valid RBAC (`system:kube-scheduler` or metric collector ServiceAccounts).

4. **Node Lifecycle & Eviction Mitigation (`--pod-eviction-timeout`, `--node-eviction-rate`)**:
   - Configures rate limits for node taints and pod evictions during network partitions to prevent cascading cluster denial-of-service (DoS).

---

## 2. Official References & Documentation
- [Kubernetes Reference: `kube-controller-manager`](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/)
- [Kubernetes Architecture: Control Plane Components](https://kubernetes.io/docs/concepts/architecture/controller/)
- [ServiceAccount Token Controller Security](https://kubernetes.io/docs/concepts/security/service-accounts-admin/)
- [CNCF KCSA Exam Curriculum](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 3. Hands-On Guided Lab Exercises

### Exercise 1: Auditing and Hardening `kube-controller-manager` Security Flags

In this exercise, you will audit an existing `kube-controller-manager` static pod manifest, identify insecure configurations, and apply production hardening flags.

#### Step 1.1: Inspect the running controller-manager static pod configuration
Execute the following command to retrieve the current flag configuration of `kube-controller-manager` on a control plane node.

```bash
kubectl get pod -n kube-system -l component=kube-controller-manager -o jsonpath='{.items[0].spec.containers[0].command}' | jq .
```

**Expected Output:**
```json
[
  "kube-controller-manager",
  "--allocate-node-cidrs=true",
  "--authentication-kubeconfig=/etc/kubernetes/controller-manager.conf",
  "--authorization-kubeconfig=/etc/kubernetes/controller-manager.conf",
  "--bind-address=127.0.0.1",
  "--client-ca-file=/etc/kubernetes/pki/ca.crt",
  "--cluster-cidr=10.244.0.0/16",
  "--cluster-name=kubernetes",
  "--cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt",
  "--cluster-signing-key-file=/etc/kubernetes/pki/ca.key",
  "--controllers=*,bootstrapsigner,tokentrainer",
  "--kubeconfig=/etc/kubernetes/controller-manager.conf",
  "--leader-elect=true",
  "--requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt",
  "--root-ca-file=/etc/kubernetes/pki/ca.crt",
  "--service-account-private-key-file=/etc/kubernetes/pki/sa.key",
  "--use-service-account-credentials=true"
]
```

#### Step 1.2: Validate RBAC binding isolation for individual controllers
Verify that `--use-service-account-credentials=true` created distinct ServiceAccount identity bindings in `kube-system`.

```bash
kubectl get clusterrolebindings -o json | jq -r '.items[] | select(.subjects[]?.name | strings | startswith("pvc-protection-controller")) | .metadata.name'
```

**Expected Output:**
```
system:controller:pvc-protection-controller
```

Inspect the permissions associated with the `pvc-protection-controller`:

```bash
kubectl get clusterrole system:controller:pvc-protection-controller -o yaml
```

**Expected Output:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:controller:pvc-protection-controller
rules:
- apiGroups:
  - ""
  resources:
  - persistentvolumeclaims
  verbs:
  - get
  - list
  - watch
  - update
```

---

#### Verification Question 1.1
What is the security risk of running `kube-controller-manager` with `--use-service-account-credentials=false` in a multi-tenant or hardened cluster environment?

---

### Exercise 2: Simulating Controller Token Compromise & Implementing Least Privilege

In this exercise, you will analyze how individual controller service account RBAC prevents horizontal privilege escalation when a controller context is isolated.

#### Step 2.1: Verify API Access using `kubectl auth can-i` for a specific controller ServiceAccount
Simulate an attacker who gained access to the `system:serviceaccount:kube-system:job-controller` token. Check if this identity can read cluster secrets.

```bash
kubectl auth can-i get secrets --as=system:serviceaccount:kube-system:job-controller -n default
```

**Expected Output:**
```
no
```

Now verify what actions the `job-controller` ServiceAccount *is* allowed to perform on Pods:

```bash
kubectl auth can-i create pods --as=system:serviceaccount:kube-system:job-controller -n default
```

**Expected Output:**
```
yes
```

#### Step 2.2: Create a Custom Controller ServiceAccount and RBAC Manifest
Below is a syntactically valid production manifest defining a least-privilege RBAC configuration for a custom operator or controller process running inside the cluster. Apply this manifest to set up restricted controller access.

Create the manifest file `custom-controller-rbac.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: custom-deployment-reconciler
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: custom-deployment-reconciler-role
rules:
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: custom-deployment-reconciler-binding
subjects:
- kind: ServiceAccount
  name: custom-deployment-reconciler
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: custom-deployment-reconciler-role
  apiGroup: rbac.authorization.k8s.io
```

Apply the manifest:

```bash
kubectl apply -f custom-controller-rbac.yaml
```

**Expected Output:**
```
serviceaccount/custom-deployment-reconciler created
clusterrole.rbac.authorization.k8s.io/custom-deployment-reconciler-role created
clusterrolebinding.rbac.authorization.kubernetes.io/custom-deployment-reconciler-binding created
```

#### Step 2.3: Test Permission Boundaries of the Custom Controller
Execute authorization queries to verify boundary enforcement:

```bash
kubectl auth can-i delete deployments --as=system:serviceaccount:kube-system:custom-deployment-reconciler -n default
```

**Expected Output:**
```
no
```

---

#### Verification Question 2.1
If a controller requires `watch` permissions on `secrets` to reconcile TLS certificates, but should never create or modify secrets, which RBAC `verbs` and `resources` entries must be configured in its `ClusterRole`? What additional field can limit access to specific Secret instances?

---

### Exercise 3: Controller Manager Metrics & HTTPS Security Diagnostics

In this exercise, you will diagnose and secure the metric endpoint of the `kube-controller-manager` using mutual TLS and RBAC authorization.

#### Step 3.1: Attempt Unauthorized Access to the Controller Manager HTTPS Endpoint
By default, secure production clusters enforce authentication on port `10257`. Test fetching metrics without a valid client certificate or bearer token:

```bash
curl -k -s -o /dev/null -w "%{http_code}\n" https://127.0.0.1:10257/metrics
```

**Expected Output:**
```
401
```

#### Step 3.2: Query Metrics with Kubeconfig Administrative Credentials
Use the system kubeconfig credentials for `kube-controller-manager` to authenticate correctly against the metric endpoint:

```bash
curl --cacert /etc/kubernetes/pki/ca.crt \
     --cert /etc/kubernetes/pki/front-proxy-client.crt \
     --key /etc/kubernetes/pki/front-proxy-client.key \
     -s https://127.0.0.1:10257/metrics | head -n 15
```

**Expected Output:**
```
# HELP go_gc_duration_seconds A summary of the pause duration of garbage collection cycles.
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} 0.0001023
go_gc_duration_seconds{quantile="0.25"} 0.0001451
go_gc_duration_seconds{quantile="0.5"} 0.0001892
go_gc_duration_seconds{quantile="0.75"} 0.0002511
go_gc_duration_seconds{quantile="1"} 0.0008912
# HELP go_goroutines Number of goroutines that currently exist.
# TYPE go_goroutines gauge
go_goroutines 142
```

#### Step 3.3: Inspect Active Controller Metrics for Security Monitoring
Check queue depth and reconciliation errors for specific controllers (e.g., `serviceaccount-token` controller) to detect resource starvation or service account abuse:

```bash
curl -k --cert /etc/kubernetes/pki/front-proxy-client.crt \
        --key /etc/kubernetes/pki/front-proxy-client.key \
        -s https://127.0.0.1:10257/metrics | grep "workqueue_adds_total" | head -n 5
```

**Expected Output:**
```
workqueue_adds_total{name="action_deployment"} 12
workqueue_adds_total{name="certificate"} 4
workqueue_adds_total{name="endpoint"} 158
workqueue_adds_total{name="garbage_collector"} 89
workqueue_adds_total{name="serviceaccount"} 34
```

---

#### Verification Question 3.1
Which two flags in `kube-controller-manager` enforce RBAC authorization and authentication checks on its HTTPS metric endpoint (`:10257`), preventing unauthenticated metric discovery?

---

## 4. Solutions & Technical Explanations

<details>
<summary>Click to expand Answers and Deep Explanations</summary>

### Answer to Question 1.1

**Response:**
When `--use-service-account-credentials=false` (or missing), all control loops inside `kube-controller-manager` execute using the client certificate/kubeconfig supplied via `--kubeconfig`. This credential typically belongs to `system:kube-controller-manager`, which possesses broad cluster-wide administrative permissions.

**Security Implication & Mechanics:**
1. **Lack of Isolation**: If a flaw, bug, or side-channel exploit in a single controller loop (e.g., `pv-protection-controller` or a third-party dependency) allows arbitrary API request construction, the exploit inherits full superuser/admin privileges over the cluster rather than being limited to PVC resources.
2. **Audit Failure**: The `kube-apiserver` audit logs will attribute all API calls across all controllers to `system:kube-controller-manager`, rendering granular forensics and anomaly detection impossible.
3. **Best Practice**: Enabling `--use-service-account-credentials=true` forces each loop to authenticate as `system:serviceaccount:kube-system:<controller-name>`, adhering to the Principle of Least Privilege.

---

### Answer to Question 2.1

**Response:**
To allow read-only watching of secrets without enabling modification or creation:
- **Verbs**: `["get", "list", "watch"]`
- **Resources**: `["secrets"]`
- **Resource Names Restriction**: To restrict access strictly to specific secret instances, use the `resourceNames` array.

**Example RBAC ClusterRole snippet:**
```yaml
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["tls-ingress-cert", "custom-api-token"]
  verbs: ["get", "list", "watch"]
```

**Technical Explanation:**
Using `resourceNames` prevents the controller from enumerating or fetching other secrets (such as ServiceAccount tokens or database passwords) in the namespace, effectively mitigating lateral movement in case the controller is compromised.

---

### Answer to Question 3.1

**Response:**
The two mandatory flags are:
1. `--authentication-kubeconfig=/path/to/kubeconfig`
2. `--authorization-kubeconfig=/path/to/kubeconfig`

**Technical Explanation:**
- Without `--authentication-kubeconfig`, the HTTPS server on port `10257` cannot verify client certificates or Bearer tokens against the API server's token review API.
- Without `--authorization-kubeconfig`, the server does not delegate authorization decisions to the API server via `SubjectAccessReview`. Setting both flags ensures that callers attempting to access `/metrics` must present a identity bound to a `ClusterRole` with permission to `get` on `/metrics` non-resource URLs.

</details>