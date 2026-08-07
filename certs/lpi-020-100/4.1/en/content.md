# LPI Security Essentials (020-100) — Topic 4.1: Network and Service Security

**Exam Code:** 020-100 (Version 1.0)  
**Topic Reference:** Topic 4.1 (Objective 024: Network and Service Security)  
**Weight:** 20  
**Target Role:** Senior SRE / Principal Platform Architect  

---

## 1. Production Architecture Motivation & Threat Modeling

### 1.1 The Production Problem: Defense-in-Depth vs. Perimeter Collapse
Legacy infrastructure models relied on a perimeter-based security model ("Castle-and-Moat"), assuming traffic inside the internal network subnet was trusted. Modern cloud-native environments render this assumption invalid due to dynamic workloads, multi-tenant container hosts, sidecar proxy injection, and distributed edge endpoints.

A single compromised container or unhardened daemon exposed on `0.0.0.0:8080` allows an attacker to pivot laterally across flat VPC subnets, execute remote code execution (RCE), perform ARP spoofing, or exfiltrate environment credentials via metadata endpoints (e.g., `169.254.169.254`). 

```
                                  [ PUBLIC INTERNET ]
                                           |
                                  ( Untrusted Traffic )
                                           |
                                           v
                             +---------------------------+
                             | Hardened Border Firewall  |
                             | (nftables / Edge Ingress) |
                             +---------------------------+
                                           |
                                           v
                             +---------------------------+
                             |   L7 Reverse Proxy / TLS  |
                             |   (NGINX / Rate Limit)    |
                             +---------------------------+
                                           |
                                 (Encrypted Transit)
                                           |
     +-------------------------------------+-------------------------------------+
     |                                                                           |
     v                                                                           v
+------------------------------------+                      +------------------------------------+
| Workload Namespace A               |                      | Workload Namespace B               |
| (Isolated netns / Systemd Sandbox) |                      | (Isolated netns / Systemd Sandbox) |
| - Localhost socket binding only    | <=== Isolated =====> | - Restricted IP family egress      |
| - Strictly enforced nftables rules |     (No Lateral)     | - WireGuard VPN Tunnel Endpoints   |
+------------------------------------+                      +------------------------------------+
```

### 1.2 Threat Modeling & Attack Vectors
Production service deployment requires protection against specific threat vectors targeting Layer 3, Layer 4, and Layer 7:

1. **Unencrypted Data-in-Transit & Interception (MitM):** Unauthenticated cleartext protocols (HTTP, FTP, Telnet, unencrypted database connections) allow passive sniffing using packet capture engines (`tcpdump`/`libpcap`) or active ARP cache poisoning.
2. **Resource Exhaustion & Denial of Service (DoS/DDoS):** TCP SYN floods consume kernel connection state tables (`conntrack`), exhausting file descriptors and memory allocations before applications can process connections.
3. **Improper Socket Binding & Unauthorized Surface Exposure:** Services binding implicitly to wildcard addresses (`0.0.0.0` or `::`) bypass intended local-only access controls, exposing internal administrative interfaces (e.g., Redis, JMX, Prometheus metrics) to external network adapters.
4. **Lateral Movement via Flat Subnets:** Lack of internal egress/ingress stateful packet filtering enables malicious workloads to scan local CIDRs using SYN stealth scans (`nmap`) to discover and exploit adjacent services.

### 1.3 Linux Kernel Networking Mechanics
Network security enforcement operates within the Linux kernel architecture through distinct subsystems:

* **Netfilter Framework:** Provides hooks inside the Linux kernel network stack (`PREROUTING`, `INPUT`, `FORWARD`, `OUTPUT`, `POSTROUTING`) allowing packet interception, Network Address Translation (NAT), and stateful connection tracking (`nf_conntrack`).
* **Linux Network Namespaces (`netns`):** Provides complete virtualization of the network stack, isolating network interfaces, routing tables, ARP tables, and socket lists per process group.
* **Control Groups (`cgroups v2`) & Socket Filtering:** Enforces network bandwidth allocation and system call/socket family restrictions (`AF_INET`, `AF_INET6`, `AF_UNIX`) via eBPF or systemd units.

---

## 2. Technical Comparative & Trade-off Analysis

### 2.1 Kernel Packet Filtering: `iptables` vs. `nftables` vs. `eBPF (XDP)`

| Metric / Dimension | `iptables` (legacy `ip_tables`) | `nftables` (`nf_tables`) | eBPF / XDP (`Express Data Path`) |
| :--- | :--- | :--- | :--- |
| **Kernel Subsystem** | Separate modules (`iptables`, `ip6tables`, `arptables`, `ebtables`). | Unified `nf_tables` engine with generic byte-code interpreter. | Programmable kernel virtual machine attached to network driver hooks. |
| **Performance (High Packet Rates)** | Linear rule evaluation ($O(N)$ overhead per packet match). | Lookup tables & sets ($O(1)$ amortized evaluation). | Early packet drop at NIC driver level ($O(1)$ prior to `sk_buff` allocation). |
| **Rule Updates & Atomicity** | Non-atomic full table replacement; causes transient packet drops under high frequency updates. | Fully atomic ruleset replacement and differential updates via transaction API. | Atomic eBPF map state updates without re-compiling or reloading network filters. |
| **Dual-Stack (IPv4/IPv6)** | Requires duplicated configurations in `iptables` and `ip6tables`. | Unified `inet` address family handling IPv4 and IPv6 simultaneously. | Custom logic handling IP header parsing natively within eBPF C program. |
| **Recommended Use Case** | Legacy infrastructure maintenance. | Standard Linux server firewalls, edge nodes, and host protection. | Ultra-high throughput micro-segmentation (e.g., Cilium, Cloudflare edge filters). |

### 2.2 Host Firewall Management Abstractions: `ufw` vs. `firewalld`

| Feature | `ufw` (Uncomplicated Firewall) | `firewalld` |
| :--- | :--- | :--- |
| **Primary Distribution** | Ubuntu / Debian ecosystem. | RHEL / Fedora / CentOS / Rocky Linux ecosystem. |
| **Backend Integration** | Translates CLI commands to `iptables` / `nftables` rulesets. | Uses D-Bus API to dynamically manipulate `nftables` rulesets. |
| **State & Zone Model** | Static profile model (Simple Ingress/Egress defaults + Rule lists). | Dynamic Zone model (`public`, `internal`, `dmz`, `trusted`) assigned per interface/source IP. |
| **Dynamic Configuration** | Modifying rules requires applying updates that reload the chains. | Supports runtime vs. permanent state updates without dropping established connections. |
| **Target Audience** | Desktop workstations and simple, static server deployments. | Dynamic multi-interface servers, enterprise virtualization, and complex routing environments. |

### 2.3 Site-to-Site & Remote Access VPN Protocols

| Parameter | WireGuard | OpenVPN | IPsec (IKEv2 / ESP) |
| :--- | :--- | :--- | :--- |
| **Implementation Layer** | In-kernel crypto module (`wireguard.ko`). | User-space process (utilizing `tun`/`tap` devices and OpenSSL). | In-kernel protocol engine (`xfrm` subsystem with external IKE daemon like StrongSwan). |
| **Cryptographic Agility** | Fixed modern primitives (ChaCha20-Poly1305, Curve25519, BLAKE2s, HKDF). | Flexible cipher negotiation (AES-GCM, ChaCha20, RSA, ECDSA). | Enterprise negotiation (AES-CBC/GCM, SHA2, Diffie-Hellman groups). |
| **Codebase Size** | ~4,000 lines of code (Highly auditable). | ~100,000+ lines of code. | High complexity across multiple RFC standards. |
| **Performance & Latency** | Near line-rate performance; low memory overhead and zero idle traffic. | Context switching between user/kernel space introduces CPU overhead and latency. | High throughput when hardware crypto acceleration (AES-NI) is present. |
| **State Management** | Connectionless UDP protocol state; dynamic handshake on demand. | Connection-oriented state over UDP/TCP with periodic TLS re-keying. | Complex security association (SA) renegotiation protocols. |

---

## 3. Production Infrastructure Manifests & Hardening Configurations

### 3.1 Hardened Dual-Stack `nftables` Configuration (`/etc/nftables.conf`)
This production-grade ruleset enforces a strict default-drop policy, isolates control plane interfaces, mitigates TCP SYN flood attacks via rate-limiting sets, and blocks invalid connection states across IPv4 and IPv6.

```nftables
#!/usr/sbin/nft -f

# Flush existing rulesets
flush ruleset

table inet filter {
    # Rate limiting sets for anti-bruteforce protection
    set ssh_meter {
        type ipv4_addr
        flags dynamic, timeout
        timeout 1m
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # 1. Allow traffic on loopback interface
        iifname "lo" accept comment "Accept all local loopback traffic"
        iifname != "lo" ip daddr 127.0.0.0/8 drop comment "Drop spoofed loopback traffic"
        iifname != "lo" ip6 daddr ::1 drop comment "Drop spoofed IPv6 loopback traffic"

        # 2. Stateful connection tracking
        ct state established,related accept comment "Allow established/related connections"
        ct state invalid drop comment "Drop invalid packet states immediately"

        # 3. ICMP rate limiting (prevent ping sweeps and ICMP flood)
        ip protocol icmp icmp type { echo-request, router-advertisement, time-exceeded, destination-unreachable } limit rate 5/second burst 10 packets accept comment "Rate limit IPv4 ICMP"
        ip6 nexthdr ipv6-icmp icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded, nd-neighbor-solicit, nd-neighbor-advert } limit rate 5/second burst 10 packets accept comment "Rate limit IPv6 ICMP"

        # 4. Anti-SYN Flood Mitigation
        tcp flags syn tcp option maxseg size 1-1460 limit rate 20/second burst 40 packets accept comment "Mitigate TCP SYN flood"

        # 5. Public Services Ingress Enforcement
        # Rate-limited SSH access on TCP/22 (max 3 connections per minute per source IP)
        tcp dport 22 ct state new update @ssh_meter { ip saddr limit rate over 3/minute } drop
        tcp dport 22 ct state new accept comment "Allow rate-limited SSH"

        # HTTPS Ingress traffic on TCP/443
        tcp dport 443 ct state new accept comment "Allow public HTTPS ingress"

        # Explicitly log rejected packets for SIEM auditing
        limit rate 3/minute log prefix "NFTABLES-INGRESS-REJECT: " level info
        reject with icmpx type admin-prohibited
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        comment "Drop all routed packet forwarding by default"
    }

    chain output {
        type filter hook output priority filter; policy accept;
        comment "Allow all egress traffic from localhost"
    }
}
```

### 3.2 Network-Isolated Systemd Service Unit (`/etc/systemd/system/secure-api.service`)
This systemd unit file applies strict Linux kernel security parameters, restricts the network socket families the process can create, isolates the network namespace, and binds the execution to an internal IP address range.

```ini
[Unit]
Description=Production Hardened API Daemon
After=network-online.target nftables.service
Wants=network-online.target
Documentation=https://internal.wiki.enterprise.io/architecture/secure-api

[Service]
Type=exec
User=api-worker
Group=api-worker
WorkingDirectory=/opt/secure-api
ExecStart=/opt/secure-api/bin/api-server --bind-address=127.0.0.1 --port=8443
Restart=on-failure
RestartSec=5s

# Process Sandbox & System Call Isolation
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
MemoryDenyWriteExecute=true
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# System Call Filtering
SystemCallFilter=@default @network-io @basic-io
SystemCallFilter=~@clock @cpu-emulation @debug @keyring @module @obsolete @raw-io @reboot @swap

# Network Security Hardening Options
# Isolate process from receiving socket calls outside specified AF families
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

# Egress/Ingress IP Filtering via cgroup v2 BPF filters
IPAddressDeny=any
IPAddressAllow=127.0.0.1/32
IPAddressAllow=10.244.0.0/16

# Socket & Port Allocation Protection
PrivateNetwork=false
ProtectClock=true

[Install]
WantedBy=multi-user.target
```

### 3.3 Production WireGuard VPN Peer Manifest (`/etc/wireguard/wg0.conf`)
Fully functional WireGuard interface manifest configuring kernel-space encryption, strict allowed IP routing, and persistent keepalives for traversing stateful NAT firewalls.

```ini
[Interface]
# Device Address Definition within Private VPN Subnet
Address = 10.200.50.1/24, fd42:200:50::1/64
ListenPort = 51820
PrivateKey = uK8Z...[REDACTED_32_BYTE_BASE64_PRIVATE_KEY]...=
SaveConfig = false

# Kernel Pre/Post Execution Rules for Firewall Traversal
PreUp = sysctl -w net.ipv4.ip_forward=1
PostUp = nft add table inet wg-nat; nft add chain inet wg-nat postrouting \{ type nat hook postrouting priority srcnat\; \}; nft add rule inet wg-nat postrouting oifname "eth0" masquerade
PostDown = nft delete table inet wg-nat

[Peer]
# Remote Branch Gateway Office
PublicKey = 7bXw...[REDACTED_32_BYTE_BASE64_PUBLIC_KEY]...=
PresharedKey = pK9q...[REDACTED_32_BYTE_BASE64_PRESHARED_KEY]...=
AllowedIPs = 10.200.50.2/32, 192.168.10.0/24
Endpoint = 198.51.100.45:51820
PersistentKeepalive = 25
```

### 3.4 Hardened NGINX Edge Reverse Proxy (`/etc/nginx/sites-available/secure-service.conf`)
Production reverse proxy enforcing strict TLS 1.3 encryption, HTTP Strict Transport Security (HSTS), rate-limiting zones, and proxy header sanitization.

```nginx
# Rate Limiting Zone Definition (10MB shared memory zone, max 10 requests/sec per IP)
limit_req_zone $binary_remote_addr zone=api_gateway_rate:10m rate=10r/s;
limit_conn_zone $binary_remote_addr zone=api_conn_limit:10m;

server {
    listen 80;
    listen [::]:80;
    server_name api.enterprise.internal;

    # Enforce global HTTP-to-HTTPS Redirection with strict 301
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name api.enterprise.internal;

    # TLS Certificate & Cryptographic Material Configuration
    ssl_certificate /etc/ssl/certs/api_enterprise_combined.crt;
    ssl_certificate_key /etc/ssl/private/api_enterprise.key;
    ssl_dhparam /etc/ssl/certs/dhparam4096.pem;

    # Strict Protocol & Cipher Suites (TLS 1.2 and TLS 1.3 only)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # TLS Session Cache Optimization
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # OCSP Stapling Configuration
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/ssl/certs/ca_chain.crt;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # Security Headers Enforcement
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Content-Security-Policy "default-src 'self'; http: https: data: blob: 'unsafe-inline'" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Proxy Rate Limiting & Connection Limits
    limit_req zone=api_gateway_rate burst=20 nodelay;
    limit_conn api_conn_limit 20;

    location / {
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;

        # Header Sanitization & Connection Protection
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;

        # Timeouts preventing Slowloris attacks
        proxy_connect_timeout 5s;
        proxy_send_timeout 10s;
        proxy_read_timeout 10s;
    }
}
```

---

## 4. Real-World CLI Execution & Terminal Outputs

### 4.1 Auditing Bound Sockets and Process Associations
Inspect open TCP/UDP sockets, verify interface binding scope (`0.0.0.0` vs. `127.0.0.1`), and correlate listening sockets to process IDs using `ss` and `lsof`.

```bash
$ sudo ss -tulpn
```
```text
Netid  State   Recv-Q  Send-Q     Local Address:Port      Peer Address:Port  Process                                                                         
udp    UNCONN  0       0                0.0.0.0:51820          0.0.0.0:*      users:(("wg-crypt-wg0",pid=1240,fd=5))                                         
tcp    LISTEN  0       511            127.0.0.1:8443          0.0.0.0:*      users:(("api-server",pid=48210,fd=3))                                           
tcp    LISTEN  0       511              0.0.0.0:80            0.0.0.0:*      users:(("nginx",pid=1102,fd=6),("nginx",pid=1103,fd=6))                         
tcp    LISTEN  0       511              0.0.0.0:443           0.0.0.0:*      users:(("nginx",pid=1102,fd=7),("nginx",pid=1103,fd=7))                         
tcp    LISTEN  0       128              0.0.0.0:22            0.0.0.0:*      users:(("sshd",pid=954,fd=3))                                                   
tcp    LISTEN  0       128                 [::]:22               [::]:*      users:(("sshd",pid=954,fd=4))                                                   
```

Inspect specific process capability boundaries and socket details:
```bash
$ sudo lsof -i TCP:8443 -a -p 48210
```
```text
COMMAND     PID       USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
api-serve 48210 api-worker    3u  IPv4  89412      0t0  TCP localhost:8443 (LISTEN)
```

### 4.2 Managing and Validating `nftables` State
Inspect active kernel chains, inspect rule counters, and monitor real-time packet drops:

```bash
$ sudo nft list ruleset
```
```text
table inet filter {
	set ssh_meter {
		type ipv4_addr
		flags dynamic,timeout
		timeout 1m
	}

	chain input {
		type filter hook input priority filter; policy drop;
		iifname "lo" accept comment "Accept all local loopback traffic"
		iifname != "lo" ip daddr 127.0.0.0/8 drop comment "Drop spoofed loopback traffic"
		iifname != "lo" ip6 daddr ::1 drop comment "Drop spoofed IPv6 loopback traffic"
		ct state established,related accept comment "Allow established/related connections"
		ct state invalid drop comment "Drop invalid packet states immediately"
		ip protocol icmp icmp type { destination-unreachable, echo-request, router-advertisement, time-exceeded } limit rate 5/second burst 10 packets accept comment "Rate limit IPv4 ICMP"
		ip6 nexthdr ipv6-icmp icmpv6 type { destination-unreachable, echo-request, packet-too-big, time-exceeded, nd-router-solicit, nd-neighbor-solicit } limit rate 5/second burst 10 packets accept comment "Rate limit IPv6 ICMP"
		tcp flags syn tcp option maxseg size 1-1460 limit rate 20/second burst 40 packets accept comment "Mitigate TCP SYN flood"
		tcp dport 22 ct state new update @ssh_meter { ip saddr limit rate over 3/minute } drop
		tcp dport 22 ct state new accept comment "Allow rate-limited SSH"
		tcp dport 443 ct state new accept comment "Allow public HTTPS ingress"
		limit rate 3/minute log prefix "NFTABLES-INGRESS-REJECT: " level info
		reject with icmpx type admin-prohibited
	}

	chain forward {
		type filter hook forward priority filter; policy drop;
	}

	chain output {
		type filter hook output priority filter; policy accept;
	}
}
```

### 4.3 Active Network Inspection with `tcpdump`
Capture raw packet headers on interface `eth0` to confirm that HTTP traffic to port 80 is receiving immediate HSTS 301 redirects to port 443 and that data on 443 contains encrypted TLS Application Data frames.

```bash
$ sudo tcpdump -i eth0 -nn -s 0 'tcp port 80 or tcp port 443' -c 4
```
```text
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN110MB (Ethernet), snapshot length 262144 bytes
00:14:22.849102 IP 198.51.100.12.54312 > 192.0.2.10.80: Flags [S], seq 382910481, win 64240, options [mss 1460,sackOK,TS val 2819010 ecr 0,nop,wscale 7], length 0
00:14:22.849280 IP 192.0.2.10.80 > 198.51.100.12.54312: Flags [S.], seq 981240192, ack 382910482, win 65160, options [mss 1460,sackOK,TS val 3912019 ecr 2819010,nop,wscale 7], length 0
00:14:22.850110 IP 198.51.100.12.54312 > 192.0.2.10.80: Flags [.], ack 1, win 501, length 0
00:14:22.850401 IP 198.51.100.12.54312 > 192.0.2.10.80: Flags [P.], seq 1:82, ack 1, win 501: HTTP: GET / HTTP/1.1
4 packets captured
12 packets received by filter
0 packets dropped by kernel
```

### 4.4 Surface Reconnaissance & Port Scanning Verification with `nmap`
Validate external attack surface using stealth SYN scans (`-sS`) combined with service/version detection (`-sV`):

```bash
$ nmap -sS -sV -p 21,22,80,443,8443,51820 192.0.2.10
```
```text
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-07 00:48 UTC
Nmap scan report for api.enterprise.internal (192.0.2.10)
Host is up (0.00042s latency).

PORT      STATE    SERVICE    VERSION
21/tcp    filtered ftp
22/tcp    open     ssh        OpenSSH 8.9p1 Ubuntu 3ubuntu0.6 (Ubuntu Linux; protocol 2.0)
80/tcp    open     http       nginx 1.18.0 (Ubuntu)
443/tcp   open     ssl/http   nginx 1.18.0 (Ubuntu)
8443/tcp  filtered https-alt
51820/udp open|filtered wireguard

Service detection performed. Please report any incorrect results at https://nmap.org/submit/ .
Nmap done: 1 IP address (1 host up) scanned in 6.42 seconds
```

### 4.5 WireGuard Link & Peer Status Management
Inspect cryptographic handshakes and transfer metrics across active WireGuard tunnels:

```bash
$ sudo wg show wg0
```
```text
interface: wg0
  public key: 7bXw...[REDACTED_BASE64_PUBLIC_KEY]...=
  private key: (hidden)
  listening port: 51820

peer: 7bXw...[REDACTED_PEER_PUBLIC_KEY]...=
  preshared key: (hidden)
  endpoint: 198.51.100.45:51820
  allowed ips: 10.200.50.2/32, 192.168.10.0/24
  latest handshake: 1 minute, 12 seconds ago
  transfer: 4.82 MiB received, 18.94 MiB sent
  persistent keepalive: every 25 seconds
```

---

## 5. Verification and Failure Diagnosis Guide

### 5.1 Diagnostic Decision Tree & Failure Scenarios

```
                          [ INCIDENT ALERT: SERVICE UNREACHABLE ]
                                             |
                                             v
                             +-------------------------------+
                             | Can host ping gateway/IP?     |
                             +-------------------------------+
                                    /                 \
                              (No) /                   \ (Yes)
                                  v                     v
                +-------------------+                 +--------------------------------+
                | Check Layer 1/2   |                 | Is port open via `ss -tulpn`?  |
                | (`ip link`, ARP)  |                 +--------------------------------+
                +-------------------+                        /                  \
                                                       (No) /                    \ (Yes)
                                                           v                      v
                                         +--------------------+        +--------------------+
                                         | Service crashed or |        | Check `nftables`   |
                                         | bound to 127.0.0.1 |        | packet drop log    |
                                         +--------------------+        +--------------------+
                                                                                  |
                                                                                  v
                                                                       +--------------------+
                                                                       | Check TLS & Proxy  |
                                                                       | logs (`journalctl`)|
                                                                       +--------------------+
```

### 5.2 Common Production Failures & Resolution Playbooks

#### Issue A: `conntrack` Table Exhaustion Dropping Valid Packets
* **Symptom:** Server drops incoming TCP connections randomly during traffic spikes; `dmesg` reports kernel error logs: `nf_conntrack: table full, dropping packet`.
* **Root Cause:** The kernel netfilter connection tracking table (`net.netfilter.nf_conntrack_max`) is undersized for current connection concurrency.
* **Diagnosis Commands:**
  ```bash
  $ sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
  ```
  ```text
  net.netfilter.nf_conntrack_count = 262144
  net.netfilter.nf_conntrack_max = 262144
  ```
* **Resolution:** Increase table size dynamically and tune hash buckets in `/etc/sysctl.d/99-netfilter.conf`:
  ```bash
  $ sudo sysctl -w net.netfilter.nf_conntrack_max=1048576
  $ echo "options nf_conntrack hashsize=262144" | sudo tee /etc/modprobe.d/conntrack.conf
  ```

#### Issue B: Service Fails to Bind Socket (`EADDRINUSE` or `EACCES`)
* **Symptom:** Application fails to start, throwing `PermissionDenied` or `Address already in use`.
* **Root Cause 1 (`EACCES`):** Non-root user attempting to bind to privileged port (< 1024) without `CAP_NET_BIND_SERVICE` or sysctl allowance.
* **Root Cause 2 (`EADDRINUSE`):** Existing orphan process lingering on the socket.
* **Diagnosis Commands:**
  ```bash
  $ sudo journalctl -u secure-api.service -n 20 --no-pager
  ```
  ```text
  Aug 07 00:48:01 edge-node-01 api-server[48210]: Error: Failed to bind socket to 0.0.0.0:443: Permission denied (os error 13)
  ```
* **Resolution:** Lower unprivileged port threshold or grant Linux capabilities:
  ```bash
  $ sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
  # Or via binary capability assignment:
  $ sudo setcap 'cap_net_bind_service=+ep' /opt/secure-api/bin/api-server
  ```

#### Issue C: Asymmetric Routing & Reverse Path Filtering Drops
* **Symptom:** Packets arrive over WireGuard (`wg0`) or secondary interface `eth1` but responses are dropped internally by the kernel.
* **Root Cause:** Strict Reverse Path Forwarding (`rp_filter`) drops packets whose egress route differs from ingress interface.
* **Diagnosis Commands:**
  ```bash
  $ sudo sysctl -a | grep rp_filter
  ```
  ```text
  net.ipv4.conf.all.rp_filter = 1
  net.ipv4.conf.eth1.rp_filter = 1
  ```
* **Resolution:** Set `rp_filter` to loose mode (`2`) on asymmetric interfaces:
  ```bash
  $ sudo sysctl -w net.ipv4.conf.all.rp_filter=2
  $ sudo sysctl -w net.ipv4.conf.eth1.rp_filter=2
  ```

---

## 6. References

* **LPI Security Essentials Official Overview:**  
  https://www.lpi.org/our-certifications/security-essentials-overview/
* **LPI Security Essentials Exam Objectives (020-100):**  
  https://wiki.lpi.org/wiki/Security_Essentials_Objectives_V1.0
* **Linux Kernel Netfilter & nftables Documentation:**  
  https://netfilter.org/projects/nftables/manpage.html
* **WireGuard Protocol & Architecture Specification:**  
  https://www.wireguard.com/papers/wireguard.pdf
* **Mozilla Web Security Guidelines & TLS Configuration Generator:**  
  https://wiki.mozilla.org/Security/Server_Side_TLS
* **Systemd Network & Security Capabilities (`systemd.exec`):**  
  https://www.freedesktop.org/software/systemd/man/systemd.exec.html