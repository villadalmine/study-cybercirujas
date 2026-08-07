# LPI-702: BSD Specialist (Exam 702-100, v1.0)
## Topic 714.1: Fundamentals of Internet Protocols
**Weight:** 3.33 | **Target Role:** Senior SRE / Platform Architect

---

### Official References
* **LPI BSD Specialist Objective 714.1:** [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **FreeBSD Network Architecture & Interfaces:** [https://docs.freebsd.org/en/books/handbook/network/](https://docs.freebsd.org/en/books/handbook/network/)
* **OpenBSD Network Configuration (`hostname.if`):** [https://man.openbsd.org/hostname.if.5](https://man.openbsd.org/hostname.if.5)
* **RFC 791 - Internet Protocol (IPv4):** [https://datatracker.ietf.org/doc/html/rfc791](https://datatracker.ietf.org/doc/html/rfc791)
* **RFC 4291 - IPv6 Addressing Architecture:** [https://datatracker.ietf.org/doc/html/rfc4291](https://datatracker.ietf.org/doc/html/rfc4291)
* **RFC 4861 - Neighbor Discovery for IP version 6 (IPv6):** [https://datatracker.ietf.org/doc/html/rfc4861](https://datatracker.ietf.org/doc/html/rfc4861)

---

### Guided Exercise 1: IPv4 Subnetting, Hexadecimal Bitmasks, and BSD Interface Aliasing

#### Executive Architectural Context
IPv4 addresses consist of a 32-bit unsigned integer divided into network and host portions. BSD operating systems (FreeBSD, OpenBSD, NetBSD) manipulate network masks internally as 32-bit hexadecimal bitmasks (e.g., `0xffffff00`). Modern network tools accept Dotted Decimal Notation (DDN), Hexadecimal, and Classless Inter-Domain Routing (CIDR) prefix notation. Understanding conversions across these representations is mandatory for configuring network interfaces, packet filter (`pf`) table definitions, and routing tables.

---

#### Step-by-Step Execution Guide

1. Log into your BSD terminal environment and identify active interface configurations using `ifconfig`:
```bash
$ ifconfig vtnet0
```
*Expected Output:*
```text
vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=8000b<TXCSUM,VLAN_MTU,VLAN_HWTAGGING,LINKSTATE>
	ether 52:54:00:fa:9b:12
	inet 192.168.1.50 netmask 0xffffff00 broadcast 192.168.1.255
	media: Ethernet autoselect (1000baseT <full-duplex>)
	status: active
```

2. Convert the CIDR prefix `/27` to Dotted Decimal Notation (DDN) and Hexadecimal notation:
   * **Bit breakdown:** A `/27` mask has 27 contiguous set bits (`1`) followed by 5 unset bits (`0`).
   * **Binary representation:** `11111111.11111111.11111111.11100000`
   * **Decimal conversion:** Octet 4 = $128 + 64 + 32 = 224$. Result: `255.255.255.224`
   * **Hexadecimal conversion:** 
     * Octet 1: `11111111` = `0xFF`
     * Octet 2: `11111111` = `0xFF`
     * Octet 3: `11111111` = `0xFF`
     * Octet 4: `11100000` = `0xE0`
     * Result: `0xffffffe0`

3. Calculate Network ID, Broadcast Address, First Usable Host, and Last Usable Host for host IP `10.200.45.138/27`:
   * **Block Size:** $2^{32-27} = 2^5 = 32$ addresses per subnet.
   * **Subnet Interval Multiples:** $0, 32, 64, 96, 128, 160, 192, \dots$
   * **Network Address:** The host octet value `138` falls between `128` and `159`. Network Address: `10.200.45.128`.
   * **Broadcast Address:** `10.200.45.159` (Network Address + Block Size - 1).
   * **Usable Host Range:** `10.200.45.129` through `10.200.45.158`.

4. Apply an IPv4 alias using CIDR notation on FreeBSD dynamically via `ifconfig`:
```bash
$ sudo ifconfig vtnet0 inet 10.200.45.138/27 alias
```

5. Verify interface configuration to observe how the kernel stores the netmask in hexadecimal format:
```bash
$ ifconfig vtnet0
```
*Expected Output:*
```text
vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=8000b<TXCSUM,VLAN_MTU,VLAN_HWTAGGING,LINKSTATE>
	ether 52:54:00:fa:9b:12
	inet 192.168.1.50 netmask 0xffffff00 broadcast 192.168.1.255
	inet 10.200.45.138 netmask 0xffffffe0 broadcast 10.200.45.159
	media: Ethernet autoselect (1000baseT <full-duplex>)
	status: active
```

6. To persist this network configuration across reboots, edit `/etc/rc.conf` (FreeBSD) or `/etc/hostname.vtnet0` (OpenBSD):

*Syntactically Valid FreeBSD `/etc/rc.conf` snippet:*
```sh
hostname="bsd-node-01.production.internal"
ifconfig_vtnet0="inet 192.168.1.50 netmask 255.255.255.0"
ifconfig_vtnet0_alias0="inet 10.200.45.138 netmask 255.255.255.224"
defaultrouter="192.168.1.1"
```

*Syntactically Valid OpenBSD `/etc/hostname.vtnet0` snippet:*
```text
inet 192.168.1.50 255.255.255.0
inet alias 10.200.45.138 255.255.255.224
!route add default 192.168.1.1
```

---

#### Comprehension Check: Block 1

1. **Question 1.1:** A FreeBSD system administrator assigns an IPv4 address to `em0` using the command `ifconfig em0 inet 172.16.89.200 netmask 0xffffffc0`. What is the CIDR prefix length, the network address, and the broadcast address for this assignment?
2. **Question 1.2:** Convert the CIDR prefix `/22` into both Dotted Decimal Notation (DDN) and 32-bit Hexadecimal notation. How many total IP addresses are contained within a single `/22` allocation?
3. **Question 1.3:** An SRE needs to subnet `192.168.10.0/24` into at least 6 distinct subnets, each supporting a minimum of 25 usable host interfaces. What is the optimal CIDR mask required, how many subnets are created, and what is the broadcast address of the 3rd subnet?

---

### Guided Exercise 2: IPv6 Architecture, SLAAC, EUI-64 Synthesis, and Neighbor Discovery Protocol (NDP)

#### Executive Architectural Context
IPv6 addresses are 128 bits long, expressed as eight 16-bit hexadecimal blocks separated by colons (RFC 4291). Unlike IPv4 ARP, IPv6 uses Neighbor Discovery Protocol (NDP)—built on top of ICMPv6 (RFC 4861)—for address resolution, router discovery, and duplicate address detection (DAD). Statutory IPv6 address types include:
* **Link-Local (`fe80::/10`):** Automatically configured on every IPv6-enabled interface; non-routable beyond the local layer-2 segment. Requires scope index specification in BSD utilities (`ping6 fe80::1%vtnet0`).
* **Global Unicast (`2000::/3`):** Globally routable public IPv6 addresses.
* **Unique Local (`fc00::/7`):** Routable within local organizations (private IP equivalent).
* **Multicast (`ff00::/8`):** Replaces IPv4 broadcast (`ff02::1` = All Nodes, `ff02::2` = All Routers).

Stateless Address Autoconfiguration (SLAAC) can use Modified EUI-64 to derive a 64-bit Interface Identifier from a 48-bit IEEE MAC address by inserting `0xfffe` into the middle and toggling the Universal/Local ($U/L$) bit (bit 7 of octet 1).

---

#### Step-by-Step Execution Guide

1. Display the system's IPv6 configuration and view assigned Link-Local and Global Unicast addresses:
```bash
$ ifconfig vtnet0 inet6
```
*Expected Output:*
```text
vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=8000b<TXCSUM,VLAN_MTU,VLAN_HWTAGGING,LINKSTATE>
	inet6 fe80::5054:00ff:fefa:9b12%vtnet0 prefixlen 64 scopeid 0x1
	inet6 2001:db8:1000:abcd:5054:00ff:fefa:9b12 prefixlen 64 autoconf
```

2. Perform a manual Modified EUI-64 Interface Identifier derivation for MAC address `00:15:5d:01:2a:4b`:
   * **Step A (Split MAC):** `00:15:5d` and `01:2a:4b`
   * **Step B (Insert `FF:FE`):** `00:15:5d:ff:fe:01:2a:4b`
   * **Step C (Invert Universal/Local bit):**
     * First octet: `00` (hex) = `00000000` (binary)
     * Bit 7 (0-indexed from left: bit 1 is MSB, bit 7 is $U/L$ bit): `000000`**`1`**`0` = `02` (hex)
   * **Step D (Format to IPv6 colon notation):** `0215:5dff:fe01:2a4b`
   * **Combined with prefix `2001:db8:cafe:1::/64`:** `2001:db8:cafe:1:215:5dff:fe01:2a4b`

3. Inspect the local IPv6 Neighbor Discovery cache using `ndp`:
```bash
$ ndp -a
```
*Expected Output:*
```text
Neighbor                             Linklayer Address  Netif Expire    S Flags
fe80::1%vtnet0                       52:54:00:12:34:56 vtnet0 23m50s    S R
2001:db8:1000:abcd::1                52:54:00:12:34:56 vtnet0 23m42s    V R
```

4. Capture ICMPv6 Neighbor Solicitation (NS) and Neighbor Advertisement (NA) traffic in real time using `tcpdump`:
```bash
$ sudo tcpdump -ni vtnet0 -vvv 'icmp6 and (ip6[40] == 135 or ip6[40] == 136)'
```
*Expected Output:*
```text
20:55:10.482019 IP6 (hlim 255, next-header ICMPv6 (58) payload length: 32) fe80::5054:00ff:fefa:9b12 > ff02::1:ff00:1:
    ICMP6, neighbor solicitation, length 32, who has 2001:db8:1000:abcd::1
	source link-address: 52:54:00:fa:9b:12
20:55:10.482811 IP6 (hlim 255, next-header ICMPv6 (58) payload length: 32) fe80::1 > fe80::5054:00ff:fefa:9b12:
    ICMP6, neighbor advertisement, length 32, tgt 2001:db8:1000:abcd::1, flags [router, solicited, override]
	target link-address: 52:54:00:12:34:56
```

5. Execute an ICMPv6 echo request to the local link-local router, explicitly specifying the required network scope interface:
```bash
$ ping6 -c 3 fe80::1%vtnet0
```
*Expected Output:*
```text
PING6(56=40+8+8 bytes) fe80::5054:00ff:fefa:9b12%vtnet0 --> fe80::1%vtnet0
16 bytes from fe80::1%vtnet0, icmp_seq=0 hlim=64 time=0.412 ms
16 bytes from fe80::1%vtnet0, icmp_seq=1 hlim=64 time=0.389 ms
16 bytes from fe80::1%vtnet0, icmp_seq=2 hlim=64 time=0.395 ms

--- fe80::1%vtnet0 ping6 statistics ---
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/std-dev = 0.389/0.398/0.412/0.010 ms
```

---

#### Comprehension Check: Block 2

1. **Question 2.1:** Given a network interface with MAC address `AC:16:2D:B4:98:C1` configured with SLAAC on network prefix `2001:db8:4444:5555::/64`, calculate the exact Modified EUI-64 global IPv6 address.
2. **Question 2.2:** What ICMPv6 packet types replace IPv4 ARP Request and ARP Reply respectively? State their ICMPv6 type numbers and explain why scope IDs (e.g. `%vtnet0`) are required when probing Link-Local IPv6 addresses.
3. **Question 2.3:** Compress the following IPv6 address to its shortest valid canonical representation per RFC 5952: `2001:0db8:0000:0000:0000:0000:0000:0001`. Can the address `fe80:0000:0000:0001:0000:0000:0000:0056` be compressed as `fe80::1::56`? Explain why or why not.

---

### Guided Exercise 3: Protocol Header Mechanics, State Machines, and Diagnostic Tools (`tcpdump`, `sockstat`, `netstat`)

#### Executive Architectural Context
Network troubleshooting at the Platform Architect / SRE level requires mapping raw network frames to OSI/TCP-IP layers and kernel socket structures:

```
+-------------------------------------------------------------------+
| OSI Model                | TCP/IP Stack     | Protocols / Units   |
+--------------------------+------------------+---------------------+
| Layer 7: Application     |                  | HTTP, DNS, SSH, TLS |
| Layer 6: Presentation    | Application      | (Data Streams)      |
| Layer 5: Session         |                  |                     |
+--------------------------+------------------+---------------------+
| Layer 4: Transport       | Transport        | TCP, UDP (Segments) |
+--------------------------+------------------+---------------------+
| Layer 3: Network         | Internet         | IPv4, IPv6, ICMP    |
|                          |                  | (Packets / Datagrams)|
+--------------------------+------------------+---------------------+
| Layer 2: Data Link       | Link             | Ethernet, L2 Switch |
| Layer 1: Physical        | (Network Access) | (Frames / Bits)     |
+-------------------------------------------------------------------+
```

Key Header Fields & Operational Mechanics:
* **IPv4 Header:** TTL (Time to Live - decremented per hop to prevent loops), Protocol field (`6` for TCP, `17` for UDP, `1` for ICMP), Flags (Don't Fragment - DF, More Fragments - MF).
* **IPv6 Header:** Hop Limit (equivalent to TTL), Next Header (chained headers replacing IPv4 options).
* **TCP Flags & Connection State Machine:** `SYN` $\rightarrow$ `SYN-ACK` $\rightarrow$ `ACK` (Establishes session); `FIN` / `RST` (Tear down session). Window Size enforces flow control.
* **BSD Socket Diagnostics:** BSD systems provide `sockstat` to directly inspect kernel socket allocations (`struct socket`), mapping open sockets to PIDs, user accounts, and file descriptors.

---

#### Step-by-Step Execution Guide

1. Query active listening IPv4 and IPv6 TCP sockets on a BSD host using `sockstat`:
```bash
$ sockstat -46 -l -P tcp
```
*Expected Output:*
```text
USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS      
root     sshd       1048  3  tcp46  *:22                  *:*
www      nginx      1201  6  tcp4   127.0.0.1:8080        *:*
root     ntpd       842   5  tcp4   127.0.0.1:123         *:*
```

2. Inspect protocol mapping configuration files in `/etc`:
```bash
$ grep -E "^(tcp|udp|icmp)\s" /etc/protocols
```
*Expected Output:*
```text
icmp	1	ICMP	# internet control message protocol
tcp	6	TCP	# transmission control protocol
udp	17	UDP	# user datagram protocol
```

3. Trace active kernel routing tables on BSD using `netstat -rn` (or `route -n show` on OpenBSD):
```bash
$ netstat -rn -f inet
```
*Expected Output:*
```text
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
default            192.168.1.1        UGS      vtnet0
10.200.45.128/27   link#1             U        vtnet0
127.0.0.1          link#2             UH          lo0
192.168.1.0/24     link#1             U        vtnet0
192.168.1.50       link#1             UHS         lo0
```

4. Conduct an ICMP Path MTU Discovery (PMTUD) probe to test MTU bottlenecks without fragmenting packets, utilizing the Don't Fragment (DF) bit:
```bash
$ ping -D -s 1472 192.168.1.1
```
*Expected Output:*
```text
PING 192.168.1.1 (192.168.1.1): 1472 data bytes
1480 bytes from 192.168.1.1: icmp_seq=0 ttl=64 time=0.512 ms
1480 bytes from 192.168.1.1: icmp_seq=1 ttl=64 time=0.481 ms

--- 192.168.1.1 ping statistics ---
2 packets transmitted, 2 packets received, 0.0% packet loss
round-trip min/avg/max/std-dev = 0.481/0.496/0.512/0.015 ms
```
*(Note: Total packet size = 1472 payload bytes + 8 bytes ICMP header + 20 bytes IPv4 header = 1500 bytes, exactly matching standard Ethernet MTU).*

5. Capture a full TCP 3-way handshake on port 80 using raw absolute sequence number analysis in `tcpdump`:
```bash
$ sudo tcpdump -ni vtnet0 -S 'tcp port 80 and (tcp[tcpflags] & (tcp-syn|tcp-ack) != 0)'
```
*Expected Output:*
```text
21:02:14.102381 IP 192.168.1.50.49152 > 192.168.1.100.80: Flags [S], seq 3892019201, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
21:02:14.102891 IP 192.168.1.100.80 > 192.168.1.50.49152: Flags [S.], seq 1102938401, ack 3892019202, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
21:02:14.102944 IP 192.168.1.50.49152 > 192.168.1.100.80: Flags [.], seq 3892019202, ack 1102938402, win 1026, length 0
```

---

#### Comprehension Check: Block 3

1. **Question 3.1:** Analyze the `tcpdump` output in Step 5 above. What is the initial sequence number (ISN) generated by the client (`192.168.1.50`)? Explain why the acknowledgment number in packet 2 (`SYN-ACK`) is set to `3892019202` even though the `SYN` packet transmitted 0 bytes of data payload.
2. **Question 3.2:** If an SRE executes `ping -D -s 1473 192.168.1.1` across an Ethernet link with MTU 1500, what ICMP response error type and code will be generated by the local network interface or intermediate router?
3. **Question 3.3:** What is the primary difference between `sockstat` and `netstat` on FreeBSD when inspecting listening network services? Which utility directly correlates an open TCP port to a process executable PID?

---

<details>
<summary><strong>Answers and Detailed Step-by-Step Solutions</strong></summary>

### Solutions for Guided Exercise 1

* **Answer 1.1:**
  * **Hexadecimal Netmask Conversion:** `0xffffffc0` = `11111111.11111111.11111111.11000000` in binary.
  * **CIDR Prefix Length:** Counting set bits gives $8 + 8 + 8 + 2 = 26$. Prefix: `/26`.
  * **Block Size:** $2^{32-26} = 2^6 = 64$.
  * **Subnet Interval Multiples:** $0, 64, 128, 192, 256$.
  * **Network Address:** The host octet value `200` falls between `192` and `255`. Network Address = `172.16.89.192`.
  * **Broadcast Address:** `172.16.89.255` ($192 + 64 - 1$).

* **Answer 1.2:**
  * **CIDR `/22` set bits:** 22 ones, 10 zeros (`11111111.11111111.11111100.00000000`).
  * **Dotted Decimal Notation (DDN):** `255.255.252.0` (Octet 3 = $128+64+32+16+8+4 = 252$).
  * **Hexadecimal Notation:** `255` = `0xFF`, `252` = `0xFC`, `0` = `0x00`. Mask: `0xfffffc00`.
  * **Total IP Addresses:** $2^{32-22} = 2^{10} = 1024$ addresses (1022 usable hosts).

* **Answer 1.3:**
  * **Subnet Requirement:** Need $\ge 6$ subnets and $\ge 25$ hosts per subnet.
  * **Formula:** $2^s \ge 6 \implies s = 3$ bits borrowed from host portion.
  * **New CIDR Prefix:** $24 + 3 = /27$ (Netmask `255.255.255.224`).
  * **Subnets Created:** $2^3 = 8$ subnets.
  * **Usable Hosts Per Subnet:** $2^{32-27} - 2 = 32 - 2 = 30$ hosts (satisfies $\ge 25$).
  * **Subnet 1 (Subnet 0):** `192.168.10.0/27` (Broadcast: `192.168.10.31`)
  * **Subnet 2 (Subnet 1):** `192.168.10.32/27` (Broadcast: `192.168.10.63`)
  * **Subnet 3 (Subnet 2):** `192.168.10.64/27` (Broadcast: `192.168.10.95`).

---

### Solutions for Guided Exercise 2

* **Answer 2.1:**
  * **MAC Address:** `AC:16:2D:B4:98:C1`
  * **Step A (Split):** `AC:16:2D` and `B4:98:C1`
  * **Step B (Insert `FF:FE`):** `AC:16:2D:FF:FE:B4:98:C1`
  * **Step C (Invert $U/L$ bit):** 
    * First octet `AC` (hex) = `10101100` (binary).
    * Inverting bit 7 (2nd LSB): `101011`**`1`**`0` = `AE` (hex).
  * **Step D (Format Interface Identifier):** `ae16:2dff:feb4:98c1`
  * **Full IPv6 Address:** `2001:db8:4444:5555:ae16:2dff:feb4:98c1`

* **Answer 2.2:**
  * **Neighbor Solicitation (NS):** ICMPv6 Type `135` (replaces IPv4 ARP Request).
  * **Neighbor Advertisement (NA):** ICMPv6 Type `136` (replaces IPv4 ARP Reply).
  * **Scope ID Requirement:** Link-Local addresses (`fe80::/10`) are non-routable and can exist identically across multiple local interfaces on the same host (e.g. `vtnet0`, `vtnet1`). The scope ID (e.g., `%vtnet0`) explicitly informs the kernel socket layer which physical interface/link layer to direct the frame to.

* **Answer 2.3:**
  * **Compressed Canonical Form:** `2001:db8::1`. RFC 5952 dictates leading zeros within a 16-bit field must be suppressed, and the longest contiguous run of all-zero fields must be replaced with `::`.
  * **Invalid Compression `fe80::1::56`:** Strictly illegal. The double-colon (`::`) operator can only appear **once** in an IPv6 address string. Multiple `::` usages create ambiguity when reconstructing the exact 128-bit array because the parser cannot determine how many zero fields belong to each `::`. Correct compression for `fe80:0000:0000:0001:0000:0000:0000:0056` is `fe80::1:0:0:0:56` (the longest run of zero fields is at the end: 3 fields vs 2 fields).

---

### Solutions for Guided Exercise 3

* **Answer 3.1:**
  * **Client Initial Sequence Number (ISN):** `3892019201`.
  * **SYN Sequence Consumption:** Control flags `SYN` and `FIN` implicitly consume **1 logical sequence number** in TCP window accounting. This ensures reliable delivery and acknowledgment of the SYN state transition itself, forcing the acknowledgment number of the returning `SYN-ACK` packet to increment to `3892019202` ($3892019201 + 1$).

* **Answer 3.2:**
  * **Error Generated:** `ICMP Destination Unreachable` (ICMPv4 Type `3`).
  * **ICMP Code:** Code `4` = `Fragmentation Needed and DF Flag Set`.
  * **Explanation:** Payload of 1473 bytes + 8 bytes ICMP header + 20 bytes IPv4 header = 1501 bytes. Because 1501 bytes exceeds the 1500-byte MTU limit and the Don't Fragment (`-D` / DF) bit is set, the network interface drops the packet and emits ICMP Type 3, Code 4, returning the next-hop MTU value to the sender.

* **Answer 3.3:**
  * **Key Operational Difference:** `sockstat` queries kernel open socket tables directly (`sysctl` network structures), quickly displaying the owner Process Name (`COMMAND`), Process ID (`PID`), and File Descriptor (`FD`). `netstat` primarily queries general network interface statistics and routing tables.
  * **PID Correlation Utility:** `sockstat` directly maps an open port to its PID.

</details>