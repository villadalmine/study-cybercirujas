# LPIC-3 Exam 303-300 (v3.0) — Topic 5.1: Network Security
**Level:** Advanced Production / Senior Platform Architect & SRE Reference  
**Exam Weight:** 16.67 (Topic 334 equivalent)

---

## 1. Production Architectural Motivation & Problem Statement

Modern enterprise infrastructure faces complex security challenges: high-throughput perimeters, multi-tenant hybrid clouds, zero-trust network architectures (ZTNA), and lateral movement risks. Traditional edge-only security models (firewall at the perimeter, trusted internal network) fail when workloads are distributed across on-premises bare-metal, virtualized hypervisors, and multi-region Kubernetes clusters.

```
       +-----------------------------------------------------------------------------------+
       |                                   INGRESS EDGE                                    |
       |  [Internet] ---> [eBPF/XDP DDoS Filter] ---> [nftables Stateful Edge Firewall]  |
       +-----------------------------------------+-----------------------------------------+
                                                 |
                                                 v
       +-----------------------------------------------------------------------------------+
       |                            ENTERPRISE CORE INFRASTRUCTURE                         |
       |                                                                                   |
       |  +---------------------------+                +--------------------------------+  |
       |  |  802.1X Network Access    |                |  Intrusion Detection/Prevention|  |
       |  |  Control (FreeRADIUS/EAP) |                |  (Snort 3 Multi-threaded NIDS) |  |
       |  +-------------+-------------+                +---------------+----------------+  |
       |                |                                              |                   |
       |                v                                              v                   |
       |  +---------------------------+                +--------------------------------+  |
       |  |  Network Packet Analysis  |                |  Vulnerability Assessment      |  |
       |  |  (tcpdump / tshark / BPF) |                |  (Greenbone GVM / OpenVAS NASL)|  |
       |  +---------------------------+                +--------------------------------+  |
       +-----------------------------------------+-----------------------------------------+
                                                 |
                                                 v
       +-----------------------------------------------------------------------------------+
       |                       CLOUD-NATIVE / KUBERNETES DATA PLANE                        |
       |  [Cilium eBPF / L3-L7 NetworkPolicies] <---> [Microsegmentation & mTLS Enforcer] |
       +-----------------------------------------------------------------------------------+
```

### The Linux Kernel Data Plane Architecture

When an IP packet arrives at a Linux NIC, it traverses several kernel subsystems:

```
[Physical NIC] ---> [Driver NAPI RX] ---> [eBPF / XDP Hook] ---> [tc (traffic control)]
                                                                         |
                                                                         v
[ip_forward] <--- [nftables / netfilter] <--- [ip_rcv] <--- [dev_gro_receive / sk_buff]
     |                                                                   |
     v                                                                   v
[eGPU/NIC TX]                                                   [Socket Layer (L7 Application)]
```

1. **XDP (eXtensible Data Path):** Executes eBPF bytecode directly inside the NIC driver context before allocating a kernel socket buffer (`sk_buff`). Ideal for line-rate DDoS mitigation ($>100\text{M pps}$).
2. **Netfilter / nftables:** Evaluates hooks (`prerouting`, `input`, `forward`, `output`, `postrouting`). Standard stateful packet filtering mechanism utilizing connection tracking (`conntrack`).
3. **Socket Layer:** Delivers payload to userspace processes (e.g., FreeRADIUS, Snort, OpenVAS scanner).

### Architectural Trade-offs & Failure Modes
- **Conntrack Saturation:** High SYN floods can exhaust the Netfilter `nf_conntrack` table (`net.netfilter.nf_conntrack_max`), dropping legitimate connections before firewall rules execute.
- **Deep Packet Inspection (DPI) Bottlenecks:** Passing high-bandwidth traffic through userspace NIDS engines (Snort/Suricata) causes CPU `softirq` saturation and dropped packets unless ring buffers (`AF_PACKET` `TPACKET_V3`) or hardware offloading (PF_RING/DPDK) are configured.
- **Rogue L2 Infrastructure Services:** Unauthenticated switches or hypervisors can be compromised via Rogue DHCP Servers or Rogue IPv6 Router Advertisements (RAs), subverting default routing tables and enabling Man-In-The-Middle (MITM) inspection.

---

## 2. Technical Comparisons & Architecture Trade-Off Tables

### Table 2.1: Packet Filtering & Data Path Mechanisms

| Feature / Metric | `iptables` (Legacy) | `nftables` (Modern Standard) | `eBPF / XDP` (High-Perf Data Plane) |
| :--- | :--- | :--- | :--- |
| **Kernel Subsystem** | Netfilter hooks (separate tables per family: ip, ip6, arp, eb) | Single unified Netfilter VM engine (evaluates bytecode) | eBPF runtime in network driver (`XDP`) or `tc` hook |
| **Execution Context** | Sequential rule processing per hook (`sk_buff` allocated) | AST compiled to internal VM bytecode (`sk_buff` allocated) | Direct DMA buffer inspection *before* `sk_buff` memory allocation |
| **Performance (100GbE)** | Low ($< 5\text{M pps}$ per core under heavy rule sets) | Moderate ($10\text{M}-20\text{M pps}$ using sets & maps) | Extreme ($> 100\text{M pps}$ hardware drop rate) |
| **Stateful Tracking** | `xt_conntrack` module | Native `ct` state expressions | Requires custom eBPF maps (`BPF_MAP_TYPE_LRU_HASH`) |
| **Atomic Updates** | Non-atomic (full table replacement via `iptables-restore`) | Native atomic rule updates via single transaction API | Atomic map updates & live eBPF program swap via `bpf_prog_attach` |
| **L7 Inspection** | Limited (`string` matching, brittle) | Payload offset matching | eBPF + sockmap / Uretprobes (requires complex helper logic) |

### Table 2.2: Intrusion Detection & Prevention Engines (NIDS / NIPS)

| Metric | Snort 3 | Suricata | Zeek (formerly Bro) |
| :--- | :--- | :--- | :--- |
| **Architecture** | Single process, multi-threaded (`snort.lua` configuration) | Native multi-threaded (pipeline / auto-fp thread models) | Event-driven single-threaded core with multi-process cluster mode |
| **Detection Method** | Signature-based rule engine + Inspector plugins | Signature-based + PCRE2 + Lua scripting | Scriptable behavioral analysis & protocol logging engine |
| **Packet Acquisition** | `DAQ` (Data Acquisition Library: pcap, afpacket, dump, dpdk) | `AF_PACKET`, `PF_RING`, `NFQ`, `DPDK` | `libpcap`, `AF_PACKET`, `Myricom`, `PF_RING` |
| **File Extraction** | Native MIME / HTTP / SMB file inspection & hashing | Native file extraction + YARA engine integration | Native script-driven file extraction & hashing engine |
| **Hardware Offload** | Hyperscan regex engine (CPU SIMD acceleration) | Hyperscan regex + GPU offload support | Hyperscan support via plugins |

### Table 2.3: Network Access Control (NAC) & Authentication Paradigms

| Dimension | 802.1X / FreeRADIUS (EAP-TLS) | WireGuard / IPsec SASE | Service Mesh mTLS (SPIFFE/SPIRE) |
| :--- | :--- | :--- | :--- |
| **OSI Layer** | Layer 2 (Data Link - Port-based authentication) | Layer 3 (Network Overlay / Tunneling) | Layer 7 (Application Transport - TLS Proxy) |
| **Identity Anchor** | X.509 Device/User Client Certificate | Noise Protocol static keypair | Short-lived SVID X.509 Certificate |
| **Primary Domain** | Campus LAN, Enterprise Wi-Fi, Data Center Top-of-Rack | Remote Access, WAN Site-to-Site Tunnels | Microservice-to-Microservice East-West Traffic |
| **Enforcement Point** | Managed Switch Port / Wireless Access Point | Kernel Network Interface (`wg0`, `ipsec0`) | Envoy / Sidecar Proxy / eBPF socket kernel bypass |

---

## 3. Production Manifold Infrastructure & Manifest Configurations

### Listing 3.1: Production Dual-Stack `nftables.conf` Edge Firewall
`/etc/nftables.conf`

```nftables
#!/usr/sbin/nft -f

# Flush existing ruleset
flush ruleset

# Define network interface variables
define WAN_IF = "eth0"
define LAN_IF = "eth1"
define MANAGEMENT_NETS = { 10.100.0.0/24, 192.168.50.0/24 }
define RADIUS_SERVERS = { 10.100.0.10, 10.100.0.11 }

table inet filter {
    # Dynamic set for auto-banned IP addresses (DDoS / Brute-force)
    set dynamic_blacklist {
        type ipv4_addr
        flags timeout
    }

    # Flowtable for hardware/software fast-path offloading
    flowtable fastpath {
        hook ingress priority 0
        devices = { $WAN_IF, $LAN_IF }
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # Drop invalid connections immediately
        ct state invalid drop comment "Drop invalid conntrack states"

        # Drop packets from dynamic blacklist
        ip saddr @dynamic_blacklist drop comment "Drop blacklisted IPs"

        # Allow loopback traffic
        iifname "lo" accept comment "Allow loopback"

        # Allow established and related connections
        ct state { established, related } accept comment "Allow tracked connections"

        # Rate limit ICMP / ICMPv6 to prevent ping floods
        ip protocol icmp icmp type echo-request limit rate 10/second accept
        ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } limit rate 20/second accept

        # Protect against TCP SYN Floods (add to blacklist if >50 conn/sec)
        tcp flags syn tcp dport { 80, 443, 22 } meter syn_limit { ip saddr limit rate over 50/second } add @dynamic_blacklist { ip saddr timeout 1h } drop

        # Allow SSH only from authorized management subnets with rate limiting
        ip saddr $MANAGEMENT_NETS tcp dport 22 ct state new limit rate 5/minute accept comment "Management SSH"

        # Allow RADIUS Authentication & Accounting from authorized NAS devices
        ip saddr $MANAGEMENT_NETS udp dport { 1812, 1813 } accept comment "RADIUS Authentication/Accounting"

        # Log and drop everything else
        log prefix "NFT_INPUT_DROP: " flags all counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        # Fastpath offload for established streams
        ip protocol { tcp, udp } flow offload @fastpath

        # Allow LAN to WAN egress forwarding
        iifname $LAN_IF oifname $WAN_IF accept comment "LAN Egress"
        iifname $WAN_IF oifname $LAN_IF ct state { established, related } accept comment "WAN Ingress Return"
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
```

---

### Listing 3.2: Complete Multi-Threaded Snort 3 Configuration
`/etc/snort/snort.lua`

```lua
-- Snort 3 Production Configuration
HOME_NET = '10.100.0.0/16'
EXTERNAL_NET = '!$HOME_NET'

-- Define paths
RULE_PATH = '/etc/snort/rules'
BUILTIN_RULE_PATH = '/etc/snort/builtin_rules'
PLUGIN_INPUT_PATH = '/usr/local/lib/snort_extra'

-- System configurations
process =
{
    chroot = '/var/log/snort',
    set_gid = 'snort',
    set_uid = 'snort',
    daemon = false,
}

thread_config =
{
    max_threads = 8,
}

-- High-performance Packet Acquisition (DAQ) via AF_PACKET
daq =
{
    module = 'afpacket',
    mode = 'inline',
    variables =
    {
        'buffer_size_mb=1024',
    }
}

-- Network Inspection Modules
stream = { }
stream_tcp =
{
    max_window = 65535,
    overlap_limit = 10,
    session_timeout = 30,
    policy = 'linux'
}

stream_udp =
{
    session_timeout = 30
}

-- Hyperscan Regex Engine Setup
search_engine =
{
    search_method = 'hyperscan',
    split_any = true
}

-- Active response configuration for NIPS mode
active =
{
    attempts = 5,
    device = 'eth0'
}

-- Alert outputs
alert_fast =
{
    file = true,
    limit = 100,
}

alert_json =
{
    file = true,
    limit = 500,
    fields = 'timestamp pkt_num proto src_addr src_port dst_addr dst_port action msg rule'
}

-- Rules configuration
ips =
{
    enable_builtin_rules = true,
    include = RULE_PATH .. '/local.rules'
}
```

#### Associated Custom Rules File: `/etc/snort/rules/local.rules`
```snort
# Rule 1: Detect Rogue RA (Router Advertisements) - ICMPv6 Type 134
drop icmp6 external_net any -> $HOME_NET any (msg:"NIDS ALERT: Rogue IPv6 Router Advertisement Detected"; ip6_hdrs:type 134; classtype:bad-traffic; sid:1000001; rev:1;)

# Rule 2: Detect Unauthorized RADIUS Access Attempt
alert udp external_net any -> $HOME_NET 1812 (msg:"NIDS ALERT: External RADIUS Authentication Attempt"; content:"|01|", depth 1; offset 0; classtype:unauthorized-login; sid:1000002; rev:1;)

# Rule 3: Detect TCP SYN Flood targeting internal microservices
drop tcp external_net any -> $HOME_NET 443 (msg:"NIPS ACTION: TCP SYN Flood Protection"; flags:S; threshold: type threshold, track by_src, count 100, seconds 1; classtype:attempted-dos; sid:1000003; rev:1;)
```

---

### Listing 3.3: Enterprise FreeRADIUS 3.x 802.1X EAP-TLS Server Configuration

#### Primary Server Config: `/etc/freeradius/3.0/radiusd.conf`
```radius
prefix = /usr
exec_prefix = ${prefix}
sysconfdir = /etc
localstatedir = /var
sbindir = ${exec_prefix}/sbin
logdir = ${localstatedir}/log/freeradius
raddbdir = ${sysconfdir}/freeradius/3.0
radacctdir = ${logdir}/radacct

name = radiusd

confdir = ${raddbdir}
modconfdir = ${confdir}/mods-config
certdir = ${confdir}/certs
cadir   = ${confdir}/certs

libdir = /usr/lib/freeradius

pidfile = ${localstatedir}/run/radiusd/radiusd.pid

correct_escapes = true
max_request_time = 30
cleanup_delay = 5
max_requests = 16384

log {
    destination = files
    colourise = yes
    file = ${logdir}/radius.log
    syslog_facility = daemon
    stripped_names = no
    auth = yes
    auth_badpass = yes
    auth_goodpass = no
}

checkrad = ${sbindir}/checkrad

security {
    user = radius
    group = radius
    allow_core_dumps = no
    max_attributes = 200
    reject_delay = 1
    status_server = yes
}

proxy_requests = no

$INCLUDE clients.conf
$INCLUDE modules/
$INCLUDE sites-enabled/
```

#### Clients Configuration: `/etc/freeradius/3.0/clients.conf`
```radius
client enterprise_switches {
    ipaddr = 10.100.0.0/24
    secret = SharedSuperSecretKey2026!
    shortname = core-switches
    nas_type = cisco
}

client wireless_controllers {
    ipaddr = 10.100.5.10
    secret = SharedWlcSecretKey2026!
    shortname = enterprise-wlc
}
```

#### EAP Module Config: `/etc/freeradius/3.0/mods-available/eap`
```radius
eap {
    default_eap_type = tls
    timer_expire = 60
    ignore_unknown_eap_types = no
    cisco_accounting_username = no
    max_sessions = ${max_requests}

    tls-config tls-common {
        private_key_password = CertificatePassword2026
        private_key_file = ${certdir}/server.key
        certificate_file = ${certdir}/server.pem
        ca_file = ${cadir}/ca.pem
        dh_file = ${certdir}/dh
        cipher_list = "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
        cipher_server_preference = yes
        ecdh_curve = "prime256v1"

        tls_min_version = "1.2"
        tls_max_version = "1.3"

        check_crl = yes
        crl_file = ${certdir}/crl.pem

        check_cert_cn = yes
    }

    tls {
        tls = tls-common
        make_cert_command = "${certdir}/bootstrap"
    }
}
```

---

### Listing 3.4: Complete Custom OpenVAS / Greenbone NASL Script
`/var/lib/openvas/plugins/custom_tls_check.nasl`

```nasl
# Complete OpenVAS NASL Script for TLS Configuration Enforcement
if(description)
{
    script_oid("1.3.6.1.4.1.99999.1.1");
    script_version("1.0");
    script_tag(name:"last_modification", value:"2026-08-06 00:00:00 +0000");
    script_tag(name:"creation_date", value:"2026-08-06 00:00:00 +0000");
    script_tag(name:"cvss_base", value:"7.5");
    script_tag(name:"cvss_base_vector", value:"AV:N/AC:L/Au:N/C:P/I:P/A:N");
    script_name(English:"Custom Corporate Audit: Weak TLS Version Enforcement");
    script_category(ACT_GATHER_INFO);
    script_family("General");
    script_copyright(English:"Production SRE Security Team");
    script_dependencies("find_service.nasl", "ssl_supported_versions.nasl");
    script_require_ports("Services/www", 443, 8443, 1812);

    script_tag(name:"summary", value:"Checks if target endpoints enforce minimum TLS 1.2/1.3 standards.");
    script_tag(name:"solution", value:"Disable TLS 1.0, TLS 1.1, and SSLv3 in the service configuration file.");
    script_tag(name:"qod_type", value:"remote_app");

    exit(0);
}

include("ssl_funcs.inc");
include("misc_func.inc");

port = get_kb_item("Services/www");
if(!port) port = 443;

if(!get_port_state(port)) exit(0);

soc = open_sock_tcp(port);
if(!soc) exit(0);

# Attempt TLS 1.0 Handshake (Deprecated)
ssl_version = SSL_v3;
hello = ssl_hello(version:ssl_version);
send(socket:soc, data:hello);
res = recv_ssl(socket:soc);
close(soc);

if(!isnull(res) && ssl_verify_server_hello(data:res))
{
    security_message(
        port: port,
        data: "SECURITY VIOLATION: The remote service accepts deprecated TLS 1.0 / SSLv3 connections."
    );
    exit(0);
}

exit(0);
```

---

### Listing 3.5: Cloud-Native Kubernetes NetworkPolicy (Cilium L3/L4/L7 Enforcement)
`cilium-network-policy.yaml`

```yaml
apiVersion: "cilium.io/2.2"
kind: CiliumNetworkPolicy
metadata:
  name: enforce-secure-radius-and-ingress
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: radius-authentication-node
  ingress:
  - fromEndpoints:
    - matchLabels:
        role: network-access-server
    toPorts:
    - ports:
      - port: "1812"
        protocol: UDP
      - port: "1813"
        protocol: UDP
  egress:
  - toEndpoints:
    - matchLabels:
        app: enterprise-db
    toPorts:
    - ports:
      - port: "5432"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/api/v1/auth/verify"
  - toCIDRSet:
    - cidr: 10.100.0.0/16
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
      rules:
        dns:
        - matchPattern: "*.internal.enterprise.domain"
```

---

## 4. Real CLI Commands & Terminal Output Logs ($ Prompt)

### Command 4.1: Inspecting Live Traffic with `tcpdump` (BPF Filtering)

```bash
$ sudo tcpdump -nn -vvv -i eth0 'ip proto 17 and (port 1812 or port 1813)' -c 2
```

```text
tcpdump: listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
13:42:01.102391 IP (tos 0x0, ttl 64, id 45210, offset 0, flags [DF], proto UDP (17), length 114)
    10.100.0.50.41203 > 10.100.0.10.1812: RADIUS, length 86
	Access-Request (1), id: 0x4f, Authenticator: 7e9b21a8f9104c88a1b2c3d4e5f60718
	  User-Name Attribute (1), length: 14, Value: 'sre_admin'
	  NAS-IP-Address Attribute (4), length: 6, Value: 10.100.0.50
	  NAS-Port Attribute (5), length: 6, Value: 50102
	  EAP-Message Attribute (79), length: 20, Value: \002\001\000\020\001sre_admin
	  Message-Authenticator Attribute (80), length: 18, Value: 0x9f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c
13:42:01.105822 IP (tos 0x0, ttl 64, id 11029, offset 0, flags [DF], proto UDP (17), length 68)
    10.100.0.10.1812 > 10.100.0.50.41203: RADIUS, length 40
	Access-Challenge (11), id: 0x4f, Authenticator: a1b2c3d4e5f607187e9b21a8f9104c88
	  EAP-Message Attribute (79), length: 8, Value: \001\002\000\006\013\001
	  Message-Authenticator Attribute (80), length: 18, Value: 0x1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d

2 packets captured
2 packets received by filter
0 packets dropped by kernel
```

---

### Command 4.2: FreeRADIUS 802.1X Authentication Verification via `radtest`

```bash
$ radtest -t eap-md5 sre_admin SecretPassword2026 127.0.0.1 1812 SharedSuperSecretKey2026!
```

```text
Sending Access-Request of id 181 to 127.0.0.1 port 1812
	User-Name = "sre_admin"
	User-Password = "SecretPassword2026"
	NAS-IP-Address = 127.0.0.1
	NAS-Port = 1812
	Message-Authenticator = 0x00000000000000000000000000000000
	EAP-Message = 0x0200000e017372655f61646d696e
Received Access-Accept Id 181 from 127.0.0.1:1812 length 48
	Framed-IP-Address = 10.100.10.250
	Framed-IP-Netmask = 255.255.255.0
	Reply-Message = "Welcome SRE Administrator. EAP Authentication Successful."
```

---

### Command 4.3: Testing Snort 3 Rules Engine & Packet Parsing

```bash
$ sudo snort -c /etc/snort/snort.lua -r /var/log/captures/malicious_ra.pcap -A alert_fast --pcap-filter "icmp6"
```

```text
--------------------------------------------------
o")~   Snort++ 3.1.72.0
--------------------------------------------------
Loading /etc/snort/snort.lua:
  Loading snort.lua...
  Loading pcap module...
  Finished snort.lua.
Appid: Loaded 3520 AppID detectors.
--------------------------------------------------
pcap DAQ configured to read-file /var/log/captures/malicious_ra.pcap
Commencing packet processing
++ [0] /var/log/captures/malicious_ra.pcap
08/06-13:45:12.802112 [**] [1000001:1] NIDS ALERT: Rogue IPv6 Router Advertisement Detected [**] [Priority: 0] {ICMP6} fe80::bad:cafe:1 -> ff02::1

===============================================================================
Run summary:
  Time:     00:00:00.031201 seconds
  Packets:  1
  Processed: 1
  Received: 1
===============================================================================
Packet statistics:
  Acquired: 1
  Analyzed: 1
  Dropped:  1 (Inline IPS Action)
===============================================================================
Snort successfully validated packet against AST rules engine.
```

---

### Command 4.4: Inspecting `nftables` Ruleset & Dynamic Blacklist Metrics

```bash
$ sudo nft list set inet filter dynamic_blacklist
```

```text
table inet filter {
	set dynamic_blacklist {
		type ipv4_addr
		flags timeout
		elements = { 198.51.100.45 expires 42m12s,
			     203.0.113.119 expires 11m05s }
	}
}
```

```bash
$ sudo nft list chain inet filter input
```

```text
table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state invalid drop comment "Drop invalid conntrack states"
		ip saddr @dynamic_blacklist drop comment "Drop blacklisted IPs"
		iifname "lo" accept comment "Allow loopback"
		ct state { established, related } accept comment "Allow tracked connections"
		ip protocol icmp icmp type echo-request limit rate 10/second accept
		ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } limit rate 20/second accept
		tcp flags syn tcp dport { 80, 443, 22 } meter syn_limit { ip saddr limit rate over 50/second } add @dynamic_blacklist { ip saddr timeout 1h } drop packets 1420 bytes 85200
		ip saddr { 10.100.0.0/24, 192.168.50.0/24 } tcp dport 22 ct state new limit rate 5/minute accept comment "Management SSH"
		ip saddr { 10.100.0.0/24, 192.168.50.0/24 } udp dport { 1812, 1813 } accept comment "RADIUS Authentication/Accounting"
		log prefix "NFT_INPUT_DROP: " flags all counter packets 4821 bytes 289260 drop
	}
}
```

---

### Command 4.5: Executing OpenVAS/GVM Scan via `gvm-cli`

```bash
$ gvm-cli --gmp-username admin --gmp-password StrongAdminPass tls --hostname 127.0.0.1 -X '<create_task name="Production Edge Security Audit" config_id="daba56c8-73ec-11df-a475-002264764cea" target_id="a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"/>'
```

```xml
<create_task_response status="201" status_text="OK, task created">
  <id>f81d4fae-7dec-11d0-a765-00a0c91e6bf6</id>
</create_task_response>
```

```bash
$ gvm-cli --gmp-username admin --gmp-password StrongAdminPass tls --hostname 127.0.0.1 -X '<start_task task_id="f81d4fae-7dec-11d0-a765-00a0c91e6bf6"/>'
```

```xml
<start_task_response status="202" status_text="OK, request submitted">
  <report_id>c4b3a2a1-9876-5432-10fe-dcba98765432</report_id>
</start_task_response>
```

---

## 5. Fault Verification & Diagnostic Guide

```
                            +-------------------------------------+
                            |    NETWORK SECURITY TROUBLESHOOTING |
                            +------------------+------------------+
                                               |
              +--------------------------------+--------------------------------+
              |                                                                 |
              v                                                                 v
+---------------------------+                                     +---------------------------+
| 802.1X / EAP-TLS FAILURE  |                                     |  SNORT 3 PACKET DROPS     |
+-------------+-------------+                                     +-------------+-------------+
              |                                                                 |
   [Check Certificate Chain]                                            [Inspect DAQ Ring Buffer]
   [Verify EAP Fragment Size]                                           [Verify CPU SoftIRQ Load]
              |                                                                 |
              v                                                                 v
+---------------------------+                                     +---------------------------+
|  Diagnose: radiusd -X     |                                     | Diagnose: ethtool -S eth0 |
+---------------------------+                                     +---------------------------+
```

### Problem 1: FreeRADIUS EAP-TLS Authentication Failure

#### Symptoms
Client devices (laptops, IoT nodes) fail 802.1X authentication when connecting to edge switches or wireless networks. Radius server logs show generic `Access-Reject` or EAP handshake timeouts.

#### Root Cause Analysis
1. **Certificate Chain Breakdown:** The RADIUS server fails to validate the client certificate because the Intermediate Certificate Authority (CA) bundle is missing from `ca_file`.
2. **MTU / EAP Fragmentation Issue:** EAP-TLS certificate payloads exceed the network MTU ($1500\text{ bytes}$), causing RADIUS UDP packets to be fragmented. Firewalls or switches drop IP fragments.

#### Diagnostic Workflow
Run FreeRADIUS in foreground debugging mode (`-X`):

```bash
$ sudo radiusd -X -l /dev/stdout
```

Look for explicit OpenSSL error traces:
```text
(0) tls: TLS_accept: Fail in SSLv3/TLS read client certificate
(0) tls: Certificate line 12 at depth:1 verify error:unable to get local issuer certificate
(0) ERROR: (0) EAP-TLS Handshake Failed
```

#### Remediation Commands
Update `/etc/freeradius/3.0/mods-available/eap` to point to a consolidated CA chain file containing both Root and Intermediate CAs:
```bash
$ cat /etc/ssl/certs/RootCA.pem /etc/ssl/certs/IntermediateCA.pem > /etc/freeradius/3.0/certs/ca_chain.pem
```

Adjust maximum EAP message size in `/etc/freeradius/3.0/mods-available/eap`:
```radius
tls-config tls-common {
    fragment_size = 1260
}
```

---

### Problem 2: Snort 3 Packet Loss Under High Network Traffic Load

#### Symptoms
Network Interface reports drops, and Snort logs display missed alerts during high throughput ($>10\text{ Gbps}$).

#### Root Cause Analysis
1. **Ring Buffer Overflow:** The Linux kernel socket receive buffer (`rmem_default`, `rmem_max`) or `afpacket` DAQ ring buffer is under-provisioned for bursty traffic.
2. **Single CPU Core Bottleneck:** Snort is bound to a single thread, causing `softirq` handling on `CPU0` to saturate at 100%.

#### Diagnostic Workflow
Check physical interface drop counters:
```bash
$ ethtool -S eth0 | grep -E "drop|fifo|missed"
```
```text
     rx_dropped: 120492
     rx_fifo_errors: 412
     rx_missed_errors: 120080
```

Check CPU IRQ distribution:
```bash
$ mpstat -P ALL 1 3
```
```text
13:50:01 CPU  %usr  %nice  %sys  %iowait  %irq  %soft  %idle
13:50:02   0  2.00   0.00  5.00     0.00  0.00  93.00   0.00  <-- SOFTIRQ SATURATION
13:50:02   1  0.00   0.00  1.00     0.00  0.00   1.00  98.00
```

#### Remediation Commands
1. Increase Linux kernel network socket buffers:
```bash
$ sudo sysctl -w net.core.rmem_max=134217728
$ sudo sysctl -w net.core.rmem_default=67108864
$ sudo sysctl -w net.core.netdev_max_backlog=100000
```

2. Configure Receive Side Scaling (RSS) and multi-threaded `afpacket` in `/etc/snort/snort.lua`:
```lua
thread_config =
{
    max_threads = 8,
}
daq =
{
    module = 'afpacket',
    mode = 'inline',
    variables =
    {
        'fanout_type=hash',
        'buffer_size_mb=2048',
    }
}
```

---

### Problem 3: Asymmetric Routing Causing `nftables` Connection Tracking Drops

#### Symptoms
Legitimate inbound traffic is dropped by `nftables` with log message `NFT_INPUT_DROP: ct state invalid`.

#### Root Cause Analysis
In a dual-homed or multi-path network, request packets arrive via `eth0`, but return packets leave via `eth1`. Netfilter on `eth0` sees out-of-order TCP state transitions, marking legitimate packets as `invalid`.

#### Diagnostic Workflow
Monitor Netfilter conntrack events live:
```bash
$ sudo conntrack -E -p tcp --state INVALID
```
```text
 [UPDATE] 10.100.0.50 -> 192.168.1.100 tcp dport=443 [UNACKNOWLEDGED] [stat=INVALID]
```

Inspect strict TCP window tracking in the kernel:
```bash
$ sysctl net.netfilter.nf_conntrack_tcp_be_liberal
```
```text
net.netfilter.nf_conntrack_tcp_be_liberal = 0
```

#### Remediation Commands
Enable liberal TCP tracking in kernel to bypass out-of-window asymmetric drops:
```bash
$ sudo sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1
```
Or update `nftables.conf` to handle asymmetric flow paths explicitly without dropping invalid states on internal interfaces:
```nftables
chain input {
    iifname "eth1" tcp flags != syn accept comment "Allow asymmetric mid-stream TCP traffic"
}
```

---

### Problem 4: Rogue IPv6 Router Advertisements (RAs) Causing Man-In-The-Middle (MITM)

#### Symptoms
Hosts on the local network dynamically re-assign their IPv6 default gateway to an untrusted IPv6 link-local address (`fe80::bad:cafe:1`), redirecting all egress traffic through an attacker node.

#### Root Cause Analysis
An unauthorized or compromised device on the Layer 2 domain is broadcasting ICMPv6 Type 134 (Router Advertisement) packets with a high router preference score.

#### Diagnostic Workflow
Monitor for ICMPv6 RA messages using `tshark`:
```bash
$ sudo tshark -i eth0 -Y "icmpv6.type == 134" -T fields -e frame.time -e ipv6.src -e icmpv6.ra.router_lifetime
```
```text
2026-08-06 13:55:01.102931  fe80::bad:cafe:1  1800
```

#### Remediation Commands
1. Block Rogue RAs on Linux host using kernel sysctl settings:
```bash
# Disable IPv6 RA acceptance on multi-homed routers
$ sudo sysctl -w net.ipv6.conf.all.accept_ra=0
$ sudo sysctl -w net.ipv6.conf.default.accept_ra=0
```

2. Enforce eBPF/XDP drop rule or `nftables` raw drop rule for unapproved IPv6 source link-local addresses:
```bash
$ sudo nft add rule inet filter input ip6 nexthdr icmpv6 icmpv6 type nd-router-advert ip6 saddr != fe80::1:1 drop
```

---

## 6. References

- **Linux Professional Institute (LPI) Official LPIC-3 303 Objectives (v3.0):**  
  [https://wiki.lpi.org/wiki/LPIC-303_Objectives_V3.0](https://wiki.lpi.org/wiki/LPIC-303_Objectives_V3.0)
- **Linux Professional Institute LPIC-3 Security Certification Overview:**  
  [https://www.lpi.org/our-certifications/lpic-3-303-overview/](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
- **nftables Official Documentation & Rule Wiki:**  
  [https://wiki.nftables.org/wiki-nftables/index.php/Main_Page](https://wiki.nftables.org/wiki-nftables/index.php/Main_Page)
- **Snort 3 Manual & Lua Configuration Architecture:**  
  [https://docs.snort.org/](https://docs.snort.org/)
- **FreeRADIUS 3.0 Documentation & EAP Configuration Guide:**  
  [https://freeradius.org/documentation/](https://freeradius.org/documentation/)
- **Greenbone Vulnerability Management (GVM / OpenVAS) Architecture:**  
  [https://greenbone.github.io/docs/gvm-architecture/](https://greenbone.github.io/docs/gvm-architecture/)
- **Wireshark & tcpdump BPF Filter Syntax Reference:**  
  [https://www.tcpdump.org/manpages/pcap-filter.7.html](https://www.tcpdump.org/manpages/pcap-filter.7.html)
- **Cilium eBPF Cloud-Native Network Policy Specification:**  
  [https://docs.cilium.io/en/stable/policy/language/](https://docs.cilium.io/en/stable/policy/language/)