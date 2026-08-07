# LPI Security Essentials (020-100) — Topic 4.1: Network and Service Security

**Exam Code:** 020-100  
**Version:** 1.0  
**Domain:** Network and Service Security (Topic 024 / 4.1)  
**Weight:** 20  
**Target Role:** Senior SRE / Platform Architect / Linux Security Specialist  

---

## Official Reference Sources
* **Linux Professional Institute (LPI) Security Essentials Overview:** [https://www.lpi.org/our-certifications/security-essentials-overview/](https://www.lpi.org/our-certifications/security-essentials-overview/)
* **LPI Learning Materials for Exam 020-100:** [https://learning.lpi.org/en/learning-materials/020-100/](https://learning.lpi.org/en/learning-materials/020-100/)
* **Netfilter / nftables Official Documentation:** [https://netfilter.org/projects/nftables/](https://netfilter.org/projects/nftables/)
* **IETF RFC 8446 — The Transport Layer Security (TLS) Protocol Version 1.3:** [https://datatracker.ietf.org/doc/html/rfc8446](https://datatracker.ietf.org/doc/html/rfc8446)
* **WireGuard Protocol Architecture:** [https://www.wireguard.com/papers/wireguard.pdf](https://www.wireguard.com/papers/wireguard.pdf)
* **IETF RFC 4033 — DNS Security Introduction and Requirements (DNSSEC):** [https://datatracker.ietf.org/doc/html/rfc4033](https://datatracker.ietf.org/doc/html/rfc4033)

---

## Exercise 1: Linux Kernel Networking Mechanics, Socket State Inspection, & Traffic Analysis

### Architectural Overview & Internal Mechanics
The Linux kernel network stack processes inbound packets through a deterministic sequence of subsystem layers:
1. **NIC Driver & NAPI:** Hard interrupts trigger SoftIRQs (`NET_RX_SOFTIRQ`), polling packets into `sk_buff` ring buffers.
2. **Link Layer (L2):** Decapsulates Ethernet headers, performs MAC filtering, checks ARP cache entries, and passes valid frames up.
3. **Network Layer (L3):** Evaluates IPv4/IPv6 headers. If the host is not acting as a router, `net.ipv4.ip_forward` must remain `0`. Kernel Reverse Path Filtering (`rp_filter`) verifies that inbound packets arrive on the interface matching the routing table's best return path, neutralizing IP spoofing attacks.
4. **Transport Layer (L4):** Validates TCP/UDP checksums and matches 5-tuples `(Source IP, Source Port, Destination IP, Destination Port, Protocol)` against socket descriptors registered in the kernel socket lookup table.

```
       +-------------------------------------------------------------------+
       |                       Linux Kernel Netfilter                      |
       |                                                                   |
[NIC] ---> [PREROUTING] ---> [Routing Decision] ---> [FORWARD] ---> [POSTROUTING] ---> [NIC]
              |                                            ^
              v                                            |
           [INPUT]                                     [OUTPUT]
              |                                            ^
              +-------------> [Socket Buffer] -------------+
```

### Guided Implementation Steps

1. **Audit Kernel Packet Forwarding and Reverse Path Filtering Settings**  
   Execute `sysctl` to inspect kernel security knobs governing L3 packet processing:

   ```bash
   sudo sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter net.ipv6.conf.all.forwarding
   ```

   **Expected Output:**
   ```text
   net.ipv4.ip_forward = 0
   net.ipv4.conf.all.rp_filter = 1
   net.ipv4.conf.default.rp_filter = 1
   net.ipv6.conf.all.forwarding = 0
   ```

2. **Inspect Transport-Layer Socket States and Active Listeners**  
   Use `ss` (Socket Statistics) with raw numeric output to audit listening sockets and process bindings, filtering out non-established TCP sockets:

   ```bash
   sudo ss -tulpn
   ```

   **Expected Output:**
   ```text
   Netid State   Recv-Q Send-Q    Local Address:Port      Peer Address:PortProc
   udp   UNCONN  0      0               0.0.0.0:68             0.0.0.0:*    users:(("dhclient",pid=842,fd=6))
   tcp   LISTEN  0      128             0.0.0.0:22             0.0.0.0:*    users:(("sshd",pid=1104,fd=3))
   tcp   LISTEN  0      511           127.0.0.1:6379           0.0.0.0:*    users:(("redis-server",pid=1420,fd=6))
   tcp   LISTEN  0      4096            0.0.0.0:443            0.0.0.0:*    users:(("nginx",pid=2048,fd=7))
   ```

3. **Capture and Analyze Raw Protocol Frames using `tcpdump`**  
   Perform non-promiscuous packet capture on the primary interface (`eth0`), filtering for TCP SYN packets to detect unauthorized connection attempts or port scanning:

   ```bash
   sudo tcpdump -i eth0 -nn -vvv -c 3 'tcp[tcpflags] & (tcp-syn) != 0 and tcp[tcpflags] & (tcp-ack) == 0'
   ```

   **Expected Output:**
   ```text
   tcpdump: listening on eth0, link-type EN10MB (Ethernet), capture size 262144 bytes
   00:48:12.104928 IP (tos 0x0, ttl 64, id 54321, offset 0, flags [DF], proto TCP (6), length 60)
       192.168.1.50.48290 > 192.168.1.10.443: Flags [S], cksum 0x1a2b (correct), seq 382910482, win 64240, options [mss 1460,sackOK,TS val 2849102 ecr 0,nop,wscale 7], length 0
   00:48:12.105110 IP (tos 0x0, ttl 64, id 54322, offset 0, flags [DF], proto TCP (6), length 60)
       192.168.1.50.48292 > 192.168.1.10.22: Flags [S], cksum 0x3c4d (correct), seq 109284019, win 64240, options [mss 1460,sackOK,TS val 2849102 ecr 0,nop,wscale 7], length 0
   ```

---

### Verification Questions — Exercise 1

**Question 1.1:** A security audit reports that `net.ipv4.conf.all.rp_filter` is set to `0` on a multi-homed Linux edge gateway. What specific attack vector does this expose the system to, and how does enabling strict mode (`rp_filter = 1`) mitigate it at the kernel packet lookup layer?

**Question 1.2:** In the output of `ss -tulpn`, `redis-server` is bound to `127.0.0.1:6379`, whereas `nginx` is bound to `0.0.0.0:443`. What are the security trade-offs of binding a service to `0.0.0.0` vs. a loopback or dedicated interface IP, and what risk occurs if Redis is accidentally exposed on `0.0.0.0` without authentication?

---

## Exercise 2: Stateful Packet Filtering & Boundary Defense with `nftables`

### Architectural Overview & Internal Mechanics
`nftables` is the modern Linux kernel packet classification framework replacing `iptables`. It executes inside a high-performance pseudo-virtual machine (nftables VM) within kernel space:
* **Netfilter Hooks:** Hooks intercept packets at specific execution stages (`prerouting`, `input`, `forward`, `output`, `postrouting`).
* **Connection Tracking (`conntrack`):** Tracks stateful TCP/UDP/ICMP sessions. States include `NEW` (initial SYN), `ESTABLISHED` (completed handshake), `RELATED` (auxiliary channels like FTP-data), and `INVALID` (malformed flags or out-of-window sequence numbers).
* **Rule Optimization:** Unlike `iptables` linear chain traversals, `nftables` uses internal lookup sets (`hash` and `rbtree`) allowing $O(1)$ constant time complexity for thousands of IP ranges or port definitions.

```
Incoming Packet ---> Netfilter Hook (input) ---> Stateful Evaluation (conntrack)
                                                        |
         +----------------------------------------------+----------------------------------------------+
         |                                              |                                              |
 [State: INVALID]                             [State: ESTABLISHED]                               [State: NEW]
         |                                              |                                              |
   Action: DROP                                   Action: ACCEPT                                 Set Verification
 (Drop immediate)                              (Fast-path pass)                           (Port & IP Rate-Limit check)
```

### Guided Implementation Steps

1. **Deploy Production Stateful Filtering Policy**  
   Create a production-grade, syntactically complete `/etc/nftables.conf` file that implements a default-deny ingress posture, allows established connections, protects against TCP SYN floods via metering, and isolates loopback traffic.

   Save the following manifest to `/etc/nftables.conf`:

   ```nftables
   #!/usr/sbin/nft -f

   flush ruleset

   table inet global_firewall {
       # Set for dynamic blacklisting of malicious IPs
       set dynamic_blacklist {
           type ipv4_addr
           flags timeout
       }

       chain ingress_input {
           type filter hook input priority filter; policy drop;

           # Early drop for invalid connection states
           ct state invalid drop comment "Drop invalid TCP packet states"

           # Accept all loopback traffic
           iifname "lo" accept comment "Accept loopback traffic"

           # Allow stateful return traffic for outbound requests
           ct state established,related accept comment "Accept established & related connections"

           # Drop blacklisted source IPs dynamically
           ip saddr @dynamic_blacklist drop comment "Drop explicit blacklisted sources"

           # Rate-limit ICMP echo requests (Ping Flood protection)
           ip protocol icmp icmp type echo-request limit rate 5/second burst 10 packets accept
           ip protocol icmp icmp type echo-request drop

           # Rate-limit SSH ingress (Anti-bruteforce: max 3 new connections per minute per IP)
           tcp dport 22 ct state new meter ssh_meter { ip saddr limit rate 3/minute burst 5 packets } accept comment "Rate-limit SSH connection attempts"
           tcp dport 22 ct state new drop

           # Accept HTTPS (Port 443) and HTTP (Port 80)
           tcp dport { 80, 443 } ct state new accept comment "Allow web ingress"
       }

       chain egress_output {
           type filter hook output priority filter; policy accept;
       }

       chain transit_forward {
           type filter hook forward priority filter; policy drop;
       }
   }
   ```

2. **Load and Verify Ruleset in Kernel Memory**  
   Apply the ruleset using `nft` and inspect kernel state tables:

   ```bash
   sudo nft -f /etc/nftables.conf
   sudo nft list ruleset
   ```

   **Expected Output:**
   ```text
   table inet global_firewall {
   	set dynamic_blacklist {
   		type ipv4_addr
   		flags timeout
   	}

   	chain ingress_input {
   		type filter hook input priority filter; policy drop;
   		ct state invalid drop comment "Drop invalid TCP packet states"
   		iifname "lo" accept comment "Accept loopback traffic"
   		ct state established,related accept comment "Accept established & related connections"
   		ip saddr @dynamic_blacklist drop comment "Drop explicit blacklisted sources"
   		ip protocol icmp icmp type echo-request limit rate 5/second burst 10 packets accept
   		ip protocol icmp icmp type echo-request drop
   		tcp dport 22 ct state new meter ssh_meter { ip saddr limit rate 3/minute burst 5 packets } accept comment "Rate-limit SSH connection attempts"
   		tcp dport 22 ct state new drop
   		tcp dport 80 ct state new accept comment "Allow web ingress"
   		tcp dport 443 ct state new accept comment "Allow web ingress"
   	}

   	chain egress_output {
   		type filter hook output priority filter; policy accept;
   	}

   	chain transit_forward {
   		type filter hook forward priority filter; policy drop;
   	}
   }
   ```

3. **Inspect Active Connection Tracking Entries**  
   Use `conntrack` to query real-time kernel session states:

   ```bash
   sudo conntrack -L -p tcp --state ESTABLISHED
   ```

   **Expected Output:**
   ```text
   tcp      6 431999 ESTABLISHED src=192.168.1.50 dst=192.168.1.10 sport=52104 dport=443 src=192.168.1.10 dst=192.168.1.50 sport=443 dport=52104 [ASSURED] mark=0 use=1
   conntrack v1.4.6 (conntrack-tools): 1 flow entries have been shown.
   ```

---

### Verification Questions — Exercise 2

**Question 2.1:** What is the fundamental operational difference between `policy drop` in the `ingress_input` chain versus appending a fallback `reject` rule at the bottom of the chain? What are the network reconnaissance and resource consumption implications of both approaches during an active port scan?

**Question 2.2:** In high-throughput SRE environments handling over 500,000 concurrent TCP connections, what kernel subsystem failure occurs if the stateful `conntrack` table max capacity (`net.netfilter.nf_conntrack_max`) is breached, and how can specific stateless high-volume services (e.g., DNS, static assets) bypass connection tracking?

---

## Exercise 3: Service Hardening, TLS 1.3 Transport Security, & Systemd Isolation

### Architectural Overview & Internal Mechanics
Securing network services requires a multi-layered approach: hardening service execution runtimes via Linux namespaces/cgroups and securing the transport layer using modern cryptography.

* **TLS 1.3 Handshake (RFC 8446):** Eliminates legacy vulnerable ciphers (RC4, 3DES, CBC mode) and weak key exchanges (static RSA, DH). TLS 1.3 reduces handshake latency to 1-RTT (or 0-RTT via PSK resumption) by combining cipher suite negotiation and Diffie-Hellman key exchange into the initial `ClientHello`. Perfect Forward Secrecy (PFS) is enforced mandatory via Ephemeral Elliptic Curve Diffie-Hellman (ECDHE).

```
Client                                                               Server
  |                                                                    |
  |--- ClientHello (Key Share: ECDHE-X25519, CipherSuites) ---------->|
  |                                                                    |
  |                                  Selects Cipher Suite & Key Share  |
  |                                  Generates Server Ephemeral Key    |
  |                                  Derives Handshake Keys            |
  |                                                                    |
  |<-- ServerHello (Key Share: ECDHE-X25519) --------------------------|
  |<-- {EncryptedExtensions} ------------------------------------------|
  |<-- {Certificate & CertificateVerify} ------------------------------|
  |<-- {Finished} -----------------------------------------------------|
  |                                                                    |
  | Derives Application Keys                                           |
  |---> {Finished} --------------------------------------------------->|
  |                                                                    |
  |<=== [Application Data (Encrypted via AES-256-GCM / ChaCha20)] ====>|
```

* **Process Isolation via Systemd:** Restricts system call access (`Seccomp`), file system visibility (`ProtectSystem=strict`), and kernel privileges (`CapabilityBoundingSet=`).

### Guided Implementation Steps

1. **Configure Hardened NGINX TLS 1.3 Web Server Manifest**  
   Create `/etc/nginx/conf.d/security_hardened.conf` to mandate TLS 1.3, strict HSTS headers, OCSP stapling, and modern AEAD ciphers:

   ```nginx
   # Hardened Production TLS 1.3 Site Configuration
   server {
       listen 443 ssl http2;
       listen [::]:443 ssl http2;
       server_name edge.production.internal;

       # X.509 Certificate Chain & Private Key
       ssl_certificate /etc/ssl/certs/production_chain.crt;
       ssl_certificate_key /etc/ssl/private/production.key;

       # Restrict Protocols strictly to TLS 1.3
       ssl_protocols TLSv1.3;

       # Modern AEAD Cipher Suites for TLS 1.3
       ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256;

       # Session Optimization & Tickets Security
       ssl_session_timeout 1d;
       ssl_session_cache shared:SSL:10m;
       ssl_session_tickets off;

       # OCSP Stapling Mechanics
       ssl_stapling on;
       ssl_stapling_verify on;
       ssl_trusted_certificate /etc/ssl/certs/ca_root_chain.crt;
       resolver 1.1.1.1 8.8.8.8 valid=300s;
       resolver_timeout 5s;

       # HTTP Security Hardening Headers
       add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
       add_header X-Content-Type-Options "nosniff" always;
       add_header X-Frame-Options "DENY" always;
       add_header Content-Security-Policy "default-src 'self';" always;

       location / {
           root /var/www/html;
           index index.html;
       }
   }
   ```

2. **Hardening the Service Unit via Systemd Namespaces**  
   Override the NGINX systemd service unit file at `/etc/systemd/system/nginx.service.d/override.conf` to enforce strict sandboxing:

   ```ini
   [Service]
   # Capability Bounding
   CapabilityBoundingSet=CAP_NET_BIND_SERVICE
   AmbientCapabilities=CAP_NET_BIND_SERVICE
   NoNewPrivileges=true

   # File System Sandboxing
   ProtectSystem=strict
   ProtectHome=true
   ReadWritePaths=/var/log/nginx /var/run /var/cache/nginx
   PrivateTmp=true
   PrivateDevices=true

   # Kernel & Protocol Hardening
   ProtectKernelTunables=true
   ProtectKernelModules=true
   ProtectControlGroups=true
   RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
   MemoryDenyWriteExecute=true
   ```

3. **Verify TLS 1.3 Handshake and Cipher Suite via OpenSSL CLI**  
   Validate transport layer encryption and handshake negotiation:

   ```bash
   openssl s_client -connect 127.0.0.1:443 -tls1_3 -servername edge.production.internal -brief
   ```

   **Expected Output:**
   ```text
   CONNECTION ESTABLISHED
   Protocol version: TLSv1.3
   Ciphersuite: TLS_AES_256_GCM_SHA384
   Peer certificate: CN = edge.production.internal
   Hash type: SHA384
   Verification: OK
   Re-negotiation NOT supported
   ALPN protocol: h2
   Early data status: not sent
   ```

---

### Verification Questions — Exercise 3

**Question 3.1:** What cryptographic security vulnerability is mitigated by setting `ssl_session_tickets off;` in TLS 1.3 configurations when central ticket key rotation mechanisms are absent across an SRE load balancer cluster?

**Question 3.2:** How does the systemd directive `MemoryDenyWriteExecute=true` protect a network service binary from memory corruption exploits (e.g., buffer overflow shellcode execution), and what dynamic runtime environments (such as Node.js or Java JVMs) would break if this setting is enabled?

---

## Exercise 4: Domain Name System Security Extensions (DNSSEC) & Name Resolution Integrity

### Architectural Overview & Internal Mechanics
Standard DNS operates over unauthenticated UDP/53, leaving name resolution vulnerable to DNS Cache Poisoning and Man-in-the-Middle (MitM) spoofing.

**DNSSEC (RFC 4033)** adds cryptographic origin authentication and data integrity protection to DNS through public key cryptography:
* **RRSIG (Resource Record Signature):** Digital signature over an RRset created by the zone's Private Zone Signing Key (ZSK).
* **DNSKEY:** Contains the public Zone Signing Key (ZSK) and Key Signing Key (KSK).
* **DS (Delegation Signer):** Digest of the child zone's KSK stored in the parent zone, establishing an unbroken **Chain of Trust** up to the Root ICANN Trust Anchor.
* **NSEC/NSEC3:** Cryptographically proves the non-existence of a DNS record (Authenticated Denial of Existence).

```
Root Zone (.) [Root Trust Anchor]
  |  DS Record (Hashes KSK of .org)
  v
.org Zone
  |  DS Record (Hashes KSK of example.org)
  v
example.org Zone
  ├── KSK (Key Signing Key) ---> Signs DNSKEY RRset (ZSK)
  └── ZSK (Zone Signing Key) ---> Signs A/AAAA Record Sets ---> Produces RRSIG Record
```

### Guided Implementation Steps

1. **Perform DNSSEC Validation Trace using `dig`**  
   Query a DNSSEC-signed domain (`ietf.org`) requesting DNSSEC records (`+dnssec`) and multiline formatting (`+multi`):

   ```bash
   dig +dnssec +multi A ietf.org @1.1.1.1
   ```

   **Expected Output:**
   ```text
   ;; Got answer:
   ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 41285
   ;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

   ;; OPT PSEUDOSECTION:
   ; EDNS: version: 0, flags: do; udp: 1232
   ;; QUESTION SECTION:
   ;ietf.org.		IN A

   ;; ANSWER SECTION:
   ietf.org.		300 IN A 104.16.44.99
   ietf.org.		300 IN RRSIG A 13 2 300 20260815000000 20260801000000 34185 ietf.org. +gH7bK9mF...
   ```

   > **Critical Flag Verification:** Notice the `ad` (Authenticated Data) flag in the header. This confirms that the validating resolver verified the complete chain of signatures against trusted root anchors.

2. **Cryptographically Validate Chain of Trust using `delv`**  
   Use `delv` (Domain Entity Link Verification) to trace cryptographic proof from root keys down to the host address record:

   ```bash
   delv @1.1.1.1 ietf.org A +rtrace
   ```

   **Expected Output:**
   ```text
   ;; fetch: . KSK KEY RSASHA256/20326 [...]
   ;; fully validated
   ;; fetch: org. DS SHA-256/26906 [...]
   ;; fully validated
   ;; fetch: ietf.org. DS SHA-256/34185 [...]
   ;; fully validated
   ;; unsigned answer: ietf.org. 300 IN A 104.16.44.99
   ;; fully validated
   ```

3. **Audit Local Resolver Configuration for DNSSEC Enforcement**  
   Inspect `/etc/systemd/resolved.conf` to ensure DNSSEC validation is set to strict mode rather than fallback:

   ```bash
   grep -E "^\[Resolve\]|^DNSSEC" /etc/systemd/resolved.conf
   ```

   **Expected Output:**
   ```text
   [Resolve]
   DNSSEC=yes
   ```

---

### Verification Questions — Exercise 4

**Question 4.1:** What is the specific role of the `ad` (Authenticated Data) flag in a DNS response header, and why must stub resolvers operating behind a local caching proxy (e.g., `systemd-resolved`) communicate over a trusted channel (loopback or IPsec) when relying on the `ad` flag?

**Question 4.2:** Explain how NSEC3 prevents zone walking (zone enumeration attacks) compared to standard NSEC records, and what performance trade-off is introduced on authoritative DNS servers when high iteration counts and salt values are used in NSEC3 parameters?

---

## Exercise 5: Encrypted Tunnels, Mesh VPNs (WireGuard), and Anonymity Layer Architecture

### Architectural Overview & Internal Mechanics
Virtual Private Networks (VPNs) and anonymizing networks secure data in transit across untrusted public networks:

* **WireGuard Kernel-State Mechanics:** WireGuard operates inside the Linux kernel as a network interface (`wg0`). It replaces legacy IPsec/OpenVPN state machines with the **Noise Protocol Framework**. It uses **Cryptokey Routing**, which maps specific public keys to allowed IP addresses (`AllowedIPs`).
  * Cryptography: Curve25519 (Key Exchange), ChaCha20 (Symmetric Encryption), Poly1305 (Authentication), BLAKE2s (Hashing).
  * Stealth Behavior: WireGuard is completely silent when not processing valid traffic; it drops unauthenticated packets without responding, making hosts invisible to UDP port scans.

```
       +-----------------------------------------------------------------------+
       |                         WireGuard Cryptokey Routing                   |
       |                                                                       |
       |  Inbound UDP 51820 Packet ---> Verify Poly1305 MAC                    |
       |                                       |                               |
       |                                Authenticated?                         |
       |                                    /     \                            |
       |                                 (Yes)    (No)                         |
       |                                  /         \                          |
       |     Decrypt Payload via ChaCha20            Silent Drop (No Response) |
       |                  |                                                    |
       |     Match Src IP to AllowedIPs                                        |
       |                  |                                                    |
       |     Forward Packet to wg0 Interface                                   |
       +-----------------------------------------------------------------------+
```

* **Onion Routing (Tor Architecture):** Anonymity networks protect metadata and traffic analysis. Data is wrapped in multiple layers of encryption (like an onion) and routed through a circuit of three node types:
  1. **Guard/Entry Node:** Sees client real IP, but cannot see destination.
  2. **Middle Relay:** Sees only previous and next hops; cannot see client identity or destination.
  3. **Exit Node:** Decrypts final layer and sends traffic to public destination. (Sees plaintext payload if TLS is not used).

### Guided Implementation Steps

1. **Construct Production WireGuard Gateway Configuration (`wg0.conf`)**  
   Create the server configuration at `/etc/wireguard/wg0.conf`:

   ```ini
   [Interface]
   # Tunnel IPv4/IPv6 Address Assignment
   Address = 10.200.0.1/24, fd42:42:42::1/64
   ListenPort = 51820

   # Server Private Key (Keep Secret)
   PrivateKey = SERVER_PRIVATE_KEY_PLACEHOLDER

   # Kernel Packet Forwarding & NAT Rules for Egress Isolation
   PostUp = sysctl -w net.ipv4.ip_forward=1
   PostUp = nft add table inet wg_nat
   PostUp = nft add chain inet wg_nat postrouting \{ type nat hook postrouting priority srcnat\; \}
   PostUp = nft add rule inet wg_nat postrouting oifname "eth0" masquerade
   PostDown = nft delete table inet wg_nat
   PostDown = sysctl -w net.ipv4.ip_forward=0

   [Peer]
   # Client 1: Engineering Laptop
   PublicKey = CLIENT1_PUBLIC_KEY_PLACEHOLDER
   AllowedIPs = 10.200.0.2/32, fd42:42:42::2/128

   [Peer]
   # Client 2: Edge Application Node
   PublicKey = CLIENT2_PUBLIC_KEY_PLACEHOLDER
   AllowedIPs = 10.200.0.3/32, fd42:42:42::3/128
   ```

2. **Bring Up WireGuard Interface and Query Kernel Status**  
   Initialize the interface using `wg-quick` and audit interface stats:

   ```bash
   sudo wg-quick up wg0
   sudo wg show wg0
   ```

   **Expected Output:**
   ```text
   interface: wg0
     public key: 8vB...server_pubkey...=
     private key: (hidden)
     listening port: 51820

   peer: CLIENT1_PUBLIC_KEY_PLACEHOLDER
     endpoint: 203.0.113.45:61022
     allowed ips: 10.200.0.2/32, fd42:42:42::2/128
     latest handshake: 1 minute, 12 seconds ago
     transfer: 14.25 MiB received, 89.41 MiB sent
     persistent keepalive: every 25 seconds
   ```

3. **Audit Anonymity Layer & Egress Isolation Mechanics**  
   Verify that traffic traversing anonymized SOCKS5 proxies (such as Tor on port 9050) completely obscures the origin IP address:

   ```bash
   curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
   ```

   **Expected Output:**
   ```json
   {"IsTor":true,"IP":"185.220.101.5"}
   ```

---

### Verification Questions — Exercise 5

**Question 5.1:** In WireGuard's Cryptokey Routing table, what happens if two separate `[Peer]` blocks are configured with overlapping IP addresses in their `AllowedIPs` directive (e.g., both listing `10.200.0.2/32`)? How does the kernel resolve inbound and outbound routing ambiguities?

**Question 5.2:** While Tor encrypts network payload traffic across three internal hops, an SRE monitors traffic leaving a Tor Exit Node. If an application client transmits HTTP traffic (without TLS) through Tor to a backend service, what security boundaries are maintained, and what critical vulnerabilities remain exposed at the exit node layer?

---

## <details><summary>Comprehension Check Answer Key & Architectural Analysis</summary>

### Exercise 1 Answers
* **Answer 1.1:** Setting `rp_filter = 0` allows the kernel to process packets whose source IP addresses are not reachable through the specific interface they arrived on. This exposes the host to **IP Source Address Spoofing**, enabling attackers on external networks to forge internal network source IPs (e.g., `10.0.0.0/8`) to bypass firewall ACLs or launch reflection attacks. Enabling strict mode (`rp_filter = 1`) causes the kernel to perform a reverse routing lookup on every incoming packet's source IP. If the best return route for that IP does not point back out the exact interface on which the packet arrived, the kernel immediately drops the packet at L3 before it reaches any service or socket.
* **Answer 1.2:** Binding a service to `0.0.0.0` instructs the kernel to listen on all current and future network interfaces (including public internet interfaces). Binding to `127.0.0.1` restricts socket listeners strictly to the local loopback interface, making it inaccessible from outside the host. If a database like Redis (which historically lacked default authentication) is exposed on `0.0.0.0:6379`, external attackers can achieve remote code execution (RCE) or unauthorized data exfiltration by writing SSH keys or cron jobs directly into system memory via Redis commands.

### Exercise 2 Answers
* **Answer 2.1:** A default `policy drop` silently discards non-matching packets without sending an ICMP response. A `reject` rule actively sends back an `ICMP Port Unreachable` (or TCP RST) packet to the sender.
  * *Reconnaissance impact:* `drop` makes closed ports appear non-responsive or filtered, slowing down port scanners (like `nmap`) because they must wait for connection timeouts. `reject` instantly confirms to a scanner that the host is alive and actively processing traffic.
  * *Resource impact:* `drop` saves outbound network bandwidth during a DDoS attack because the kernel generates zero egress response packets.
* **Answer 2.2:** When `conntrack` fills up (`nf_conntrack: table full`), the kernel drops all subsequent incoming packets for new connections, resulting in a complete Denial of Service (DoS) for legitimate traffic. In high-volume environments, SREs use the `raw` table in Netfilter with the `NOTRACK` target (`nft add rule inet raw prerouting tcp dport 53 counter notrack`) to bypass state tracking for statelessly stateless or ultra-high-throughput services.

### Exercise 3 Answers
* **Answer 3.1:** In TLS 1.3, session tickets can be issued as stateless Session Tickets encrypted by a symmetric Session Ticket Encryption Key (STEK) maintained by the server. If `ssl_session_tickets` is enabled without automated STEK rotation across a load balancer pool, an attacker who compromises the static STEK key can retroactively decrypt all captured TLS sessions recorded from the past, breaking Perfect Forward Secrecy (PFS). Disabling session tickets forces clients to rely on stateful session IDs or requires strict out-of-band STEK key rotation.
* **Answer 3.2:** `MemoryDenyWriteExecute=true` enforces the $W \oplus X$ (Write XOR Execute) memory protection policy. It instructs the kernel to disallow mapping memory pages that are simultaneously writable and executable (`PROT_WRITE | PROT_EXEC`), preventing attackers from placing executable shellcode into stack/heap memory and executing it.
  * *Broken runtimes:* Dynamic Just-In-Time (JIT) compilers (e.g., Node.js V8 engine, Java HotSpot JVM, Python PyPy) generate machine code dynamically in memory at runtime and immediately execute it. Enforcing `MemoryDenyWriteExecute=true` causes these runtime environments to crash with `SIGSEGV` or `EPERM` error signals upon allocation.

### Exercise 4 Answers
* **Answer 4.1:** The `ad` (Authenticated Data) flag indicates that an upstream validating recursive resolver has validated the cryptographic signature chain from the root trust anchor down to the target record set. Stub resolvers (like local applications) do not perform full signature checks themselves; they trust the `ad` flag. Therefore, the network hop between the stub resolver and the validating proxy must be secured (via loopback `127.0.0.1` or encrypted IPsec/TLS tunnels) to prevent an adversary on the local LAN from forging responses and injecting a fake `ad` flag.
* **Answer 4.2:** Standard `NSEC` records return the exact existing domain names preceding and following the queried non-existent domain name, allowing an attacker to iterate through the zone and discover all private record names ("Zone Walking"). `NSEC3` replaces plaintext domain names with salted, iterated cryptographic hashes (e.g., `SHA-1(domain + salt)`), preventing bulk enumeration. However, high iteration counts require significant CPU processing power on authoritative servers for every `NXDOMAIN` response, exposing authoritative DNS infrastructure to CPU-exhaustion Denial-of-Service attacks.

### Exercise 5 Answers
* **Answer 5.1:** WireGuard enforces a strict 1-to-1 association between an allowed IP address and a peer's public key in its Cryptokey Routing table. If a duplicate IP address is defined under a second peer, the kernel silently overwrites the previous entry, associating the IP exclusively with the *last* peer parsed in the configuration file. Outbound traffic to that IP will route only to the last peer, and inbound traffic from the original peer using that IP address will be dropped as unauthenticated.
* **Answer 5.2:** Tor provides metadata anonymity and encrypted transport through the Guard and Middle relays, successfully obscuring the client's source IP address from both internet observers and the destination server. However, because Tor's Exit Node decrypts the final layer of onion encryption, non-TLS HTTP traffic leaves the Exit Node in cleartext. An operator of a malicious Exit Node can inspect, intercept, log, or modify the unencrypted HTTP payload (e.g., stealing passwords, cookies, or injecting malicious scripts) before delivering it to the destination. End-to-end TLS (HTTPS over Tor) is required to secure payload confidentiality and integrity.

</details>