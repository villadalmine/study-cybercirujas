# KCSA Study Guide: Topic 2.4 - Kubelet Security & Architecture

## 1. Production Architectural Motivation & Problem Statement

The `kubelet` is the primary node-level agent running on every worker and control plane node within a Kubernetes cluster. It acts as the bridge between the centralized Kubernetes Control Plane (`kube-apiserver`) and the underlying container runtime (via the Container Runtime Interface, CRI). 

From a Platform Architecture and SRE perspective, the `kubelet` represents one of the most critical attack surfaces in a Kubernetes environment:
1. **Direct Workload Execution Control**: The `kubelet` exposes HTTP endpoints (by default on port `10250`) that allow pod creation, command execution (`exec`), log streaming (`logs`), port forwarding (`portforward`), and container debugging.
2. **Credential & Secret Exposure**: The `kubelet` manages node-bound credentials (such as client certificates and tokens) and fetches `Secrets`, `ConfigMaps`, and volume credentials required by scheduled pods.
3. **Privilege Escalation Vector**: Misconfigured `kubelet` authentication or authorization allows unauthenticated network attackers or compromised workloads to invoke the Kubelet API directly, bypassing `kube-apiserver` RBAC controls and achieving remote code execution (RCE) as `root` inside containers or on the host node.

```
                   [ Attacker / Compromised Pod ]
                                 |
                                 | (Direct HTTP call to :10250)
                                 v
   +-------------------------------------------------------------+
   | Node Host                                                   |
   |                                                             |
   |   [ Kubelet HTTP API Server (Port 10250) ]                  |
   |     |                                                       |
   |     +-- Authentication Check  (--anonymous-auth=false)      |
   |     |                                                       |
   |     +-- Authorization Check   (--authorization-mode=Webhook)|
   |     |                                                       |
   |     v                                                       |
   |   [ CRI Shim / Runtime (containerd / crio) ]                |
   |     |                                                       |
   |     v                                                       |
   |   [ Host Kernel & Container Namespaces ]                    |
   +-------------------------------------------------------------+
```

### Key Security Threats Addressed in KCSA Domain 2.4
- **Unauthenticated Kubelet API Access**: Default or insecure configurations allowing anonymous access to port `10250` or enabling the legacy read-only port `10255`.
- **Bypassing API Server Authorization**: Direct access to `10250/exec/` allowing attackers to execute commands within pods without generating audit logs in `kube-apiserver`.
- **Node Impersonation & Secret Harvesting**: Nodes requesting credentials outside their authorization scope if `NodeRestriction` admission plugin and `Node` authorizer are disabled.
- **Weak TLS Ciphers & Expired Certificates**: Vulnerability to Man-In-The-Middle (MITM) attacks during control-plane-to-kubelet traffic.

---

## 2. Technical Comparisons & Trade-off Matrix

### Table 2.4a: Kubelet Authentication Modes

| Authentication Mode | Configuration (`KubeletConfiguration`) | Security Posture | Performance Impact | Operational Complexity | Use Case / Production Recommendation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Anonymous** | `authentication.anonymous.enabled: true` | **CRITICAL RISK**. Anyone with network access to port 10250 can execute commands as root in containers. | Zero overhead (no validation). | Low | **NEVER** in production. Must be disabled. |
| **x509 Client Certificates** | `authentication.x509.clientCAFile: /etc/kubernetes/pki/ca.crt` | **HIGH**. Validates client TLS certificates against trusted CA. | Low (TLS handshake CPU cost only). | Medium (Requires CA distribution). | **REQUIRED**. Validates `kube-apiserver` client certs when it connects to Kubelet. |
| **Bearer Token / Webhook** | `authentication.webhook.enabled: true` | **HIGH**. Validates bearer tokens against `kube-apiserver` via `TokenReview` API. | Low-Medium (Mitigated by TTL caching). | Medium (Requires `kube-apiserver` connectivity). | **RECOMMENDED**. Used alongside x509 for token-based API server authentication. |

### Table 2.4b: Kubelet Authorization Modes

| Authorization Mode | Configuration (`KubeletConfiguration`) | Security Mechanics | Risk Profile | Production Suitability |
| :--- | :--- | :--- | :--- | :--- |
| **AlwaysAllow** | `authorization.mode: AlwaysAllow` | Grants full access to any authenticated user/client, regardless of RBAC rules. | **HIGH**. Authenticated users with low privileges can perform `exec` or `attach`. | **UNSUITABLE** for production. |
| **Webhook** | `authorization.mode: Webhook` | Calls `kube-apiserver` `SubjectAccessReview` API to verify if the identity has permissions on `nodes/proxy`, `nodes/log`, `nodes/exec`, etc. | **SECURE**. Enforces global RBAC policy on all Kubelet endpoints. | **MANDATORY** for CIS Benchmark compliance. |

### Table 2.4c: Kubelet Network & Resource Hardening Trade-offs

| Hardening Feature | Insecure / Legacy State | Hardened Production State | Operational Trade-off / Considerations |
| :--- | :--- | :--- | :--- |
| **Read-Only Port** | `readOnlyPort: 10255` | `readOnlyPort: 0` | Disabling port 10255 prevents unauthenticated pod spec metrics leakage. Third-party monitoring agents must be updated to use authenticated port 10250 or cAdvisor metrics endpoint with bearer tokens. |
| **Protect Kernel Defaults** | `protectKernelDefaults: false` | `protectKernelDefaults: true` | Kubelet will fail to start if kernel sysctls (e.g., `vm.overcommit_memory`) do not match required Kubernetes defaults. Prevents silent runtime failures due to misconfigured host OS parameters. |
| **Server TLS Rotation** | Static TLS certs | `serverTLSBootstrap: true` | Kubelet automatically requests server certificates via the CSR API (`certificates.k8s.io`). Requires automated CSR approval controller (e.g., `kube-controller-manager` auto-approval rules). |

---

## 3. Production-Grade Manifests & Infrastructure Configurations

### 3.1 Hardened Kubelet Configuration File (`/var/lib/kubelet/config.yaml`)

This manifest conforms to `kubelet.config.k8s.io/v1beta1` and implements strict CIS Kubernetes Benchmark recommendations.

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: 0.0.0.0
port: 10250
readOnlyPort: 0
healthzPort: 10248
healthzBindAddress: 127.0.0.1
cgroupDriver: systemd
hairpinMode: hairpin-veth
protectKernelDefaults: true
serializeImagePulls: false

# Authentication Configuration
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
    cacheTTL: 2m0s
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt

# Authorization Configuration
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s

# TLS Hardening
tlsCertFile: /var/lib/kubelet/pki/kubelet-server.crt
tlsPrivateKeyFile: /var/lib/kubelet/pki/kubelet-server.key
tlsMinVersion: VersionTLS12
tlsCipherSuites:
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256

# Certificate Rotation
rotateCertificates: true
serverTLSBootstrap: true

# Resource Reservation & Management
kubeReserved:
  cpu: 200m
  memory: 512Mi
  ephemeral-storage: 1Gi
systemReserved:
  cpu: 200m
  memory: 512Mi
  ephemeral-storage: 1Gi
evictionHard:
  memory.available: 100Mi
  nodefs.available: 10%
  nodefs.inodesFree: 5%

# Event & Logging Rate Limiting
eventRecordQPS: 5
eventBurst: 10
containerLogMaxSize: 10Mi
containerLogMaxFiles: 5
```

### 3.2 Production Systemd Service Unit File (`/etc/systemd/system/kubelet.service`)

```ini
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --config=/var/lib/kubelet/config.yaml \
  --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
  --kubeconfig=/etc/kubernetes/kubelet.conf \
  --node-ip=192.168.1.50 \
  --v=2
Restart=always
RestartSec=10s
StartLimitInterval=0
KillMode=process
LimitNOFILE=65536
LimitNPROC=65536
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
```

### 3.3 Control Plane RBAC for Kubelet API Access

To allow `kube-apiserver` (or monitoring services) to fetch metrics and execute commands via the Kubelet API, explicit RBAC must be defined.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:kubelet-api-admin
rules:
- apiGroups: [""]
  resources:
  - nodes/proxy
  - nodes/stats
  - nodes/log
  - nodes/spec
  - nodes/metrics
  verbs:
  - "*"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-apiserver-kubelet-api
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kubelet-api-admin
subjects:
- kind: User
  name: kube-apiserver
  apiGroup: rbac.authorization.k8s.io
```

---

## 4. Real Terminal CLI Commands and Expected Outputs

### 4.1 Verifying Anonymous Access is Blocked on Port 10250

Attempting an unauthenticated HTTP request directly to the Kubelet API port must result in an `HTTP 401 Unauthorized` response.

```bash
$ curl -k -i https://127.0.0.1:10250/metrics
```
```http
HTTP/2 401 
audit-id: 204d13fa-2384-4e2b-b9d9-952467d028cf
content-type: text/plain; charset=utf-8
x-content-type-options: nosniff
content-length: 13

Unauthorized
```

### 4.2 Verifying Read-Only Port 10255 is Fully Disabled

```bash
$ curl -i http://127.0.0.1:10255/pods
```
```text
curl: (7) Failed to connect to 127.0.0.1 port 10255 after 0 ms: Connection refused
```

### 4.3 Authenticating against Kubelet API using Client Certificates

Using the API server's client certificate to interact securely with the Kubelet `/runningpods/` endpoint:

```bash
$ curl --cacert /etc/kubernetes/pki/ca.crt \
       --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
       --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
       -s https://127.0.0.1:10250/runningpods/ | jq '.items[0].metadata'
```
```json
{
  "name": "coredns-768b85b76f-4x2lm",
  "namespace": "kube-system",
  "uid": "a1c2b3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
}
```

### 4.4 Inspecting Active Kubelet Configuration at Runtime

```bash
$ kubectl get --raw "/api/v1/nodes/node-01/proxy/configz" | jq '.kubeletconfig.authentication'
```
```json
{
  "anonymous": {
    "enabled": false
  },
  "webhook": {
    "cacheTTL": "2m0s",
    "enabled": true
  },
  "x509": {
    "clientCAFile": "/etc/kubernetes/pki/ca.crt"
  }
}
```

### 4.5 Testing Approved TLS Cipher Suites with OpenSSL

```bash
$ openssl s_client -connect 127.0.0.1:10250 -tls1_3 2>&1 | grep "Protocol"
```
```text
Protocol  : TLSv1.3
```

---

## 5. Verification & Troubleshooting / Diagnostic Playbook

### Flowchart: Kubelet Authentication & Authorization Failure Spectrum

```
                [ Client Connection Request to Port 10250 ]
                                     |
                         Is TLS Handshake Valid?
                                /         \
                              NO           YES
                             /               \
              [ TLS Handshake Error ]     Is Client Authenticated?
               (Check Client CA File)        (x509 / Webhook Token)
                                             /                  \
                                           NO                    YES
                                          /                        \
                            [ 401 Unauthorized ]            Is Client Authorized?
                             (Check --anonymous-auth)       (Webhook SubjectAccessReview)
                                                            /                  \
                                                          NO                    YES
                                                         /                        \
                                          [ 403 Forbidden ]                 [ 200 OK ]
                                        (Check RBAC ClusterRole)
```

### Scenario 1: `kubectl exec` / `kubectl logs` fails with `401 Unauthorized` or `403 Forbidden`

**Symptom**:
```bash
$ kubectl exec -it coredns-768b85b76f-4x2lm -n kube-system -- sh
Error from server (Forbidden): error execing into pod: open //node-01:10250/exec/kube-system/coredns-768b85b76f-4x2lm/coredns: 403 Forbidden
```

**Diagnostic Steps**:
1. Inspect `kube-apiserver` logs to see if Kubelet authentication credentials are standard:
   ```bash
   $ journalctl -u kubelet | grep -E "Unable to authenticate|Forbidden"
   ```
2. Verify that `kube-apiserver` has the required flags configured to authenticate itself to the Kubelet:
   - `--kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt`
   - `--kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key`
   - `--kubelet-certificate-authority=/etc/kubernetes/pki/ca.crt`
3. Verify the subject CN/OU of the API server's Kubelet client certificate:
   ```bash
   $ openssl x509 -in /etc/kubernetes/pki/apiserver-kubelet-client.crt -text -noout | grep -E "Subject:|Issuer:"
   ```
   *Expected Output*:
   ```text
   Issuer: CN = kubernetes
   Subject: O = system:masters, CN = kube-apiserver-kubelet-client
   ```
4. If Kubelet uses `authorization.mode: Webhook`, ensure the `system:masters` group or `kube-apiserver-kubelet-client` user has a `ClusterRoleBinding` for `system:kubelet-api-admin`.

---

### Scenario 2: Kubelet Fails to Start due to Kernel Defaults (`protectKernelDefaults: true`)

**Symptom**:
`systemctl status kubelet` reports state `failed` with crash loop exit status.

**Diagnostic Log Extraction**:
```bash
$ journalctl -u kubelet -n 20 --no-pager | grep -i "kernel"
```
*Output*:
```text
fatal error: failed to start Kubelet: invalid configuration: vm.overcommit_memory sysctl mismatch: expected 1, got 0
```

**Remediation**:
Update `/etc/sysctl.d/99-kubernetes.conf` with required kernel tunables and reload:

```bash
$ cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes.conf
vm.overcommit_memory = 1
kernel.panic = 10
kernel.panic_on_oops = 1
EOF

$ sudo sysctl --system
$ sudo systemctl restart kubelet
```

---

### Scenario 3: Kubelet Certificate Auto-Rotation Pending Approval

**Symptom**:
Kubelet server certificate expires, leading to `x509: certificate expired or not yet valid` errors when `kube-apiserver` connects to `10250`.

**Diagnostic Steps**:
1. List pending Certificate Signing Requests (CSRs) in the cluster:
   ```bash
   $ kubectl get csr | grep -i pending
   ```
   *Output*:
   ```text
   csr-9z8x7   2m   kubernetes.io/kubelet-serving   system:node:node-01   Pending
   ```
2. Inspect the details of the pending CSR:
   ```bash
   $ kubectl describe csr csr-9z8x7
   ```
3. Manually approve the server CSR if auto-approval is not enabled in `kube-controller-manager`:
   ```bash
   $ kubectl certificate approve csr-9z8x7
   ```

---

## 6. References

- **CNCF KCSA Exam Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Kubernetes Documentation - Kubelet Security Configuration**: [https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
- **Kubernetes Documentation - Controlling Kubelet Authentication/Authorization**: [https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/)
- **Kubernetes Documentation - TLS Bootstrap and Certificate Rotation**: [https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/)
- **CIS Kubernetes Benchmark**: [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)