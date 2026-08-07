# LPI-702 (Exam 702-100) | Topic 714.1: Fundamentals of Internet Protocols

**Weight:** 3.33  
**Target Profile:** Principal Platform Architect / Senior Site Reliability Engineer (SRE)  
**Exam Objectives Covered:** IPv4/IPv6 addressing architecture, subnetting mathematics, CIDR/Dotted-Decimal/Hexadecimal mask conversions, host and broadcast range calculations, L3/L4 protocol mechanics, and FreeBSD system-level IP stack integration.

---

## 1. Production Architectural Motivation & Problem Statement

In enterprise platform engineering and cloud-native infrastructure, the IP layer is the fundamental substrate for traffic routing, security segmentation, and service mesh isolation. Modern production environments deploy hybrid architectures where FreeBSD edge routers, security gateways (using `pf`), and Linux/Kubernetes nodes interact over complex IPv4 CIDR allocations and IPv6 Dual-Stack networks.

```
                     +-------------------------------------------------------+
                     |                IPv4 / IPv6 Ingress Router             |
                     |       FreeBSD 14.1 (pf / BGP / Dual-Stack IPAM)        |
                     +-------------------------------------------------------+
                                        /                 \
            IPv4: 192.168.10.0/24 (0xffffff00)      IPv6: 2001:db8:abc1::/64
           Broadcast: 192.168.10.255                Gateway: 2001:db8:abc1::1
                                      /                     \
                   +-----------------------+           +-----------------------+
                   | Kubernetes Worker 01  |           | FreeBSD Storage Node  |
                   | Calico / Cilium CNI   |           | ZFS NFS / iSCSI Host  |
                   | 192.168.10.16/28      |           | 2001:db8:abc1::50/64  |
                   +-----------------------+           +-----------------------+
```

### Architectural Trade-offs and Production Bottlenecks

1. **IPv4 Address Exhaustion & NAT Overhead**
   * **The Problem:** The limited 32-bit IPv4 address space (`2^32 ≈ 4.29 billion` addresses) forces architectures into heavy reliance on RFC 1918 private spaces combined with Network Address Translation (NAT/NAPT).
   * **Production Impact:** Stateful NAT firewall tables consume memory buffers (BSD `pf` state entries require ~400 bytes each). High-concurrency edge systems (e.g., 500,000 active connections) consume hundreds of megabytes of non-pageable kernel memory solely for translation states. Furthermore, broken end-to-end IP reachability disables direct peer-to-peer telemetry and complicates microservice auditing.

2. **Subnetting Misconfigurations & Broadcast Storms**
   * **The Problem:** Miscalculating netmasks (e.g., configuring a `/23` host on a `/24` physical switch segment) breaks local Layer 2 resolution via ARP (Address Resolution Protocol).
   * **Production Impact:** When an IPv4 host miscalculates its broadcast address, it either drops incoming un-unicast frames or forwards traffic destined for adjacent subnets to the local gateway unnecessarily, inducing CPU-intensive kernel routing lookup re-evaluations via BSD `radix` (PATRICIA) trees.

3. **IPv4 vs IPv6 Header Efficiency & Processing Overhead**
   * **IPv4 Header:** Variable length (20 to 60 bytes) due to optional fields. Requires routers to recalculate the IPv4 Header Checksum at every hop due to TTL decrementing, adding CPU latency.
   * **IPv6 Header:** Fixed length of 40 bytes. Checksum is eliminated at Layer 3 (relying on Layer 2 and Layer 4 checksums). Hop Limit replaces TTL. Optional features are moved to chaining *Extension Headers* (e.g., Hop-by-Hop, Routing, Fragment, ESP), allowing intermediate transit routers to process packets entirely in hardware (ASIC/eBPF/DPDK) without parsing optional fields.

4. **Layer 2 Protocol Shift: ARP vs ICMPv6 Neighbor Discovery (NDP)**
   * **IPv4 ARP:** Relies on broadcast frames (`ff:ff:ff:ff:ff:ff`). On large L2 segments (e.g., `/22` with 1,022 hosts), ARP requests generate severe noise, waking up every host's network interface card (NIC) to process packet filters.
   * **IPv6 NDP:** Replaces ARP broadcasts with **Solicited-Node Multicast** (`ff02::1:ffxx:xxxx`), computed from the last 24 bits of the target IPv6 address. Only hosts matching the lower 24-bit multicast group filter receive and decode the frame at the NIC hardware level.

---

## 2. Technical Comparisons & Comprehensive Trade-Off Matrices

### Table 2.1: Protocol Architecture Comparison (IPv4 vs. IPv6)

| Feature / Metric | IPv4 Architecture | IPv6 Architecture | Production SRE Trade-off & Impact |
| :--- | :--- | :--- | :--- |
| **Address Space** | 32 bits (`4.29 x 10^9`) | 128 bits (`3.4 x 10^38`) | IPv6 eliminates stateful CGNAT; restores true end-to-end IP trace-ability. |
| **Header Size** | Dynamic: 20–60 Bytes | Fixed: 40 Bytes | Fixed header enables hardware routing speed optimization in edge transit devices. |
| **L3 Checksum** | Present (Recalculated per hop) | None | Eliminates per-hop checksum calculation; reduces CPU latency on BSD kernel routers. |
| **Fragmentation** | Performed by Routers & Hosts | Performed by Source Host ONLY | Routers drop oversized IPv6 packets and return ICMPv6 *Packet Too Big* (Type 2). |
| **L2 Resolution** | ARP (Layer 2 Broadcasts) | NDP / ICMPv6 Multicast | NDP dramatically reduces CPU interrupts across large compute clusters. |
| **Autoconfiguration**| DHCPv4 or Manual Static | SLAAC (RFC 4862) / DHCPv6 | SLAAC enables zero-touch node bootstrapping without central stateful DHCP servers. |
| **Broadcast Address**| Present (Last IP of subnet) | None (Replaced by Multicast) | Eliminates subsegment-wide broadcast noise and amplification attack vectors. |

---

### Table 2.2: Subnetting & Notation Conversion Matrix

Understanding conversions between **CIDR Notation**, **Dotted-Decimal Subnet Masks**, **Hexadecimal Masks** (frequently seen in BSD `ifconfig` output), **Wildcard Masks**, and usable IP capacity is mandatory for LPI-702.

| CIDR | Dotted Decimal Mask | Hexadecimal Mask (`ifconfig`) | Wildcard Mask | Total IPs | Usable Hosts (IPv4) | Typical Production Topology |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `/32` | `255.255.255.255` | `0xffffffff` | `0.0.0.0` | 1 | 1 (Host Route) | Loopback (`lo0`), BGP Router ID, Container Endpoint |
| `/30` | `255.255.255.252` | `0xfffffffc` | `0.0.0.3` | 4 | 2 | Legacy Point-to-Point WAN links |
| `/29` | `255.255.255.248` | `0xfffffff8` | `0.0.0.7` | 8 | 6 | High-Availability HAProxy / VRRP ClusterVIP pool |
| `/28` | `255.255.255.240` | `0xfffffff0` | `0.0.0.15` | 16 | 14 | Small Ingress Gateway / DMZ Pod subnet |
| `/27` | `255.255.255.224` | `0xffe00000` -> `0xffffffe0`| `0.0.0.31` | 32 | 30 | Database Node Cluster Subnet |
| `/26` | `255.255.255.192` | `0xffffffc0` | `0.0.0.63` | 64 | 62 | Application Microservice Pool |
| `/25` | `255.255.255.128` | `0xffffff80` | `0.0.0.127` | 128 | 126 | Mid-size Infrastructure Zone |
| `/24` | `255.255.255.0` | `0xffffff00` | `0.0.0.255` | 256 | 254 | Standard Rack / VPC Subnet segment |
| `/23` | `255.255.250.0` -> `255.255.254.0`| `0xfffffe00` | `0.0.1.255` | 512 | 510 | Dual-Rack Aggregated Node Subnet |
| `/16` | `255.255.0.0` | `0xffff0000` | `0.0.255.255` | 65,536 | 65,534 | Complete Regional VPC / Datacenter Block |
| `/8` | `255.0.0.0` | `0xff000000` | `0.7.255.255` -> `0.255.255.255`| 16,777,216| 16,777,214 | Class A Enterprise Backbone Allocation |

---

### Mathematical Conversion Formulas & Rules

1. **Subnet Bit Calculation:**
   $$\text{Usable Hosts} = 2^{(32 - \text{CIDR})} - 2$$
   *(Note: Subtract 2 for Network ID and Broadcast ID. In IPv6, subnets are standardized to `/64` for SLAAC, providing $2^{64}$ addresses per subnet without broadcast subtractors).*

2. **Dotted Decimal to Hexadecimal Conversion:**
   To convert `255.255.255.224` (`/27`):
   * $255 = \text{0xFF}$
   * $255 = \text{0xFF}$
   * $255 = \text{0xFF}$
   * $224 = 128 + 64 + 32 + 0 + 0 + 0 + 0 + 0 = 11100000_2 = \text{0xE0}$
   * **Hex Representation:** `0xffffffe0`

---

### Table 2.3: Layer 4 Transport Protocols Semantics

| Feature | TCP (Transmission Control Protocol) | UDP (User Datagram Protocol) | ICMP / ICMPv6 |
| :--- | :--- | :--- | :--- |
| **Connection State**| Stateful (3-Way Handshake: SYN, SYN-ACK, ACK) | Connectionless | Connectionless (Informational / Error) |
| **Flow & Congestion**| Window Scaling, Selective ACK (SACK), BBR/CUBIC | None (Application layer managed) | None |
| **Header Overhead**| 20–60 Bytes | 8 Bytes | 8 Bytes |
| **Key Field** | Sequence / Ack Numbers, Flags | Source/Dest Port, Length, Checksum | Type, Code, Checksum, Data Payload |
| **Production Use** | HTTP/HTTPS, SSH, gRPC, Database connectivity | DNS queries, QUIC, WireGuard, Telemetry | Path MTU Discovery, Ping, NDP, Router Advertisements |

---

## 3. Production Infrastructure Manifests & System Configurations

### 3.1 FreeBSD Dual-Stack Network Interface Architecture Configuration (`/etc/rc.conf`)

This configuration sets up a dual-stack FreeBSD edge node featuring static IPv4 (`192.168.10.14/26`), static IPv6 Global Unicast (`2001:db8:1000::14/64`), static routes, and system-wide forwarding.

```sh
# System Hostname Definition
hostname="edge-node-01.infra.internal"

# ------------------------------------------------------------------------------
# IPv4 Network Configuration (vtnet0)
# Subnet: 192.168.10.0/26 -> Netmask: 255.255.255.192 (Hex: 0xffffffc0)
# Broadcast: 192.168.10.63 | Usable Hosts: 192.168.10.1 - 192.168.10.62
# ------------------------------------------------------------------------------
ifconfig_vtnet0="inet 192.168.10.14 netmask 255.255.255.192 broadcast 192.168.10.63"
defaultrouter="192.168.10.1"

# ------------------------------------------------------------------------------
# IPv6 Network Configuration (vtnet0)
# Global Unicast Address (GUA): 2001:db8:1000::14/64
# Prefix: 2001:db8:1000::/64
# Link-Local automatically configured by kernel (fe80::/10)
# ------------------------------------------------------------------------------
ifconfig_vtnet0_ipv6="inet6 2001:db8:1000::14 prefixlen 64"
ipv6_defaultrouter="2001:db8:1000::1"

# Enable Dual-Stack Forwarding (Acts as Router/Gateway)
gateway_enable="YES"
ipv6_gateway_enable="YES"

# Enable Packet Filter Firewall
pf_enable="YES"
pf_rules="/etc/pf.conf"
pf_flags=""
```

---

### 3.2 FreeBSD Packet Filter Security Configuration (`/etc/pf.conf`)

A complete, production-grade `pf.conf` ruleset allowing critical IPv4 ARP/ICMP traffic and IPv6 Neighbor Discovery Protocol (NDP) while filtering unauthorized network prefixes.

```pf
# Interface and Subnet Definitions
ext_if = "vtnet0"
ipv4_sub = "192.168.10.0/26"
ipv6_sub = "2001:db8:1000::/64"

# Global Options
set skip on lo0
set block-policy drop
set loginterface $ext_if

# Scrub incoming packets to prevent fragmentation attacks
scrub in on $ext_if all fragment reassemble

# Default Deny Policy
block all

# Pass outbound traffic statefully
pass out quick on $ext_if all flags S/SA keep state

# ------------------------------------------------------------------------------
# IPv4 Mandatory Protocols
# Allow ICMP Type 3 (Destination Unreachable) for Path MTU Discovery
# Allow ICMP Type 8 (Echo Request) for monitoring
# ------------------------------------------------------------------------------
pass in quick on $ext_if inet proto icmp icmp-type { unreach, echoreq } keep state

# ------------------------------------------------------------------------------
# IPv6 Mandatory Protocols (RFC 4890 Compliance)
# NDP (ICMPv6 Types 135, 136) and Router Advertisements (Types 133, 134) MUST pass
# ICMPv6 Type 2 (Packet Too Big) MUST pass for Path MTU Discovery
# ------------------------------------------------------------------------------
pass in quick on $ext_if inet6 proto icmp6 icmp6-type {
    unreach, toobig, echoreq, echorep,
    routersol, routeradv, neighbrsol, neighbradv
} hoplimit 255

# Pass Inbound SSH for Management
pass in quick on $ext_if proto tcp from any to ($ext_if) port 22 flags S/SA keep state
```

---

### 3.3 Kubernetes Dual-Stack Cilium CNI Manifest (`cilium-ipam-config.yaml`)

Production Kubernetes manifest defining dual-stack IPAM routing allocations for IPv4 and IPv6 clusters.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  # Enable Dual-Stack Operation
  enable-ipv4: "true"
  enable-ipv6: "true"
  
  # IPAM Pools Definition
  ipam: "cluster-pool"
  cluster-pool-ipv4-cidr: "10.244.0.0/16"
  cluster-pool-ipv4-mask-size: "24"
  cluster-pool-ipv6-cidr: "fd00:10:244::/48"
  cluster-pool-ipv6-mask-size: "64"
  
  # Tunneling vs Direct Routing
  routing-mode: "native"
  ipv4-native-routing-cidr: "10.244.0.0/16"
  ipv6-native-routing-cidr: "fd00:10:244::/48"
  
  # ICMP and PMTUD Support
  enable-ipv4-pmtu-discovery: "true"
  enable-ipv6-big-tcp: "true"
```

---

## 4. Real CLI Commands and Terminal Outputs

### 4.1 FreeBSD Interface Inspection (`ifconfig`)

Executing `ifconfig` on FreeBSD to verify dual-stack properties, hexadecimal subnet mask representation (`0xffffffc0`), broadcast addresses, and IPv6 scopes.

```console
$ ifconfig vtnet0
vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=8000b<RXCSUM,TXCSUM,VLAN_MTU,LINKSTATE>
	ether 52:54:00:12:34:56
	inet 192.168.10.14 netmask 0xffffffc0 broadcast 192.168.10.63
	inet6 fe80::5054:ff:fe12:3456%vtnet0 prefixlen 64 scopeid 0x1
	inet6 2001:db8:1000::14 prefixlen 64
	media: Ethernet autoselect (10Gbase-T <full-duplex>)
	status: active
	nd6 options=21<PERFORMNUD,AUTO_LINKLOCAL>
```

---

### 4.2 Subnet Bitmask & Network Range Calculation (`sipcalc`)

Calculating network properties for IPv4 (`192.168.10.138/27`) and IPv6 (`2001:db8:abcd:0012::/64`) using `sipcalc`.

#### IPv4 Subnet Breakdown:
```console
$ sipcalc 192.168.10.138/27
-[ipv4 : 192.168.10.138/27] - 0

[Usage]
Host address		- 192.168.10.138
Host address (decimal)	- 3232238218
Host address (hex)	- C0A80A8A
Network address		- 192.168.10.128
Network mask		- 255.255.255.224
Network mask (bits)	- 27
Network mask (hex)	- FFFFFFE0
Broadcast address	- 192.168.10.159
Cisco wildcard		- 0.0.0.31
Addresses in network	- 32
Network range		- 192.168.10.128 - 192.168.10.159
Usable range		- 192.168.10.129 - 192.168.10.158
```

#### IPv6 Subnet Breakdown:
```console
$ sipcalc 2001:db8:abcd:0012::1/64
-[ipv6 : 2001:db8:abcd:0012::1/64] - 0

[Usage]
Expanded Address	- 2001:0db8:abcd:0012:0000:0000:0000:0001
Compressed address	- 2001:db8:abcd:12::1
Subnet prefix (masked)	- 2001:db8:abcd:12:0:0:0:0/64
Address type		- Aggregable Global Unicast Addresses
Prefix length		- 64
Network range		- 2001:0db8:abcd:0012:0000:0000:0000:0000 -
			  2001:0db8:abcd:0012:ffff:ffff:ffff:ffff
```

---

### 4.3 Kernel Routing Table Inspection (`netstat -rn`)

Checking both IPv4 and IPv6 BSD kernel routing table trees.

```console
$ netstat -rn -f inet
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
default            192.168.10.1       UGS      vtnet0
127.0.0.1          link#2             UH          lo0
192.168.10.0/26    link#1             U        vtnet0
192.168.10.14      link#1             UHS         lo0
192.168.10.63      link#1             UHS      vtnet0
```

```console
$ netstat -rn -f inet6
Routing tables

Internet6:
Destination                       Gateway            Flags     Netif Expire
::/0                              2001:db8:1000::1   UGS      vtnet0
::1                               link#2             UHS         lo0
2001:db8:1000::/64                link#1             U        vtnet0
2001:db8:1000::14                 link#1             UHS         lo0
fe80::%vtnet0/64                  link#1             U        vtnet0
fe80::5054:ff:fe12:3456%vtnet0    link#1             UHS         lo0
ff02::%vtnet0/32                  link#1             U        vtnet0
```

* **Flags Explanation:**
  * `U`: Route is Up.
  * `G`: Destination requires routing via Gateway.
  * `S`: Static Route.
  * `H`: Host Route (single `/32` or `/128` destination).
  * `S`: Loopback/Host alias.

---

### 4.4 Live Packet Tracing (`tcpdump`)

Capturing ICMPv6 Neighbor Discovery Protocol (NDP) packet flows on FreeBSD.

```console
$ sudo tcpdump -nni vtnet0 -c 4 icmp6
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on vtnet0, link-type EN10MB (Ethernet), capture size 262144 bytes
20:49:55.102941 IP6 fe80::5054:ff:fe12:3456 > ff02::1:ff00:1: ICMP6, neighbor solicitation, who has 2001:db8:1000::1, length 32
20:49:55.103412 IP6 fe80::5054:ff:fe12:9999 > fe80::5054:ff:fe12:3456: ICMP6, neighbor advertisement, tgt is 2001:db8:1000::1, length 32
20:49:56.201112 IP6 2001:db8:1000::14 > 2001:db8:1000::1: ICMP6, echo request, seq 1, length 64
20:49:56.201488 IP6 2001:db8:1000::1 > 2001:db8:1000::14: ICMP6, echo reply, seq 1, length 64
4 packets captured
4 packets received by filter
0 packets dropped by kernel
```

---

## 5. Troubleshooting, Verification & Failure Analysis

### Diagnostic Flowchart

```
                          [ Networking Issue Detected ]
                                        |
                   +--------------------+--------------------+
                   |                                         |
            [ IPv4 Failure ]                         [ IPv6 Failure ]
                   |                                         |
     Check IP & Mask (`ifconfig`)              Check Link-Local & GUA (`ifconfig`)
     Must match segment CIDR                   Verify scopeid (%vtnet0)
                   |                                         |
     Check ARP Table (`arp -a`)                Check NDP Table (`ndp -a`)
     Is MAC resolved?                          Is Neighbor Reachable?
                   |                                         |
     Verify ICMP (`ping -c 3`)                 Verify ICMPv6 (`ping6 -c 3`)
     Filter blocking Type 3/8?                 Filter blocking Type 135/136/2?
                   |                                         |
                   +--------------------+--------------------+
                                        |
                        [ Check Path MTU Discovery ]
                        `ping -D -s 1472 <IP>` (v4)
                        `ping6 -b 1440 <IP>`   (v6)
```

---

### Scenario A: IPv4 Subnet Mask Misalignment & Silent Routing Blackhole

* **Symptom:** Host `192.168.10.45` cannot reach Database Server `192.168.10.70`. Pings fail with `No route to host`.
* **Root Cause Analysis:** Host `A` is configured with netmask `255.255.255.192` (`/26`), defining its subnet range as `192.168.10.0` to `192.168.10.63`. The Database Server at `192.168.10.70` sits in a higher subnet block (`192.168.10.64/26`). Because Host `A` treats `.70` as off-link, it forwards traffic to its default gateway. If the gateway lacks a route to `.70`, traffic drops silently.

#### Diagnostic Protocol:

1. Query interface parameters:
   ```console
   $ ifconfig vtnet0 | grep inet
   inet 192.168.10.45 netmask 0xffffffc0 broadcast 192.168.10.63
   ```
2. Trace destination route evaluation:
   ```console
   $ route get 192.168.10.70
      route to: 192.168.10.70
   destination: default
       gateway: 192.168.10.1
     fib: 0
     interface: vtnet0
         flags: <UP,GATEWAY,DONE,STATIC>
   ```
3. **Remediation:** Adjust subnet mask to `/25` (`255.255.255.128` / `0xffffff80`) if both hosts belong to the same L2 broadcast segment:
   ```console
   $ sudo ifconfig vtnet0 inet 192.168.10.45/25
   ```

---

### Scenario B: IPv6 Neighbor Discovery (NDP) Stall due to ICMPv6 Filtering

* **Symptom:** IPv6 address is assigned, but nodes cannot ping adjacent hosts on the same physical link.
* **Root Cause Analysis:** A firewall rule in `/etc/pf.conf` blocks all ICMPv6 traffic (`block in proto icmp6`). This blocks Neighbor Solicitation (Type 135) and Neighbor Advertisement (Type 136), preventing nodes from resolving MAC addresses.

#### Diagnostic Protocol:

1. Check kernel NDP table:
   ```console
   $ ndp -a
   Neighbor                             Linklayer Address  Netif Expire S Flags
   2001:db8:1000::1                     (incomplete)       vtnet0 3s     S 
   2001:db8:1000::14                    52:54:00:12:34:56  lo0    permanent R
   ```
   *(Note `(incomplete)` state indicates Layer 2 address resolution failure via NDP).*

2. Verify raw packet ingress using `tcpdump`:
   ```console
   $ sudo tcpdump -nni vtnet0 icmp6 type 135 or icmp6 type 136
   ```

3. **Remediation:** Update `/etc/pf.conf` to explicitly permit NDP types:
   ```pf
   pass in quick on vtnet0 inet6 proto icmp6 icmp6-type { neighbrsol, neighbradv } hoplimit 255
   ```
   Reload rule base:
   ```console
   $ sudo pfctl -f /etc/pf.conf
   ```

---

### Scenario C: Path MTU Discovery (PMTUD) Black Hole

* **Symptom:** SSH sessions freeze upon executing large commands (e.g., `cat large_file.txt`), or HTTP/TLS handshakes stall indefinitely. Simple `ping` packets pass without issue.
* **Root Cause Analysis:** An intermediate link has a lower MTU (e.g., 1400 bytes due to VXLAN encapsulation) than the host NIC (1500 bytes). The host sets the IPv4 DF (*Don't Fragment*) flag. The router drops packets exceeding 1400 bytes and sends an ICMP Type 3 Code 4 (*Fragmentation Needed and DF set*) packet back to the host. A firewall drops this ICMP packet, causing the host TCP stack to retransmit 1500-byte frames until connection timeout.

#### Diagnostic Protocol:

1. Perform sweep test with DF bit set (`-D` on FreeBSD):
   ```console
   $ ping -D -s 1472 192.168.10.1
   PING 192.168.10.1 (192.168.10.1): 1472 data bytes
   1480 bytes from 192.168.10.1: icmp_seq=0 ttl=64 time=0.412 ms
   
   $ ping -D -s 1473 192.168.10.1
   PING 192.168.10.1 (192.168.10.1): 1473 data bytes
   ping: sendto: Message too long
   ```
   *(Payload of 1472 + 8 bytes ICMP header + 20 bytes IP header = 1500 bytes MTU).*

2. Query specific route MTU via kernel route table:
   ```console
   $ route get 192.168.10.1
      route to: 192.168.10.1
   destination: 192.168.10.1
     interface: vtnet0
          flags: <UP,HOST,DONE,STATIC>
       recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire
              0         0         0         0      1500         0         0
   ```

3. **Remediation:** Permit ICMP PMTUD messages in firewall rulesets, or clamp TCP MSS (Maximum Segment Size) in `pf.conf`:
   ```pf
   scrub in on vtnet0 max-mss 1360
   ```

---

## 6. References

* **Linux Professional Institute (LPI) Official Objectives:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **FreeBSD Handbook - Network Configuration:**  
  [https://docs.freebsd.org/en/books/handbook/network/](https://docs.freebsd.org/en/books/handbook/network/)
* **FreeBSD Manual Pages - `ifconfig(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=ifconfig](https://man.freebsd.org/cgi/man.cgi?query=ifconfig)
* **FreeBSD Manual Pages - `pf.conf(5)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=pf.conf](https://man.freebsd.org/cgi/man.cgi?query=pf.conf)
* **RFC 791 - Internet Protocol (IPv4 Specification):**  
  [https://www.rfc-editor.org/rfc/rfc791](https://www.rfc-editor.org/rfc/rfc791)
* **RFC 8200 - Internet Protocol, Version 6 (IPv6) Specification:**  
  [https://www.rfc-editor.org/rfc/rfc8200](https://www.rfc-editor.org/rfc/rfc8200)
* **RFC 4291 - IP Version 6 Addressing Architecture:**  
  [https://www.rfc-editor.org/rfc/rfc4291](https://www.rfc-editor.org/rfc/rfc4291)
* **RFC 4861 - Neighbor Discovery for IP version 6 (IPv6):**  
  [https://www.rfc-editor.org/rfc/rfc4861](https://www.rfc-editor.org/rfc/rfc4861)
* **RFC 4890 - Recommendations for Filtering ICMPv6 Messages in Firewalls:**  
  [https://www.rfc-editor.org/rfc/rfc4890](https://www.rfc-editor.org/rfc/rfc4890)