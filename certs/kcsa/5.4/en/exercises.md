# KCSA Exam Study Module: Topic 5.4 — Service Mesh Security

**Target Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain 5:** Application & Workload Security  
**Topic 5.4:** Service Mesh Security  
**Domain Weight:** ~2.29%  
**Official Reference:** [CNCF KCSA Curriculum (GitHub)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 1. Deep-Dive Architecture & Production Mechanics

### 1.1 The Service Mesh Security Paradigm

A Service Mesh provides transparent, infrastructure-level security features to applications without requiring code modifications. From a security architecture perspective, it implements a **Zero Trust Network Architecture (ZTNA)** within Kubernetes clusters.

```
                          +-------------------------------------------------------+
                          |                   Control Plane                       |
                          | (e.g., Istiod / SPIRE Server / Linkerd Control Plane) |
                          +--------------------------+----------------------------+
                                                     |
                                           xDS / mTLS / X.509 CA
                                                     |
  +--------------------------------------------------v--------------------------------------------------+
  |  Data Plane (Pod Boundary)                                                                          |
  |                                                                                                     |
  |  +---------------------------+    iptables / eBPF redirect   +------------------------------------+  |
  |  |    Application Container  | <===========================> |        Sidecar Proxy               |  |
  |  |   (App code, plain HTTP)  |       localhost traffic       |        (Envoy Proxy)               |  |
  |  +---------------------------+                               +-----------------+------------------+  |
  +--------------------------------------------------------------------------------|--------------------+
                                                                                   |
                                                                        mTLS (X.509 SVID / SPIFFE)
                                                                                   |
  +--------------------------------------------------------------------------------v--------------------+
  |  Data Plane (Peer Pod Boundary)                                                                     |
  |                                                              +------------------------------------+  |
  |                                                              |     Peer Envoy Proxy               |  |
  |                                                              +-----------------+------------------+  |
  +-----------------------------------------------------------------------------------------------------+
```

#### Core Components & Security Functions

1. **Cryptographic Identity Management (SPIFFE/SPIRE & X.509 SVIDs):**
   - Workload identity is decoupled from IP addresses and namespaces.
   - Identifiers follow the SPIFFE ID standard (e.g., `spiffe://cluster.local/ns/prod/sa/payment-service`).
   - Short-lived X.509 certificates (SVIDs) are automatically issued, mounted, and continuously rotated (typically every 12–24 hours) by control plane components (e.g., `istiod` or SPIRE agents).

2. **Mutual TLS (mTLS) & Traffic Encryption:**
   - **Permissive Mode:** Accepts both plaintext and mTLS traffic. Used exclusively during brownfield migrations.
   - **Strict Mode:** Rejects all unencrypted plaintext traffic at the proxy interface using TLS handshake validation.

3. **Layer 4 & Layer 7 Access Control (RBAC & Authorization Policies):**
   - **L4 Policies:** Evaluate source/destination IPs, ports, and authenticated SPIFFE IDs.
   - **L7 Policies:** Inspect HTTP methods, URIs, headers, hostnames, and JWT claims extracted from request headers.

4. **Traffic Redirection Mechanics:**
   - **Sidecar Model:** Uses `iptables` rules (via `initContainers` or `CNI` plugins) to redirect `PREROUTING` and `OUTPUT` traffic to local port `15001`/`15006` managed by Envoy.
   - **Ambient / Sidecarless Model:** Uses eBPF or node-level proxies (ztunnel) to handle L4 mTLS encryption per node, with optional L7 proxies (Waypoints) deployed per namespace or service account.

---

### 1.2 Architectural Trade-Off Analysis

| Architectural Dimension | Sidecar Architecture (Envoy per Pod) | Ambient / Sidecarless Architecture (ztunnel + Waypoint) |
| :--- | :--- | :--- |
| **Security Isolation Boundary** | **Pod-level.** Compromise of a single sidecar proxy only exposes that pod's memory space and certificates. | **Node-level (L4) + Pod-level (L7).** ztunnel runs as DaemonSet; memory fault could impact node L4 mTLS. |
| **Resource Overhead** | High memory/CPU footprint aggregated across large clusters (10–50MB RAM per sidecar). | Low node-level baseline footprint for L4. L7 resources allocated dynamically via Waypoint proxies. |
| **Application Compatibility** | Requires container injection (`initContainers`, `iptables` manipulation or CNI). | Completely transparent to Pod specs; no injection required. Uses kernel-level eBPF / Geneve routing. |
| **Attack Surface** | Requires elevated `NET_ADMIN` or `NET_RAW` capabilities during init, unless Service Mesh CNI is deployed. | Eliminates pod `NET_ADMIN` requirements entirely. |

---

### 1.3 Official Reference URLs

- **Istio Security Architecture:** [https://istio.io/latest/docs/concepts/security/](https://istio.io/latest/docs/concepts/security/)
- **SPIFFE Concepts:** [https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/)
- **CNCF KCSA Curriculum Specification:** [https://github.com/cncf/curriculum](https://github.com/cncf/curriculum)
- **Envoy Proxy Security Documentation:** [https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/security/security](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/security/security)

---

## 2. Guided Production Lab Exercises

### Exercise 1: Enforcing Strict mTLS and Cryptographic SPIFFE Identity Validation

#### Objective
Configure namespace-wide strict mTLS enforcement using Istio security primitives, verify certificate validation, and prove unauthenticated plaintext requests are terminated at Layer 4.

#### Step 1: Prepare Namespaces and Deploy Test Workloads
Execute the following commands to create isolated namespaces, label them for sidecar injection, and deploy client and server workloads.

```bash
kubectl create namespace mesh-secure
kubectl label namespace mesh-secure istio-injection=enabled

kubectl create namespace legacy-unmeshed
```

Apply the following manifest to deploy the `frontend` (client) and `backend` (server) workloads:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-api
  namespace: mesh-secure
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend-api
  template:
    metadata:
      labels:
        app: backend-api
    spec:
      serviceAccountName: backend-sa
      containers:
      - name: hashicorp-http-echo
        image: hashicorp/http-echo:0.2.3
        args:
        - "-text=secure-payload-v1"
        - "-listen=:8080"
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-sa
  namespace: mesh-secure
---
apiVersion: v1
kind: Service
metadata:
  name: backend-api
  namespace: mesh-secure
spec:
  ports:
  - port: 8080
    targetPort: 8080
    name: http
  selector:
    app: backend-api
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-client
  namespace: legacy-unmeshed
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-client
  template:
    metadata:
      labels:
        app: legacy-client
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
```

Apply the manifest:
```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-api
  namespace: mesh-secure
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend-api
  template:
    metadata:
      labels:
        app: backend-api
    spec:
      serviceAccountName: backend-sa
      containers:
      - name: hashicorp-http-echo
        image: hashicorp/http-echo:0.2.3
        args:
        - "-text=secure-payload-v1"
        - "-listen=:8080"
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-sa
  namespace: mesh-secure
---
apiVersion: v1
kind: Service
metadata:
  name: backend-api
  namespace: mesh-secure
spec:
  ports:
  - port: 8080
    targetPort: 8080
    name: http
  selector:
    app: backend-api
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-client
  namespace: legacy-unmeshed
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-client
  template:
    metadata:
      labels:
        app: legacy-client
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
EOF
```

#### Step 2: Enforce STRICT PeerAuthentication Policy
Apply a `PeerAuthentication` manifest targeting the `mesh-secure` namespace to reject plaintext traffic.

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-strict-mtls
  namespace: mesh-secure
spec:
  mtls:
    mode: STRICT
```

Execute command:
```bash
kubectl apply -f - <<EOF
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

Expected Output:
```
peerauthentication.security.istio.io/default-strict-mtls created
```

#### Step 3: Validate Connection Rejection from Unmeshed Pods
Attempt to execute a raw HTTP request from the unmeshed pod in `legacy-unmeshed` namespace:

```bash
LEGACY_POD=$(kubectl get pod -n legacy-unmeshed -l app=legacy-client -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n legacy-unmeshed "$LEGACY_POD" -- curl -sS --connect-timeout 3 http://backend-api.mesh-secure.svc.cluster.local:8080/
```

Expected Output:
```
curl: (56) Recv failure: Connection reset by peer
```

---

#### Verification Questions — Exercise 1
1. **Q1.1:** Why did the HTTP request from `legacy-client` receive `Connection reset by peer` instead of an HTTP `403 Forbidden` status code?
2. **Q1.2:** If the `PeerAuthentication` mode is changed to `PERMISSIVE`, what security exposure is introduced into the cluster network?

---

### Exercise 2: Implementing Zero Trust L7 Micro-segmentation with SPIFFE Identifiers

#### Objective
Implement an explicit Default Deny security posture followed by fine-grained `AuthorizationPolicy` rules enforcing HTTP method and SPIFFE Subject Alternative Name (SAN) validation.

#### Step 1: Deploy Authorized and Unauthorized Clients inside the Mesh

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: authorized-sa
  namespace: mesh-secure
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: authorized-client
  namespace: mesh-secure
spec:
  replicas: 1
  selector:
    matchLabels:
      app: authorized-client
  template:
    metadata:
      labels:
        app: authorized-client
    spec:
      serviceAccountName: authorized-sa
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: unauthorized-sa
  namespace: mesh-secure
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unauthorized-client
  namespace: mesh-secure
spec:
  replicas: 1
  selector:
    matchLabels:
      app: unauthorized-client
  template:
    metadata:
      labels:
        app: unauthorized-client
    spec:
      serviceAccountName: unauthorized-sa
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3600"]
EOF
```

#### Step 2: Implement Global Default Deny Authorization Policy
Construct a catch-all `AuthorizationPolicy` with an empty `spec` to enforce Zero Trust by denying all incoming requests across `mesh-secure`.

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: mesh-secure
spec:
  {}
```

Apply manifest:
```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: mesh-secure
spec:
  {}
EOF
```

#### Step 3: Implement Least-Privilege L7 Authorization Policy
Define an `AuthorizationPolicy` that allows **only** requests originating from SPIFFE identity `spiffe://cluster.local/ns/mesh-secure/sa/authorized-sa` sending HTTP `GET` requests to the `/` path on `backend-api`.

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-backend-api-l7
  namespace: mesh-secure
spec:
  selector:
    matchLabels:
      app: backend-api
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/mesh-secure/sa/authorized-sa"]
    to:
    - operation:
        methods: ["GET"]
        paths: ["/"]
```

Apply manifest:
```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-backend-api-l7
  namespace: mesh-secure
spec:
  selector:
    matchLabels:
      app: backend-api
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/mesh-secure/sa/authorized-sa"]
    to:
    - operation:
        methods: ["GET"]
        paths: ["/"]
EOF
```

#### Step 4: Validate Access Behavior across Workloads

1. **Test from Authorized Service Account (`authorized-sa`):**
```bash
AUTH_POD=$(kubectl get pod -n mesh-secure -l app=authorized-client -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n mesh-secure "$AUTH_POD" -c curl -- curl -i -s http://backend-api:8080/
```
Expected Output:
```http
HTTP/1.1 200 OK
date: Fri, 07 Aug 2026 20:30:00 GMT
content-length: 18
content-type: text/plain; charset=utf-8
x-envoy-upstream-service-time: 1

secure-payload-v1
```

2. **Test Unauthorized Method (`POST`) from Authorized Service Account:**
```bash
kubectl exec -n mesh-secure "$AUTH_POD" -c curl -- curl -i -s -X POST http://backend-api:8080/
```
Expected Output:
```http
HTTP/1.1 403 Forbidden
content-length: 19
content-type: text/plain
date: Fri, 07 Aug 2026 20:30:05 GMT
server: envoy

RBAC: access denied
```

3. **Test from Unauthorized Service Account (`unauthorized-sa`):**
```bash
UNAUTH_POD=$(kubectl get pod -n mesh-secure -l app=unauthorized-client -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n mesh-secure "$UNAUTH_POD" -c curl -- curl -i -s http://backend-api:8080/
```
Expected Output:
```http
HTTP/1.1 403 Forbidden
content-length: 19
content-type: text/plain
date: Fri, 07 Aug 2026 20:30:10 GMT
server: envoy

RBAC: access denied
```

---

#### Verification Questions — Exercise 2
1. **Q2.1:** At which layer of the OSI/TCP-IP stack is the authorization decision evaluated for request `#2` (Unauthorized HTTP `POST` from `authorized-sa`) versus request `#3` from `unauthorized-sa`?
2. **Q2.2:** In the principal pattern `cluster.local/ns/mesh-secure/sa/authorized-sa`, what component guarantees that a malicious pod cannot impersonate this principal string?

---

### Exercise 3: Advanced Diagnostics, SPIFFE Certificate Extraction & Envoy Security Auditing

#### Objective
Use diagnostic tools (`istioctl`, `openssl`, and local Envoy administrative interfaces) to inspect active X.509 SVID certificates, extract SAN fields, and audit dynamic authorization filter chains in memory.

#### Step 1: Extract Active X.509 SVID Certificate from Envoy Memory
Run `istioctl proxy-config secret` to extract active certificates loaded inside the sidecar proxy of the `backend-api` pod.

```bash
BACKEND_POD=$(kubectl get pod -n mesh-secure -l app=backend-api -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config secret "$BACKEND_POD".mesh-secure -o json > cert_dump.json
```

Filter and decode the active `default` certificate chain using `jq` and `openssl`:

```bash
jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' cert_dump.json | base64 -d | openssl x509 -noout -text -certopt no_header,no_version,no_serial,no_signame,no_validity,no_issuer,no_pubkey,no_sigdump
```

Expected Output Snippet:
```text
        Attributes:
            Requested Extensions:
                X509v3 Subject Alternative Name: critical
                    URI:spiffe://cluster.local/ns/mesh-secure/sa/backend-sa
                X509v3 Basic Constraints: critical
                    CA:FALSE
                X509v3 Key Usage: critical
                    Digital Signature, Key Encipherment
                X509v3 Extended Key Usage: 
                    TLS Web Server Authentication, TLS Web Client Authentication
```

#### Step 2: Audit Dynamic Listener Filters and RBAC Enforcements
Query Envoy's internal configuration state using `istioctl proxy-config listener` to inspect dynamic inbound security chains bound to port `15006` (Envoy inbound virtual listener).

```bash
istioctl proxy-config listener "$BACKEND_POD".mesh-secure --port 15006 -o json
```

Inspect the output to confirm presence of `envoy.filters.network.rbac` and `envoy.filters.http.rbac` in the filter chains:

```json
[
    {
        "name": "virtualInbound",
        "address": {
            "socketAddress": {
                "address": "0.0.0.0",
                "portValue": 15006
            }
        },
        "filterChains": [
            {
                "filterChainMatch": {
                    "destinationPort": 8080,
                    "transportProtocol": "tls"
                },
                "filters": [
                    {
                        "name": "envoy.filters.network.http_connection_manager",
                        "typedConfig": {
                            "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
                            "httpFilters": [
                                {
                                    "name": "envoy.filters.http.rbac",
                                    "typedConfig": {
                                        "@type": "type.googleapis.com/envoy.extensions.filters.http.rbac.v3.RBAC"
                                    }
                                }
                            ]
                        }
                    }
                ]
            }
        ]
    }
]
```

#### Step 3: Direct Inspection of Envoy Admin Endpoint via Port-Forwarding
Expose Envoy's administrative endpoint directly to inspect RBAC engine metrics:

```bash
kubectl port-forward -n mesh-secure "$BACKEND_POD" 15000:15000 &
PF_PID=$!
sleep 2

curl -s http://127.0.0.1:15000/stats | grep "http.inbound_15006_8080.rbac"
kill $PF_PID
```

Expected Output:
```text
http.inbound_15006_8080.rbac.allowed: 1
http.inbound_15006_8080.rbac.denied: 2
http.inbound_15006_8080.rbac.shadow_allowed: 0
http.inbound_15006_8080.rbac.shadow_denied: 0
```

---

#### Verification Questions — Exercise 3
1. **Q3.1:** What critical X.509 extensions must be marked as `critical` in a valid SPIFFE SVID certificate according to the SPIFFE specification?
2. **Q3.2:** How can an engineer differentiate between a request dropped due to mTLS handshaking failure versus a request dropped by an `AuthorizationPolicy` using Envoy administrative metrics?

---

## 3. Answer Key & Self-Assessment

<details>
<summary>Click to expand Answer Key & Technical Explanations</summary>

### Exercise 1 Answers

- **Q1.1 Answer:**  
  When `PeerAuthentication` is configured with `mode: STRICT`, mTLS enforcement happens at **Layer 4 (TCP/TLS handshake)** by Envoy's network filter (`envoy.filters.network.metadata_exchange` / TLS Inspector). Because the unmeshed client does not initiate a TLS handshake with a valid client certificate trusted by the Mesh CA, Envoy immediately closes the TCP socket via a `TCP RST` packet. It never reaches the Layer 7 HTTP processing pipeline, so no HTTP response codes (such as `403 Forbidden`) can be generated.

- **Q1.2 Answer:**  
  `PERMISSIVE` mode instructs the sidecar proxy to open dual listeners or dynamically inspect the initial incoming bytes on the socket (ALPN sniffing). If a client initiates plaintext HTTP, Envoy allows it; if it initiates mTLS, Envoy terminates TLS.  
  *Security Risk:* An attacker who gains access to the pod network (or bypasses edge firewalls) can execute plaintext lateral movement attacks, perform man-in-the-middle packet sniffing, or spoof unauthenticated traffic directly into meshed workloads without presenting a valid cryptographic SPIFFE SVID.

---

### Exercise 2 Answers

- **Q2.1 Answer:**  
  - **Request #3 (Unauthorized SA):** Evaluated at **Layer 4/7 Identity Verification level**. The client's mTLS certificate presents `spiffe://cluster.local/ns/mesh-secure/sa/unauthorized-sa`. Envoy's HTTP RBAC filter (`envoy.filters.http.rbac`) compares this SPIFFE SAN string against allowed `principals`. Finding no match, it returns an HTTP `403 Forbidden` response.
  - **Request #2 (Unauthorized HTTP Method POST from Authorized SA):** Evaluated at **Layer 7 Application Protocol level**. The identity matches `authorized-sa`, but the operational metadata (`method: POST`) fails the `operation.methods` matching engine. The HTTP RBAC filter rejects the request with HTTP `403 Forbidden`.

- **Q2.2 Answer:**  
  The cryptographic integrity of the SPIFFE SAN principal is guaranteed by the **Control Plane Certificate Authority (`istiod` / SPIRE Server)** and the **TLS Handshake Protocol**.  
  During the mTLS handshake:
  1. The server sidecar verifies that the client's X.509 certificate was signed by the trusted Mesh Root CA key.
  2. The server sidecar verifies certificate validity (expiration, revocation).
  3. The SAN extension `URI:spiffe://...` is cryptographically bound to the public key pair owned exclusively by that client proxy (which receives its private key through private Unix Domain Sockets over Secret Discovery Service - SDS). The private key never leaves pod memory.

---

### Exercise 3 Answers

- **Q3.1 Answer:**  
  According to the SPIFFE X.509 SVID specification:
  - **Subject Alternative Name (SAN):** Must be present and **MUST** contain exactly one URI entry representing the SPIFFE ID (e.g., `spiffe://<domain>/ns/<namespace>/sa/<serviceaccount>`).
  - **Basic Constraints:** Must be marked as `critical` with `CA:FALSE` for workload certificates to prevent compromised workload proxies from re-issuing subordinate certificates to downstream attackers.
  - **Key Usage:** Must be marked as `critical` with `Digital Signature` (and optionally `Key Encipherment`).

- **Q3.2 Answer:**  
  - **mTLS Handshake Failures (L4):** Recorded in Envoy SSL metrics such as `ssl.connection_error`, `ssl.handshake_failed`, or `listener.downstream_cx_destroy` prior to HTTP parsing.
  - **Authorization Policy Violations (L7):** Increment specific RBAC filter counters, explicitly named `http.inbound_<listener_id>.rbac.denied`. Additionally, RBAC violations generate access log entries with response flag `FI` (AccessDenied by downstream filter) or `RL` (Rate limited/RBAC denied) alongside HTTP status `403`.

</details>