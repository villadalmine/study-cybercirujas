# KCSA Exam Preparation: Topic 2.4 - Kubelet Security & Hardening

**Domain:** Cluster Hardening / Node Security  
**Exam Weight:** ~2.0  
**Target Audience:** SREs, Security Engineers, and Platform Architects preparing for the CNCF KCSA Certification.

---

## Official Reference Documentation
- [CNCF KCSA Curriculum](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- [Kubernetes Hardening Guide - Kubelet Authentication & Authorization](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/)
- [Kubelet Configuration API (v1beta1)](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
- [Kubernetes Node Authorization and NodeRestriction Admission Plugin](https://kubernetes.io/docs/reference/access-authn-authz/node/)

---

## Technical Overview & Core Architecture

The **Kubelet** is the primary node agent that runs on every worker node in a Kubernetes cluster. It receives PodSpecs primarily from the `kube-apiserver` and ensures that the containers described in those PodSpecs are running and healthy.

Because the Kubelet exposes HTTPS server endpoints (default TCP port `10250`) capable of performing high-privilege actions (executing commands in containers, streaming logs, retrieving pod secrets, exposing node metrics), securing the Kubelet is a fundamental requirement of cluster security.

```
                         [ API Requests (e.g. exec, logs, metrics) ]
                                            │
                                            ▼
                        ┌───────────────────────────────────────┐
                        │        Kubelet HTTPS Server           │
                        │             (Port 10250)              │
                        └───────────────────┬───────────────────┘
                                            │
                                            ▼
                       ┌─────────────────────────────────────────┐
                       │       Phase 1: Authentication           │
                       │ ───> Client X.509 Cert (/etc/.../ca.crt) │
                       │ ───> Bearer Token (TokenReview API)     │
                       │ ───> Anonymous (If enabled - DANGER!)   │
                       └────────────────────┬────────────────────┘
                                            │ (Identity Verified)
                                            ▼
                       ┌─────────────────────────────────────────┐
                       │        Phase 2: Authorization           │
                       │ ───> Mode: Webhook                      │
                       │      Delegates to API Server            │
                       │      (SubjectAccessReview API call)     │
                       └────────────────────┬────────────────────┘
                                            │ (Allowed)
                                            ▼
                       ┌─────────────────────────────────────────┐
                       │       CRI / Runtime Execution           │
                       │  (containerd, crictl, systemd cgroups) │
                       └─────────────────────────────────────────┘
```

### Critical Security Vectors in Kubelet Architecture:
1. **Authentication (`authentication`)**: By default, untreated Kubelets may allow anonymous requests (`--anonymous-auth=true`). Production Kubelets must enforce X.509 client certificate validation or Bearer Token Webhook authentication.
2. **Authorization (`authorization`)**: Setting `authorization.mode` to `AlwaysAllow` permits any authenticated client to perform arbitrary node management tasks (including `exec` into `kube-system` pods). Production configuration requires `mode: Webhook`, which delegates access control evaluation to the `kube-apiserver` via `SubjectAccessReview`.
3. **Node Isolation (`Node` Authorizer & `NodeRestriction` Admission Plugin)**: Limits Kubelet API permissions strictly to its assigned Node, preventing a compromised Kubelet credential from modifying other worker nodes or accessing secrets outside its scheduled Pods.
4. **Legacy Ports & Cipher Suites**: Disabling the read-only port (`--read-only-port=0`, legacy port `10255`) and restricting TLS ciphers to modern forward-secrecy suites.

---

## Hands-On Guided Exercises

### Module 1: Hardening Kubelet Authentication (Anonymous Access & X.509 Client CA)

#### Step 1.1: Probe the Current Kubelet Authentication State
Execute an unauthenticated TLS probe against the local node's Kubelet HTTPS endpoint (Port `10250`) on `/metrics` and `/pods`.

```bash
curl -sk -X GET https://127.0.0.1:10250/pods
```

**Expected Output (Unsecured / Default Kubelet):**
```json
{
  "kind": "PodList",
  "apiVersion": "v1",
  "metadata": {},
  "items": [
    {
      "metadata": {
        "name": "coredns-768b85b76f-2v48l",
        "namespace": "kube-system"
      }
    }
  ]
}
```

**Expected Output (Secured Kubelet):**
```text
Unauthorized
```

#### Step 1.2: Audit and Create Hardened `KubeletConfiguration`
Create a production-grade Kubelet configuration manifest `kubelet-config.yaml` using the `kubelet.config.k8s.io/v1beta1` API.

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: "0.0.0.0"
port: 10250
readOnlyPort: 0
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
    cacheTTL: 2m0s
  x509:
    clientCAFile: "/etc/kubernetes/pki/ca.crt"
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
tlsCertFile: "/var/lib/kubelet/pki/kubelet.crt"
tlsPrivateKeyFile: "/var/lib/kubelet/pki/kubelet.key"
tlsCipherSuites:
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
cgroupDriver: systemd
protectKernelDefaults: true
```

#### Step 1.3: Apply Configuration and Restart Kubelet Service
Copy the configuration to `/var/lib/kubelet/config.yaml`, reload systemd configuration, and restart the `kubelet` daemon.

```bash
sudo cp kubelet-config.yaml /var/lib/kubelet/config.yaml
sudo systemctl daemon-reload
sudo systemctl restart kubelet
sudo systemctl status kubelet --no-pager
```

**Expected Output:**
```text
● kubelet.service - kubelet: The Kubernetes Node Agent
     Active: active (running) since Fri 2026-08-07 19:34:10 UTC; 4s ago
       Docs: https://kubernetes.io/docs/home/
   Main PID: 142091 (kubelet)
      Tasks: 34 (limit: 9472)
     Memory: 42.1M
        CPU: 410ms
     CGroup: /system.slice/kubelet.service
             └─142091 /usr/local/bin/kubelet --config=/var/lib/kubelet/config.yaml
```

#### Step 1.4: Verify Anonymous Access Rejection
Verify that unauthenticated requests fail with `401 Unauthorized`.

```bash
curl -sk -I -X GET https://127.0.0.1:10250/metrics
```

**Expected Output:**
```http
HTTP/2 401 
content-type: text/plain; charset=utf-8
x-content-type-options: nosniff
date: Fri, 07 Aug 2026 19:34:15 GMT
content-length: 13
```

#### Step 1.5: Authenticate Using API Server Client Certificates
Perform an authenticated query against the Kubelet using the API server's client certificate and private key (`apiserver-kubelet-client.crt` and `apiserver-kubelet-client.key`).

```bash
curl -sk --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
         --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
         -X GET https://127.0.0.1:10250/healthz
```

**Expected Output:**
```text
ok
```

---

### Module 1 Comprehension Questions

**Question 1.1:** What HTTP response code does the Kubelet return when `authentication.anonymous.enabled` is set to `false` and a request is made without client certificates or a valid Bearer token?
- A) `403 Forbidden`
- B) `401 Unauthorized`
- C) `400 Bad Request`
- D) `500 Internal Server Error`

**Question 1.2:** If `authentication.webhook.enabled` is set to `true`, how does the Kubelet verify an incoming HTTP Bearer token presented in a request?
- A) It validates the token against its local `/etc/kubernetes/passwd` file.
- B) It sends a `TokenReview` request to the `kube-apiserver`.
- C) It decrypts the token using its local TLS private key.
- D) It queries the `etcd` cluster directly on port 2379.

---

### Module 2: Delegating Kubelet Authorization to `kube-apiserver` (Webhook Mode & RBAC)

#### Step 2.1: Architectural Understanding of Webhook Authorization
When `authorization.mode: Webhook` is enabled in `KubeletConfiguration`, the Kubelet calls the API Server's `SubjectAccessReview` API endpoint to determine whether an authenticated user/service account has permission to access specific Kubelet endpoints (`/exec`, `/logs`, `/metrics`, `/stats`, `/pods`).

Permissions map directly to subresources on the `nodes` API resource:
- `/exec` $\rightarrow$ `nodes/proxy` (Verb: `create`, `get`)
- `/metrics` $\rightarrow$ `nodes/metrics` (Verb: `get`)
- `/stats` $\rightarrow$ `nodes/stats` (Verb: `get`)
- `/logs` $\rightarrow$ `nodes/log` (Verb: `get`)

#### Step 2.2: Implement Fine-Grained RBAC for Monitoring Agents
Create a minimal-privilege `ClusterRole` and `ClusterRoleBinding` granting a monitoring ServiceAccount (`prometheus-k8s`) access *only* to `/metrics` and `/stats`, explicitly excluding command execution (`nodes/proxy`).

Save as `kubelet-monitoring-rbac.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus-k8s
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubelet-metrics-only-reader
rules:
  - apiGroups: [""]
    resources:
      - nodes/metrics
      - nodes/stats
    verbs:
      - get
      - list
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-kubelet-metrics-binding
subjects:
  - kind: ServiceAccount
    name: prometheus-k8s
    namespace: monitoring
roleRef:
  kind: ClusterRole
  name: kubelet-metrics-only-reader
  apiGroup: rbac.authorization.k8s.io
```

Apply the RBAC manifest:

```bash
kubectl apply -f kubelet-monitoring-rbac.yaml
```

**Expected Output:**
```text
serviceaccount/prometheus-k8s created
clusterrole.rbac.authorization.k8s.io/kubelet-metrics-only-reader created
clusterrolebinding.rbac.authorization.k8s.io/prometheus-kubelet-metrics-binding created
```

#### Step 2.3: Test Authorization Boundaries using `kubectl auth can-i`
Verify that the `prometheus-k8s` ServiceAccount can access node metrics, but cannot execute commands inside container environments.

```bash
# Check metrics access (Should be YES)
kubectl auth can-i get nodes/metrics --as=system:serviceaccount:monitoring:prometheus-k8s

# Check container exec access (Should be NO)
kubectl auth can-i create nodes/proxy --as=system:serviceaccount:monitoring:prometheus-k8s
```

**Expected Output:**
```text
yes
no
```

#### Step 2.4: Test Real Webhook Authorization with ServiceAccount Token
Extract the Bearer token for `prometheus-k8s` and query the Kubelet API directly.

```bash
# Obtain token for the ServiceAccount
TOKEN=$(kubectl create token prometheus-k8s -n monitoring --duration=1h)

# Query Kubelet metrics endpoint with Bearer Token (Should succeed 200 OK)
curl -sk -H "Authorization: Bearer ${TOKEN}" -X GET https://127.0.0.1:10250/metrics | head -n 5
```

**Expected Output:**
```text
# HELP go_gc_duration_seconds A summary of the pause duration of garbage collection cycles.
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} 1.2541e-05
go_gc_duration_seconds{quantile="0.25"} 2.4510e-05
go_gc_duration_seconds{quantile="0.5"} 3.6120e-05
```

Query the `/exec` endpoint with the same token:

```bash
curl -sk -H "Authorization: Bearer ${TOKEN}" -X POST https://127.0.0.1:10250/exec/default/my-pod/my-container?command=date
```

**Expected Output:**
```text
Forbidden (user=system:serviceaccount:monitoring:prometheus-k8s, verb=get, resource=nodes, subresource=proxy)
```

---

### Module 2 Comprehension Questions

**Question 2.1:** Why is granting `nodes/proxy` access to third-party monitoring or logging agents considered a severe security risk in production Kubernetes environments?
- A) `nodes/proxy` allows the agent to shut down the host operating system.
- B) `nodes/proxy` grants complete execution privileges inside any container running on that node via the Kubelet exec API.
- C) `nodes/proxy` exposes the master etcd database encryption keys.
- D) `nodes/proxy` bypasses TLS handshake encryption on TCP port 10250.

**Question 2.2:** When Kubelet receives a request while `authorization.mode: Webhook` is configured, what API object does the Kubelet transmit to the `kube-apiserver` to verify user permissions?
- A) `TokenReview`
- B) `SubjectAccessReview`
- C) `CertificateSigningRequest`
- D) `SelfSubjectRulesReview`

---

### Module 3: Enforcing Node Scope Isolation (Node Authorizer & NodeRestriction Admission Plugin)

#### Step 3.1: Mechanics of Node Authorization & NodeRestriction
The **Node Authorizer** is a dedicated authorization plugin that authorizes requests made by Kubelets. To be recognized by the Node Authorizer, Kubelet client certificates must present:
- **Organization (`O`)**: `system:nodes`
- **Common Name (`CN`)**: `system:node:<nodeName>`

The **`NodeRestriction`** admission plugin intercepts API requests originating from Kubelets and limits their mutation scope:
1. A Kubelet can only modify its own `Node` object status.
2. A Kubelet cannot add/modify node labels matching `node-restriction.kubernetes.io/*`.
3. A Kubelet can only modify `Pod` objects bound to its own node.
4. A Kubelet cannot create or delete its own `Node` object.

```
       [ Kubelet Certificate ]
        CN: system:node:worker-01
        O:  system:nodes
               │
               ▼
       ┌──────────────────────────────────────────────────────────┐
       │                 kube-apiserver Pipeline                  │
       ├─────────────────────────┬────────────────────────────────┤
       │ 1. Node Authorizer      │ Checks if request touches pods │
       │                         │ / secrets bound to worker-01   │
       ├─────────────────────────┼────────────────────────────────┤
       │ 2. NodeRestriction      │ Blocks cross-node mutations &  │
       │    Admission Plugin     │ forbidden label updates        │
       └─────────────────────────┴────────────────────────────────┘
```

#### Step 3.2: Inspect API Server Admission Controllers
Verify that `NodeRestriction` is enabled on the `kube-apiserver` static pod manifest (`/etc/kubernetes/manifests/kube-apiserver.yaml`).

```bash
grep -E "--enable-admission-plugins" /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Expected Output:**
```yaml
    - --enable-admission-plugins=NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota
```

#### Step 3.3: Inspect Kubelet X.509 Identity Certificate
Inspect the X.509 certificate used by Kubelet to authenticate against `kube-apiserver`.

```bash
openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -text -noout | grep -E "Subject:"
```

**Expected Output:**
```text
        Subject: O = system:nodes, CN = system:node:worker-01
```

#### Step 3.4: Test NodeRestriction Enforcement (Simulating Compromised Kubelet Mutation)
Simulate a compromised Kubelet attempt to modify labels on another node (`worker-02`) or apply restricted labels on itself using the Kubelet client certificate credentials.

Create a raw patch request file `node-patch.json`:
```json
{
  "metadata": {
    "labels": {
      "node-restriction.kubernetes.io/compromised": "true"
    }
  }
}
```

Execute patch request to `kube-apiserver` using Kubelet's client certificate credentials:

```bash
curl -sk --cert /var/lib/kubelet/pki/kubelet-client-current.pem \
         --key /var/lib/kubelet/pki/kubelet-client-current.pem \
         -X PATCH \
         -H "Content-Type: application/strategic-merge-patch+json" \
         --data @node-patch.json \
         https://127.0.0.1:6443/api/v1/nodes/worker-01
```

**Expected Output:**
```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "nodes \"worker-01\" is forbidden: is restricted from modifying labels with prefix node-restriction.kubernetes.io/",
  "reason": "Forbidden",
  "details": {
    "name": "worker-01",
    "kind": "nodes"
  },
  "code": 403
}
```

---

### Module 3 Comprehension Questions

**Question 3.1:** What exact X.509 Subject attributes are required in a Kubelet client certificate for the Node Authorizer to correctly identify it as a valid node agent?
- A) `O = system:kubelet`, `CN = node:<nodeName>`
- B) `O = system:nodes`, `CN = system:node:<nodeName>`
- C) `O = kubernetes:nodes`, `CN = kubelet:<nodeName>`
- D) `O = system:masters`, `CN = system:node-agent`

**Question 3.2:** Which of the following operations would be **rejected** by the `NodeRestriction` admission controller if executed by Kubelet `worker-01`?
- A) Updating the status of a Pod scheduled on `worker-01`.
- B) Reporting status updates (e.g., DiskPressure) for `worker-01`.
- C) Fetching a Secret mounted by a Pod scheduled on `worker-01`.
- D) Modifying annotations or labels on node `worker-02`.

---

### Module 4: Disabling Legacy Ports, Cipher Hardening & CRI Socket Diagnostics

#### Step 4.1: Audit Open System Ports for Legacy Read-Only Port
The legacy read-only port (`10255`) historically provided unauthenticated access to pod specs, metrics, and health data. In production environments, `readOnlyPort` must be set to `0`.

Audit open listening sockets on the host operating system:

```bash
ss -tulpn | grep -E "10255|10250"
```

**Expected Output (Secure):**
```text
tcp   LISTEN 0      4096       *:10250            *:*    users:(("kubelet",pid=142091,fd=31))
```
*(Notice TCP port `10255` is absent from the listening socket table).*

If port `10255` appears, ensure `readOnlyPort: 0` is defined in `/var/lib/kubelet/config.yaml`.

#### Step 4.2: Inspect Container Runtime Interface (CRI) Socket Security
The Kubelet communicates locally with the container runtime (e.g., `containerd`) over a Unix domain socket (typically `/run/containerd/containerd.sock`). Access to this socket grants root-equivalent control over all containers on the host.

Audit ownership and permissions of the CRI domain socket:

```bash
ls -la /run/containerd/containerd.sock
```

**Expected Output:**
```text
srw-rw---- 1 root root 0 Aug  7 18:00 /run/containerd/containerd.sock
```

> [!CAUTION]
> If non-root users or unprivileged containers mount `/run/containerd/containerd.sock`, they can bypass all Kubernetes security controls (PodSecurityStandards, RBAC, NetworkPolicies) and gain full container breakout onto the host system.

#### Step 4.3: Perform CRI Level Diagnostics with `crictl`
Use `crictl` to interact directly with the CRI socket for low-level node debugging.

```bash
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock info | grep -A 10 "containerd"
```

**Expected Output:**
```json
    "containerd": {
      "version": "1.7.13",
      "revision": "7cbf65a396706173223f9583a2d591a27e0b9040",
      "dynamicPlugins": {},
      "pendingPlugins": null
    }
```

Verify running pods directly at the runtime layer:

```bash
sudo crictl pods --limit 3
```

**Expected Output:**
```text
POD ID              CREATED             STATE               NAME                        NAMESPACE           ATTEMPT             DEFAULT
a1b2c3d4e5f6        2 hours ago         Ready               coredns-768b85b76f-2v48l    kube-system         0                   (default)
f6e5d4c3b2a1        2 hours ago         Ready               kube-proxy-8j9xz            kube-system         0                   (default)
```

---

### Module 4 Comprehension Questions

**Question 4.1:** What is the security impact of setting `readOnlyPort: 0` in the `KubeletConfiguration`?
- A) It disables HTTPS encryption on port 10250.
- B) It closes legacy HTTP TCP port 10255, eliminating unauthenticated access to pod information and node stats.
- C) It prevents the Kubelet from reading `/etc/kubernetes/pki/ca.crt`.
- D) It places the Kubelet in read-only mode, blocking pod creations on the node.

**Question 4.2:** Why must mounting host Unix domain sockets such as `/run/containerd/containerd.sock` inside non-administrative Pods be restricted via Pod Security Standards (`Restricted` profile)?
- A) It increases CPU consumption on the Kubelet loop.
- B) It allows containers to interact directly with the runtime engine, enabling complete host takeover and security control bypass.
- C) It causes `crictl` binary execution timeouts.
- D) It forces Kubelet to fallback to cgroups v1 driver.

---

## Exercise Solutions & Technical Explanations

<details>
<summary>Click to expand answers and full technical explanations...</summary>

### Module 1 Answers

**Question 1.1: Correct Answer: B (`401 Unauthorized`)**
- **Explanation:** When `authentication.anonymous.enabled` is set to `false`, any incoming request that lacks credentials (X.509 client certificates or Bearer tokens) fails the authentication phase. Kubelet returns HTTP `401 Unauthorized`. HTTP `403 Forbidden` occurs during the authorization phase (i.e., when authentication succeeds but the subject lacks RBAC permissions).

**Question 1.2: Correct Answer: B (It sends a `TokenReview` request to the `kube-apiserver`)**
- **Explanation:** When `authentication.webhook.enabled: true` is configured, Kubelet delegates Bearer token verification to the API server. It issues an HTTP POST containing a `authentication.k8s.io/v1` `TokenReview` object to the `kube-apiserver`. The API server validates the signature/expiration of the token and returns the user identity (`username`, `groups`, `uid`) back to the Kubelet.

---

### Module 2 Answers

**Question 2.1: Correct Answer: B (`nodes/proxy` grants complete execution privileges inside any container running on that node)**
- **Explanation:** The `nodes/proxy` subresource maps to Kubelet endpoints `/exec`, `/attach`, `/portForward`, and `/run`. Granting `nodes/proxy` permission to an identity allows that identity to open an interactive shell (`kubectl exec`) inside *any* pod running on the target node, including privileged system pods (`kube-system`). Monitoring agents should only be granted `nodes/metrics` and `nodes/stats`.

**Question 2.2: Correct Answer: B (`SubjectAccessReview`)**
- **Explanation:** In `authorization.mode: Webhook`, once Kubelet authenticates the caller, it transmits an `authorization.k8s.io/v1` `SubjectAccessReview` spec to the `kube-apiserver`. The spec details the user identity, requested verb (`get`, `create`), resource (`nodes`), and subresource (`proxy`, `metrics`). The API server evaluates RBAC rules and returns `allowed: true` or `allowed: false`.

---

### Module 3 Answers

**Question 3.1: Correct Answer: B (`O = system:nodes`, `CN = system:node:<nodeName>`)**
- **Explanation:** The Node Authorizer explicitly checks X.509 certificate subject fields. The Organization MUST be `system:nodes` and the Common Name MUST strictly follow the format `system:node:<nodeName>`. If these exact strings are not present, the request is not recognized as coming from a valid node agent and Node Authorizer rules are skipped or rejected.

**Question 3.2: Correct Answer: D (Modifying annotations or labels on node `worker-02`)**
- **Explanation:** The `NodeRestriction` admission controller restricts a Kubelet to operating exclusively on its own node's resources. `worker-01` is strictly forbidden from reading/modifying node objects, pods, or status belonging to `worker-02`. Furthermore, `NodeRestriction` blocks Kubelet from adding labels prefixed with `node-restriction.kubernetes.io/` even on its own node object.

---

### Module 4 Answers

**Question 4.1: Correct Answer: B (It closes legacy HTTP TCP port 10255, eliminating unauthenticated access...)**
- **Explanation:** Historically, Kubelet served unencrypted, unauthenticated metrics and health data over TCP port 10255. Setting `readOnlyPort: 0` disables this listener entirely, forcing all clients to connect via HTTPS port 10250 where authentication and authorization pipelines are enforced.

**Question 4.2: Correct Answer: B (It allows containers to interact directly with the runtime engine...)**
- **Explanation:** The CRI socket (`/run/containerd/containerd.sock`) is the low-level management interface for containerd. Anyone with write access to this socket can issue API calls to spin up privileged containers, mount host root filesystems (`/`), inspect host network namespaces, or terminate arbitrary host processes. Access to the socket effectively grants root privileges on the node host.

</details>