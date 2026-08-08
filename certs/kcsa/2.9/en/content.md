# CNCF KCSA Study Guide: Topic 2.9 – Container Networking

## 1. Production Architectural Problem & Motivation

### The Default Kubernetes Flat Network Model
Kubernetes mandates an un-segmented, flat network architecture: every Pod must be able to communicate with every other Pod across all namespaces without network address translation (NAT). While this model simplifies service discovery and application deployment, it introduces a severe security vulnerability in multi-tenant or enterprise production environments: **zero inherent East-West boundary enforcement**.

By default, an attacker compromising a low-privilege application (e.g., a vulnerable public-facing web service) immediately inherits unhindered network reachability to:
* High-value internal microservices (e.g., payment gateways, auth services).
* The cluster control plane infrastructure (`kube-apiserver` running on port 6443).
* Unauthenticated database clusters, Redis caches, and internal ETCD endpoints.
* Cloud provider link-local metadata endpoints (`169.254.169.254`), exposing IAM instance credentials.

```
+-----------------------------------------------------------------------------------+
|                            DEFAULT FLAT NETWORK MODEL                             |
|                                                                                   |
|  [ Compromised Pod ]  ======( Unrestricted Lateral Access )======> [ Payment DB ]  |
|   (Namespace: public)                                             (Namespace: db) |
|            ||                                                            ^        |
|            ||=======( SSRF Attack )=======> [ 169.254.169.254 ] ---------+        |
|                                             (Cloud Metadata)                      |
+-----------------------------------------------------------------------------------+
```

### Container Network Interface (CNI) Architecture & Low-Level Mechanics
The Container Network Interface (CNI) standardizes how network interfaces are configured for Linux containers. When the Kubelet instructs the container runtime (e.g., `containerd`) to create a Pod sandbox, the runtime delegates network provisioning to the configured CNI plugin via stdio JSON payloads.

#### The CNI Lifecycle:
1. **Network Namespace Creation**: The runtime initializes an isolated network namespace (`netns`) for the Pod sandbox.
2. **CNI Invocation (`ADD`)**: The runtime executes the CNI binary with environment variables (`CNI_COMMAND=ADD`, `CNI_CONTAINERID=...`, `CNI_NETNS=/proc/<pid>/ns/net`) and passes JSON configuration via `stdin`.
3. **Virtual Ethernet (`veth`) Pair Creation**:
   * The CNI plugin creates a `veth` pair (`vethX` in root `netns` and `eth0` inside container `netns`).
   * It assigns an IP address from the Node's allocated Pod CIDR subnet (managed by Host-Local IPAM or CNI IPAM plugins like Calico/Cilium IPAM).
   * It configures default routes inside the container `netns` pointing to the node bridge (`cbr0`), gateway interface, or eBPF tail-call hook.
4. **Network Policy Engine Attachment**: The CNI network policy agent (e.g., `calico-node`, `cilium-agent`) detects the new Pod event via the Kubernetes API server and dynamically injects filtering rules into the host datapath (`iptables`, `IPVS`, or `eBPF` maps).

```
+-----------------------------------------------------------------------------------+
|                            POD & HOST NETNS CONNECTIONS                           |
|                                                                                   |
|   [ Pod Network Namespace ]                       [ Host Network Namespace ]      |
|  +-------------------------+                     +---------------------------+    |
|  | Interface: eth0         |                     | Interface: veth4a21b3     |    |
|  | IP: 10.244.1.15/24      | <=== veth pair ===>| IP: unassigned (Promisc)  |    |
|  | Route: default via gw   |                     | Connected to Bridge/eBPF  |    |
|  +-------------------------+                     +---------------------------+    |
+-----------------------------------------------------------------------------------+
```

---

## 2. Technical Comparison & Trade-off Tables

### Datapath Architectural Comparison: iptables vs. IPVS vs. eBPF

| Feature Dimension | `iptables` Datapath | `IPVS` Datapath | `eBPF` Datapath (Cilium / Calico eBPF) |
| :--- | :--- | :--- | :--- |
| **Algorithmic Complexity** | $O(N)$ sequential rule evaluation per packet. | $O(1)$ hash table lookups for Service load balancing. | $O(1)$ BPF map lookups for routing, load balancing, and policy. |
| **Scaling Limit** | Degrades significantly past ~5,000 Services (~20,000 rules). High CPU during updates. | Handles 50,000+ Services cleanly. Uses `iptables` for NetworkPolicy. | Scales to 100,000+ Services and Pods with negligible latency overhead. |
| **Network Policy Mechanics** | Injects chain calls into `filter` table (`FORWARD`, `INPUT`, `OUTPUT`). | Injects rules into `iptables` chains; IPVS handles IP-VS mode only. | Attaches BPF programs to `tc` (Traffic Control) ingress/egress & `XDP`. |
| **Kernel Context Bypass** | No. Full Linux network stack processing per packet. | No. Full Linux network stack processing per packet. | Yes. Bypasses `veth` traversal via socket layer enforcement (`sockmap`). |
| **Observability Impact** | Low. Requires `iptables` trace logs (`NFLOG` / `LOG` targets). | Low. Requires `ipvsadm` and connection tracking state inspection. | High. Real-time packet event tracing via `perf_event` buffer and Cilium Hubble. |
| **L7 Policy Enforcement** | Impossible natively. Requires sidecar proxy (Envoy/Istio). | Impossible natively. Requires sidecar proxy. | Native L7 HTTP/gRPC/DNS parsing via embedded Envoy / BPF hooks. |

---

### Enterprise CNI Security Capabilities Matrix

| Security Capability | Flannel | Calico (Standard) | Cilium | Antrea |
| :--- | :--- | :--- | :--- | :--- |
| **Standard NetworkPolicy Support** | None (Requires external engine) | Full (`networking.k8s.io/v1`) | Full (`networking.k8s.io/v1`) | Full (`networking.k8s.io/v1`) |
| **Custom Security CRDs** | None | `GlobalNetworkPolicy` | `CiliumNetworkPolicy`, `CiliumClusterwideNetworkPolicy` | `ClusterNetworkPolicy` |
| **Layer 7 Policy Enforcement** | No | No (Requires Service Mesh integration) | Yes (Native HTTP, DNS FQDN, gRPC, Kafka) | Limited (HTTP via Envoy integration) |
| **In-Transit Node-to-Node Encryption**| None | IPsec / WireGuard | WireGuard / IPsec | IPsec / WireGuard |
| **Host Endpoint Protection** | No | Yes (`HostEndpoint`) | Yes (`CiliumNodeConfig` / Host Firewall) | Yes |
| **eBPF Native Acceleration** | No | Yes (eBPF mode optional) | Yes (Primary architecture) | Yes (via Open vSwitch eBPF) |

---

### Node-to-Node Pod Traffic Encryption Protocols

| Parameter | WireGuard | IPsec (ESP) | mTLS (Sidecar / Ambient Service Mesh) |
| :--- | :--- | :--- | :--- |
| **OSI Layer** | Layer 3 (Network Layer) | Layer 3 (Network Layer) | Layer 7 (Application Layer) |
| **Cryptographic Primitives** | ChaCha20-Poly1305, Curve25519, BLAKE2s | AES-GCM-256, SHA-2, IKEv2 | RSA 2048/4048, ECDSA P-256, TLS 1.3 |
| **Performance Overhead** | Very Low (~1-3% CPU penalty, high throughput) | Low to Medium (Hardware AES-NI offload supported) | High (Context switches between user-space proxy & socket) |
| **Identity Mechanism** | Static/Rotated Public Keys mapped to Node IPs | Security Associations (SA) / Security Policies (SPD) | X.509 SVID Certificates issued by SPIRE/Istio CA |
| **L7 Identity Inspection** | No (Encrypts raw IP packets transparently) | No (Encrypts raw IP packets transparently) | Yes (Validates SAN, SPIFFE ID, HTTP headers) |

---

## 3. Production-Grade Complete Manifests

### 3.1 Strict Zero-Trust Production `NetworkPolicy` (Standard Kubernetes API)

This policy secures a microservice (`app: payment-api`) in namespace `production`. It restricts ingress strictly to approved frontend pods running in `production`, limits egress exclusively to the internal PostgreSQL database in namespace `database` on port `5432`, permits DNS resolution to `kube-dns`, and explicitly blocks access to cloud metadata services (`169.254.169.254`).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payment-api-zero-trust-policy
  namespace: production
  labels:
    tier: payment
    security.aspect: network-segmentation
spec:
  podSelector:
    matchLabels:
      app: payment-api
  policyTypes:
  - Ingress
  - Egress

  # ---------------------------------------------------------------------------
  # INGRESS RULES: Default Deny active. Allow only explicit sources.
  # ---------------------------------------------------------------------------
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: production
      podSelector:
        matchLabels:
          app: payment-frontend
    ports:
    - protocol: TCP
      port: 8443

  # ---------------------------------------------------------------------------
  # EGRESS RULES: Restrict outbound destinations and block metadata services.
  # ---------------------------------------------------------------------------
  egress:
  # Rule 1: Allow DNS resolution to CoreDNS in kube-system
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

  # Rule 2: Allow access to PostgreSQL DB in 'database' namespace
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: database
      podSelector:
        matchLabels:
          role: postgres-primary
    ports:
    - protocol: TCP
      port: 5432

  # Rule 3: Allow external HTTPS outbound EXCEPT Cloud Metadata (169.254.169.254/32)
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
```

---

### 3.2 Advanced Layer 7 FQDN & DNS Inspection Policy (`CiliumNetworkPolicy`)

This policy leverages eBPF layer-7 capabilities to restrict egress traffic to explicit domain names (`api.stripe.com` and `*.vault.internal`) dynamically resolved via intercepted DNS responses.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payment-api-l7-fqdn-policy
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: payment-api

  egress:
  # Step 1: Intercept DNS queries to discover dynamic IPs for FQDNs
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: ANY
      rules:
        dns:
        - matchPattern: "*"

  # Step 2: Restrict L7 Egress to designated third-party APIs and internal Vault
  - toFQDNs:
    - matchName: "api.stripe.com"
    - matchPattern: "*.vault.service.consul"
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/v1/charges"
        - method: "GET"
          path: "/v1/vault/v1/secret/.*"
```

---

### 3.3 Cluster-Wide Global Network Default Deny (`Calico GlobalNetworkPolicy`)

This cluster-wide policy activates a zero-trust posture across all non-system namespaces, guaranteeing that newly created namespaces default to denying all incoming and outgoing traffic until a localized `NetworkPolicy` explicitly permits it.

```yaml
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: global-default-deny-all
spec:
  selector: >-
    kubernetes.io/metadata.name != 'kube-system' &&
    kubernetes.io/metadata.name != 'calico-system' &&
    kubernetes.io/metadata.name != 'kube-node-lease'
  types:
  - Ingress
  - Egress
  # Ingress and Egress list left empty: Implicitly drops all non-system traffic
```

---

## 4. Real CLI Commands & Exact Terminal Outputs

### 4.1 Inspecting Pod Network Namespaces & Virtual Interfaces on a Node

Locate a container's PID, enter its network namespace, and identify its corresponding host-side `veth` interface using `ethtool`.

```bash
$ crictl ps --name payment-api-7b89569b9b-x9z4l
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPTS            CONTAINER ID
d4f1e8a9c12b3       c8f2b1a3d9e01       10 minutes ago      Running             payment-api         0                   d4f1e8a9c12b3

$ crictl inspect --output json d4f1e8a9c12b3 | jq '.info.pid'
142859

$ sudo nsenter -t 142859 -n ip addr show eth0
3: eth0@if42: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default 
    link/ether 8a:3f:9d:11:02:b4 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.244.1.15/24 brd 10.244.1.255 scope global eth0
       valid_lft forever preferred_lft forever

$ sudo nsenter -t 142859 -n ethtool -S eth0 | grep peer_ifindex
     peer_ifindex: 42

$ ip link show dev | grep '^42:'
42: veth4a21b3@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master cbr0 state UP group default
```

---

### 4.2 Verifying Applied Network Policies with `kubectl`

Query applied network policies within a namespace and describe policy enforcement rules.

```bash
$ kubectl get networkpolicy -n production -o wide
NAME                            POD-SELECTOR      AGE   POLICY-TYPES   GEN
payment-api-zero-trust-policy   app=payment-api   4h    Ingress,Egress 1

$ kubectl describe networkpolicy payment-api-zero-trust-policy -n production
Name:         payment-api-zero-trust-policy
Namespace:    production
Created on:   2026-08-07 15:30:12 -0400 EDT
Labels:       security.aspect=network-segmentation
              tier=payment
Annotations:  <none>
Spec:
  PodSelector:     app=payment-api
  Allowing ingress traffic:
    To Port: 8443/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=production
      PodSelector: app=payment-frontend
  Allowing egress traffic:
    To Port: 53/UDP, 53/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=kube-system
      PodSelector: k8s-app=kube-dns
    --------------
    To Port: 5432/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=database
      PodSelector: role=postgres-primary
    --------------
    To Port: 443/TCP
    To IPBlock:
      CIDR: 0.0.0.0/0
      Except: 169.254.169.254/32, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
Policy Types: Ingress, Egress
```

---

### 4.3 Low-Level eBPF & Packet Drop Inspection via Cilium CLI & `bpftool`

Monitor real-time eBPF packet drop events generated by policy violations using `cilium monitor`.

```bash
$ kubectl exec -n kube-system cilium-5z8kl -- cilium monitor --type drop
Listening for events on 2 LBDs, 4 CPUS...
Press Ctrl-C to quit
xx drop 65535 at status egress policy dropped: (cilium-agent) egress 10.244.1.15:43982 -> 169.254.169.254:80 tcp SYN identity 49102->2 (reserved:host)
xx drop 65535 at status ingress policy dropped: (cilium-agent) ingress 10.244.2.88:51204 -> 10.244.1.15:8443 tcp SYN identity 10443->49102 (app=payment-api)

$ kubectl exec -n kube-system cilium-5z8kl -- bpftool map dump name cilium_policy_v2
key: 00 00 00 00 00 00 00 00  value: 01 00 00 00 00 00 00 00
key: 00 00 00 00 00 00 bf f6  value: 00 00 00 00 00 00 00 00
Found 2 elements
```

---

### 4.4 Debugging Legacy `iptables` Network Policy Rules

Inspect system `iptables` rules generated by plugins like Calico or kube-router in the host network namespace.

```bash
$ sudo iptables-save -t filter | grep -E "cali-pi-|cali-po-|FORWARD"
:FORWARD DROP [0:0]
-A FORWARD -m comment --comment "cali:w36w8W8a9v4pG" -j cali-FORWARD
-A cali-FORWARD -m comment --comment "cali:H3aD92fK1l" -m physdev --physdev-is-bridged -j ACCEPT
-A cali-FORWARD -m comment --comment "cali:v8S1s4v7X1" -j cali-from-hep-forward
-A cali-pi-_Z9a8f7e6d5 -m comment --comment "cali:Rule:Match" -m set --match-set cali40-production-frontend src -p tcp -m tcp --dport 8443 -j ACCEPT
-A cali-pi-_Z9a8f7e6d5 -m comment --comment "cali:Implicit Drop" -j DROP
```

---

## 5. Troubleshooting & Diagnostic Guide

```
+-----------------------------------------------------------------------------------+
|                        NETWORK TROUBLESHOOTING FLOWCHART                          |
|                                                                                   |
|                   [ Pod Traffic Dropped / Interrupted ]                           |
|                                     |                                             |
|                                     v                                             |
|                  /-------------------------------------\                          |
|                 / Is CNI Pod running on target node?    \                         |
|                 \  (e.g., cilium-agent, calico-node)    /                         |
|                  \-------------------------------------/                          |
|                               /             \                                     |
|                              /               \                                    |
|                            NO                 YES                                 |
|                            /                   \                                  |
|                           v                     v                                 |
|            [ Restart CNI DaemonSet ]    /-------------------------\               |
|            [ Check CNI Agent Logs  ]   / Is MTU matched across    \               |
|                                        \ CNI overlay and phys dev?/               |
|                                         \-------------------------/               |
|                                                     /         \                   |
|                                                    /           \                  |
|                                                  NO             YES               |
|                                                  /               \                |
|                                                 v                 v               |
|                                        [ Fix MTU Mismatch ]  /----------------\   |
|                                                              / Check NetPol   \   |
|                                                              \ Ingress/Egress /   |
|                                                               \---------------/   |
+-----------------------------------------------------------------------------------+
```

### Scenario 1: Intermittent Connection Resets & Packet Loss (MTU Mismatch)

#### Root Cause:
Overlay network encapsulation (e.g., VXLAN adding 50 bytes of overhead, Geneve adding 50 bytes, or IPsec adding up to 73 bytes) causes the effective MTU of the virtual container interface (`eth0`) to exceed the MTU of the underlying physical network interface (`eth0` on node). Packets larger than Path MTU with `DF` (Don't Fragment) flag set are silently dropped.

#### Diagnostic Workflow:
1. Check physical interface MTU on host:
   ```bash
   $ ip link show eth0 | grep mtu
   2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
   ```
2. Check CNI interface MTU inside pod:
   ```bash
   $ kubectl exec -it payment-api-7b89569b9b-x9z4l -n production -- ip link show eth0
   3: eth0@if42: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP
   ```
   *Analysis*: Physical MTU is 1500, but container MTU is also set to 1500. With VXLAN encapsulation (50 bytes), the container MTU must be $\le 1450$.

3. Perform ping with DF flag set to pinpoint breaking payload size:
   ```bash
   $ kubectl exec -it payment-api-7b89569b9b-x9z4l -n production -- ping -M do -s 1422 10.244.2.88
   PING 10.244.2.88 (10.244.2.88) 1422(1450) bytes of data.
   1430 bytes from 10.244.2.88: icmp_seq=1 ttl=63 time=0.412 ms

   $ kubectl exec -it payment-api-7b89569b9b-x9z4l -n production -- ping -M do -s 1423 10.244.2.88
   PING 10.244.2.88 (10.244.2.88) 1423(1451) bytes of data.
   ping: local error: Message too long, mtu=1450
   ```

#### Resolution:
Update the CNI ConfigMap (e.g., `cilium-config` or `calico-config`) to set `veth-mtu: "1450"` (or `mtu: 1450`), then execute a rolling restart of the CNI DaemonSet.

---

### Scenario 2: Traffic Blocked Due to NetworkPolicy Evaluation Order Misunderstanding

#### Root Cause:
Engineers assume NetworkPolicies act like sequential firewalls with explicit `ALLOW` / `DENY` ordering. In Kubernetes:
* If **no** `NetworkPolicy` selects a Pod, it is in **Non-Isolated Mode** (all ingress and egress allowed).
* As soon as **a single** `NetworkPolicy` selects a Pod, the Pod enters **Isolated Mode** for the specified `policyTypes` (`Ingress`, `Egress`, or both).
* NetworkPolicies are **additive (OR logic)**. There is no concept of a explicit `DENY` rule in the standard Kubernetes `networking.k8s.io/v1` API.

#### Diagnostic Step-by-Step Execution:
1. Verify if the target Pod is isolated by any existing policy:
   ```bash
   $ kubectl get netpol -n production -o json | jq '.items[] | select(.spec.podSelector.matchLabels.app=="payment-api") | .metadata.name'
   "payment-api-zero-trust-policy"
   ```

2. Check whether namespace selectors miss the required auto-created metadata label:
   ```bash
   # INCORRECT: Expecting 'name: production' when label is not set on namespace
   $ kubectl get ns production --show-labels
   NAME         STATUS   AGE   LABELS
   production   Active   10d   environment=prod

   # CORRECT: Match standard immutable metadata label
   # kubernetes.io/metadata.name: production
   ```

3. Trace active drops using `tcpdump` on the target Pod's `veth` interface on the host node:
   ```bash
   $ sudo tcpdump -nn -i veth4a21b3 tcp port 8443
   19:42:10.104921 IP 10.244.2.88.51204 > 10.244.1.15.8443: Flags [S], seq 382910482, win 64240, length 0
   19:42:11.108210 IP 10.244.2.88.51204 > 10.244.1.15.8443: Flags [S], seq 382910482, win 64240, length 0
   # Result: SYN packets arrive at veth interface but no SYN-ACK is returned (silent drop by host datapath filter)
   ```

---

### Scenario 3: CNI Pod IP Leakage & Stale Network Namespace Handles

#### Root Cause:
Rapid Pod churn (e.g., high-frequency CronJobs or auto-scaling events) can cause un-cleaned network namespaces in `/var/run/netns/` or orphan `veth` interfaces, exhausting the CNI IPAM pool or host ARP table capacity (`net.ipv4.neigh.default.gc_thresh3`).

#### Diagnostic & Remediation Commands:
1. Check for orphaned network namespaces:
   ```bash
   $ sudo ip netns list-id
   nsid 0 (ipns-d4f1e8a9c12b)
   nsid 1 (ipns-9a8b7c6d5e4f)

   $ ls -l /var/run/netns/
   total 0
   -r--r--r-- 1 root root 0 Aug  7 14:00 cni-8d9e0f1a-2b3c-4d5e-6f7a-8b9c0d1e2f3a
   -r--r--r-- 1 root root 0 Aug  7 14:05 cni-1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d
   ```

2. Check kernel ARP/Neighbor table usage:
   ```bash
   $ sysctl net.ipv4.neigh.default.gc_thresh1 net.ipv4.neigh.default.gc_thresh2 net.ipv4.neigh.default.gc_thresh3
   net.ipv4.neigh.default.gc_thresh1 = 128
   net.ipv4.neigh.default.gc_thresh2 = 512
   net.ipv4.neigh.default.gc_thresh3 = 1024

   $ ip neigh show | wc -l
   1021
   ```
   *Analysis*: ARP table is approaching `gc_thresh3` (1024 entries), causing kernel packet drops (`neighbor table overflow`).

3. Permanently resolve by tuning `/etc/sysctl.d/99-k8s-cni.conf`:
   ```sysctl
   net.ipv4.neigh.default.gc_thresh1 = 1024
   net.ipv4.neigh.default.gc_thresh2 = 4096
   net.ipv4.neigh.default.gc_thresh3 = 8192
   ```
   Apply immediately without rebooting:
   ```bash
   $ sudo sysctl --system
   ```

---

## 6. References

* **CNCF Curriculum Repository**: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **Kubernetes Official Documentation – Network Policies**: https://kubernetes.io/docs/concepts/services-networking/network-policies/
* **Kubernetes Official Documentation – Cluster Networking**: https://kubernetes.io/docs/concepts/cluster-administration/networking/
* **CNI Specification (Containernetworking)**: https://github.com/containernetworking/cni/blob/main/SPEC.md
* **Cilium Security Policy Documentation**: https://docs.cilium.io/en/stable/security/policy/
* **Project Calico Network Policy Reference**: https://docs.tigera.io/calico/latest/reference/resources/networkpolicy