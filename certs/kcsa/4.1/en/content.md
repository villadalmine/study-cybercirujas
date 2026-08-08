# CNCF KCSA Study Guide: Topic 4.1 — Kubernetes Trust Boundaries and Data Flow

---

## 1. Motivation and Production Architectural Problem

### 1.1 The Production Security Problem: Implicit Trust and Flat Architectures
In a default Kubernetes deployment, the network model assumes flat connectivity across all pods, nodes, and control plane endpoints. This implicit trust model creates a severe security vulnerability in enterprise multi-tenant environments:

1. **Unchecked Blast Radius:** A compromised container in a low-privilege namespace can probe every pod IP across the cluster overlay network (CNI flat network) and attempt lateral movement toward high-value control plane or data plane services.
2. **Node-to-Control-Plane Over-Privilege:** Worker nodes host untrusted customer or application code. If a container breaks out to the host kernel (container escape), an attacker possessing the worker node's `kubelet` client credentials could attempt to read secrets, mutate cluster state, or hijack other nodes if authorization boundaries are not strictly enforced.
3. **Data Plane Interception & Impersonation:** Traffic between microservices or between `kube-apiserver` and worker nodes (`kubelet` log streaming, `exec`, `port-forward`) sent over unencrypted or unauthenticated channels allows adversary-in-the-middle (AiTM) eavesdropping and credential harvesting.
4. **Long-Lived Identity Vulnerabilities:** Legacy Kubernetes ServiceAccount tokens were static JWTs stored indefinitely as Secrets in `etcd`. Exfiltration of such tokens provided attackers with persistent API server access outside the cluster boundary.

### 1.2 Kubernetes Architectural Trust Zones
To establish zero-trust governance, a production Kubernetes cluster must be divided into four distinct **Trust Zones**, separated by cryptographic and policy-enforced **Trust Boundaries**:

```
+-----------------------------------------------------------------------------------+
| ZONE 0: External / Ingress Boundary (Untrusted)                                   |
| Clients, External API Consumers, Public Internet                                  |
+-----------------------------------------------------------------------------------+
                                         | Ingress / TLS Termination (ALPN / SNI)
                                         v
+-----------------------------------------------------------------------------------+
| ZONE 1: Control Plane Core (Highest Trust / Cryptographic Core)                  |
|  +-------------------+   +--------------------+   +----------------------------+  |
|  |   kube-apiserver  |---| etcd (Encrypted DB)|---| controller-mgr / scheduler |  |
|  +-------------------+   +--------------------+   +----------------------------+  |
+-----------------------------------------------------------------------------------+
       ^ (mTLS / NodeAuthorizer)                     | (Kube-apiserver Proxy / mTLS)
       |                                             v
+-----------------------------------------------------------------------------------+
| ZONE 2: Worker Node Host Plane (Medium Trust)                                     |
|  +--------------------+   +-------------------+   +----------------------------+  |
|  | Kubelet Agent      |---| Container Runtime |---| CNI Daemon (eBPF/iptables) |  |
|  +--------------------+   +-------------------+   +----------------------------+  |
+-----------------------------------------------------------------------------------+
                                         | Container Isolation / Linux Namespaces
                                         v
+-----------------------------------------------------------------------------------+
| ZONE 3: Pod Execution Environment (Low Trust / Workload Isolation Zone)          |
|  +-------------------------------+      +--------------------------------------+  |
|  | Tenant A Pod (Restricted Context)|      | Tenant B Pod (Sandboxed/gVisor)      |  |
|  +-------------------------------+      +--------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### 1.3 Control Plane and Data Plane Data Flow Vectors

#### A. Control Plane to Node Flow (API Server initiated)
* **Vectors:** `kubectl exec`, `kubectl logs`, `kubectl attach`, `kubectl port-forward`.
* **Path:** Client $\rightarrow$ `kube-apiserver` $\rightarrow$ `kubelet` (Port 10250).
* **Trust Requirement:** `kube-apiserver` must authenticate the target `kubelet` using client certificates (mTLS) to prevent rogue node registration or proxy hijack.

#### B. Node to Control Plane Flow (Worker initiated)
* **Vectors:** Pod scheduling state updates, node status heartbeats, Secret/ConfigMap retrieval for pods.
* **Path:** `kubelet` $\rightarrow$ `kube-apiserver` (Port 6443).
* **Trust Requirement:** Must use client certificates authenticated under the `system:nodes` group and authorized via the **Node Authorizer** alongside the `NodeRestriction` admission controller. This limits the `kubelet` to reading only secrets mounted to pods assigned to *that specific node*.

#### C. Pod to API Server Flow (In-Cluster Workload initiated)
* **Vectors:** Operators, service discovery, in-cluster controllers calling Kubernetes APIs.
* **Path:** Pod $\rightarrow$ In-cluster `kubernetes.default.svc` Service (Port 443) $\rightarrow$ `kube-apiserver`.
* **Trust Requirement:** Bound ServiceAccount Tokens via the `TokenRequest` API with restricted duration (`expirationSeconds`) and audience binding (`audiences`), avoiding static secret persistence.

#### D. Pod to Pod Flow (East-West Inter-Workload Traffic)
* **Vectors:** REST, gRPC, DB queries across pods.
* **Path:** Pod A veth interface $\rightarrow$ Host CNI Bridge / eBPF Datapath $\rightarrow$ Encrypted Overlay (IPsec/WireGuard) $\rightarrow$ Pod B veth.
* **Trust Requirement:** Enforced explicit **Default Deny** NetworkPolicies coupled with cryptographic identity-based mTLS (e.g., via Service Mesh / SPIFFE identities).

---

## 2. Technical Comparatives and Trade-Off Analysis

### 2.1 Comparative Matrix: Trust Boundary Enforcement Mechanisms

| Security Vector | Mechanism | Isolation Strength | Performance Overhead | Operational Complexity | Blast Radius Reduction |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Pod-to-Pod Network** | Default CNI Overlay | None (Flat network) | 0% additional | Extremely Low | Minimal (0%) |
| **Pod-to-Pod Network** | Standard `NetworkPolicy` (iptables) | Medium (L3/L4 filtering) | Low (<2% CPU latency) | Medium | High (Restricts ports & IP paths) |
| **Pod-to-Pod Network** | eBPF Microsegmentation + mTLS (Cilium) | High (L3-L7 policy + identity) | Low (<1% CPU, sub-ms) | High | Critical (Enforces Zero-Trust identity) |
| **Container-to-Host** | Standard OCI Runtime (`runc`) | Low (Shared Linux kernel) | 0% baseline | Low | Low (Vulnerable to zero-day kernel exploits) |
| **Container-to-Host** | Sandboxed Runtime (`gVisor` / `runsc`) | Very High (Syscall interception proxy) | Medium-High (10-30% I/O & syscall delay) | High | Critical (Container cannot reach host kernel directly) |
| **Pod Identity** | Legacy Static SA Tokens | Low (Non-expiring JWT Secret) | 0% | Low | Low (Exfiltrated token works indefinitely) |
| **Pod Identity** | Bound ServiceAccount Tokens (`TokenRequest`) | High (Short-lived, audience-scoped) | Negligible | Medium | High (Token invalid outside specified pod/audience) |
| **Node-to-API** | Default RBAC for Nodes | Medium (Can list cluster assets) | 0% | Low | Low-Medium |
| **Node-to-API** | Node Authorizer + `NodeRestriction` | High (Strict node-scoped RBAC) | 0% | Built-in | Critical (Node can only access its own bound data) |

---

## 3. Production Manifold Manifests & Infrastructure Configurations

### 3.1 Hardened Ingress/Egress Default-Deny NetworkPolicy with Explicit Allow
This manifest strictly segregates the target workload boundary, enforcing a zero-trust network posture:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-payment-processor
  namespace: finance-prod
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: payment-processor
      app.kubernetes.io/tier: backend
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Allow ingress strictly from api-gateway pods inside gateway-prod namespace on port 8443
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: gateway-prod
      podSelector:
        matchLabels:
          app.kubernetes.io/name: api-gateway
    ports:
    - protocol: TCP
      port: 8443
  egress:
  # Allow egress strictly to PostgreSQL database pods inside database-prod namespace on port 5432
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: database-prod
      podSelector:
        matchLabels:
          app.kubernetes.io/name: postgresql-cluster
    ports:
    - protocol: TCP
      port: 5432
  # Allow egress strictly to CoreDNS for cluster internal DNS resolution
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

### 3.2 Sandboxed Workload Security Context and RuntimeClass Isolation
Enforces both host-kernel isolation via `gVisor` (`RuntimeClass`) and strict container-level pod security standards (`Restricted` profile):

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor-sandbox
handler: runsc
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: untrusted-processor
  namespace: finance-prod
  labels:
    app.kubernetes.io/name: untrusted-processor
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: untrusted-processor
  template:
    metadata:
      labels:
        app.kubernetes.io/name: untrusted-processor
    spec:
      runtimeClassName: gvisor-sandbox
      serviceAccountName: processor-sa
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: processor
        image: internal-registry.enterprise.io/finance/processor:v2.4.1
        imagePullPolicy: IfNotPresent
        command: ["/app/processor"]
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
        volumeMounts:
        - name: tmp-dir
          mountPath: /tmp
        - name: bound-sa-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
      volumes:
      - name: tmp-dir
        emptyDir:
          medium: Memory
          sizeLimit: 64Mi
      - name: bound-sa-token
        projected:
          sources:
          - serviceAccountToken:
              audience: https://vault.enterprise.io
              expirationSeconds: 3600
              path: vault-token
```

### 3.3 Production Hardened KubeletConfiguration (Node-to-Control-Plane Trust Boundary)
This configuration secures the Kubelet authentication and authorization endpoints to eliminate anonymous access and enforce Webhook authorization via the API Server:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
    cacheTTL: 2m0s
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
readOnlyPort: 0
tlsCertFile: /var/lib/kubelet/pki/kubelet-server.crt
tlsPrivateKeyFile: /var/lib/kubelet/pki/kubelet-server.key
rotateCertificates: true
serverTLSBootstrap: true
protectKernelDefaults: true
streamingConnectionIdleTimeout: 4h0m0s
makeIPTablesAvailable: true
eventRecordQPS: 5
```

---

## 4. Real CLI Executions and Expected Terminal Outputs

### 4.1 Inspecting API Server Admission Control and Node Restriction Enforcements
Verify that the `Node` authorizer and `NodeRestriction` admission controller are correctly blocking cross-node resource access attempts.

```bash
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type
```
```text
NAME                                STATUS
control-plane-01.internal.infra    Ready
worker-node-01.internal.infra      Ready
worker-node-02.internal.infra      Ready
```

Simulate a compromised Kubelet on `worker-node-01` attempting to retrieve a secret bound exclusively to `worker-node-02`:

```bash
$ curl -k -v --cert /var/lib/kubelet/pki/kubelet-client-current.pem \
    --key /var/lib/kubelet/pki/kubelet-client-current.pem \
    https://10.96.0.1:443/api/v1/namespaces/finance-prod/secrets/database-credentials-node02
```
```text
*   Trying 10.96.0.1:443...
* Connected to 10.96.0.1 (10.96.0.1) port 443
* ALPN: curl offers h2,http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, CERT (11):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
> GET /api/v1/namespaces/finance-prod/secrets/database-credentials-node02 HTTP/2
> Host: 10.96.0.1:443
> User-Agent: curl/7.88.1
> Accept: */*
> 
< HTTP/2 403 
< audit-id: 8c3e16b9-7b3c-4d8a-9e11-d0092bf2310b
< content-type: application/json
< x-kubernetes-pf-priority-level-uid: 3b94a821-2e11-4f10-9111-c91823901aef
< content-length: 371
< 
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "secrets \"database-credentials-node02\" is forbidden: node \"worker-node-01.internal.infra\" is cannot get resource \"secrets\" in API group \"\" in the namespace \"finance-prod\"",
  "reason": "Forbidden",
  "details": {
    "name": "database-credentials-node02",
    "group": "",
    "kind": "secrets"
  },
  "code": 403
}
```

### 4.2 Verifying Projected ServiceAccount Token Audience and Expiration
Inspect the content of a mounted bound ServiceAccount token directly from inside a running container to verify cryptographic boundaries.

```bash
$ kubectl exec -it deploy/untrusted-processor -n finance-prod -c processor -- cat /var/run/secrets/tokens/vault-token | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```
```json
{
  "aud": [
    "https://vault.enterprise.io"
  ],
  "exp": 1754611499,
  "iat": 1754607899,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "nbf": 1754607899,
  "sub": "system:serviceaccount:finance-prod:processor-sa",
  "kubernetes.io": {
    "namespace": "finance-prod",
    "pod": {
      "name": "untrusted-processor-67998b688c-9x2kz",
      "uid": "a4d339ef-1188-4e8c-a111-90327bd98c31"
    },
    "serviceaccount": {
      "name": "processor-sa",
      "uid": "e812d341-99ab-42cc-b657-3f9b0011234a"
    },
    "warnafter": 1754611506
  }
}
```

### 4.3 Auditing Node Kubelet Client Certificate Subject & SANs
Verify that Kubelet client certificates follow the required standard for `NodeAuthorizer` matching (`O=system:nodes`, `CN=system:node:<node-name>`).

```bash
$ openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -text -noout | grep -E "Subject:|DNS:|IP:"
```
```text
        Subject: O = system:nodes, CN = system:node:worker-node-01.internal.infra
                DNS:worker-node-01.internal.infra, IP Address:10.0.12.45
```

### 4.4 Probing Inter-Pod Network Isolation Boundaries via Netcat
Demonstrate that ingress microsegmentation blocks non-authorized pod communication across namespaces.

```bash
$ kubectl run connectivity-test --rm -i --tty --image=alpine:latest --namespace=default -- nc -zv -w 3 payment-processor.finance-prod.svc.cluster.local 8443
```
```text
nc: bad address 'payment-processor.finance-prod.svc.cluster.local'
Pod "connectivity-test" deleted
command terminated with exit code 1
```

Now execute the probe targeting the exact IP from an unauthorized pod within the same network segment:

```bash
$ kubectl run connectivity-test-raw --rm -i --tty --image=alpine:latest --namespace=default -- nc -zv -w 3 10.244.2.115 8443
```
```text
nc: connect to 10.244.2.115 port 8443 (tcp) failed: Connection timed out
Pod "connectivity-test-raw" deleted
command terminated with exit code 1
```

---

## 5. Verification and Diagnostic Guide for Broken Boundaries

### 5.1 Failure Matrix & Root Cause Resolution

```
                                  +-------------------------------+
                                  |  SRE Diagnostic Flowchart     |
                                  +-------------------------------+
                                                  |
                                                  v
                                     Is Request Blocked/Failing?
                                                  |
                       +--------------------------+--------------------------+
                       |                                                     |
                       v                                                     v
          HTTP 403 Forbidden (API Level)                       TCP Timeout / Connection Refused
                       |                                                     |
        +--------------+--------------+                       +--------------+--------------+
        |                             |                       |                             |
        v                             v                       v                             v
[NodeAuthorizer Failure]   [Token Audience Mismatch]   [NetworkPolicy Drop]     [Kubelet Port 10250 Block]
Check node CN & Kubelet    Inspect JWT "aud" claim     Run eBPF/Cilium audit    Check API Server client CA
Client Cert validity        against target Service      (`cilium monitor`)       & Kubelet `--client-ca-file`
```

### 5.2 Step-by-Step Troubleshooting Workflows

#### Scenario A: API Server Rejecting Kubelet Communication (Node Restriction Failure)
* **Symptom:** Kubelet fails to post node status or fetch pod configuration (`Status 403 Forbidden`).
* **Diagnostic Command:**
  ```bash
  $ journalctl -u kubelet -n 50 --no-pager | grep -E "E0807|unauthorized|forbidden"
  ```
  *Sample Log Output:*
  `E0807 20:14:02.112341 4102 kubelet_node_status.go:420] Error updating node status: nodes "worker-01" is forbidden: node "worker-node-01.internal.infra" cannot modify node "worker-01"`
* **Root Cause:** The Kubelet client certificate Common Name (`CN=system:node:worker-node-01.internal.infra`) does not match the `--hostname-override` parameter passed to Kubelet (`worker-01`).
* **Remediation:** Align Kubelet `--hostname-override` with the exact CN present in the client certificate issued by the cluster CA, or re-issue the certificate via the CSR API (`certificates.k8s.io`).

#### Scenario B: Inter-Service Data Flow Blocked by Network Policy
* **Symptom:** Application reports `Connection timed out` when communicating with a downstream microservice.
* **Diagnostic Command (Using Cilium eBPF Monitor):**
  ```bash
  $ cilium monitor --type drop -v
  ```
  *Sample Output:*
  ```text
  xx drop skin: policy-denied identity 4210 -> 8912 matching [proto=TCP dst-port=8443]
  POLICY DENIED: Direction=ingress Match=NONE FromIdentity=4210 (ns=default, app=unauthorized-client) ToIdentity=8912 (ns=finance-prod, app=payment-processor)
  ```
* **Root Cause:** Ingress traffic is being dropped by a default-deny `NetworkPolicy` because the originating pod's namespace (`default`) or labels do not match the policy's allowed selector rules.
* **Remediation:** Update the target `NetworkPolicy` ingress section to explicitly include the source `namespaceSelector` and `podSelector`.

#### Scenario C: Projected Token Authentication Failure at External Service (Vault / Cloud Provider)
* **Symptom:** Container application fails to authenticate against external service using mounted projected token.
* **Diagnostic Command:**
  ```bash
  $ kubectl get APIService v1.tokenreviews.k8s.io -o yaml
  ```
  Extract and decode the token:
  ```bash
  $ token=$(kubectl exec deploy/payment-processor -n finance-prod -- cat /var/run/secrets/tokens/vault-token)
  $ jq -R 'split(".") | .[1] | @base64d | fromjson' <<< "$token"
  ```
* **Root Cause:** The `aud` (Audience) claim inside the projected token (`https://vault.enterprise.io`) does not match the expected issuer/audience configured in Vault's Kubernetes authentication backend, or the token has passed its `exp` timestamp.
* **Remediation:** Adjust `spec.containers[*].volumeMounts` token projection `audience` field to match the external identity provider specification, and ensure the API server's `--service-account-issuer` flag matches the OIDC discovery URL expected by external reliance parties.

---

## 6. References

* **CNCF KCSA Official Curriculum:**
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

* **Kubernetes Threat Model and Security Assessment:**
  [https://kubernetes.io/docs/concepts/security/overview/](https://kubernetes.io/docs/concepts/security/overview/)

* **Kubernetes Control Plane to Node Communication Controls:**
  [https://kubernetes.io/docs/concepts/architecture/control-plane-node-communication/](https://kubernetes.io/docs/concepts/architecture/control-plane-node-communication/)

* **Kubernetes Node Authorization and NodeRestriction Admission Plugin:**
  [https://kubernetes.io/docs/reference/access-authn-authz/node/](https://kubernetes.io/docs/reference/access-authn-authz/node/)

* **ServiceAccount Token Volume Projection (Bound Tokens):**
  [https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-volume-projection](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-volume-projection)

* **Kubernetes Network Policies Configuration and Enforcement:**
  [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

* **Kubernetes Sandboxed Runtimes (RuntimeClass):**
  [https://kubernetes.io/docs/concepts/containers/runtime-class/](https://kubernetes.io/docs/concepts/containers/runtime-class/)

* **CIS Kubernetes Benchmark Guidance:**
  [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)