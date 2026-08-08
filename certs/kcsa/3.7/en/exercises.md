# KCSA Study Guide: Topic 3.7 - Network Policy

**Domain:** Kubernetes & Cloud Native Security Associate (KCSA)  
**Topic Weight:** ~3.14%  
**Target Audience:** SREs, Platform Engineers, and Security Architects  

---

## 1. Deep Technical Architecture & Internal Mechanics

### 1.1 Control Plane API vs. Data Plane Enforcement
Kubernetes standardizes network security policies through the `networking.k8s.io/v1` `NetworkPolicy` API resource. However, **kube-apiserver and kube-proxy do not enforce NetworkPolicies**. 

```
                                  +------------------------------------+
                                  |   Kubernetes API Server            |
                                  |   (networking.k8s.io/v1 NetPol)    |
                                  +-----------------+------------------+
                                                    |
                                          Watches & Translates
                                                    |
                                                    v
                                  +-----------------+------------------+
                                  |   CNI Plugin Controller            |
                                  |   (e.g., Cilium Agent / Calico)    |
                                  +-----------------+------------------+
                                                    |
                                          Programs Data Plane
                                                    |
             +--------------------------------------+--------------------------------------+
             |                                                                             |
             v                                                                             v
+--------------------------+                                                   +--------------------------+
|  eBPF Data Path          |                                                   |  iptables / ipset        |
|  (e.g., Cilium TC BPF)   |                                                   |  (e.g., Calico Felix)    |
|  - eBPF Maps (O(1) lookup|                                                   |  - Custom Chains         |
|  - In-kernel verdict     |                                                   |  - ipset sets for PODs   |
+--------------------------+                                                   +--------------------------+
```

1. **Control Plane Responsibilities**:
   - Validates `NetworkPolicy` syntax and persists objects in `etcd`.
   - Exposes watch endpoints for ingress/egress rule updates.

2. **Data Plane (CNI Plugin) Responsibilities**:
   - **Calico (iptables / ipset)**: Felix agent watches API objects, dynamically generates kernel `ipset` collections mapping pod IP addresses, and programs custom `iptables` chains (`cali-pi-*`, `cali-po-*`). Rule matching complexity scales with chain length, though `ipset` keeps IP lookups at $O(1)$.
   - **Cilium (eBPF)**: Cilium Agent translates `NetworkPolicies` directly into eBPF BPF maps (`cilium_policy_*`). Packet filtering occurs at the Traffic Control (`tc`) layer or socket layer (`cgroup-ebpf`) with $O(1)$ hash table lookups, completely bypassing `iptables` overhead.

### 1.2 Isolation Semantics and Policy Evaluation
By default, Kubernetes networking operates under an **Unisolated (Default-Allow)** model. Pods accept traffic from any source and transmit traffic to any destination.

- **Selective Isolation**: Adding a `NetworkPolicy` that selects a pod puts that pod into **Isolated Mode** for the specified `policyTypes` (`Ingress`, `Egress`, or both). Unselected pods remain unisolated.
- **Additive Authorization (Allow-List)**: NetworkPolicies are strictly additive. Multiple policies selecting the same pod are combined using an OR operation. There are no explicit "DENY" rules in standard Kubernetes `NetworkPolicy` resources.
- **AND vs. OR Selector Semantics**:
  - **OR Semantics (Multiple array elements)**:
    ```yaml
    ingress:
    - from:
      - namespaceSelector: { matchLabels: { environment: production } }
      - podSelector: { matchLabels: { role: frontend } }
    ```
    *Matches traffic if origin is in `production` namespace OR has label `role: frontend` in the policy's namespace.*
  - **AND Semantics (Single array element with multiple keys)**:
    ```yaml
    ingress:
    - from:
      - namespaceSelector: { matchLabels: { environment: production } }
        podSelector: { matchLabels: { role: frontend } }
    ```
    *Matches traffic ONLY IF origin is in `production` namespace AND has label `role: frontend`.*

---

## 2. Production Trade-offs and Operational Edge Cases

| Feature / Scenario | Technical Implication / Trade-off |
| :--- | :--- |
| **DNS Egress Policy (UDP/TCP 53)** | Restricting egress requires explicitly opening port 53 (UDP & TCP) to `kube-dns` / `CoreDNS`. Blocking egress DNS breaks service discovery entirely for isolated pods. |
| **Cloud Provider Metadata (169.254.169.254)** | Default-allow egress permits pods to reach node-local cloud metadata endpoints (IMDSv1/v2), risking instance role credential theft. Defense-in-depth requires explicit egress block via `ipBlock`. |
| **`ipBlock` in Dynamic Pod Networks** | `ipBlock` targets fixed CIDRs (e.g., corporate subnets, external APIs). Using `ipBlock` for Pod-to-Pod traffic is an anti-pattern because Pod IPs are ephemeral and reassigned dynamically. |
| **CNI Plugin Dependency** | Manifests succeed during `kubectl apply` even if no CNI network policy controller exists (e.g., raw Flannel). The policy will sit silently in `etcd` without enforcing isolation. |

---

## 3. Official References & Citations

- **Kubernetes Documentation - Network Policies**: [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- **Kubernetes API Reference - NetworkPolicy v1**: [https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.30/#networkpolicy-v1-networking-k8s-io](https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.30/#networkpolicy-v1-networking-k8s-io)
- **CNCF KCSA Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 4. Production Guided Exercises

### Exercise 1: Enforcing Multi-Tenant Default-Deny (Ingress & Egress)

In this exercise, you will create a multi-namespace topology, verify unisolated communication, apply a strict zero-trust default-deny stance, and verify complete isolation.

#### Step 1.1: Deploy test infrastructure across target namespaces

Execute the following commands to create isolated namespaces and workloads:

```bash
kubectl create namespace tenant-app
kubectl create namespace tenant-db

# Deploy Frontend in tenant-app
kubectl run frontend --namespace=tenant-app --image=nginx:alpine --labels=app=frontend,tier=web

# Deploy Backend API in tenant-app
kubectl run backend --namespace=tenant-app --image=nginx:alpine --labels=app=backend,tier=api

# Deploy Database in tenant-db
kubectl run database --namespace=tenant-db --image=nginx:alpine --labels=app=database,tier=db

# Wait for pods to be ready
kubectl wait --namespace=tenant-app --for=condition=Ready pod/frontend pod/backend --timeout=60s
kubectl wait --namespace=tenant-db --for=condition=Ready pod/database --timeout=60s
```

*Expected Output:*
```text
namespace/tenant-app created
namespace/tenant-db created
pod/frontend created
pod/backend created
pod/database created
pod/frontend condition met
pod/backend condition met
pod/database condition met
```

#### Step 1.2: Validate default unisolated cross-namespace connectivity

Retrieve the `database` Pod IP and test HTTP reachability from `frontend` in `tenant-app`:

```bash
DB_IP=$(kubectl get pod database -n tenant-db -o jsonpath='{.status.podIP}')
kubectl exec -n tenant-app frontend -- wget -qO- --timeout=3 http://$DB_IP
```

*Expected Output:*
```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

#### Step 1.3: Apply Default-Deny Ingress and Egress NetworkPolicies

Apply zero-trust baseline manifests to both namespaces:

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-app
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-db
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
networkpolicy.networking.k8s.io/default-deny-all created
```

#### Step 1.4: Verify traffic block and timeout behavior

Attempt network reachability again from `frontend` to `database`:

```bash
kubectl exec -n tenant-app frontend -- wget -qO- --timeout=3 http://$DB_IP
```

*Expected Output:*
```text
wget: download timed out
command terminated with exit code 1
```

---

### Verification Questions (Exercise 1)

1. Why must `policyTypes` explicitly include `Egress` in `default-deny-all`? What happens if `policyTypes` is omitted entirely in a manifest that contains no `ingress` or `egress` rules?
2. If a pod has label `app=unaffected` in `tenant-app`, is its traffic blocked by `default-deny-all`? Why or why not?

---

### Exercise 2: Fine-Grained Least-Privilege Policy with Combined Selectors

In this exercise, you will authorize specific microservice traffic while retaining zero-trust isolation for non-authorized routes. You will allow `frontend` in `tenant-app` to access `backend` on TCP port 80, and allow `backend` to access `database` in `tenant-db`.

```
[ tenant-app ]                         [ tenant-db ]
+----------+       TCP 80      +---------+       TCP 80      +----------+
| frontend |  -------------->  | backend |  -------------->  | database |
+----------+                   +---------+                   +----------+
```

#### Step 2.1: Label the namespaces for selector matching

Namespace selectors rely on namespace metadata. Add standard labels to `tenant-app` and `tenant-db`:

```bash
kubectl label namespace tenant-app name=tenant-app
kubectl label namespace tenant-db name=tenant-db
```

*Expected Output:*
```text
namespace/tenant-app labeled
namespace/tenant-db labeled
```

#### Step 2.2: Apply CoreDNS Egress policy for `tenant-app`

Allow pods in `tenant-app` to perform DNS resolution against `kube-system`:

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-coredns-egress
  namespace: tenant-app
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
EOF
```

*Expected Output:*
```text
networkpolicy.networking.k8s.io/allow-coredns-egress created
```

#### Step 2.3: Apply Frontend-to-Backend authorization policy

Allow `frontend` pod egress to `backend`, and `backend` pod ingress from `frontend` on port 80:

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: tenant-app
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-backend
  namespace: tenant-app
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 80
EOF
```

*Expected Output:*
```text
networkpolicy.networking.k8s.io/allow-frontend-to-backend created
networkpolicy.networking.k8s.io/allow-egress-to-backend created
```

#### Step 2.4: Apply Cross-Namespace Backend-to-Database authorization policy

Configure `tenant-db` to allow ingress to `app=database` ONLY from `app=backend` residing in `name=tenant-app`:

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-ingress
  namespace: tenant-db
spec:
  podSelector:
    matchLabels:
      app: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: tenant-app
      podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-db
  namespace: tenant-app
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: tenant-db
      podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 80
EOF
```

*Expected Output:*
```text
networkpolicy.networking.k8s.io/allow-backend-ingress created
networkpolicy.networking.k8s.io/allow-egress-to-db created
```

#### Step 2.5: Validate end-to-end traffic flows and boundaries

1. Test DNS resolution and HTTP path from `frontend` to `backend.tenant-app.svc.cluster.local`:
```bash
kubectl exec -n tenant-app frontend -- wget -qO- --timeout=3 http://backend
```
*Expected Output:* HTML string from `backend` nginx.

2. Test HTTP path from `backend` to `database.tenant-db.svc.cluster.local`:
```bash
kubectl exec -n tenant-app backend -- wget -qO- --timeout=3 http://database.tenant-db
```
*Expected Output:* HTML string from `database` nginx.

3. Test illegal traffic path from `frontend` directly to `database.tenant-db.svc.cluster.local`:
```bash
kubectl exec -n tenant-app frontend -- wget -qO- --timeout=3 http://database.tenant-db
```
*Expected Output:* `wget: download timed out` (Blocked by policy).

---

### Verification Questions (Exercise 2)

1. Examine the `ingress` rule in Step 2.4. What would happen if `- namespaceSelector:` and `podSelector:` were formatted as separate array items (prefixed with `-` on both elements)?
2. Why did `frontend` fail to reach `database.tenant-db` directly in Step 2.5 even though `database` allows ingress from namespace `tenant-app`?

---

### Exercise 3: External Egress Control and Cloud Metadata Mitigation

In this exercise, you will enforce egress filtering to allow access to public HTTPS services while strictly blocking access to cloud metadata IP (`169.254.169.254/32`).

#### Step 3.1: Apply Egress policy with `ipBlock` filtering

Deploy an egress policy for `frontend` allowing external CIDR access while excepting link-local metadata addresses:

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-egress-secure
  namespace: tenant-app
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Egress
  egress:
  # Rule 1: Allow DNS
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
  # Rule 2: Allow Internet HTTPS, exclude Cloud Metadata IMDS
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 169.254.169.254/32
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
    ports:
    - protocol: TCP
      port: 443
EOF
```

*Expected Output:*
```text
networkpolicy.networking.k8s.io/allow-external-egress-secure created
```

#### Step 3.2: Verify metadata blocking and permitted HTTPS egress

1. Execute request to simulated/actual cloud metadata endpoint:
```bash
kubectl exec -n tenant-app frontend -- wget -qO- --timeout=3 http://169.254.169.254/latest/meta-data/
```
*Expected Output:*
```text
wget: download timed out
command terminated with exit code 1
```

2. Execute request to public HTTPS endpoint:
```bash
kubectl exec -n tenant-app frontend -- wget -qO- --timeout=5 https://1.1.1.1
```
*Expected Output:* Connection successful (HTTP 200/404 response body or SSL handshake success).

---

### Verification Questions (Exercise 3)

1. Does `ipBlock.except` block internal cluster Pod-to-Pod traffic if the pod network uses `10.244.0.0/16` and `10.0.0.0/8` is in `except`?
2. If a pod attempts to contact `https://169.254.169.254` on port 443, which rule processes it, and is it allowed?

---

### Exercise 4: Production Diagnostics & CNI Data-Plane Inspection

When network policies fail or block legitimate traffic, SREs must inspect data plane rules directly.

#### Step 4.1: Inspect Policy Enforcement via `kubectl` Audit Commands

Verify which NetworkPolicies apply to target pods in `tenant-app`:

```bash
kubectl get networkpolicy -n tenant-app -o wide
```

*Expected Output:*
```text
NAME                           POD-SELECTOR   AGE
default-deny-all               <none>         10m
allow-coredns-egress           <none>         8m
allow-frontend-to-backend      app=backend    5m
allow-egress-to-backend        app=frontend   5m
allow-egress-to-db             app=backend    3m
allow-external-egress-secure   app=frontend   1m
```

#### Step 4.2: Inspect CNI iptables rules (Calico / Standard Linux Node Environment)

If running Calico or an iptables-based CNI on the cluster nodes, view programmed iptables rules for pod interfaces:

```bash
# Execute on cluster node or via privileged daemonset
iptables-save | grep -E "cali-pi|cali-po|FORWARD" | head -n 20
```

*Expected Output:*
```text
:cali-pi-wlan0 - [0:0]
:cali-po-wlan0 - [0:0]
-A FORWARD -m comment --comment "cali:wvbV2563hsh" -j cali-FORWARD
-A cali-fw-cali12345 -m comment --comment "cali:deny-all-ingress" -j DROP
```

#### Step 4.3: Inspect CNI eBPF Maps (Cilium Environment)

If using Cilium, monitor dropped packets live in kernel space:

```bash
# Execute within cilium agent pod (e.g. in kube-system)
CILIUM_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system $CILIUM_POD -c cilium-agent -- cilium monitor --type drop
```

*Expected Output:*
```text
Press Ctrl-C to quit management monitor.
xx drop (Policy denied) flow 0x3d2a4f61 to endpoint 1024, context identity 45102->18201, direction egress
xx drop (Policy denied) flow 0x12b489a2 to endpoint 2048, context identity 18201->59012, direction ingress
```

---

## 5. Answers and Solutions

<details>
<summary><strong>Click to expand Answers and Deep-Dive Explanations</strong></summary>

### Exercise 1 Answers

1. **`policyTypes` Behavior**:
   - If `policyTypes` is omitted, Kubernetes defaults `policyTypes` to `["Ingress"]`. If the manifest contains an `egress:` section, it automatically adds `Egress`. 
   - However, for a `default-deny-all` policy with an empty `podSelector: {}` and **no** `ingress` or `egress` rules specified, omitting `policyTypes` causes Kubernetes to ONLY enforce Ingress default deny. Egress traffic would remain unisolated (default-allow). Therefore, `Egress` must be explicitly listed in `policyTypes`.

2. **Pod Label Matching**:
   - Yes, `app=unaffected` is blocked. `podSelector: {}` is an empty label selector, which in Kubernetes API mechanics selects **ALL pods** in the policy's namespace (`tenant-app`).

---

### Exercise 2 Answers

1. **AND vs. OR Selector Semantics**:
   - If formatted as separate items:
     ```yaml
     ingress:
     - from:
       - namespaceSelector:
           matchLabels: { name: tenant-app }
       - podSelector:
           matchLabels: { app: backend }
     ```
     This configures **OR** semantics. Traffic would be permitted from ANY pod in namespace `tenant-app` OR from ANY pod matching `app=backend` in the `tenant-db` namespace.
   - Using a single array item configures **AND** semantics: traffic must come from namespace `tenant-app` AND originate from a pod labeled `app=backend`.

2. **Cross-Namespace Egress Isolation**:
   - `frontend` failed to reach `database.tenant-db` for two distinct reasons:
     1. **Egress Block at Source**: `frontend` in `tenant-app` is under `default-deny-all` Egress isolation. It has no egress rule permitting traffic to namespace `tenant-db` or port 80 on `database`.
     2. **Ingress Block at Target**: `database` in `tenant-db` enforces ingress rules allowing ONLY pods matching `app=backend`. `frontend` does not match `app=backend`.

---

### Exercise 3 Answers

1. **`ipBlock` Scope**:
   - Yes, `ipBlock` evaluates raw IP headers. If pod IPs fall within `10.0.0.0/8`, the `except` clause explicitly removes those destination IPs from the rule's permit hash. Pod-to-Pod communication within `10.0.0.0/8` will be denied unless another rule permits it via `podSelector` / `namespaceSelector`.
   - **Best Practice**: Use `podSelector` / `namespaceSelector` for cluster-internal traffic and reserve `ipBlock` strictly for external egress/ingress endpoints outside the Kubernetes cluster SDN.

2. **Port-Specific Egress Evaluation**:
   - The packet is **blocked**. Rule 2 specifies `ports: [{ protocol: TCP, port: 443 }]`. Even though `169.254.169.254/32` is explicitly excluded from the CIDR range, any request to port 80 or port 443 targeting `169.254.169.254` fails to match the rule's permitted destination IP set.

</details>