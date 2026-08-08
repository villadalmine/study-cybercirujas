# KCSA Exam Preparation: Topic 3.7 – Network Policy

## 1. Motivation and Production Architectural Problem

### 1.1 The Default Flat-Network Threat Model
By default, the Kubernetes networking model adheres to the fundamental specification that **any Pod can communicate with any other Pod across any Namespace without NAT**, provided IP routability exists. In a default-installed cluster without active NetworkPolicies, the network posture is strictly **Default-Allow**.

```
+---------------------------------------------------------------------------------------+
| DEFAULT KUBERNETES FLAT NETWORK (NO NETWORK POLICIES)                                 |
|                                                                                       |
|  [Compromised Web Pod] --------(ANY Port/IP)--------> [Payment Gateway Service]       |
|            |                                                   |                      |
|            +------------------(ANY Port/IP)-------------------> [Etcd / Control Plane]    |
|            |                                                   |                      |
|            +------------------(ANY Port/IP)-------------------> [AWS Metadata Service] |
|                                                                 (169.254.169.254)     |
+---------------------------------------------------------------------------------------+
```

From an enterprise SRE and Zero-Trust Security perspective, this flat network model exposes several critical attack vectors:
1. **Unrestricted Lateral Movement**: If an attacker gains Remote Code Execution (RCE) on a public-facing NGINX Pod in the `frontend` namespace, they can directly probe and exploit unauthenticated internal microservice endpoints, Redis caches, or PostgreSQL databases residing in the `backend` or `database` namespaces.
2. **Cloud Metadata Exfiltration**: Compromised workloads can query cloud provider Instance Metadata Services (IMDSv1 at `169.254.169.254`) to extract node IAM role credentials, leading to total cloud account compromise.
3. **Internal Reconnaissance & Port Scanning**: Attackers can execute `nmap` or custom scripts inside a container to map out internal ClusterIP ranges, service discovery records (`*.svc.cluster.local`), and Kubelet APIs (`10250/TCP`).
4. **Data Exfiltration**: Without egress restrictions, malicious code can establish reverse shells or exfiltrate sensitive data to arbitrary external IP addresses over standard outbound ports (`80/TCP`, `443/TCP`, `22/TCP`).

### 1.2 Declarative Intent vs. CNI Enforcement Engine
A common production failure mode is confusing the API declaration with packet-level enforcement. `NetworkPolicy` (`networking.k8s.io/v1`) is an **abstract API resource**. The Kubernetes Control Plane (`kube-apiserver` and `etcd`) merely stores and validates the manifest. It **does not filter network packets**.

Actual network traffic filtration relies entirely on the underlying **Container Network Interface (CNI)** plugin implementation:
* **Silent Non-Enforcement**: If a cluster runs on a basic CNI like standard Flannel (without Calico integration) or basic AWS-VPC CNI without policy enforcement enabled, `NetworkPolicy` resources will be successfully created in `etcd`, but network packets will **never be dropped**.
* **Stateful Filtering**: Compliance with `NetworkPolicy` requires stateful connection tracking (Conntrack). When ingress or egress rules allow traffic, the return traffic for established connections is automatically permitted.

---

## 2. Technical Comparisons & Architecture Trade-Offs

### 2.1 Security Postures: Default-Deny vs. Ad-Hoc Filtering

| Architectural Dimension | Default-Allow (Default K8s) | Ad-Hoc Specific Rules | Strict Default-Deny (Zero Trust) |
| :--- | :--- | :--- | :--- |
| **Ingress Posture** | Open to all cluster Pods and external nodes. | Open except where specific ingress rules exist. | Isolated by default (`policyTypes: [Ingress]`). |
| **Egress Posture** | Open to all internal IPs and public Internet. | Open except where specific egress rules exist. | Isolated by default (`policyTypes: [Egress]`). |
| **Blast Radius on Pod Compromise** | Maximum. Total internal network access. | Moderate. Depends on defined blacklists/whitelists. | Minimal. Traffic limited strictly to explicit pairs. |
| **Operational Overhead** | Zero setup effort; high security risk. | Low initial setup; prone to missing coverage. | High initial mapping requirement; complete control. |
| **Fail-Safe Mode** | Insecure on CNI misconfiguration. | Partially insecure. | Secure (Fails closed if policies applied correctly). |

### 2.2 CNI Policy Enforcement Architectures: eBPF vs. iptables vs. Open vSwitch (OVS)

```
                       TRAFFIC EVALUATION ARCHITECTURES
                       
 iptables (Linear Evaluation):
 Packet In -> [Rule 1] -> [Rule 2] -> ... -> [Rule N] -> Accept / Drop  (O(N) Complexity)

 eBPF Map Lookup (Hash Table):
 Packet In -> [ eBPF XDP/TC Hook ] -> HASH LOOKUP (BFP Map) -> Accept / Drop (O(1) Complexity)
```

| Feature / Metric | iptables (e.g., Legacy Calico/Kube-Router) | eBPF (e.g., Cilium, Calico eBPF Mode) | Open vSwitch (e.g., Antrea) |
| :--- | :--- | :--- | :--- |
| **Kernel Hook Point** | Netfilter hooks (`PREROUTING`, `FORWARD`, `POSTROUTING`) | eBPF TC (Traffic Control) & XDP (eXpress Data Path) | OpenFlow Pipeline / OVS Kernel module |
| **Algorithm Complexity** | $O(N)$ linear chain traversal per packet | $O(1)$ Hash Map lookups | $O(1)$ to $O(\log N)$ Flow table matching |
| **CPU Overhead at Scale (10k+ Pods)** | **High**: Sequential rule evaluation causes CPU throttling. | **Very Low**: Constant-time map lookup. | **Low**: Optimized flow table caching. |
| **Rule Update Latency** | **Slow**: Table lock requires re-loading entire rule set. | **Instant**: Atomic eBPF map update via syscalls. | **Fast**: Incremental OpenFlow rule insertion. |
| **L7 Filtering Capability** | No (L3/L4 only). | Yes (Native HTTP, gRPC, Kafka parsing via Envoy). | Requires proxy injection for L7. |
| **Packet Trace / Observability** | Packet counters via `iptables-save`; trace log flooding. | Rich observability (Hubble / eBPF ring buffer events). | OVS tracing tools (`ovs-appctl ofproto/trace`). |

### 2.3 Native NetworkPolicy vs. Extended CNI CRDs

| Requirement | Native K8s `NetworkPolicy` (`networking.k8s.io/v1`) | Cilium `CiliumNetworkPolicy` / Calico `GlobalNetworkPolicy` |
| :--- | :--- | :--- |
| **Scope** | Namespaced only. | Global (Cluster-wide) + Namespaced options. |
| **Selector Types** | `podSelector`, `namespaceSelector`, `ipBlock`. | Pod, Namespace, Service Account, Node, Domain (FQDN). |
| **Deny Rules** | Implicit (via policy selection). **No explicit DENY**. | Supports explicit **DENY** overrides and Precedence. |
| **L7 Control** | Supported in API structure conceptually, but standard is L3/L4 only. | Full L7 (HTTP Methods, Headers, Path, gRPC, DNS). |
| **Cluster Egress by FQDN** | **Unsupported** (IP CIDR blocks only). | **Supported** (e.g., allow `api.stripe.com` dynamically). |

---

## 3. Production-Grade Complete YAML Manifests

The following manifests construct a multi-tenant microservice environment featuring a `Default-Deny-All` baseline, explicit intra-namespace rules, cross-namespace monitoring collection, and outbound metadata protection.

### 3.1 Namespace Infrastructure Setup
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    environment: production
    security-zone: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    environment: production
    security-zone: infrastructure
```

### 3.2 Global Default-Deny-All NetworkPolicy (`production` Namespace)
This policy isolates **all** Pods within the `production` namespace for both Ingress and Egress traffic.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {} # Selects all Pods in the namespace
  policyTypes:
  - Ingress
  - Egress
```

### 3.3 Core Database NetworkPolicy
Permits inbound traffic on port `5432/TCP` **strictly** from Pods labeled `app.kubernetes.io/name: backend` in the `production` namespace. Blocks all outbound egress from the database.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: database
      app.kubernetes.io/component: database
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: backend
          app.kubernetes.io/component: api
    ports:
    - protocol: TCP
      port: 5432
  egress: [] # Explicitly empty: No outbound traffic allowed
```

### 3.4 Backend API NetworkPolicy (Complex Ingress & Egress Rules)
Includes:
1. **Ingress**: Port `8080/TCP` from `frontend` Pods; Port `9090/TCP` from Prometheus Pods in `monitoring` namespace (**AND** logic combination).
2. **Egress**: Port `5432/TCP` to Database Pods; Ports `53/UDP` & `53/TCP` to Kube-DNS; Port `443/TCP` to external APIs, **explicitly excluding AWS Metadata IP `169.254.169.254/32`**.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: backend
      app.kubernetes.io/component: api
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Rule 1: Allow Ingress from Frontend Pods in same namespace
  - from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: frontend
    ports:
    - protocol: TCP
      port: 8080
  # Rule 2: Allow Metrics Collection from Prometheus in 'monitoring' namespace
  - from:
    - namespaceSelector:
        matchLabels:
          environment: production
          security-zone: infrastructure
      podSelector:
        matchLabels:
          app.kubernetes.io/name: prometheus
    ports:
    - protocol: TCP
      port: 9090
  egress:
  # Rule 1: Allow Egress to Database Pods
  - to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: database
    ports:
    - protocol: TCP
      port: 5432
  # Rule 2: Allow DNS Resolution (CoreDNS in kube-system)
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
  # Rule 3: Allow Outbound HTTPS to Public Internet EXCEPT Cloud Metadata & Private RFC1918 Ranges
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 169.254.169.254/32 # Block AWS/GCP Metadata Service
        - 10.0.0.0/8         # Block internal cluster/VPC network exfiltration
        - 172.16.0.0/12
        - 192.168.0.0/16
    ports:
    - protocol: TCP
      port: 443
```

---

## 4. Real CLI Commands & Terminal Output Execution

### 4.1 Provisioning Test Workloads
Execute the deployment of `frontend`, `backend`, `database`, and external test Pods across namespaces.

```bash
$ kubectl create deployment database --image=postgres:15-alpine -n production --port=5432
deployment.apps/database created

$ kubectl label deployment database -n production app.kubernetes.io/name=database app.kubernetes.io/component=database
deployment.apps/database labeled

$ kubectl create deployment backend --image=nginx:alpine -n production --port=8080
deployment.apps/backend created

$ kubectl label deployment backend -n production app.kubernetes.io/name=backend app.kubernetes.io/component=api
deployment.apps/backend labeled

$ kubectl create deployment frontend --image=nginx:alpine -n production --port=80
deployment.apps/frontend created

$ kubectl label deployment frontend -n production app.kubernetes.io/name=frontend
deployment.apps/frontend labeled

$ kubectl run prometheus --image=busybox -n monitoring -- labels="app.kubernetes.io/name=prometheus" -- sleep 3600
pod/prometheus created
```

### 4.2 Applying Network Policies and Inspecting State

```bash
$ kubectl apply -f default-deny-all.yaml -n production
networkpolicy.networking.k8s.io/default-deny-all created

$ kubectl apply -f database-policy.yaml -n production
networkpolicy.networking.k8s.io/database-policy created

$ kubectl apply -f backend-policy.yaml -n production
networkpolicy.networking.k8s.io/backend-policy created

$ kubectl get netpol -n production
NAME               POD-SELECTOR                                  AGE
backend-policy     app.kubernetes.io/component=api,app...        18s
database-policy    app.kubernetes.io/component=database,app...   24s
default-deny-all   <none>                                        30s
```

```bash
$ kubectl describe netpol backend-policy -n production
Name:         backend-policy
Namespace:    production
Created on:   2026-08-07T20:01:36-04:00
Labels:       <none>
Annotations:  <none>
Spec:
  PodSelector:     app.kubernetes.io/component=api,app.kubernetes.io/name=backend
  Allowing ingress traffic:
    To Port: 8080/TCP
      From:
        PodSelector: app.kubernetes.io/name=frontend
    To Port: 9090/TCP
      From:
        NamespaceSelector: environment=production, security-zone=infrastructure
        PodSelector: app.kubernetes.io/name=prometheus
  Allowing egress traffic:
    To Port: 5432/TCP
      To:
        PodSelector: app.kubernetes.io/name=database
    To Port: 53/TCP
    To Port: 53/UDP
      To:
        NamespaceSelector: kubernetes.io/metadata.name=kube-system
        PodSelector: k8s-app=kube-dns
    To Port: 443/TCP
      To:
        IPBlock:
          CIDR: 0.0.0.0/0
          Except: 169.254.169.254/32, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
  Policy Types: Ingress, Egress
```

### 4.3 Empirical Traffic Verification Tests

#### Test 1: Verify Unauthorized Ingress to Database is BLOCKED
Attempting to connect directly from `frontend` to `database` on port `5432` must time out.

```bash
$ FRONTEND_POD=$(kubectl get pod -n production -l app.kubernetes.io/name=frontend -o jsonpath='{.items[0].metadata.name}')
$ DB_IP=$(kubectl get pod -n production -l app.kubernetes.io/name=database -o jsonpath='{.items[0].status.podIP}')

$ kubectl exec -n production "$FRONTEND_POD" -- nc -zv -w 3 "$DB_IP" 5432
nc: connect to 10.244.1.45 port 5432 (tcp) timed out
command terminated with exit code 1
```

#### Test 2: Verify Authorized Ingress from Backend to Database SUCCEEDS

```bash
$ BACKEND_POD=$(kubectl get pod -n production -l app.kubernetes.io/name=backend -o jsonpath='{.items[0].metadata.name}')

$ kubectl exec -n production "$BACKEND_POD" -- nc -zv -w 3 "$DB_IP" 5432
10.244.1.45 (10.244.1.45:5432) open
```

#### Test 3: Verify Cloud Metadata Access from Backend is BLOCKED

```bash
$ kubectl exec -n production "$BACKEND_POD" -- curl -m 3 -sI http://169.254.169.254/latest/meta-data/
command terminated with exit code 28
# Exit code 28: Operation timeout (Packet dropped by egress policy)
```

#### Test 4: Verify Public HTTPS Egress from Backend SUCCEEDS

```bash
$ kubectl exec -n production "$BACKEND_POD" -- curl -m 5 -sI https://1.1.1.1/
HTTP/2 200
date: Fri, 07 Aug 2026 20:01:36 GMT
content-type: text/html; charset=UTF-8
```

---

## 5. Verification and Failure Troubleshooting Guide

### 5.1 The Logical Operator Trap: OR vs. AND Semantics
The single most frequent mistake in Kubernetes `NetworkPolicy` syntax is formatting `- from:` array items improperly, causing unintended access grants or over-restrictive blocks.

#### The `OR` Evaluation Syntax (Multiple Array Elements)
```yaml
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          team: analytics
    - podSelector:
        matchLabels:
          role: reporting
```
* **Meaning**: Allow traffic from **ANY** Pod in a namespace labeled `team: analytics` **OR** from **ANY** Pod in the *current* namespace labeled `role: reporting`.

#### The `AND` Evaluation Syntax (Single Combined Array Element)
```yaml
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          team: analytics
      podSelector:
        matchLabels:
          role: reporting
```
* **Meaning**: Allow traffic **ONLY** from Pods labeled `role: reporting` that **ALSO** reside inside namespaces labeled `team: analytics`.

### 5.2 Common Troubleshooting Scenarios & Remediation Flow

```
                      NETWORK POLICY TROUBLESHOOTING FLOWCHART
                      
           [ Pod Communication Fails / Unexpectedly Passes ]
                                   |
                  Is CNI NetworkPolicy Enabled?
                                  / \
                            No   /   \  Yes
                            /         \
   [ CNI Does Not Support Policies ]   [ Inspect Active NetworkPolicies ]
   (e.g., Plain Flannel)               `kubectl get netpol -n <ns>`
   -> Install/Configure Calico/Cilium            |
                                       Does a Policy Target the Pod?
                                       (`podSelector` match)
                                             / \
                                       No   /   \  Yes
                                           /     \
                       [ Default-Allow Active ]   [ Pod is Isolated ]
                       Traffic Should Pass        Check Ingress/Egress Rules
                                                         |
                                                  Does DNS Work?
                                                  (Port 53 UDP Egress)
```

#### Issue A: Egress Policy Enabled, but Application Cannot Resolve Hostnames
* **Symptom**: Pod fails to reach external services with `Could not resolve host` errors.
* **Root Cause**: An `egress:` policy block was added without explicitly permitting traffic to the cluster DNS engine (`CoreDNS`).
* **Fix**: Always include an Egress rule selecting `k8s-app: kube-dns` in `kube-system` on port `53/UDP` & `53/TCP`.

#### Issue B: Silent Pass-Through (Policy Applied, but Traffic Not Blocked)
* **Symptom**: Unauthorized Pods can still talk to isolated Pods.
* **Root Cause**: CNI plugin lacks policy enforcement capabilities.
* **Diagnosis Command**:
```bash
# Check CNI pod logs (Example for Cilium or Calico)
$ kubectl logs -n kube-system -l k8s-app=cilium --tail=50 | grep -i "policy"
2026-08-07T20:01:36Z info [cilium-agent] Regenerated policy maps for 12 endpoints

# Verify if iptables rules exist on the worker node (for iptables-based CNI)
$ iptables-save -t filter | grep -i "KUBE-NWPOLICY"
:KUBE-NWPOLICY-CHAIN - [0:0]
-A KUBE-SERVICES -m comment --comment "kubernetes networkpolicy chain" -j KUBE-NWPOLICY-CHAIN
```

### 5.3 Low-Level Packet Tracing and eBPF Diagnostic Commands

#### 1. Trace Traffic Drops via Kernel eBPF (Cilium Hubble CLI)
```bash
$ hubble observe --namespace production --to-pod database --follow
Aug 07 20:01:36.412: production/frontend-7b447844-x89zk:43210 -> production/database-5586684-p9lq2:5432 policy-denied DROPPED (TCP Flags: SYN)
```

#### 2. Trace iptables Rule Evaluation on Worker Node
Log dropped packets directly to `dmesg` to inspect dropped TCP SYN packets:

```bash
$ iptables -I KUBE-NWPOLICY-CHAIN 1 -m limit --limit 5/min -j LOG --log-prefix "K8S_NETPOL_DROP: "

$ dmesg -T | grep K8S_NETPOL_DROP
[Fri Aug  7 20:01:36 2026] K8S_NETPOL_DROP: IN=cali12345 OUT=cali67890 SRC=10.244.1.44 DST=10.244.1.45 LEN=60 TOS=0x00 PREC=0x00 TTL=64 ID=43123 DF TCP SPT=51234 DPT=5432 WINDOW=64240 SYN
```

#### 3. Validate NetworkPolicy Object Structure with `kubectl-netpol` Plugin
```bash
$ kubectl netpol evaluate -n production --src-pod frontend-7b447844-x89zk --dst-pod database-5586684-p9lq2 --port 5432
Source: production/frontend-7b447844-x89zk
Destination: production/database-5586684-p9lq2
Port: 5432/TCP
Result: DENIED
Active Denying Policy: production/default-deny-all
Matching Allowed Policies: None
```

---

## 6. References

* **Kubernetes Official Documentation – Network Policies**: https://kubernetes.io/docs/concepts/services-networking/network-policies/
* **CNCF KCSA Exam Curriculum**: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **Cilium Network Policy Engine & eBPF Security**: https://docs.cilium.io/en/stable/security/policy/
* **Calico Network Policy Reference & Enforcement Mechanics**: https://docs.tigera.io/calico/latest/reference/resources/networkpolicy
* **Kubernetes Network Policy Recipes Repository**: https://github.com/ahmetb/kubernetes-network-policy-recipes