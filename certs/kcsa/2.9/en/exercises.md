# KCSA Topic 2.9: Container Networking Hands-on Guided Lab

**Certification Domain:** Kubernetes Security Associate (KCSA)  
**Domain Weight:** 2.0  
**Target Version:** Kubernetes v1.30+  
**Official References:**  
* [CNCF KCSA Curriculum](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)  
* [Kubernetes Documentation: Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)  
* [CNCF CNI Specification](https://github.com/containernetworking/cni/blob/main/SPEC.md)  
* [Cilium Security Architecture](https://docs.cilium.io/en/stable/security/)  
* [Calico Network Policy Architecture](https://docs.tigera.io/calico/latest/network-policy/)  

---

## Prerequisites & Lab Environment
Ensure you have access to a Kubernetes cluster running a CNI plugin that supports `NetworkPolicy` enforcement (e.g., Calico, Cilium, or Flannel with Kube-Router). Commands use `kubectl`, standard Linux network tools (`ip`, `nsenter`), and CNI diagnostics.

---

## Exercise 1: Linux Network Namespace Isolation & CNI Data Plane Inspection

### Architectural Context
Container networking relies on Linux network namespaces (`netns`), virtual ethernet pairs (`veth`), and CNI binaries. When a Pod is created, the CRI plugin invokes the CNI plugin via the CNI specification API (`ADD` command). The CNI plugin creates a `veth` pair, moves one end into the Pod's network namespace (renamed to `eth0`), attaches the host end to a bridge or eBPF hook, assigns an IP address, and configures host routing and firewalling.

```
+-------------------------------------------------------------------------+
| Host Network Namespace (Node)                                           |
|                                                                         |
|  +-------------------------+            +----------------------------+  |
|  | CNI Bridge / eBPF Maps  |            | iptables / netfilter /     |  |
|  | (e.g. cni0 / cilium_host) |           | conntrack engine           |  |
|  +------------+------------+            +--------------+-------------+  |
|               |                                        |                |
|           vethX1234                                    |                |
|               | (veth pair boundary)                   |                |
+---------------+----------------------------------------+----------------+
                |
+---------------+---------------------------------------------------------+
| Pod Network Namespace (Target Pod)                                     |
|               |                                                         |
|             eth0 (10.244.1.15/24)                                       |
|               |                                                         |
|         [ App Container ]                                               |
+-------------------------------------------------------------------------+
```

### Execution Steps

1. Create a isolated namespace `net-sec-lab` and deploy a workload to inspect:
```bash
kubectl create namespace net-sec-lab
kubectl run target-app --namespace=net-sec-lab --image=nginx:1.25-alpine --port=80
kubectl wait --for=condition=Ready pod/target-app -n net-sec-lab --timeout=60s
```
*Expected Output:*
```text
namespace/net-sec-lab created
pod/target-app created
pod/target-app condition met
```

2. Identify the Node running the Pod and the target Container ID using `kubectl`:
```bash
POD_NODE=$(kubectl get pod target-app -n net-sec-lab -o jsonpath='{.spec.nodeName}')
CONTAINER_ID=$(kubectl get pod target-app -n net-sec-lab -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's/containerd:\/\///')
echo "Node: ${POD_NODE} | ContainerID: ${CONTAINER_ID}"
```
*Expected Output:*
```text
Node: worker-node-01 | ContainerID: a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0
```

3. Retrieve the Sandbox Network Namespace PID for the Pod using `crictl` or `nerdctl` on the host node (or via container runtime socket):
```bash
# Executed on the worker node:
PSTATUS=$(crictl inspectp --output json $(crictl pods --name target-app -q))
PID=$(echo $PSTATUS | jq '.info.pid')
echo "Pod Network Namespace PID: ${PID}"
```
*Expected Output:*
```text
Pod Network Namespace PID: 12458
```

4. Inspect the network interface and routes inside the Pod's network namespace from the host:
```bash
nsenter -t ${PID} -n ip addr show dev eth0
nsenter -t ${PID} -n ip route show
```
*Expected Output:*
```text
3: eth0@if14: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UP group default 
    link/ether 6e:4a:32:89:12:ef brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.244.1.15/24 brd 10.244.1.255 scope global eth0
       valid_lft forever preferred_lft forever
default via 10.244.1.1 dev eth0 
10.244.1.0/24 dev eth0 scope link src 10.244.1.15 
```

5. Find the corresponding host-side `veth` interface index (index `14` from `@if14`):
```bash
ip link show | grep -B1 "if3:"
```
*Expected Output:*
```text
14: vethb9a1c2d@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue master cni0 state UP group default 
    link/ether 22:33:44:55:66:77 brd ff:ff:ff:ff:ff:ff link-netnsid 1
```

---

### Verification Questions (Exercise 1)

1. **Question 1.1:** Why does the `veth` interface inside the Pod namespace reference `@if14`, while the interface on the host namespace references `@if3`? What security boundary does this mechanism enforce?
2. **Question 1.2:** If an attacker executes a container breakout exploit and gains `CAP_NET_ADMIN` inside a non-hostNetwork Pod, can they reconfigure interface routes or inspect traffic of other network namespaces on the host?

---

## Exercise 2: Implementing Zero-Trust Micro-segmentation with NetworkPolicies

### Architectural Context
By default, Kubernetes networking uses an unsegmented flat network model: any Pod can communicate with any other Pod across all namespaces. A `NetworkPolicy` acts as an ingress/egress firewall evaluated at the CNI data plane (via `iptables`, `IPVS`, or `eBPF` maps). 

When a `NetworkPolicy` is applied to a namespace selecting a set of Pods:
1. The selected Pods transition from **Unisolated** to **Isolated** for the declared policy types (`Ingress`, `Egress`, or both).
2. Traffic not explicitly permitted by an `ingress` or `egress` rule is dropped (Implicit Default Deny).
3. `NetworkPolicy` enforcement is **stateful**: return traffic for allowed connection flows is automatically permitted by `conntrack` or eBPF connection tracking tables.

```
+----------------------------------------------------------------------------------+
| Namespace: net-sec-lab                                                           |
|                                                                                  |
|  +-------------------+        +--------------------+        +-----------------+  |
|  |   client-frontend |        |   backend-api      |        |   db-storage    |  |
|  | (role=frontend)   |        |  (role=backend)    |        |   (role=db)     |  |
|  +---------+---------+        +---------+----------+        +--------+--------+  |
|            |                            |                            |           |
|            | TCP/8080 (Allowed)         | TCP/5432 (Allowed)         |           |
|            +--------------------------->+--------------------------->+           |
|                                                                                  |
|            X-------------------------------------------------------->X           |
|                     TCP/5432 Direct Access BLOCKED (Default Deny)                |
+----------------------------------------------------------------------------------+
```

### Execution Steps

1. Deploy a multi-tier application stack in `net-sec-lab`:
```bash
# Create Backend API
kubectl run backend-api -n net-sec-lab --image=nginx:1.25-alpine --labels="app=backend-api,tier=api" --port=8080
# Create Database
kubectl run db-storage -n net-sec-lab --image=nginx:1.25-alpine --labels="app=db-storage,tier=db" --port=5432
# Create Frontend Client
kubectl run client-frontend -n net-sec-lab --image=alpine:3.19 --labels="app=client-frontend,tier=frontend" -- sleep 3600

kubectl wait --for=condition=Ready pod --all -n net-sec-lab --timeout=60s
```
*Expected Output:*
```text
pod/backend-api created
pod/db-storage created
pod/client-frontend created
pod/backend-api condition met
pod/db-storage condition met
pod/client-frontend condition met
```

2. Retrieve internal IP addresses of all pods:
```bash
BACKEND_IP=$(kubectl get pod backend-api -n net-sec-lab -o jsonpath='{.status.podIP}')
DB_IP=$(kubectl get pod db-storage -n net-sec-lab -o jsonpath='{.status.podIP}')
echo "Backend IP: ${BACKEND_IP} | DB IP: ${DB_IP}"
```
*Expected Output:*
```text
Backend IP: 10.244.1.16 | DB IP: 10.244.1.17
```

3. Verify unsegmented connectivity before applying policies:
```bash
kubectl exec -n net-sec-lab client-frontend -- nc -z -v -w 2 ${DB_IP} 5432
```
*Expected Output:*
```text
10.244.1.17 (10.244.1.17:5432): open
```

4. Apply a **Default Deny All Ingress and Egress** NetworkPolicy manifest to isolate the `net-sec-lab` namespace:

```yaml
# default-deny-all.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: net-sec-lab
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```
Save and apply:
```bash
kubectl apply -f default-deny-all.yaml
```
*Expected Output:*
```text
networkpolicy.networking.k8s.io/default-deny-all created
```

5. Confirm that communication is now blocked:
```bash
kubectl exec -n net-sec-lab client-frontend -- nc -z -v -w 2 ${DB_IP} 5432
```
*Expected Output:*
```text
nc: bad address '10.244.1.17'
# or connection timed out after 2 seconds
```

6. Apply a zero-trust policy allowing:
   - `client-frontend` to access `backend-api` on TCP 8080.
   - `backend-api` to access `db-storage` on TCP 5432.
   - Essential CoreDNS Egress (UDP 53) for DNS resolution.

```yaml
# microsegmentation-rules.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: net-sec-lab
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: net-sec-lab
spec:
  podSelector:
    matchLabels:
      app: backend-api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: client-frontend
    ports:
    - protocol: TCP
      port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-db
  namespace: net-sec-lab
spec:
  podSelector:
    matchLabels:
      app: db-storage
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: backend-api
    ports:
    - protocol: TCP
      port: 5432
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-egress-to-db
  namespace: net-sec-lab
spec:
  podSelector:
    matchLabels:
      app: backend-api
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: db-storage
    ports:
    - protocol: TCP
      port: 5432
```
Save and apply:
```bash
kubectl apply -f microsegmentation-rules.yaml
```
*Expected Output:*
```text
networkpolicy.networking.k8s.io/allow-dns-egress created
networkpolicy.networking.k8s.io/allow-frontend-to-backend created
networkpolicy.networking.k8s.io/allow-backend-to-db created
networkpolicy.networking.k8s.io/allow-backend-egress-to-db created
```

7. Execute network verification commands:
```bash
# Test 1: Frontend to Backend (Should Succeed if port matches)
kubectl exec -n net-sec-lab client-frontend -- nc -z -v -w 2 ${BACKEND_IP} 8080

# Test 2: Frontend to DB (Must Fail - Direct access prohibited)
kubectl exec -n net-sec-lab client-frontend -- nc -z -v -w 2 ${DB_IP} 5432
```
*Expected Output:*
```text
10.244.1.16 (10.244.1.16:8080): open
nc: 10.244.1.17 (10.244.1.17:5432): Operation timed out
```

---

### Verification Questions (Exercise 2)

1. **Question 2.1:** In `allow-frontend-to-backend`, why did we specify `podSelector` under `spec` to target `app: backend-api`, while `app: client-frontend` is inside the `ingress.from` list?
2. **Question 2.2:** What happens if `allow-backend-egress-to-db` is omitted, but `allow-backend-to-db` (Ingress on DB) and `default-deny-all` are both active? Will the request succeed?
3. **Question 2.3:** Consider an `ingress` item combining `podSelector` and `namespaceSelector`:
   ```yaml
   ingress:
   - from:
     - namespaceSelector:
         matchLabels:
           env: prod
       podSelector:
         matchLabels:
           role: worker
   ```
   How does this differ in evaluation compared to separate list items under `from`:
   ```yaml
   ingress:
   - from:
     - namespaceSelector:
         matchLabels:
           env: prod
     - podSelector:
         matchLabels:
           role: worker
   ```

---

## Exercise 3: CNI Data Plane Diagnostics & eBPF / iptables Troubleshooting

### Architectural Context
When a `NetworkPolicy` packet drop occurs, troubleshooting requires diagnosing whether the issue is at the DNS layer, CNI policy engine layer, netfilter layer, or overlay tunnel layer.

In `iptables`-based CNIs (e.g., Calico in standard mode), policy rules are programmed into specific iptables chains (`cali-pi-...` / `cali-po-...`).  
In `eBPF`-based CNIs (e.g., Cilium), filtering occurs directly at the Linux socket layer or TC (Traffic Control) ingress/egress hooks using eBPF maps, bypassing netfilter entirely.

```
iptables Engine (Traditional CNI):
[ Packet ] ---> TC ---> PREROUTING ---> FORWARD ---> cali-FORWARD ---> cali-pi-eth0 (Policy Check) ---> DROP/ACCEPT

eBPF Engine (Modern CNI):
[ Packet ] ---> Network Interface (TC Hook / XDP) ---> eBPF Program (Map Lookup: cilium_policy) ---> DROP/PASS
```

### Execution Steps

1. Inspect active `NetworkPolicy` objects and their selectors:
```bash
kubectl get netpol -n net-sec-lab -o wide
```
*Expected Output:*
```text
NAME                         POD-SELECTOR        AGE   INGRESS-OWNERS   EGRESS-OWNERS
allow-backend-egress-to-db   app=backend-api     2m    <none>           <none>
allow-backend-to-db          app=db-storage      2m    <none>           <none>
allow-dns-egress             <none>              2m    <none>           <none>
allow-frontend-to-backend    app=backend-api     2m    <none>           <none>
default-deny-all             <none>              2m    <none>           <none>
```

2. Trace drop events on an iptables-based Node:
```bash
# Executed on Node running the target Pod
iptables-save | grep -E "KUBE-NWPOLICY|cali-DROP|cilium" | head -n 20
```
*Expected Output (Calico example):*
```text
:cali-pi-vethb9a1c2d - [0:0]
:cali-po-vethb9a1c2d - [0:0]
-A cali-pi-vethb9a1c2d -m comment --comment "cali:wX9_aBcDe123" -m state --state RELATED,ESTABLISHED -j ACCEPT
-A cali-pi-vethb9a1c2d -m comment --comment "cali:drop-default" -j MARK --set-xmark 0x10000/0x10000
-A cali-pi-vethb9a1c2d -m mark --mark 0x10000/0x10000 -j DROP
```

3. Trace policy drop verdicts on a Cilium-based CNI Node:
```bash
# Executed inside the Cilium agent pod on the target node
cilium monitor --type drop
```
*Expected Output:*
```text
xx drop (Policy denied) flow 0x0 to endpoint 1421, drop origin policy-ingress, bad-ip: 10.244.1.18 -> 10.244.1.17
```

4. Perform packet capture inside the network namespace of `client-frontend` to inspect dropped packets (notice TCP SYN retries without SYN-ACK response when dropped statelessly or silently by CNI):
```bash
nsenter -t ${PID} -n tcpdump -nn -i eth0 dst ${DB_IP} and port 5432
```
*Expected Output:*
```text
19:42:01.102938 IP 10.244.1.18.42312 > 10.244.1.17.5432: Flags [S], seq 312984012, win 64240, length 0
19:42:02.104112 IP 10.244.1.18.42312 > 10.244.1.17.5432: Flags [S], seq 312984012, win 64240, length 0
19:42:04.108221 IP 10.244.1.18.42312 > 10.244.1.17.5432: Flags [S], seq 312984012, win 64240, length 0
^C
3 packets captured
3 packets received by filter
0 packets dropped by kernel
```

---

### Verification Questions (Exercise 3)

1. **Question 3.1:** In the `tcpdump` output, we see multiple `Flags [S]` (SYN packets) retransmitted without receiving `[R.]` (RST) or `[S.]` (SYN-ACK). What does this pattern indicate regarding how CNI network policies enforce packet drops (Silent Drop vs Reject)?
2. **Question 3.2:** If a CNI uses eBPF (e.g., Cilium in kube-proxy replacement mode), why will standard `iptables-save` commands fail to display active `NetworkPolicy` rules?

---

## Exercise 4: Overlay Encryption & Transit Security (IPsec / WireGuard)

### Architectural Context
Container Network Interfaces can encrypt Pod-to-Pod traffic across Node boundaries using overlay encryption mechanisms like WireGuard or IPsec. This provides defense-in-depth against node network sniffing without requiring application-level modifications or service mesh proxies.

```
+------------------------+                        +------------------------+
| Node A (192.168.1.10)  |                        | Node B (192.168.1.11)  |
|                        |                        |                        |
|  [ Pod A: 10.244.1.5 ] |                        |  [ Pod B: 10.244.2.8 ] |
|           |            |                        |           ^            |
|     eth0 / veth        |                        |     eth0 / veth        |
|           v            |                        |           |            |
|   +---------------+    |                        |    +---------------+   |
|   | WireGuard/    |    |  Encrypted ESP/UDP    |    | WireGuard/    |   |
|   | IPsec Interface    +=======================>+    | IPsec Interface   |
|   +---------------+    | (Port 51820 / IPsec)   |    +---------------+   |
+------------------------+                        +------------------------+
```

### Execution Steps

1. Verify WireGuard interface status on host nodes when CNI transparent encryption is enabled:
```bash
# Executed on Node host
wg show
```
*Expected Output:*
```text
interface: cilium_wg0
  public key: 4xK9...aB8=
  private key: (hidden)
  listening port: 51820

peer: 7yL1...cD9=
  endpoint: 192.168.1.11:51820
  allowed ips: 10.244.2.0/24
  latest handshake: 12 seconds ago
  transfer: 1.42 MiB received, 2.18 MiB sent
```

2. Capture cross-node physical interface traffic using `tcpdump` to verify that inter-Pod payloads are encrypted:
```bash
# Run on the physical host interface (e.g., eth0) while generating traffic between Pods across nodes:
tcpdump -i eth0 -n "port 51820 or proto 50"
```
*Expected Output:*
```text
19:45:10.110291 IP 192.168.1.10.51820 > 192.168.1.11.51820: UDP, length 148
19:45:10.112411 IP 192.168.1.11.51820 > 192.168.1.10.51820: UDP, length 180
```

---

### Verification Questions (Exercise 4)

1. **Question 4.1:** How does CNI transparent overlay encryption (e.g., WireGuard/IPsec) differ from application-layer mTLS enforced by a Service Mesh (e.g., Istio/Linkerd) in terms of authentication granularity and OSI layer execution?
2. **Question 4.2:** Does CNI WireGuard encryption encrypt Pod-to-Pod traffic occurring between two containers running on the *same* Kubernetes Node?

---

## Clean-up Commands
```bash
kubectl delete namespace net-sec-lab
```

---

<details>
<summary><b>Click here to expand Answers & Detailed Technical Explanations</b></summary>

### Answers to Exercise 1

* **Answer 1.1:**  
  A `veth` (virtual ethernet) pair acts as a bidirectional virtual wire connecting two network namespaces. Interface index 3 (`eth0`) inside the Pod network namespace is linked directly to interface index 14 (`vethb9a1c2d`) in the host network namespace (and vice-versa).  
  *Security Boundary:* Linux network namespaces isolate the network stack (interfaces, routing tables, iptables rules, sockets). The Pod container cannot view, bind to, or manipulate host network interfaces unless `hostNetwork: true` is set in the Pod's `securityContext`.

* **Answer 1.2:**  
  **No.** Even if an attacker gains `CAP_NET_ADMIN` inside a Pod container, Linux namespace boundary constraints limit their administrative privilege strictly to the network namespace of that Pod. They cannot alter routes, modify interfaces, or sniff traffic on the host or other Pod namespaces because they do not possess `CAP_NET_ADMIN` within the host's initial network namespace (`init_net`).

---

### Answers to Exercise 2

* **Answer 2.1:**  
  In Kubernetes `NetworkPolicy` syntax:
  * `spec.podSelector` defines the **Target Pods** to which the firewall policy applies (in this case, the `backend-api` pods receiving traffic).
  * `spec.ingress.from.podSelector` defines the **Allowed Source Pods** that are permitted to initiate inbound connections to the target pods.

* **Answer 2.2:**  
  **The request will be blocked.** Because `default-deny-all` declares both `Ingress` and `Egress` policy types, `backend-api` is isolated for both incoming and outgoing traffic.  
  While `allow-backend-to-db` permits *Ingress* on `db-storage`, `backend-api` cannot *initiate* the egress TCP handshake unless an explicit `Egress` policy (`allow-backend-egress-to-db`) permits `backend-api` to send packets outbound on port 5432.

* **Answer 2.3:**  
  * **Single Array Item with both selectors (AND evaluation):**
    ```yaml
    ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            env: prod
        podSelector:
          matchLabels:
            role: worker
    ```
    Matches Pods that have `role: worker` **AND** reside inside a namespace labeled `env: prod`.
  * **Multiple Array Items (OR evaluation):**
    ```yaml
    ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            env: prod
      - podSelector:
          matchLabels:
            role: worker
    ```
    Matches **ANY** Pod in a namespace labeled `env: prod` **OR** any Pod in the *current* namespace with label `role: worker`.

---

### Answers to Exercise 3

* **Answer 3.1:**  
  The repeated `Flags [S]` (SYN) packets without any `RST` or `ACK` response indicate a **Silent Drop (FILTER / DROP)** policy action. The CNI firewall drops ingress packets silently instead of sending a TCP RST or ICMP Port Unreachable packet (`REJECT`). This causes the client TCP stack to hang and wait for timeout during connection initiation (`SYN_SENT` state).

* **Answer 3.2:**  
  eBPF-based CNIs execute network filtering code directly at kernel hooks (e.g., eBPF TC classifier or XDP) before packets reach the Linux `netfilter` subsystem. Because packets bypass the `iptables` hooks entirely, standard `iptables-save` or `iptables -L` commands will show no policy rules or counters; security state is maintained inside kernel eBPF BPF maps (`cilium_policy_*`).

---

### Answers to Exercise 4

* **Answer 4.1:**  
  * **CNI Overlay Encryption (WireGuard/IPsec):** Operates at Layer 3 (Network Layer). Encrypts host-to-host IP packets carrying Pod traffic. It authenticates Nodes (machine identity) but lacks cryptographic Pod identity or L7 (HTTP/gRPC header) awareness.
  * **Service Mesh mTLS (Istio/Linkerd):** Operates at Layer 7 (Application Layer) via sidecar/ambient proxies. Provides cryptographic **Pod-to-Pod SPIFFE identity**, mutual TLS certificate rotation, fine-grained HTTP URI/method authorization, and telemetry.

* **Answer 4.2:**  
  **No.** CNI WireGuard/IPsec encryption triggers when traffic traverses node network interfaces across the physical host boundary. Pods running on the *same* Kubernetes Node communicate internally via local virtual bridge switches or eBPF memory maps, bypassing the host-to-host WireGuard tunnel interface entirely.

</details>