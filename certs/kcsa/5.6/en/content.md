# KCSA Study Guide: Topic 5.6 – Connectivity

**Domain:** Microservice & Platform Security  
**Exam Weight:** 2.29%  
**Target Level:** Principal Platform Architect / Senior SRE  

---

## 1. Architectural Motivation & Production Problem Statement

In default Kubernetes CNI implementations (e.g., standard Flannel or unconfigured Calico/Cilium), the cluster network operates on a **flat, non-segmented East-West traffic model**. Every Pod can route packets directly to any other Pod across namespaces using IP routing without authentication or protocol inspection. 

```
[ Compromised Pod (Namespace: dev) ] 
               │
               ▼ (Unrestricted IP Routing / East-West Flat Network)
[ Payment Database Pod (Namespace: prod) ]  <-- CRITICAL EXPLOIT VECTOR
```

### Production Threat Vectors & Risks
1. **Lateral Movement Post-Exploitation:** If an attacker compromises a vulnerable public-facing edge service (e.g., via a remote code execution vulnerability), the flat network enables unhindered reconnaissance and data exfiltration against internal microservices, control plane endpoints, or database Pods.
2. **Lack of Identity Verification:** Standard IP routing relies purely on IP addresses. IP spoofing, Pod re-creation (IP churn), or ARP/ND cache poisoning in unencrypted overlay networks can lead to unauthorized impersonation.
3. **Egress Data Exfiltration:** Without egress controls, compromised Pods can establish outbound TCP connections to external Command & Control (C2) servers or exfiltrate sensitive data over non-standard ports.
4. **Lack of Wire-Level Encryption:** Intra-cluster network traffic across public cloud VPC subnets or multi-rack bare-metal hosts travels in plain text, making it vulnerable to packet sniffing and man-in-the-middle (MitM) attacks.

### Zero Trust Network Architecture (ZTNA) Requirements
To achieve compliance (PCI-DSS, SOC 2, HIPAA) and zero-trust posture, platform engineering teams must enforce:
- **Default-Deny Engress/Ingress Isolation:** Explicit opt-in policy evaluation for all communication paths.
- **Least-Privilege Layer 4 & Layer 7 Boundaries:** Restricting access not only by IP/Port but also by cryptographically verified Service Accounts, HTTP methods, and URL paths.
- **Wire-Level Encryption:** Transparent IPsec or WireGuard encryption at the CNI layer, combined with mTLS (Mutual TLS) at the application layer.

---

## 2. Technical Comparison & Trade-off Matrix

| Vector / Dimension | Kubernetes Native NetworkPolicy (L4) | Cilium CRD Policies (L4 + L7 + FQDN) | Service Mesh mTLS (Istio / Linkerd) | CNI Transparent Encryption (WireGuard / IPsec) |
| :--- | :--- | :--- | :--- | :--- |
| **Enforcement Layer** | Layer 3 / Layer 4 (IP, CIDR, Port, Protocol) | Layer 3 / Layer 4 / Layer 7 (HTTP, gRPC, Kafka, FQDN) | Layer 7 (mTLS, JWT, RBAC, HTTP Routing) | Layer 3 (Node-to-Node / Pod-to-Pod Wire Level) |
| **Implementation Mechanism** | `iptables`, `ipvs`, or CNI eBPF maps | Linux eBPF kernel probes & inline envoy proxies | Sidecar proxy (Envoy) or Ambient/Node-level daemon | Kernel-level WireGuard module or IPsec ESP |
| **Performance Impact** | Low to High (`iptables` scales $O(N)$ with policy count) | Extremely Low ($O(1)$ lookup speed via eBPF Hash Maps) | Moderate to High (Sidecar latency + memory overhead) | Low (Hardware-accelerated crypto) |
| **Identity Mechanism** | Namespace & Pod Labels | Identity Labels + eBPF Security Identity IDs | X.509 SVID Certificates (SPIFFE/SPIRE) | Machine/Node Public Key or IPsec SA |
| **L7 Protocol Awareness** | None | Full (HTTP Path/Verb, gRPC Method, FQDN regex) | Full (HTTP, gRPC, WebSockets) | None (Network layer only) |
| **Cryptographic Authentication** | None | Optional (SPIFFE integration) | Cryptographic mTLS Handshake per Connection | Symmetric / Asymmetric Tunnel Encryption |
| **Operational Complexity** | Low (Built-in K8s API primitives) | Medium (Requires eBPF CNI & Custom CRDs) | High (Requires Control Plane, Certificate Authority, Envoy lifecycle) | Low-Medium (CNI Configuration Flag) |

---

## 3. Complete Production Manifests & Infrastructure Specs

The following manifests construct an isolated multi-tier production environment in the `payments-prod` namespace using strict least-privilege networking.

### 3.1 Production Namespace & Isolated Workloads

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments-prod
  labels:
    environment: production
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-serviceaccount
  namespace: payments-prod
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-db
  namespace: payments-prod
  labels:
    app.kubernetes.io/name: payment-db
    tier: database
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-db
      tier: database
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-db
        tier: database
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        ports:
        - containerPort: 5432
          name: postgres
        env:
        - name: POSTGRES_PASSWORD
          value: "SecureProductionPassword123!"
        resources:
          limits:
            cpu: "1"
            memory: "1Gi"
          requests:
            cpu: "250m"
            memory: "256Mi"
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          runAsNonRoot: true
          runAsUser: 70
          capabilities:
            drop:
            - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: payment-db-svc
  namespace: payments-prod
spec:
  type: ClusterIP
  ports:
  - port: 5432
    targetPort: postgres
    protocol: TCP
    name: postgres
  selector:
    app.kubernetes.io/name: payment-db
    tier: database
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: payments-prod
  labels:
    app.kubernetes.io/name: payment-api
    tier: api
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-api
      tier: api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-api
        tier: api
    spec:
      serviceAccountName: api-serviceaccount
      containers:
      - name: api
        image: nginx:1.25-alpine
        ports:
        - containerPort: 8080
          name: http
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          runAsNonRoot: true
          runAsUser: 101
          capabilities:
            drop:
            - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: payment-api-svc
  namespace: payments-prod
spec:
  type: ClusterIP
  ports:
  - port: 8080
    targetPort: http
    protocol: TCP
    name: http
  selector:
    app.kubernetes.io/name: payment-api
    tier: api
```

---

### 3.2 Native Kubernetes NetworkPolicies (Strict L4 Isolation)

#### Default Deny All Ingress and Egress
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments-prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

#### CoreDNS Egress Policy (Required for Service Discovery)
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-coredns-egress
  namespace: payments-prod
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
    - protocol: TCP
      port: 53
```

#### Fine-Grained Multi-Tier Communication Policy
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-to-db
  namespace: payments-prod
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: payment-db
      tier: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: payment-api
          tier: api
    ports:
    - protocol: TCP
      port: 5432
```

---

### 3.3 Advanced L7 & FQDN Egress Policy (`CiliumNetworkPolicy`)

```yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: payment-api-l7-egress-rules
  namespace: payments-prod
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: payment-api
      tier: api
  egress:
  # Allow internal DB access at L4
  - toEndpoints:
    - matchLabels:
        app.kubernetes.io/name: payment-db
        tier: database
    toPorts:
    - ports:
      - port: "5432"
        protocol: TCP
  # Allow External Payment Gateway via FQDN and enforce HTTPS L7 filtering
  - toFQDNs:
    - matchName: "api.stripe.com"
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/v1/charges"
```

---

### 3.4 Ingress Resource with TLS Termination

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: payment-ingress
  namespace: payments-prod
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "15"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
spec:
  tls:
  - hosts:
    - payments.example.com
    secretName: payments-tls-cert
  rules:
  - host: payments.example.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: payment-api-svc
            port:
              number: 8080
```

---

## 4. Real CLI Execution Commands & Expected Terminal Outputs

### 4.1 Applying Network Manifests and Verifying Policy State

```bash
$ kubectl apply -f payment-workloads.yaml
namespace/payments-prod created
serviceaccount/api-serviceaccount created
deployment.apps/payment-db created
service/payment-db-svc created
deployment.apps/payment-api created
service/payment-api-svc created

$ kubectl apply -f network-policies.yaml
networkpolicy.networking.k8s.io/default-deny-all created
networkpolicy.networking.k8s.io/allow-coredns-egress created
networkpolicy.networking.k8s.io/allow-api-to-db created

$ kubectl get networkpolicies -n payments-prod -o wide
NAME                   POD-SELECTOR                       AGE   POLICY-TYPES
allow-api-to-db        app.kubernetes.io/name=payment-db  12s   Ingress
allow-coredns-egress   <none>                             12s   Egress
default-deny-all       <none>                             12s   Ingress,Egress
```

---

### 4.2 Validating Allowed Traffic (API -> Database)

```bash
$ API_POD=$(kubectl get pod -n payments-prod -l app.kubernetes.io/name=payment-api -o jsonpath='{.items[0].metadata.name}')
$ DB_SVC_IP=$(kubectl get svc -n payments-prod payment-db-svc -o jsonpath='{.spec.clusterIP}')

$ kubectl exec -n payments-prod -it $API_POD -- nc -zv -w 3 $DB_SVC_IP 5432
payment-db-svc.payments-prod.svc.cluster.local (10.96.142.88:5432) open
```

---

### 4.3 Testing Default Deny & Policy Enforcement (Unauthorized Pod -> Database)

```bash
$ kubectl run unauthorized-test --image=alpine:3.18 -n payments-prod -it --rm -- sh
If you don't see a command prompt, try pressing enter.
/ # nc -zv -w 3 payment-db-svc 5432
nc: payment-db-svc (10.96.142.88:5432): Operation timed out
/ # ping -c 2 8.8.8.8
PING 8.8.8.8 (8.8.8.8): 56 data bytes
--- 8.8.8.8 ping statistics ---
2 packets transmitted, 0 packets received, 100% packet loss
/ # exit
Session ended, pod payments-prod/unauthorized-test deleted
```

---

### 4.4 Debugging WireGuard CNI Encryption Status (Cilium CLI)

```bash
$ cilium status --verbose | grep -A 5 "Encryption"
Encryption: Wireguard
  Mode: Wireguard
  Keys: 1/1 active
  Interface: cilium_wg0
  Node-to-Node: Enabled
  Pod-to-Pod: Enabled
```

---

### 4.5 Inspecting Low-Level eBPF Network Maps

```bash
$ CILIUM_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
$ kubectl exec -n kube-system $CILIUM_POD -c cilium-agent -- cilium bpf policy dump
POLICY MAP: DATAPATH POLICY MAP (v2)
POLICY   DIRECTION   IDENTITY   PORT/PROTO   BYTES   PACKETS   ACTION
Rule 1   Ingress     45210      5432/TCP     4082    62        ALLOW
Rule 2   Egress      1          53/UDP       1240    18        ALLOW
Rule 3   Ingress     ANY        ANY          582     12        DROP (Default Deny)
```

---

## 5. Verification, Diagnostic & Failure Troubleshooting Runbook

### Diagnostic Flowchart

```
[ Connectivity Issue Detected ]
              │
              ▼
[ 1. Check Pod DNS Resolution ] ──(Fails)──► Check CoreDNS Egress Policy (Port 53 UDP/TCP)
              │
           (Passes)
              ▼
[ 2. Verify Selectors & Labels ] ──(Mismatch)──► Fix matchLabels / podSelector
              │
           (Passes)
              ▼
[ 3. Inspect CNI Agent Logs ] ──(Sync Error)──► Restart CNI Agent DaemonSet
              │
           (Passes)
              ▼
[ 4. Analyze eBPF / iptables Drops ] ──► Check 'cilium monitor --type drop' or 'iptables-save'
```

---

### 5.1 Common Production Failure Modes

#### Issue A: Egress DNS Resolution Timeout
* **Symptom:** Pods cannot resolve service names (`payment-db-svc.payments-prod.svc.cluster.local`), reporting `Host unreachable` or `Name or service not known`.
* **Root Cause:** A `default-deny-all` NetworkPolicy was applied without an explicit egress rule permitting traffic to CoreDNS (`kube-dns`) on port 53 UDP/TCP.
* **Remediation:** Apply `allow-coredns-egress` Policy targeting `kube-system` namespace.

#### Issue B: Cross-Namespace NetworkPolicy Selector Mismatch
* **Symptom:** Ingress policy fails to allow cross-namespace API calls despite explicit `namespaceSelector`.
* **Root Cause:** The target namespace lacks matching labels. `namespaceSelector` matches labels on the `Namespace` object itself, **not** the namespace name string (unless using standard label `kubernetes.io/metadata.name`).
* **Remediation:** Ensure namespaces have correct labels applied (`kubectl label ns payments-prod environment=production`).

#### Issue C: CNI Policy Engine Out of Sync / eBPF Map Full
* **Symptom:** Pods fail to transmit packets even when NetworkPolicy manifests appear syntactically valid.
* **Root Cause:** The CNI daemon failed to reconcile the BPF map state due to exhausted map limits or Linux kernel ring buffer overflow.
* **Remediation Runbook:**

```bash
# 1. Describe the failing NetworkPolicy to check validation errors
$ kubectl describe networkpolicy allow-api-to-db -n payments-prod

# 2. Monitor live network drops using Hubble / Cilium Monitor
$ kubectl exec -n kube-system $CILIUM_POD -c cilium-agent -- cilium monitor --type drop
XX drop (Policy denied) flow 0x3f5ab120 to endpoint 40125, drop-reason Policy denied, Verdict Drop, PolicyID 3

# 3. Check iptables drop counters (if using iptables-based CNI like Calico/Kube-Router)
$ iptables-save | grep -i "KUBE-NWPOLICY"
-A KUBE-NWPOLICY-DEFAULT-DENY -m comment --comment "default-deny-all policy" -j DROP

# 4. Verify Node network interfaces and MTU mismatch
$ ip link show | grep -E "cilium|calico|flannel|wireguard"
14: cilium_wg0: <MTU 1420,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN group default
```

---

## 6. References

- **CNCF KCSA Exam Curriculum:**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- **Kubernetes Official Documentation – Network Policies:**  
  https://kubernetes.io/docs/concepts/services-networking/network-policies/
- **Kubernetes Security Task Guide – Declare Network Policy:**  
  https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
- **Cilium Security Architecture & Policy Engine:**  
  https://docs.cilium.io/en/stable/security/policy/
- **Istio Security Architecture & Authorization Policies:**  
  https://istio.io/latest/docs/concepts/security/
- **Kubernetes Ingress & TLS Termination Specification:**  
  https://kubernetes.io/docs/concepts/services-networking/ingress/#tls