# KCSA Exam Preparation: Domain 5.6 – Connectivity (Weight: 2.29%)

**Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Reference Document:** [CNCF KCSA Curriculum (v1.0.0)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)  
**Official Documentation Sources:**  
- [Kubernetes PKI Certificates and Requirements](https://kubernetes.io/docs/setup/best-practices/certificates/)  
- [Kubernetes Network Policies Specification](https://kubernetes.io/docs/concepts/services-networking/network-policies/)  
- [Istio Security Architecture & PeerAuthentication](https://istio.io/latest/docs/concepts/security/)  
- [SPIFFE/SPIRE Architecture](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/)  
- [Cilium eBPF Datapath & Policy Mechanics](https://docs.cilium.io/en/stable/security/policy/)

---

## Technical Overview & Internal Mechanics

In cloud-native environments, **Connectivity** encompasses the data plane, control plane, and edge network paths. Security in this domain relies on a **Zero-Trust Network Architecture (ZTNA)** where physical or overlay network perimeters are assumed to be compromised.

```
+-----------------------------------------------------------------------------------+
|                                CONTROL PLANE PKI                                  |
|  [ kube-apiserver ] <--- mTLS (X.509 Client Certs) ---> [ etcd / kubelet ]        |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|                             POD-TO-POD DATA PLANE                                 |
|  +------------------------+                     +------------------------------+  |
|  | Pod A (Frontend)       |   mTLS / SPIFFE ID   | Pod B (Backend)              |  |
|  | [Envoy Proxy]          | ===================>| [Envoy Proxy]                |  |
|  +------------------------+                     +------------------------------+  |
|               |                                                |                  |
|               v                                                v                  |
|  +-----------------------------------------------------------------------------+  |
|  | eBPF / CNI NetworkPolicy Engine (Default Deny Ingress & Egress Isolation)   |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|                            EDGE & EGRESS BOUNDARIES                               |
|  [ Ingress Controller (TLS 1.3 / SNI) ] ----> [ Egress Gateway (FQDN / CIDR) ]    |
+-----------------------------------------------------------------------------------+
```

1. **Control Plane & Node PKI Architecture**: Kubernetes relies on an internal Public Key Infrastructure (PKI) hierarchy. The API Server authenticates components (Kubelet, Scheduler, Controller Manager, `kubectl`) using dual X.509 client certificates. The `Subject` field encodes identity via `CN` (Common Name = User/ServiceAccount) and `O` (Organization = Group membership).
2. **Layer 3/4 Microsegmentation (NetworkPolicies)**: Native Kubernetes `NetworkPolicy` resources operate at L3 (IP addresses) and L4 (TCP/UDP/SCTP ports). CNI plugins enforce these rules using kernel primitives:
   - **iptables / netfilter**: Matches packet headers against chains (`KUBE-NWPLCY-*`).
   - **eBPF (Extended Berkeley Packet Filter)**: Attaches BPF programs directly to `tc` (Traffic Control) ingress/egress hooks or socket layers (`sockmap`), bypassing network stack overhead and filtering at the kernel driver layer.
3. **Layer 7 Identity & Service Mesh mTLS**: NetworkPolicies cannot inspect application payloads or cryptographically verify pod identity (due to IP reuse vulnerabilities). Service meshes (e.g., Istio, Linkerd) inject sidecar proxies (Envoy) using `iptables` `PREROUTING` / `OUTPUT` redirect rules (e.g., port 15001/15006). Identity is established via **SPIFFE IDs** (`spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`) embedded in X.509 Subject Alternative Names (SANs) rotated by an internal CA.

---

## Guided Practical Exercises

---

### Exercise 1: Auditing Control Plane PKI and mTLS Mutual Authentication

In this exercise, you will analyze the control plane X.509 certificates, verify SAN entries, and diagnose mTLS authentication requirements on the `kube-apiserver` interface.

#### Execution Steps

1. SSH into your control plane node and list the certificate files used by `kube-apiserver`:

```bash
ls -la /etc/kubernetes/pki/
```

*Expected Output:*
```text
drwxr-xr-x 3 root root 4096 Aug  7 10:00 .
drwxr-xr-x 4 root root 4096 Aug  7 10:00 ..
-rw-r--r-- 1 root root 1099 Aug  7 10:00 ca.crt
-rw------- 1 root root 1679 Aug  7 10:00 ca.key
-rw-r--r-- 1 root root 1272 Aug  7 10:00 apiserver.crt
-rw------- 1 root root 1679 Aug  7 10:00 apiserver.key
-rw-r--r-- 1 root root 1107 Aug  7 10:00 apiserver-kubelet-client.crt
-rw------- 1 root root 1675 Aug  7 10:00 apiserver-kubelet-client.key
-rw-r--r-- 1 root root 1066 Aug  7 10:00 front-proxy-ca.crt
-rw------- 1 root root 1679 Aug  7 10:00 front-proxy-ca.key
```

2. Inspect the X.509 Subject, Issuer, and Subject Alternative Names (SANs) of the API Server server certificate:

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -E "Subject:|Issuer:|DNS:|IP Address:"
```

*Expected Output:*
```text
        Issuer: CN = kubernetes
        Subject: CN = kube-apiserver
            DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, IP Address:10.96.0.1, IP Address:192.168.1.10
```

3. Inspect the client identity encoded inside the admin client certificate used by `kubectl`:

```bash
openssl x509 -in /etc/kubernetes/admin.conf --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null || \
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -text -noout | grep "Subject:"
```

*Expected Output:*
```text
        Subject: O = system:masters, CN = kubernetes-admin
```

4. Attempt an unauthenticated TLS handshake against the secure API server port (6443) using `curl` to verify client certificate rejection:

```bash
curl -k -v https://127.0.0.1:6443/api/v1/namespaces
```

*Expected Output:*
```text
*   Trying 127.0.0.1:6443...
* Connected to 127.0.0.1 (127.0.0.1) port 6443 (#0)
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Request CERT (13):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* TLSv1.3 (OUT), TLS handshake, Change cipher spec (1):
* TLSv1.3 (OUT), TLS handshake, Finished (20):
* HTTP/2 stream 1 allocated
> GET /api/v1/namespaces HTTP/2
> Host: 127.0.0.1:6443
> User-Agent: curl/7.81.0
> Accept: */*
> 
< HTTP/2 401 
< audit-id: e3b890f1-4c12-4a09-91a2-63b7e9bbf011
< content-type: application/json
< x-content-type-options: nosniff
< content-length: 129
< 
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "unauthorized",
  "reason": "Unauthorized",
  "code": 401
}
```

5. Re-issue the request passing the valid X.509 client certificate and private key:

```bash
curl --cacert /etc/kubernetes/pki/ca.crt \
     --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
     --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
     https://127.0.0.1:6443/api/v1/namespaces | grep '"name":' | head -n 3
```

*Expected Output:*
```text
        "name": "default",
        "name": "kube-node-lease",
        "name": "kube-system",
```

---

#### Verification Questions – Block 1

1. **Question 1.1**: In the client certificate subject `O = system:masters, CN = kubernetes-admin`, how does the API Server RBAC authorizer interpret the `O` and `CN` attributes during request evaluation?
2. **Question 1.2**: Why does `kube-apiserver` require specific IP addresses and FQDNs declared under the `X509v3 Subject Alternative Name` extension in `apiserver.crt`, and what cryptographic validation failure occurs if a client connects via an IP not listed in the SAN?

---

### Exercise 2: Implementing Zero-Trust Pod Microsegmentation with Granular NetworkPolicies

In this exercise, you will create a multi-tier application namespace, enforce a strict Default-Deny-All policy, and selectively authorize L4 ingress/egress communication.

#### Execution Steps

1. Create a isolated namespace `production-secure`:

```bash
kubectl create namespace production-secure
```

*Expected Output:*
```text
namespace/production-secure created
```

2. Deploy a `frontend`, `backend`, and `database` pod setup:

```bash
kubectl apply -n production-secure -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  labels:
    app.kubernetes.io/name: frontend
    tier: frontend
spec:
  containers:
  - name: nginx
    image: nginx:1.25-alpine
    ports:
    - containerPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: backend
  labels:
    app.kubernetes.io/name: backend
    tier: backend
spec:
  containers:
  - name: app
    image: hashicorp/http-echo:latest
    args: ["-listen=:8080", "-text=backend response"]
    ports:
    - containerPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: database
  labels:
    app.kubernetes.io/name: database
    tier: database
spec:
  containers:
  - name: db
    image: hashicorp/http-echo:latest
    args: ["-listen=:5432", "-text=db response"]
    ports:
    - containerPort: 5432
EOF
```

*Expected Output:*
```text
pod/frontend created
pod/backend created
pod/database created
```

3. Obtain pod IP addresses and verify initial unrestricted connectivity from `frontend` to `database`:

```bash
DB_IP=$(kubectl get pod database -n production-secure -o jsonpath='{.status.podIP}')
kubectl exec -n production-secure frontend -- wget -qO- --timeout=2 http://${DB_IP}:5432
```

*Expected Output:*
```text
db response
```

4. Apply a **Default Deny All Ingress and Egress** policy to isolate the entire namespace:

```bash
kubectl apply -n production-secure -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production-secure
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
```

*Expected Output:*
```text
networkpolicy.networking.k8s.io/default-deny-all created
```

5. Test connectivity again from `frontend` to `database`. Verify that traffic is dropped at the CNI datapath layer:

```bash
kubectl exec -n production-secure frontend -- wget -qO- --timeout=2 http://${DB_IP}:5432
```

*Expected Output:*
```text
wget: download timed out
command terminated with exit code 1
```

6. Apply granular NetworkPolicies to allow:
   - `frontend` egress to `backend` on TCP port 8080.
   - `backend` ingress from `frontend` on TCP port 8080.
   - `backend` egress to `database` on TCP port 5432.
   - `database` ingress from `backend` on TCP port 5432.
   - UDP 53 egress to `kube-dns` for all pods.

```bash
kubectl apply -n production-secure -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: production-secure
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
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
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: production-secure
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: frontend
    ports:
    - protocol: TCP
      port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-egress-to-backend
  namespace: production-secure
spec:
  podSelector:
    matchLabels:
      tier: frontend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          tier: backend
    ports:
    - protocol: TCP
      port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-database
  namespace: production-secure
spec:
  podSelector:
    matchLabels:
      tier: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: backend
    ports:
    - protocol: TCP
      port: 5432
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-egress-to-database
  namespace: production-secure
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          tier: database
    ports:
    - protocol: TCP
      port: 5432
EOF
```

*Expected Output:*
```text
networkpolicy.networking.k8s.io/allow-dns-egress created
networkpolicy.networking.k8s.io/allow-frontend-to-backend created
networkpolicy.networking.k8s.io/allow-frontend-egress-to-backend created
networkpolicy.networking.k8s.io/allow-backend-to-database created
networkpolicy.networking.k8s.io/allow-backend-egress-to-database created
```

7. Validate authorized vs unauthorized communication flows:

```bash
BACKEND_IP=$(kubectl get pod backend -n production-secure -o jsonpath='{.status.podIP}')

# Authorized: Frontend -> Backend (Port 8080)
kubectl exec -n production-secure frontend -- wget -qO- --timeout=2 http://${BACKEND_IP}:8080

# Unauthorized: Frontend -> Database (Port 5432 - Must Timeout)
kubectl exec -n production-secure frontend -- wget -qO- --timeout=2 http://${DB_IP}:5432
```

*Expected Output:*
```text
backend response
wget: download timed out
command terminated with exit code 1
```

---

#### Verification Questions – Block 2

1. **Question 2.1**: If a pod matches multiple `NetworkPolicy` objects selecting its labels in the same namespace, how does the CNI plugin resolve conflicting allow/deny rules?
2. **Question 2.2**: Why is it mandatory to explicitly define an `Egress` policy rule targeting UDP port 53 on `kube-dns` when applying a default-deny egress policy, even when internal pod-to-pod IP traffic is explicitly authorized?

---

### Exercise 3: Service Mesh mTLS Enforcement & Cryptographic Identity Inspection (Istio / SPIFFE)

In this exercise, you will enforce strict transparent mutual TLS (`PeerAuthentication`) using Istio and inspect Envoy's datapath interception and SPIFFE X.509 certificate identities.

#### Execution Steps

1. Create a namespace `mesh-secure` and enable automatic Envoy sidecar injection:

```bash
kubectl create namespace mesh-secure
kubectl label namespace mesh-secure istio-injection=enabled
```

*Expected Output:*
```text
namespace/mesh-secure created
namespace/mesh-secure labeled
```

2. Deploy a sample microservice architecture consisting of `client` and `server`:

```bash
kubectl apply -n mesh-secure -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: server-sa
  namespace: mesh-secure
---
apiVersion: v1
kind: Service
metadata:
  name: server-svc
  namespace: mesh-secure
spec:
  ports:
  - port: 8080
    targetPort: 8080
    name: http
  selector:
    app: server
---
apiVersion: v1
kind: Pod
metadata:
  name: server
  namespace: mesh-secure
  labels:
    app: server
spec:
  serviceAccountName: server-sa
  containers:
  - name: server
    image: hashicorp/http-echo:latest
    args: ["-listen=:8080", "-text=secure mesh response"]
    ports:
    - containerPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: mesh-secure
  labels:
    app: client
spec:
  containers:
  - name: client
    image: curlimages/curl:latest
    command: ["sleep", "3600"]
EOF
```

*Expected Output:*
```text
serviceaccount/server-sa created
service/server-svc created
pod/server created
pod/client created
```

3. Verify Envoy sidecar proxy injection (`2/2` containers ready):

```bash
kubectl get pods -n mesh-secure
```

*Expected Output:*
```text
NAME     READY   STATUS    RESTARTS   AGE
client   2/2     Running   0          25s
server   2/2     Running   0          25s
```

4. Enforce **STRICT mTLS** mode across the `mesh-secure` namespace using Istio `PeerAuthentication`:

```bash
kubectl apply -n mesh-secure -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-strict-mtls
  namespace: mesh-secure
spec:
  mtls:
    mode: STRICT
EOF
```

*Expected Output:*
```text
peerauthentication.security.istio.io/default-strict-mtls created
```

5. Apply an `AuthorizationPolicy` enforcing that `server-svc` can ONLY be called by requests bearing a valid SPIFFE identity belonging to `client`:

```bash
kubectl apply -n mesh-secure -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: restrict-server-access
  namespace: mesh-secure
spec:
  selector:
    matchLabels:
      app: server
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/mesh-secure/sa/default"]
    to:
    - operation:
        methods: ["GET"]
        ports: ["8080"]
EOF
```

*Expected Output:*
```text
authorizationpolicy.security.istio.io/restrict-server-access created
```

6. Inspect Envoy's low-level `iptables` redirection rules executed within the pod network namespace:

```bash
kubectl exec -n mesh-secure server -c istio-proxy -- sudo netstat -tlpn 2>/dev/null || \
kubectl exec -n mesh-secure server -c istio-proxy -- pilot-agent request GET config_dump | grep -i "15006" -B 2 -A 5 | head -n 10
```

*Expected Output:*
```text
    "name": "virtualInbound",
    "active_state": {
     "version_info": "2026-08-07T10:00:00Z/1",
     "listener": {
      "@type": "type.googleapis.com/envoy.config.listener.v3.Listener",
      "name": "virtualInbound",
      "address": {
       "socket_address": {
        "address": "0.0.0.0",
        "port_value": 15006
```

7. Extract and decode the active SPIFFE SVID X.509 certificate presented by Envoy sidecar:

```bash
kubectl exec -n mesh-secure server -c istio-proxy -- openssl s_client -connect 127.0.0.1:15006 -showcerts </dev/null 2>/dev/null | openssl x509 -text -noout | grep -A 2 "Subject Alternative Name"
```

*Expected Output:*
```text
            X509v3 Subject Alternative Name: critical
                URI:spiffe://cluster.local/ns/mesh-secure/sa/server-sa
```

8. Test valid end-to-end mTLS connectivity from `client` to `server-svc`:

```bash
kubectl exec -n mesh-secure client -c client -- curl -s http://server-svc:8080
```

*Expected Output:*
```text
secure mesh response
```

---

#### Verification Questions – Block 3

1. **Question 3.1**: What is the difference between `PERMISSIVE` and `STRICT` mode in Istio's `PeerAuthentication` policy, and what security risk does `PERMISSIVE` mode introduce in a multi-tenant production cluster?
2. **Question 3.2**: How does SPIFFE prevent identity spoofing between microservices, and where is the SPIFFE ID embedded inside the workload's cryptographic credential?

---

### Exercise 4: Edge Ingress Hardening & Egress Exfiltration Prevention

In this exercise, you will harden the Ingress connectivity path with modern TLS standards (TLS 1.3, strong cipher suites) and implement an Egress boundary control to block unapproved external IP/domain communication.

#### Execution Steps

1. Generate a self-signed TLS certificate key pair for the external domain `api.example.com`:

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
  -keyout egress-ingress-tls.key \
  -out egress-ingress-tls.crt \
  -subj "/CN=api.example.com/O=EdgeSecurity" \
  -addext "subjectAltName=DNS:api.example.com"
```

*Expected Output:*
```text
Generating a RSA private key
...................................................................+++++
writing new private key to 'egress-ingress-tls.key'
-----
```

2. Store the keypair in a Kubernetes `tls` Secret inside the `default` namespace:

```bash
kubectl create secret tls edge-tls-secret \
  --cert=egress-ingress-tls.crt \
  --key=egress-ingress-tls.key
```

*Expected Output:*
```text
secret/edge-tls-secret created
```

3. Deploy a syntactically valid Ingress resource configured for TLS termination, enforcing TLS 1.3 and security headers via ingress annotations:

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hardened-edge-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/ssl-protocols: "TLSv1.3"
    nginx.ingress.kubernetes.io/ssl-ciphers: "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "Strict-Transport-Security: max-age=31536000; includeSubDomains; preload";
      more_set_headers "X-Frame-Options: DENY";
      more_set_headers "X-Content-Type-Options: nosniff";
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - api.example.com
    secretName: edge-tls-secret
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kubernetes
            port:
              number: 443
EOF
```

*Expected Output:*
```text
ingress.networking.k8s.io/hardened-edge-ingress created
```

4. Create an egress isolation policy in namespace `egress-restricted` that explicitly denies outbound connections to public Internet IPs, allowing access **only** to internal RFC 1918 networks (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`):

```bash
kubectl create namespace egress-restricted

kubectl apply -n egress-restricted -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-external-egress
  namespace: egress-restricted
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  # Rule 1: Allow DNS resolution inside cluster
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
  # Rule 2: Restrict HTTP/HTTPS outbound to internal corporate subnets only
  - to:
    - ipBlock:
        cidr: 10.0.0.0/8
    - ipBlock:
        cidr: 172.16.0.0/12
    - ipBlock:
        cidr: 192.168.0.0/16
    ports:
    - protocol: TCP
      port: 80
    - protocol: TCP
      port: 443
EOF
```

*Expected Output:*
```text
namespace/egress-restricted created
networkpolicy.networking.k8s.io/block-external-egress created
```

5. Deploy a test pod in `egress-restricted` and verify that outbound internet data exfiltration attempts (e.g., calling `1.1.1.1` or `google.com`) are dropped by the egress policy:

```bash
kubectl run test-exfil --image=curlimages/curl -n egress-restricted -- sleep 3600

# Wait for pod to be running
kubectl wait --for=condition=Ready pod/test-exfil -n egress-restricted --timeout=30s

# Test connectivity to external public IP (1.1.1.1) - Must fail/timeout
kubectl exec -n egress-restricted test-exfil -- curl -s --connect-timeout 3 https://1.1.1.1
```

*Expected Output:*
```text
pod/test-exfil condition met
command terminated with exit code 28
```

---

#### Verification Questions – Block 4

1. **Question 4.1**: What vulnerability occurs if an Ingress resource terminates TLS using an outdated protocol (e.g., TLS 1.0/1.1 or weak CBC ciphers), and how does HTTP Strict Transport Security (HSTS) mitigate active man-in-the-middle downgrade attacks?
2. **Question 4.2**: Why are standard Kubernetes L4 `NetworkPolicy` `ipBlock` rules insufficient on their own to prevent data exfiltration to external domains hosted on dynamically changing public Cloud IPs or CDNs (e.g., AWS S3, Cloudflare), and what cloud-native component resolves this gap?

---

## Solutions & Comprehensive Technical Explanations

<details>
<summary>Click here to view detailed solutions and answers for all exercises</summary>

### Exercise 1 Solutions

* **Answer 1.1**:
  During the API Server request processing pipeline, once an X.509 client certificate passes cryptographic validation against `ca.crt`, the API Server extracts identity metadata from the certificate's X.509 `Subject` header:
  - **Common Name (`CN`)**: Mapped directly as the authenticated **User identity** (`kubernetes-admin`).
  - **Organization (`O`)**: Mapped directly as the user's **Group memberships**. The value `system:masters` is a built-in break-glass system group in Kubernetes.
  
  During the **RBAC Authorization** phase, the API Server checks the `ClusterRoleBinding` objects. The default cluster binding `cluster-admin` binds the group `system:masters` to the `cluster-admin` `ClusterRole`. Thus, any client presenting a valid certificate signed by the cluster CA with `O=system:masters` bypasses explicit RBAC role checks and is granted full root privilege (`*` verbs on `*` resources) across the entire cluster.

* **Answer 1.2**:
  The `X509v3 Subject Alternative Name` (SAN) extension specifies all valid hostnames (DNS names) and IP addresses through which the TLS server can be legally addressed. When a TLS client (such as `kubectl` or `kubelet`) initiates a TLS handshake against `https://10.96.0.1:6443` or `https://kubernetes.default.svc`, it performs hostname verification by comparing the target endpoint string against the SAN entries in `apiserver.crt`.
  
  If the API Server is accessed via an IP or DNS name **not** present in the SAN list (e.g., `https://192.168.99.100:6443`), the client TLS library terminates the connection during the handshake phase returning:
  `x509: certificate is valid for 10.96.0.1, 192.168.1.10, not 192.168.99.100`.

---

### Exercise 2 Solutions

* **Answer 2.1**:
  Kubernetes `NetworkPolicy` evaluation follows an **Additive Allow (Union)** model:
  1. **Default State**: By default, if no `NetworkPolicy` selects a pod, it is un-isolated (allows all ingress and egress).
  2. **Isolation Trigger**: As soon as a pod is selected by at least one `NetworkPolicy` defining `Ingress` or `Egress` under `policyTypes`, it becomes isolated for that direction.
  3. **Rule Precedence**: There are **no explicit DENY rules** in standard Kubernetes `NetworkPolicies`. If multiple policies select the same pod, the effective policy is the **logical OR union** of all individual `ingress` and `egress` allow rules across all selecting policies. A connection is allowed if it satisfies at least one matching rule in any matching policy; otherwise, it is dropped.

* **Answer 2.2**:
  When a Default-Deny Egress policy is applied to a namespace (`podSelector: {}`, `policyTypes: ["Egress"]`), **all outbound network traffic from every pod in that namespace is blocked by default**, including traffic destined for internal cluster services.
  
  When an application pod attempts to resolve a hostname (e.g., `http://backend:8080`), the application runtime sends a UDP DNS query packet to the cluster DNS resolver IP (e.g., CoreDNS at `10.96.0.10:53`). If egress to `kube-dns` on UDP port 53 is not explicitly permitted, the DNS query packet is silently dropped by the node's datapath (iptables/eBPF). Consequently, the pod experiences a DNS lookup failure (`Host not found` or timeout) **before** it can even attempt to establish an outbound TCP HTTP connection to the backend service.

---

### Exercise 3 Solutions

* **Answer 3.1**:
  - **`PERMISSIVE` Mode**: Allows the target workload to accept **both** unencrypted plaintext TCP traffic and encrypted mTLS traffic simultaneously. This mode is intended exclusively as a temporary state during service mesh migration. In production, `PERMISSIVE` mode introduces a severe risk: an attacker who gains execution inside the network boundary can bypass Envoy mTLS encryption and sniff or inject unencrypted plaintext traffic to target services.
  - **`STRICT` Mode**: Enforces that **all** inbound TCP connections to the workload must be encrypted using mTLS and present a valid X.509 SPIFFE certificate issued by the Mesh CA. Any plaintext connection attempt or connection presenting an untrusted certificate is immediately reset at the socket layer by the Envoy proxy (`virtualInbound` listener port 15006).

* **Answer 3.2**:
  SPIFFE (Secure Production Identity Framework for Everyone) prevents identity spoofing by replacing mutable, IP-based network identity with cryptographically verified X.509 certificates called **SVIDs (SPIFFE Verifiable Identity Documents)**.
  
  The SPIFFE ID is formatted as a structured URI string:
  `spiffe://<trust-domain>/ns/<namespace>/sa/<service-account-name>`
  
  This URI is embedded in the X.509 certificate's **`Subject Alternative Name (SAN)`** field (specifically under `URI:`). During the mTLS handshake, Envoy proxies on both ends extract and validate the SAN extension against trusted root certificates distributed by the control plane (e.g., Istiod). Because the certificate keypair is minted directly into pod memory and short-lived (rotated every few hours), an attacker cannot spoof another service account's identity without possessing its private key.

---

### Exercise 4 Solutions

* **Answer 4.1**:
  - **Outdated Protocols/Ciphers**: TLS 1.0/1.1 and legacy CBC-mode ciphers are vulnerable to cryptographic attacks (e.g., BEAST, POODLE, LUCKY13) allowing attackers sniffing network traffic to decrypt payload sessions or forge authentication tokens. TLS 1.3 removes legacy insecure primitives, enforcing forward secrecy via Ephemeral Diffie-Hellman (ECDHE).
  - **HSTS (HTTP Strict Transport Security)**: HSTS sends an HTTP response header (`Strict-Transport-Security: max-age=31536000; includeSubDomains`) instructing user agents and browsers to **force** all future communication over HTTPS automatically. This prevents SSL-stripping attacks where a Man-in-the-Middle (MitM) interceptor downgrades an initial `http://` request to plaintext before the server can execute an HTTP-to-HTTPS 301 redirect.

* **Answer 4.2**:
  Standard L4 Kubernetes `NetworkPolicy` objects rely on static IP/CIDR blocks (`ipBlock.cidr`). Modern external services (e.g., AWS S3, GitHub APIs, Payment Gateways, CDNs) utilize multi-region dynamic IP pools, Anycast routing, and rapidly changing DNS A/AAAA records. Hardcoding public IP addresses in `ipBlock` manifests is unmaintainable and insecure.
  
  To resolve this exfiltration control gap, cloud-native architectures utilize **Service Mesh Egress Gateways** or **FQDN-based L7 Network Policies** (such as Cilium `CiliumNetworkPolicy` with `fqdn` matching):
  - **DNS Inspection / SNI Filtering**: The egress proxy intercepts outbound requests, performs TLS Server Name Indication (SNI) packet inspection or HTTP Host header parsing, and evaluates traffic against an authorized domain whitelist (e.g., allow `*.s3.amazonaws.com` exclusively) while dropping unauthorized egress attempts regardless of the underlying IP address.

</details>