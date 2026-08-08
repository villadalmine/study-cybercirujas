# KCSA Study Guide: Domain 4.5 – Attacker on the Network

**Exam Domain:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain Topic:** 4.5 Attacker on the Network  
**Domain Weight:** 2.29%  
**Target Audience:** Principal Platform Architects & Senior SRE Engineers  

---

## 1. Motivation and Production Architectural Problem

### 1.1 Threat Model of Flat Container Networks
The default design principle of Kubernetes networking (as specified by the Container Network Interface / CNI specification) requires that any Pod can communicate with any other Pod across all nodes without Network Address Translation (NAT), unless explicitly restricted. In an unhardened cluster, the network operates as a flat, unsegmented Layer 3/Layer 4 IP network.

```
       +-----------------------------------------------------------------------------------+
       |                               KUBERNETES CLUSTER                                  |
       |                                                                                   |
       |  [ Compromised Pod ]                                  [ Sensitive Pod ]           |
       |  (Attacker Footprint)                                 (Database / Payment Gateway)|
       |         |                                                       ^                 |
       |         | 1. Internal Reconnaissance (Nmap / DNS Enum)          |                 |
       |         +-------------------------------------------------------+                 |
       |         | 2. Plaintext Packet Sniffing (veth / VXLAN / Geneve)   |                 |
       |         | 3. East-West Lateral Movement                         |                 |
       |         v                                                       |                 |
       |  [ CoreDNS Pod ]                                                |                 |
       |         | 4. DNS Cache Poisoning / Spoofing                     |                 |
       |         v                                                       |                 |
       |  [ Cloud IMDS Endpoint ] (169.254.169.254)                       |                 |
       |         | 5. IAM Credential Exfiltration                        |                 |
       |         +-------------------------------------------------------+                 |
       +-----------------------------------------------------------------------------------+
```

When an attacker gains arbitrary code execution inside a single container (e.g., via a remote code execution vulnerability, compromised dependency, or supply-chain attack), the flat network topology presents multiple attack vectors:

1. **Internal Reconnaissance & Service Discovery:**
   - **DNS Enumeration:** By querying CoreDNS (`/etc/resolv.conf`), an attacker can brute-force or enumerate service names (`*.namespace.svc.cluster.local`) to map out sensitive internal architectures.
   - **Subnet Port Scanning:** An attacker can execute synthetic TCP/UDP SYN scans across the Pod CIDR range (e.g., `10.244.0.0/16`) to locate non-authenticated internal ports (e.g., Redis on 6379, Memcached on 11211, unauthenticated JMX/metrics endpoints).

2. **Unencrypted East-West Traffic Interception:**
   - Traffic between Pods running on different nodes is typically encapsulated in overlay protocols (VXLAN UDP 4789, Geneve UDP 6081) or routed natively without encryption.
   - If an attacker gains host-level access to a node or executes a packet capture inside a shared network namespace, they can capture sensitive payloads (JWTs, basic auth headers, API keys, database queries) sent over unencrypted HTTP, gRPC, or database wire protocols.

3. **Cloud Instance Metadata Service (IMDS) Exfiltration:**
   - Pods inherit network access to the underlying host's virtual IP interfaces, including the link-local Cloud Metadata IP (`169.254.169.254`).
   - An attacker reaching `http://169.254.169.254/latest/meta-data/iam/security-credentials/` on AWS (or equivalent endpoints on GCP/Azure) can extract the IAM role credentials of the worker node, leading to full cloud-account privilege escalation.

4. **DNS Spoofing & Traffic Redirection:**
   - In shared or unsegmented L2 network domains (or via UDP port 53 manipulation), attackers can perform DNS spoofing or ARP cache poisoning to intercept traffic intended for legitimate cluster services and redirect it to a rogue pod under their control.

5. **Unrestricted Egress & Command-and-Control (C2):**
   - Outbound connections from Pods to the public internet are allowed by default. Attackers leverage this to establish reverse shells, exfiltrate stolen data over HTTPS/DNS tunneling, or download secondary attack payloads.

---

## 2. Technical Comparisons & Trade-Off Analysis

### Table 2.1: Network Isolation Architectures (L3/L4 NetworkPolicies vs. L7 Policies vs. CNI eBPF)

| Feature / Metric | Native Kubernetes NetworkPolicy (L3/L4) | eBPF-Based Network Policies (Cilium/Calico eBPF) | Service Mesh Security (Istio/Linkerd) |
| :--- | :--- | :--- | :--- |
| **Enforcement Layer** | OSI Layer 3 (IP) & Layer 4 (TCP/UDP ports) | OSI Layer 3, Layer 4, and selective Layer 7 | OSI Layer 7 (HTTP, gRPC, TLS SNI, Method, Path) |
| **Data Path Mechanism** | Linux `iptables` / IPVS rules appended per chain | Kernel eBPF bytecode programs attached to `tc` (Traffic Control) & socket hooks | User-space proxy sidecars (Envoy) or ambient node proxies |
| **Performance Overhead** | High latency scaled to $O(N)$ with large rule sets due to sequential `iptables` evaluation | Extremely low; $O(1)$ hash table lookups directly inside kernel memory | Moderate to high CPU/memory consumption; introduces sub-millisecond latency per hop |
| **Identity Mechanism** | Namespace and Pod Selector Labels (`k8s:app=frontend`) | Cryptographic Identity (Security Identities mapped to eBPF maps) | Cryptographic identity via SPIFFE/SPIRE X.509 SVID certificates |
| **DNS-Aware Filtering** | No (requires explicit CIDR blocks) | Yes (enforces egress by exact FQDN / regex patterns) | Yes (via ServiceEntry & Egress Gateways) |
| **Cryptographic Security** | None (traffic remains plaintext on the wire) | Supports transparent Node-to-Node / Pod-to-Pod IPsec/WireGuard | Enforces Mutual TLS (mTLS) with identity validation and automatic cert rotation |

### Table 2.2: Intra-Cluster Traffic Encryption (WireGuard vs. IPsec vs. Service Mesh mTLS)

| Property | CNI Transparent WireGuard | CNI Transparent IPsec | Service Mesh mTLS (SPIFFE/SPIRE) |
| :--- | :--- | :--- | :--- |
| **Encryption Scope** | Node-to-Node and Pod-to-Pod network payloads | Node-to-Node and Pod-to-Pod packets (ESP encapsulation) | Application-to-Application payload stream (TLS 1.3) |
| **Kernel vs. User-space** | Linux Kernel Module (`wireguard.ko`) | Linux Kernel XFRM framework & `crypto` subsystem | User-space Envoy sidecar proxy processing |
| **Key Exchange & Management**| Static public keys exchanged automatically via CNI control plane | IKEv2 daemon (StrongSwan/Charon) or manual XFRM key programming | Dynamic short-lived X.509 SVIDs issued by internal CA |
| **Throughput / Latency** | Near line-rate; ChaCha20-Poly1305 hardware acceleration | High CPU overhead unless AES-NI hardware offloading is active | Extra user-space context switches; higher memory consumption |
| **L7 Inspection Compatibility** | Encrypts L3 packets transparently; compatible with eBPF L7 | Encrypts L3 packets transparently | Native L7 routing, authorization policies, and distributed tracing |

---

## 3. Production-Grade YAML & Infrastructure Manifests

### 3.1 Strict Zero-Trust Network Isolation Baseline
This manifest implements a complete default-deny strategy for both Ingress and Egress across a namespace, followed by an explicit policy allowing Pods to communicate **only** with CoreDNS on port 53 (UDP/TCP).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production-workloads
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-coredns-egress
  namespace: production-workloads
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

### 3.2 Advanced L7 and FQDN Egress Control with CiliumNetworkPolicy
This policy enforces strict Layer 7 egress rules:
1. Blocks all access to the AWS Cloud Metadata IP (`169.254.169.254/32`).
2. Restricts egress to external payment endpoints using exact FQDN matching (`api.stripe.com`) over HTTPS (port 443).
3. Enforces L7 HTTP method restriction on internal microservice communications.

```yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: secure-payment-service-policy
  namespace: production-workloads
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: payment-service
  ingress:
  - fromEndpoints:
    - matchLabels:
        app.kubernetes.io/name: checkout-frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/v1/charge"
  egress:
  # Explicitly deny Cloud Metadata Endpoint (IMDSv1/v2)
  - toCIDRSet:
    - cidr: "169.254.169.254/32"
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http: {}
    # Cilium treats unlisted egress as implicitly denied when egress rules exist
  # FQDN Based Egress Allowlist for External APIs
  - toFQDNs:
    - matchName: "api.stripe.com"
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
  # Allow internal CoreDNS resolution required for FQDN resolution
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
      rules:
        dns:
        - matchPattern: "*"
```

### 3.3 Helm Values for Transparent Pod-to-Pod WireGuard Encryption in Cilium
Deploying Cilium with native transparent encryption encrypts all East-West traffic in-kernel via WireGuard without requiring application modifications or sidecar proxies.

```yaml
# cilium-helm-values.yaml
cilium:
  routingMode: "native"
  ipv4NativeRoutingCIDR: "10.244.0.0/16"
  autoDirectNodeRoutes: true
  
  # Enable eBPF Host Routing to bypass iptables overhead
  bpf:
    masquerade: true
    preallocateMaps: true
    
  # Cryptographic Encryption Configuration
  encryption:
    enabled: true
    type: wireguard
    wireguard:
      persistentKeepalive: 0
      userspaceFallback: false
    # Encrypt traffic between nodes as well as between pods
    nodeToNode: true

  # Enable L7 policy enforcement engine
  l7Proxy: true
```

### 3.4 Istio Mutual TLS (mTLS) and Strict L7 Authorization Policy
This configuration completely disallows unencrypted HTTP communication within the namespace and enforces cryptographically verified SPIFFE identities.

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-strict-mtls
  namespace: production-workloads
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: database-access-control
  namespace: production-workloads
spec:
  selector:
    matchLabels:
      app: postgresql-primary
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/production-workloads/sa/payment-service-sa"]
    to:
    - operation:
        ports: ["5432"]
        methods: ["TCP"]
```

---

## 4. Real CLI Commands and Terminal Outputs

### 4.1 Simulating an Attacker's Network Reconnaissance
An attacker attempts to enumerate services, sniff traffic, and reach the AWS metadata service from inside an compromised Pod.

```bash
$ kubectl exec -it compromised-pod-6d87487-x9z21 -n production-workloads -- sh

# 1. Attempting to reach Cloud Metadata Service (IMDSv1)
$ curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/
curl: (28) Connection timed out after 2001 milliseconds

# 2. Executing internal network scan on neighbor pods in the same CIDR block
$ nmap -p 80,443,5432,6379 10.244.1.0/24 -n --open
Starting Nmap 7.93 ( https://nmap.org ) at 2026-08-07 20:15 UTC
Nmap scan report for 10.244.1.15
Host is up (0.00045s latency).
PORT     STATE SERVICE
5432/tcp OPEN  postgresql
Nmap done: 256 IP addresses (12 hosts up) scanned in 2.14 seconds

# 3. Attempting to sniff wire traffic using raw socket capabilities
$ tcpdump -i eth0 -n -c 5
tcpdump: eth0: You don't have permission to capture on that device
(socket: Operation not permitted)
```

### 4.2 Verifying Active NetworkPolicy Drops via Cilium CLI
Platform operators can inspect realtime eBPF drop events to audit denied lateral movement attempts.

```bash
$ cilium monitor --type drop
Signal arrive from parent process, parsing events...
xx drop 65535 at status inform: 10.244.1.84:43212 -> 169.254.169.254:80, egress policy dropped packet (CiliumNetworkPolicy)
xx drop 65535 at status inform: 10.244.1.84:51234 -> 10.244.1.15:6379, egress policy dropped packet (NetworkPolicy)
```

### 4.3 Inspecting eBPF Security Maps on a Kubernetes Node
Deep inspection of the kernel eBPF map tables enforcing network policy isolation on the worker node.

```bash
$ kubectl exec -n kube-system cilium-qn8v2 -c cilium-agent -- cilium bpf policy get 1421
POLICY ENFORCEMENT DIRECTION  IDENTITY   PORT/PROTO   ACTION     PACKETS   BYTES     
Ingress                       24102      8080/TCP     ALLOW      41295     2890640   
Ingress                       0          ANY          DENY       142       8520      
Egress                        3          53/UDP       ALLOW      892       64224     
Egress                        0          ANY          DENY       512       30720     
```

### 4.4 Validating Transparent WireGuard Encrypted East-West Traffic
To verify that East-West container traffic across nodes is fully encrypted on the physical interface (`eth0`), inspect the wire format using `tcpdump`.

```bash
$ sudo tcpdump -i eth0 -n "src host 192.168.1.50 and dst host 192.168.1.51"
20:18:02.104921 IP 192.168.1.50.51820 > 192.168.1.51.51820: UDP, length 1420
20:18:02.105231 IP 192.168.1.51.51820 > 192.168.1.50.51820: UDP, length 88
```
*Notice that container IPs (`10.244.x.x`) and application payloads (HTTP/SQL) are completely absent from the wire capture, replaced entirely by WireGuard UDP packets on port 51820.*

---

## 5. Troubleshooting, Fault Diagnosis, and Verification Guide

### 5.1 Troubleshooting Matrix for Network Security Breakages

```
                                  [ Issue Reported ]
                                          |
                        +-----------------+-----------------+
                        |                                   |
              [ Connection Dropped ]             [ Traffic Unencrypted ]
                        |                                   |
           +------------+------------+                      v
           |                         |            Inspect CNI Encryption State:
  [ Ingress Drop ]          [ Egress Drop ]       $ cilium encrypt status
           |                         |            - Verify WireGuard/IPsec SA keys
           v                         v            - Check node firewall (UDP 51820/ESP)
 Check Policy Selectors   Check DNS & IMDS Rules
 - `podSelector` labels   - Verify Port 53 UDP
 - eBPF map entry         - FQDN resolution table
 - iptables TRACE         - Cloud Metadata deny
```

| Symptom | Root Cause | Diagnostic Method | Remediation |
| :--- | :--- | :--- | :--- |
| Pod fails to resolve internal cluster services (DNS lookup timeout). | Egress NetworkPolicy applied without allowing UDP/TCP port 53 to CoreDNS. | Run `dig +time=2 auth-service.prod.svc.cluster.local` from pod; check policy egress rules. | Add an explicit Egress rule targetting `kube-dns` in namespace `kube-system` on port 53. |
| FQDN Egress Policy permits initial connection, then randomly drops packets. | DNS TTL mismatch between client application cache and CNI FQDN proxy lookup table. | Execute `cilium fqdn cache list` and compare IP addresses against `dig <domain>`. | Increase DNS proxy max-ttl setting in CNI configuration (`dnsproxy-min-ttl`). |
| Istio mTLS connection returns `503 Service Unavailable` with `UC` (Upstream Connection termination). | Client app sending plaintext to a server in `STRICT` mTLS mode without Istio sidecar injection. | Check envoy logs: `kubectl logs <pod> -c istio-proxy` looking for `TLS_error`. | Ensure namespace has label `istio-injection=enabled` or configure `PeerAuthentication` to `PERMISSIVE` temporarily. |
| Pod can still reach `169.254.169.254` despite NetworkPolicy. | CNI does not support `toCIDRSet` or pod operates in `hostNetwork: true` mode. | Test `curl http://169.254.169.254/latest/meta-data/` from pod; check `hostNetwork` field in PodSpec. | Set `hostNetwork: false` or enforce AWS IMDSv2 with `HttpTokens=required` and `HttpPutResponseHopLimit=1`. |

### 5.2 Diagnostic Walkthrough: Debugging Blocked Egress Traffic

#### Step 1: Trace `iptables` Packet Drops (for non-eBPF CNIs like Kube-Router/Flannel)
If using standard iptables-based NetworkPolicies, add a `TRACE` target to capture packet verdicts inside `kern.log`:

```bash
$ sudo iptables -t raw -A PREROUTING -p tcp --dport 5432 -j TRACE
$ dmesg -T | grep "TRACE: filter:KUBE-NWPLCY-DEFAULT-DENY"
[Fri Aug  7 20:20:12 2026] IN=veth84a0b2 OUT=eth0 SRC=10.244.1.84 DST=10.244.1.15 LEN=60 TOS=0x00 PREC=0x00 TTL=64 ID=41203 DF PROTO=TCP SPT=43212 DPT=5432 SEQ=10294821 ACK=0 WINDOW=64240 RES=0x00 SYN URGP=0
```

#### Step 2: Validate SPIFFE Certificate Validity in Service Mesh mTLS
Verify that the X.509 certificate loaded into the Envoy proxy sidecar is valid and unexpired:

```bash
$ istioctl proxy-config secret payment-service-789456-abc12.production-workloads
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER                         EXPIRES
default           CERTIFICATE    Active     true           19028301928301928301928               2026-08-08T20:00:00Z
ROOTCA            CERTIFICATE    Active     true           98127391827391827391827               2036-08-07T20:00:00Z
```

---

## 6. References

- **CNCF KCSA Official Curriculum:**  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

- **Kubernetes Official Documentation – Network Policies:**  
  [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

- **Cilium Documentation – Network Policy & L7 Security:**  
  [https://docs.cilium.io/en/stable/security/policy/](https://docs.cilium.io/en/stable/security/policy/)

- **Cilium Documentation – Transparent Wireguard/IPsec Encryption:**  
  [https://docs.cilium.io/en/stable/security/network/encryption/](https://docs.cilium.io/en/stable/security/network/encryption/)

- **Istio Documentation – PeerAuthentication & Authorization Policies:**  
  [https://istio.io/latest/docs/concepts/security/](https://istio.io/latest/docs/concepts/security/)

- **AWS Documentation – Restricting Access to IMDSv2:**  
  [https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)

- **NIST SP 800-190 – Application Container Security Guide:**  
  [https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-190.pdf](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-190.pdf)