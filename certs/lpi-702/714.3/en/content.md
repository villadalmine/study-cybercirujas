# LPI-702 (Exam 702-100) | Topic 714.3: Basic Network Troubleshooting

## 1. Production Architectural Motivation & Real-World Failures

In mission-critical enterprise environments—ranging from FreeBSD-based high-throughput storage systems (e.g., TrueNAS enterprise SANs) and OpenBSD edge firewalls/routers (PF appliances) to NetBSD embedded network appliances—network reliability is the primary structural requirement. Network anomalies directly impact distributed application stability, service-level objectives (SLOs), and data integrity.

Troubleshooting BSD networking at a Senior SRE or Platform Architect level requires moving beyond simple connectivity tests (`ping`). Architects must diagnose complex failure modes originating at the kernel driver layer, the socket buffer memory subsystem (`mbufs`), interface routing tables, packet filter rule evaluations, and dual-stack protocol translations.

```
+-----------------------------------------------------------------------------------+
|                              User Space Application                               |
|                     (e.g., NGINX, BGP daemon, PostgreSQL)                         |
+-----------------------------------------------------------------------------------+
                                         |
                            BSD Socket Layer (sys/kern)
                 [sockstat / fstat / netstat / sysctl socket limits]
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                              BSD Network Stack (INET/INET6)                       |
|  - Routing Table Engine (radix tree / route get)                                  |
|  - Neighbor Cache (ARP / NDP tables)                                              |
|  - Packet Filter Subsystem (PF / pflog / pfctl)                                   |
|  - Socket Buffer Management (mbuf chains / sysctl kern.ipc.mbuf)                  |
+-----------------------------------------------------------------------------------+
                                         |
                            Network Interface Controller (NIC)
                      [ifconfig / media status / link flags / MTU]
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                               Physical / Virtual Wire                             |
+-----------------------------------------------------------------------------------+
```

### Critical Production Failure Scenarios

1. **Path MTU Discovery (PMTUD) Black-Holes**:
   - **Root Cause**: When outer encap headers (GRE, IPsec, VXLAN, WireGuard) lower the effective Maximum Segment Size (MSS), packets exceeding the interface MTU require fragmentation. If upstream routers or internal Packet Filters (`pf`) drop ICMP Type 3 Code 4 (`Fragmentation Needed and DF Bit Set`) or ICMPv6 Type 2 (`Packet Too Big`) messages, TCP connections hang during the TLS handshake or bulk payload transfers.
   - **Impact**: TCP SYN/ACK completes successfully, but HTTP POST requests or database queries freeze indefinitely.

2. **BSD Socket Buffer & Ephemeral Port Exhaustion**:
   - **Root Cause**: High-concurrency microservices or edge proxies deplete available ephemeral ports in `net.inet.ip.portrange.first` to `net.inet.ip.portrange.last`, or exhaust system `mbuf` clusters (`kern.ipc.nmbclusters`).
   - **Impact**: Applications trigger `EADDRNOTAVAIL` (Can't assign requested address) or kernel syslog emits `kern.ipc.nmbclusters limit reached`, causing socket creation calls to fail system-wide.

3. **Asymmetric Egress Routing & Stateful PF Drop**:
   - **Root Cause**: Dual-homed systems or multi-homed BGP speakers send egress packets out interface `em1` while incoming ingress packets return via interface `em0`. Stateful firewalls (`pf`) track TCP state sequences bound to specific interfaces unless explicit multi-interface floating state rules (`keep state`) are enforced.
   - **Impact**: Ingress packets are silently dropped by `pf` due to state sequence validation errors, emitting `state-mismatch` counters in `pfctl -s info`.

4. **Silent ARP / NDP Stale Neighbor Black-holing**:
   - **Root Cause**: Virtualized environments (vMotion, CARP failover, AWS ENI re-attachments) fail to flush or update neighbor caches. BSD ARP/NDP tables maintain stale MAC address mappings for unreachable IPs.
   - **Impact**: L3 IP routing works, but L2 frames are encapsulated with obsolete destination MACs, dropping egress traffic at the switch port.

---

## 2. Technical Comparisons & Trade-off Matrix

Understanding the operational boundaries, performance overhead, and OS-specific behavior of BSD diagnostic tools is mandatory for rapid incident response.

### BSD Network Diagnostic Utilities Comparison

| Utility | OSI Layer | OS Availability | Inspection Target | Overhead | Primary Use Case | SRE Operational Trade-off |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `ifconfig` | Layer 1 / 2 / 3 | FreeBSD, OpenBSD, NetBSD | NIC state, IP/IPv6, MTU, Media flags | Low | Interface configuration & PHY diagnostics | Cannot view socket layer states; requires root for changes. |
| `sockstat` | Layer 4 | FreeBSD, NetBSD | Active TCP/UDP sockets, PIDs, file descriptors | Low to Medium | Local socket-to-process mapping | FreeBSD native; not available in vanilla OpenBSD (use `fstat` or `netstat -lnp`). |
| `fstat` | Layer 4 / VFS | OpenBSD, NetBSD, FreeBSD | Open file descriptors including network sockets | Medium | Process socket association in OpenBSD | Output requires manual correlation of socket endpoints; heavier memory footprint than `sockstat`. |
| `netstat` | Layer 3 / 4 | All BSDs | Routing tables (`-r`), interface stats (`-i`), socket states (`-a`) | Low | Protocol counters, routing radix trees | Heavy output on high-concurrency servers (`netstat -an` can freeze terminals with 500k connections). |
| `route` | Layer 3 | All BSDs | Routing table manipulation & lookup queries (`route get`) | Low | Path decision simulation & gateway resolution | `route get` simulates kernel L3 lookup without generating network packets. |
| `ping` / `ping6` | Layer 3 | All BSDs | L3 ICMP Echo Request / Reply reachability | Low | IPv4/IPv6 end-to-end path testing | Frequently blocked by firewalls; ping success does not guarantee L4 TCP service availability. |
| `traceroute` / `traceroute6` | Layer 3 | All BSDs | Hop-by-hop L3 path discovery via TTL expiration | Medium | Identifying upstream router drops & latency spikes | Defaults to UDP in BSD (`traceroute`), unlike Linux which can default to ICMP. Use `-I` for ICMP mode. |
| `nc` (Netcat) | Layer 4 / 7 | All BSDs | L4 TCP/UDP port scanning and raw payload probing | Low | Verifying listener responsiveness & firewall passes | OpenBSD `nc` supports TLS (`-e`), UNIX sockets (`-U`), and zero-I/O port checking (`-z`). |
| `tcpdump` | Layer 2 - 7 | All BSDs | Raw packet capture via BPF (`/dev/bpf*`) | High | Microsecond-level frame analysis & protocol decoding | High CPU/memory overhead under high packet rates; must use restrictive BPF filter expressions. |

### Socket Resolution Mechanisms Across BSD Variants

```
FreeBSD:   [Process PID] <---> sockstat -46 -l -p <---> Kernel Socket Struct <---> mbuf
OpenBSD:   [Process PID] <---> fstat -p <PID>     <---> File Descriptor (Internet) <---> Netstat PCB
NetBSD:    [Process PID] <---> sockstat / fstat   <---> Socket Control Block <---> mbuf
```

---

## 3. Production Configuration Manifests & Declarative Infrastructure

Below are fully valid, production-grade configuration files illustrating networking parameters, static routing, VLAN tagging, dual-stack IPv4/IPv6, and diagnostic logging filters.

### A. FreeBSD Enterprise Networking (`/etc/rc.conf`)

```sh
# System Hostname & Dual-Stack Network Setup
hostname="app-gateway-01.production.internal"

# Physical Interface Configuration (em0 - Primary WAN)
ifconfig_em0="inet 192.168.10.50 netmask 255.255.255.0 mtu 1500 description 'Primary WAN Egress'"
ifconfig_em0_ipv6="inet6 2001:db8:1000::50 prefixlen 64 auto_linklocal"

# Virtual LAN Configuration (802.1Q tagging on em1)
cloned_interfaces="vlan100 vlan200"
ifconfig_em1="up description 'Trunk Core Switch'"
ifconfig_vlan100="vlan 100 vlandev em1 inet 10.100.0.1/24 description 'App Subnet'"
ifconfig_vlan200="vlan 200 vlandev em1 inet 10.200.0.1/24 description 'Database Subnet'"

# Default Gateways (IPv4 and IPv6)
defaultrouter="192.168.10.1"
ipv6_defaultrouter="2001:db8:1000::1"

# Static Routing for Internal Data Center Subnets
static_routes="internal_dc management"
route_internal_dc="-net 10.0.0.0/8 10.100.0.254"
route_management="-net 172.16.0.0/12 10.100.0.253"

# Enable Network Packet Filtering (PF) & Logging
pf_enable="YES"
pf_rules="/etc/pf.conf"
pflog_enable="YES"
pflog_logfile="/var/log/pflog"

# Network Performance & Diagnostic System Tuning
icmp_drop_redirect="YES"
icmp_log_redirect="YES"
```

### B. OpenBSD Declarative Interface Configuration (`/etc/hostname.em0`)

```sh
# Primary Dual-Stack Interface with Jumbo Frames for Storage Network
inet 192.168.50.10 255.255.255.0 192.168.50.255 mtu 9000 description "Storage Backbone"
inet6 2001:db8:5000::10 64
up
```

### C. OpenBSD Gateway Route Configuration (`/etc/mygate`)

```sh
192.168.50.1
2001:db8:5000::1
```

### D. Production Packet Filter Diagnostic Rules (`/etc/pf.conf`)

```pf
# Global Interfaces & Macros
ext_if = "em0"
int_if = "vlan100"
icmp_types = "{ echoreq, unreach, timex }"
icmp6_types = "{ echoreq, unreach, timex, toobig, neighbrsol, neighbradvet }"

# System Options & State Limits for High Concurrency
set skip on lo0
set block-policy drop
set loginterface $ext_if
set limit states 100000
set limit src-nodes 50000

# Optimization & Reassembly
scrub in on $ext_if all fragment reassemble max-mss 1440

# Tables for Dynamic Blacklisting
table <bruteforce> persist

# Default Block Rule with Diagnostic Logging
block log all

# Block Malicious Hosts
block drop in quick on $ext_if from <bruteforce>

# Allow Ingress ICMP/ICMPv6 Essential for PMTUD & Neighbor Discovery
pass in quick on $ext_if inet proto icmp all icmp-type $icmp_types keep state
pass in quick on $ext_if inet6 proto icmp6 all icmp6-type $icmp6_types keep state

# Ingress Services (HTTP/HTTPS/SSH) with Connection Rate Limiting
pass in quick on $ext_if proto tcp to port { 80, 443 } flags S/SA keep state \
    (max-src-conn 100, max-src-conn-rate 50/5, overload <bruteforce> flush global)

pass in quick on $ext_if proto tcp to port 22 flags S/SA keep state \
    (max-src-conn 10, max-src-conn-rate 5/60, overload <bruteforce> flush global)

# Egress Traffic Filtering & State Tracking
pass out quick on $ext_if proto { tcp, udp, icmp } all flags S/SA keep state
pass out quick on $ext_if proto ipv6-icmp all keep state
```

### E. BSD Kernel Diagnostic & Network Stack Tuning (`/etc/sysctl.conf`)

```ini
# Socket Buffer Optimization for High Bandwidth Delay Product (BDP)
net.inet.tcp.sendspace=262144
net.inet.tcp.recvspace=262144
kern.ipc.maxsockbuf=2097152

# Ephemeral Port Range Expansion for High Concurrency Proxying
net.inet.ip.portrange.first=1024
net.inet.ip.portrange.last=65535

# Enable Path MTU Discovery & Prevent PMTU Blackholing
net.inet.tcp.mssdflt=1460
net.inet.tcp.path_mtu_discovery=1

# Security & ICMP Control
net.inet.icmp.drop_redirect=1
net.inet.icmp.log_redirect=1
net.inet.ip.redirect=0
```

---

## 4. Real CLI Commands & Terminal Output Sequences

The following section contains execution traces captured from production BSD systems.

### Step 1: Interface & Link State Inspection (`ifconfig`)

Inspect physical interface link state, media negotiation, duplex, MTU, and assigned IPv4/IPv6 addresses.

```console
$ ifconfig em0
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=81009b<VLAN_MTU,VLAN_HWTAGGING,VLAN_HWCSUM,TSO4,WOL_UCAST,WOL_MCAST,WOL_MAGIC,VLAN_HWFILTER>
	ether 52:54:00:12:34:56
	inet 192.168.10.50 netmask 0ffffff00 broadcast 192.168.10.255
	inet6 fe80::5054:ff:fe12:3456%em0 prefixlen 64 scopeid 0x1
	inet6 2001:db8:1000::50 prefixlen 64
	media: Ethernet autoselect (1000baseT <full-duplex>)
	status: active
	nd6 options=21<PERFORMNUD,AUTO_LINKLOCAL>
```

### Step 2: L2 Neighbor Resolution (`arp` & `ndp`)

Verify L2 MAC address resolution for IPv4 (ARP) and IPv6 (NDP).

```console
$ arp -a
? (192.168.10.1) at 00:11:22:33:44:55 on em0 expires in 1180 seconds [ethernet]
? (192.168.10.254) at 00:50:56:99:aa:bb on em0 expires in 840 seconds [ethernet]

$ ndp -a
Neighbor                             Linklayer Address  Netif Expire    S Flags
2001:db8:1000::1                     00:11:22:33:44:55    em0 23h59m58s S R
2001:db8:1000::50                    52:54:00:12:34:56    em0 permanent s R
```

### Step 3: Kernel Routing Table Simulation & Lookup (`netstat` & `route get`)

Determine which interface and gateway the kernel selects for a remote IP, and inspect MSS/MTU constraints.

```console
$ netstat -rn -f inet
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
default            192.168.10.1       UGS         em0
10.0.0.0/8         10.100.0.254       UGS     vlan100
10.100.0.0/24      link#2             UC      vlan100      -
127.0.0.1          link#5             UH          lo0
192.168.10.0/24    link#1             UC          em0      -

$ route get 8.8.8.8
   route to: 8.8.8.8
destination: 0.0.0.0
    mask: 0.0.0.0
 gateway: 192.168.10.1
 fib: 0
 interface: em0
  flags: <UP,GATEWAY,DONE,STATIC>
 recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire
       0         0         0         0      1500         0         0
```

### Step 4: Active L3 Probing & PMTUD Verification (`ping` & `ping6`)

Diagnose path reachability and test for Path MTU truncation using Don't Fragment (DF) flags.

```console
$ ping -c 3 -D -s 1472 192.168.10.1
PING 192.168.10.1 (192.168.10.1): 1472 data bytes
1480 bytes from 192.168.10.1: icmp_seq=0 ttl=64 time=0.412 ms
1480 bytes from 192.168.10.1: icmp_seq=1 ttl=64 time=0.388 ms
1480 bytes from 192.168.10.1: icmp_seq=2 ttl=64 time=0.395 ms

--- 192.168.10.1 ping statistics ---
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 0.388/0.398/0.412/0.010 ms

$ ping6 -c 3 2001:db8:1000::1
PING6(56=40+8+8 bytes) 2001:db8:1000::50 --> 2001:db8:1000::1
16 bytes from 2001:db8:1000::1, icmp_seq=0 hlim=64 time=0.521 ms
16 bytes from 2001:db8:1000::1, icmp_seq=1 hlim=64 time=0.485 ms
16 bytes from 2001:db8:1000::1, icmp_seq=2 hlim=64 time=0.490 ms

--- 2001:db8:1000::1 ping6 statistics ---
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/std-dev = 0.485/0.498/0.521/0.016 ms
```

### Step 5: Socket & Process Association (`sockstat` & `netstat`)

Map listening processes to TCP/UDP ports and verify socket states.

```console
$ sockstat -4 -6 -l -p 80,443,22
USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS
root     nginx      1244  6  tcp4   *:80                  *:*
root     nginx      1244  7  tcp6   *:80                  *:*
root     nginx      1244  8  tcp4   *:443                 *:*
root     nginx      1244  9  tcp6   *:443                 *:*
root     sshd       912   3  tcp4   192.168.10.50:22      *:*
root     sshd       912   4  tcp6   2001:db8:1000::50:22  *:*

$ netstat -an -p tcp | grep LISTEN
tcp4       0      0 *.80                   *.*                    LISTEN
tcp6       0      0 *.80                   *.*                    LISTEN
tcp4       0      0 *.443                  *.*                    LISTEN
tcp6       0      0 *.443                  *.*                    LISTEN
tcp4       0      0 192.168.10.50.22       *.*                    LISTEN
tcp6       0      0 2001:db8:1000::50.22   *.*                    LISTEN
```

### Step 6: Layer 4 Service Availability Probing (`nc`)

Perform zero-I/O TCP handshake verification against remote target services.

```console
$ nc -zvw3 192.168.10.1 443
Connection to 192.168.10.1 443 port [tcp/https] succeeded!

$ nc -zvw3 192.168.10.1 8080
nc: connect to 192.168.10.1 port 8080 (tcp) failed: Connection refused
```

### Step 7: Low-Level Packet Capture & Packet Filter Debugging (`tcpdump` & `pfctl`)

Capture live network frames to observe TCP flag handshakes and inspect `pf` drops on `pflog0`.

```console
$ tcpdump -nni em0 -c 3 'tcp[tcpflags] & (tcp-syn|tcp-ack) != 0'
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on em0, link-type EN10MB (Ethernet), capture size 262144 bytes
20:45:10.123456 IP 10.100.0.15.54321 > 192.168.10.50.443: Flags [S], seq 384920192, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
20:45:10.123510 IP 192.168.10.50.443 > 10.100.0.15.54321: Flags [S.], seq 918273641, ack 384920193, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
20:45:10.125112 IP 10.100.0.15.54321 > 192.168.10.50.443: Flags [.], ack 918273642, win 1026, length 0

$ pfctl -s info | grep -E "Status|State Table|Counters"
Status: Enabled for 14 days 03:22:11           Debug: Urgent
State Table                               Total             Rate
  current entries                          1420
Counters
  match                                  941204               0.8/s
  bad-offset                                  0               0.0/s
  fragment                                    0               0.0/s
  short                                       0               0.0/s
  normalize                                   0               0.0/s
  memory                                      0               0.0/s
  bad-timestamp                               0               0.0/s
  congestion                                  0               0.0/s
  state-mismatch                             14               0.0/s

$ tcpdump -nni pflog0
listening on pflog0, link-type PFLOG (OpenBSD PF status log), capture size 262144 bytes
20:46:02.881234 rule 0/(match) block in on em0: 198.51.100.45.41234 > 192.168.10.50.22: Flags [S], seq 109283741, win 1024, length 0
```

---

## 5. Systematic Verification & Fault Diagnosis Guide

When investigating network outages on BSD systems, standard operating procedure dictates a bottom-up diagnostic workflow aligned with the OSI reference model.

```
       OSI LAYER                 DIAGNOSTIC STEP                 PRIMARY COMMANDS
+---------------------+    +-------------------------+    +----------------------------+
| L7: Application     | -> | Service Availability    | -> | nc -z, curl -v, syslog     |
+---------------------+    +-------------------------+    +----------------------------+
| L4: Transport       | -> | Socket State & Ports    | -> | sockstat, netstat -an, fstat|
+---------------------+    +-------------------------+    +----------------------------+
| L3: Network         | -> | IP, Routing & PMTUD     | -> | route get, ping, traceroute|
+---------------------+    +-------------------------+    +----------------------------+
| L2: Data Link       | -> | MAC & Neighbor Resolution| ->| arp -a, ndp -a, vlan check |
+---------------------+    +-------------------------+    +----------------------------+
| L1: Physical        | -> | NIC Link & PHY Status   | -> | ifconfig media status      |
+---------------------+    +-------------------------+    +----------------------------+
```

### Incident Runbooks

#### Runbook A: Path MTU Discovery (PMTUD) Blackhole Resolution

```
[Issue]: TCP SYN completes, but TLS Handshake or Large HTTP Payloads Hang.
```

1. **Test Payload Fragmentation Threshold**:
   Execute ICMP probing with the Don't Fragment (`-D` on BSD) flag enabled, starting at standard Ethernet MTU (1500 bytes = 1472 data + 20 IP header + 8 ICMP header):
   ```console
   $ ping -c 2 -D -s 1472 10.200.0.1
   ```
2. **Isolate Exact Path MTU Breakdown**:
   If 1472 bytes drop without response, decrement packet size systematically to identify the bottleneck MTU:
   ```console
   $ ping -c 2 -D -s 1412 10.200.0.1
   ```
   *Result*: 1412 bytes succeeds. Effective path MTU is $1412 + 28 = 1440$ bytes (indicating an overlay tunnel such as IPsec or GRE consuming 60 bytes of overhead).

3. **Remediation Strategy**:
   Enforce MSS Clamping inside `/etc/pf.conf` to force TCP clients to negotiate a lower segment size automatically:
   ```pf
   scrub in on em0 all fragment reassemble max-mss 1400
   ```
   Reload the PF configuration:
   ```console
   $ pfctl -f /etc/pf.conf
   ```

---

#### Runbook B: Socket Buffer & Memory Cluster Exhaustion

```
[Issue]: Service emits 'EADDRNOTAVAIL' or kernel drops incoming connections under high load.
```

1. **Inspect Kernel mbuf Cluster Usage**:
   ```console
   $ netstat -m
   4096/1248/5344 mbufs in use (current/cache/total)
   2048/812/2860 mbuf clusters in use (current/cache/total)
   0/0/0 requests for mbufs denied
   0/0/0 requests for mbuf clusters denied
   ```
   *Condition*: If `requests for mbuf clusters denied` is greater than zero, the system is dropping packets due to kernel memory exhaustion.

2. **Inspect Ephemeral Port Utilization**:
   Check currently configured port range:
   ```console
   $ sysctl net.inet.ip.portrange.first net.inet.ip.portrange.last
   net.inet.ip.portrange.first: 49152
   net.inet.ip.portrange.last: 65535
   ```
   Count active TIME_WAIT and ESTABLISHED sockets:
   ```console
   $ netstat -an -p tcp | awk '{print $6}' | sort | uniq -c
   ```

3. **Remediation Strategy**:
   Expand port range and double `mbuf` cluster allocation dynamically via `sysctl`:
   ```console
   $ sysctl net.inet.ip.portrange.first=1024
   $ sysctl kern.ipc.nmbclusters=65536
   ```
   Persist settings in `/etc/sysctl.conf`.

---

#### Runbook C: Packet Filter State Mismatch & Asymmetric Egress

```
[Issue]: Traffic reaches host, but outgoing replies are dropped by PF firewall.
```

1. **Check State Mismatch Counters**:
   ```console
   $ pfctl -s info | grep "state-mismatch"
     state-mismatch                             412               0.2/s
   ```
2. **Monitor Live Drop Interface (`pflog0`)**:
   ```console
   $ tcpdump -nni pflog0 -v
   ```
   *Diagnostic Output*: Shows packets arriving on `em1` matching states created on `em0`.

3. **Remediation Strategy**:
   Update `/etc/pf.conf` rules to explicitly allow floating states across all physical interfaces:
   ```pf
   pass out quick on { em0, em1 } proto tcp all flags S/SA keep state (floating)
   ```
   Reload rule base:
   ```console
   $ pfctl -f /etc/pf.conf
   ```

---

## 6. References

* **LPI BSD Specialist Certification Overview**: https://www.lpi.org/our-certifications/bsd-overview/
* **LPI BSD Specialist 702-100 Objectives**: https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **FreeBSD System Administration Handbook - Networking**: https://docs.freebsd.org/en/books/handbook/network/
* **FreeBSD Manual Pages - `ifconfig(8)`**: https://man.freebsd.org/cgi/man.cgi?ifconfig(8)
* **FreeBSD Manual Pages - `sockstat(1)`**: https://man.freebsd.org/cgi/man.cgi?sockstat(1)
* **FreeBSD Manual Pages - `netstat(1)`**: https://man.freebsd.org/cgi/man.cgi?netstat(1)
* **OpenBSD Packet Filter (`pf`) User Guide**: https://www.openbsd.org/faq/pf/
* **OpenBSD Manual Pages - `fstat(1)`**: https://man.openbsd.org/fstat.1
* **NetBSD Network Documentation**: https://www.netbsd.org/docs/network/