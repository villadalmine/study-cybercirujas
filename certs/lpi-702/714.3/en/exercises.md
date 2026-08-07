# LPI 702-100: BSD Specialist Certification — Topic 714.3: Basic Network Troubleshooting

**Weight:** 5  
**Level:** Advanced SRE / Production Platform Architect  
**Official Reference:** [LPI BSD Specialist Objectives & Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## Technical Overview & Internal Mechanics

Network troubleshooting across BSD variants (FreeBSD, OpenBSD, NetBSD) requires a methodical, layered approach anchored in the OSI model. Understanding BSD kernel network stack internals is essential for diagnosing failures under heavy production loads.

```
+-----------------------------------------------------------------------+
|                        Application Layer (L7)                         |
|                 (curl, dig, drill, host, nc, telnet)                  |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                        Transport Layer (L4)                           |
|       (TCP, UDP, SCTP - Inspected via sockstat, netstat, fstat)        |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                         Network Layer (L3)                            |
|    (IP Routing, ICMP, ARP/NDP - Inspected via route, ping, traceroute)|
|                    FreeBSD Radix Tree Routing Table                   |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                        Data Link Layer (L2)                           |
|         (Ethernet, VLANs, LAGG - Inspected via ifconfig, arp)         |
|         Berkeley Packet Filter (BPF) tapped via tcpdump               |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                        Physical Layer (L1)                            |
|             (Media status, autoneg, duplex via ifconfig)              |
+-----------------------------------------------------------------------+
```

### Key Architectural Concepts
1. **Link Status & Media Negotiaton (L1/L2):** The BSD kernel exposes interface state flags via `ifconfig`. Key flags include `UP` (administrative enablement), `RUNNING` (driver allocated resources and link layer ready), `PROMISC` (promiscuous mode), and `OACTIVE` (transmission queue overflow). Link state changes are managed by the kernel interface layer (`ifnet` structure).
2. **Address Resolution Protocol (ARP / NDP):** Maps L3 IP addresses to L2 MAC addresses. In FreeBSD, ARP entries reside in an in-memory hash table managed by `in_arpcom`, viewable with `arp -a`. For IPv6, Neighbor Discovery Protocol (NDP) operates over ICMPv6 and is managed via `ndp -a`.
3. **Radix Tree Routing Table (L3):** BSD uses a Patricia/Radix tree data structure for matching IP destination routes. Route lookups execute Longest Prefix Match (LPM). Network routing tables are queried using `netstat -rn` and modified using `route(8)`.
4. **Socket State Inspection (L4):** BSD provides `sockstat(1)` (a native replacement for `lsof` / Linux `ss`) which queries kernel socket tables (`sysctl` nodes `kern.ipc.sockets` and `net.inet.tcp.sctp_pcbinfo`) directly to map processes (PIDs, UIDs) to open file descriptors, local/remote IP endpoints, and socket states (e.g., `LISTEN`, `ESTABLISHED`, `TIME_WAIT`).
5. **Berkeley Packet Filter (BPF):** `tcpdump` attaches to raw BPF kernel devices (`/dev/bpf*`). BPF compiles filters into pseudo-machine instructions that execute directly inside the kernel context, eliminating user/kernel context switches for non-matching packets.

---

## Guided Exercises

---

### Exercise 1: Physical and Link Layer (L1/L2) Diagnostics

#### Steps
1. Display detailed configuration and state for all network interfaces on the system:
   ```bash
   ifconfig -a
   ```
   **Expected Output:**
   ```text
   vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
           options=80007<PERFORMANCE,VLAN_MTU,VLAN_HWTAGGING,LINKSTATE>
           ether 52:54:00:12:34:56
           inet 192.168.1.50 netmask 0xffffff00 broadcast 192.168.1.255
           inet6 fe80::5054:ff:fe12:3456%vtnet0 prefixlen 64 scopeid 0x1
           media: Ethernet autoselect (1000baseT <full-duplex>)
           status: active
           nd6 options=23<PERF,ACCEPT_RTADV,AUTO_LINKLOCAL>
   lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> metric 0 mtu 16384
           options=680003<RXCSUM,TXCSUM,LINKSTATE,RXCSUM_IPV6,TXCSUM_IPV6>
           inet 127.0.0.1 netmask 0xff000000
           inet6 ::1 prefixlen 128
           inet6 fe80::1%lo0 prefixlen 64 scopeid 0x2
           groups: lo
           nd6 options=21<PERF,AUTO_LINKLOCAL>
   ```

2. Inspect link errors, dropped packets, and collision counters on interface `vtnet0`:
   ```bash
   netstat -I vtnet0 -b
   ```
   **Expected Output:**
   ```text
   Name    Mtu Network       Address              Ipkts Ierrs Opkts Oerrs  Coll Drop
   vtnet0 1500 <Link#1>      52:54:00:12:34:56  142093     0 98231     0     0    0
   vtnet0 1500 192.168.1.0/2 192.168.1.50       141802     - 98110     -     -    -
   ```

3. Query the current L2 ARP cache table to identify resolved MAC addresses:
   ```bash
   arp -a
   ```
   **Expected Output:**
   ```text
   gateway (192.168.1.1) at 00:11:22:33:44:55 on vtnet0 expires in 1180 seconds [ethernet]
   host2 (192.168.1.100) at 52:54:00:ab:cd:ef on vtnet0 expires in 850 seconds [ethernet]
   ```

4. Force flush an invalid or stale ARP entry for IP `192.168.1.100`:
   ```bash
   sudo arp -d 192.168.1.100
   ```
   **Expected Output:**
   ```text
   192.168.1.100 (192.168.1.100) deleted
   ```

#### Verification Questions (Exercise 1)
1. **Q1.1:** What is the technical difference between the `UP` and `RUNNING` flags in `ifconfig` output?
2. **Q1.2:** If `Ierrs` or `Coll` counters are steadily incrementing in `netstat -I <interface>`, what underlying physical or link-layer issues are indicated?

---

### Exercise 2: Network Layer (L3) Routing & Path Diagnostics

#### Steps
1. Display the IPv4 kernel routing table with numeric IP representation:
   ```bash
   netstat -rn -f inet
   ```
   **Expected Output:**
   ```text
   Routing tables

   Internet:
   Destination        Gateway            Flags     Netif Expire
   default            192.168.1.1        UGS      vtnet0
   127.0.0.1          link#2             UH          lo0
   192.168.1.0/24     link#1             U        vtnet0
   192.168.1.50       link#1             UHS         lo0
   ```

2. Test L3 reachability to a remote endpoint while altering packet size and disabling IP fragmentation to discover Path MTU (PMTU):
   ```bash
   ping -c 3 -D -s 1472 1.1.1.1
   ```
   **Expected Output:**
   ```text
   PING 1.1.1.1 (1.1.1.1): 1472 data bytes
   1480 bytes from 1.1.1.1: icmp_seq=0 ttl=58 time=12.341 ms
   1480 bytes from 1.1.1.1: icmp_seq=1 ttl=58 time=11.892 ms
   1480 bytes from 1.1.1.1: icmp_seq=2 ttl=58 time=12.105 ms

   --- 1.1.1.1 ping statistics ---
   3 packets transmitted, 3 packets received, 0.0% packet loss
   round-trip min/avg/max/stddev = 11.892/12.112/12.341/0.185 ms
   ```

3. Trace the network path and hop latency to remote destination `8.8.8.8` using ICMP ECHO probes (overcoming firewalls blocking default UDP probes):
   ```bash
   traceroute -I 8.8.8.8
   ```
   **Expected Output:**
   ```text
   traceroute to 8.8.8.8 (8.8.8.8), 64 hops max, 48 byte packets
    1  192.168.1.1 (192.168.1.1)  1.102 ms  0.893 ms  0.941 ms
    2  10.0.0.1 (10.0.0.1)  4.215 ms  3.890 ms  4.112 ms
    3  172.16.32.1 (172.16.32.1)  8.450 ms  8.120 ms  8.301 ms
    4  dns.google (8.8.8.8)  11.950 ms  11.512 ms  11.780 ms
   ```

4. Manually add a static host route to send traffic destined for `10.200.1.5` via gateway `192.168.1.254`:
   ```bash
   sudo route add -host 10.200.1.5 192.168.1.254
   ```
   **Expected Output:**
   ```text
   add host 10.200.1.5: gateway 192.168.1.254
   ```

5. Verify the route resolution path selected by the BSD Radix tree for destination `10.200.1.5`:
   ```bash
   route get 10.200.1.5
   ```
   **Expected Output:**
   ```text
      route to: 10.200.1.5
   destination: 10.200.1.5
       gateway: 192.168.1.254
        fib: 0
     interface: vtnet0
         flags: <UP,GATEWAY,HOST,DONE,STATIC>
    recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire
           0         0         0         0      1500         0         0
   ```

#### Verification Questions (Exercise 2)
1. **Q2.1:** In the `ping -c 3 -D -s 1472 1.1.1.1` command, why does an ICMP payload size of 1472 bytes verify an Ethernet MTU of 1500 bytes?
2. **Q2.2:** What does the flag `UGS` signify in `netstat -rn` output?

---

### Exercise 3: Transport Layer (L4) Socket & Service Inspection

#### Steps
1. Use FreeBSD native `sockstat` tool to inspect all listening IPv4 and IPv6 sockets alongside their bound daemon PIDs, command names, and port numbers:
   ```bash
   sockstat -4 -6 -l
   ```
   **Expected Output:**
   ```text
   USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS
   root     sshd       1204  3  tcp4   *:22                  *:*
   root     sshd       1204  4  tcp6   *:22                  *:*
   bind     named      945   20 tcp4   127.0.0.1:53          *:*
   bind     named      945   21 udp4   127.0.0.1:53          *:*
   www      nginx      1532  6  tcp4   *:80                  *:*
   www      nginx      1532  7  tcp4   *:443                 *:*
   ```

2. Identify active established TCP connections on the system:
   ```bash
   sockstat -4 -c -c
   ```
   **Expected Output:**
   ```text
   USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS
   root     sshd       2041  5  tcp4   192.168.1.50:22       192.168.1.105:54322
   www      nginx      1532  8  tcp4   192.168.1.50:443      10.45.2.14:61204
   ```

3. Query global TCP protocol stack statistics (retransmissions, dropped connections, checksum errors) via `netstat`:
   ```bash
   netstat -s -p tcp
   ```
   **Expected Output:**
   ```text
   tcp:
           241045 packets sent
                   198421 data packets (28491204 bytes)
                   114 data packets (150244 bytes) retransmitted
           310941 packets received
                   214091 acks (for 28491000 bytes)
                   0 bad connection attempt requests
                   12 connection drops in rxmt timeout
   ```

4. Perform a port connection test and banners-grab on remote target `192.168.1.100` on port `80` with a timeout of 3 seconds using `nc` (Netcat):
   ```bash
   nc -v -z -w 3 192.168.1.100 80
   ```
   **Expected Output:**
   ```text
   Connection to 192.168.1.100 80 port [tcp/http] succeeded!
   ```

#### Verification Questions (Exercise 3)
1. **Q3.1:** How does `sockstat` differ fundamentally from `netstat` when diagnosing local service binding issues?
2. **Q3.2:** What does a high count of retransmitted data packets in `netstat -s -p tcp` output indicate in a production database server environment?

---

### Exercise 4: Layer 7 DNS Diagnostics & Packet Capture Analysis (BPF / tcpdump)

#### Steps
1. Execute a low-level DNS resolution query against local resolver `127.0.0.1` for host `freebsd.org` using `drill` (standard BSD DNS diagnostic tool replacing `dig`):
   ```bash
   drill freebsd.org @127.0.0.1
   ```
   **Expected Output:**
   ```text
   ;; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 41029
   ;; flags: qr rd ra ; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 0
   ;; QUESTION SECTION:
   ;; freebsd.org.  IN  A

   ;; ANSWER SECTION:
   freebsd.org. 3600 IN A 96.47.72.84
   freebsd.org. 3600 IN A 2610:1c1:1:607c::84

   ;; Query time: 14 msec
   ;; SERVER: 127.0.0.1
   ;; WHEN: Thu Aug  6 20:54:10 2026
   ;; MSG SIZE rcvd: 71
   ```

2. Interrogate reverse DNS (PTR record) mapping for IP `96.47.72.84` using `host`:
   ```bash
   host 96.47.72.84
   ```
   **Expected Output:**
   ```text
   84.72.47.96.in-addr.arpa domain name pointer wfe0.bsdgroup.ipv4.freebsd.org.
   ```

3. Capture real-time live network traffic on interface `vtnet0`, filtering specifically for DNS traffic (UDP/TCP port 53) without resolving IP addresses or port names (`-nn`):
   ```bash
   sudo tcpdump -i vtnet0 -nn -c 4 'port 53'
   ```
   **Expected Output:**
   ```text
   tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
   listening on vtnet0, link-type EN10MB (Ethernet), capture size 262144 bytes
   20:54:10.102341 IP 192.168.1.50.53412 > 127.0.0.1.53: 12415+ A? freebsd.org. (29)
   20:54:10.116812 IP 127.0.0.1.53 > 192.168.1.50.53412: 12415 1/0/0 A 96.47.72.84 (45)
   20:54:10.120101 IP 192.168.1.50.61203 > 1.1.1.1.53: 41209+ A? pkg.freebsd.org. (33)
   20:54:10.134219 IP 1.1.1.1.53 > 192.168.1.50.61203: 41209 2/0/0 A 96.47.72.71, A 96.47.72.72 (65)
   4 packets captured
   4 packets received by filter
   0 packets dropped by kernel
   ```

4. Capture and write TCP SYN packets (connection establishment attempts) to a binary PCAP file for offline analysis:
   ```bash
   sudo tcpdump -i vtnet0 -nn -w /tmp/syn_capture.pcap 'tcp[tcpflags] & tcp-syn != 0'
   ```
   **Expected Output:**
   ```text
   tcpdump: listening on vtnet0, link-type EN10MB (Ethernet), capture size 262144 bytes
   ^C12 packets captured
   15 packets received by filter
   0 packets dropped by kernel
   ```

5. Read and analyze the saved PCAP capture with detailed header timestamps and sequence numbers:
   ```bash
   tcpdump -nn -r /tmp/syn_capture.pcap
   ```
   **Expected Output:**
   ```text
   reading from file /tmp/syn_capture.pcap, link-type EN10MB (Ethernet)
   20:54:30.412109 IP 192.168.1.50.49152 > 192.168.1.100.80: Flags [S], seq 312451298, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
   20:54:31.412501 IP 192.168.1.50.49152 > 192.168.1.100.80: Flags [S], seq 312451298, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
   ```

#### Verification Questions (Exercise 4)
1. **Q4.1:** What does the `rcode: NOERROR` vs `rcode: NXDOMAIN` mean in a `drill` query output?
2. **Q4.2:** In `tcpdump`, why is it critical to pass `-nn` when troubleshooting under high traffic/load conditions in production?
3. **Q4.3:** In the output of Step 5 (`tcpdump -r /tmp/syn_capture.pcap`), the exact same SYN packet is transmitted twice spaced ~1 second apart without receiving a `[S.]` (SYN-ACK). What SRE-level root cause does this indicate?

---

## Solutions & Verification Answers

<details>
<summary>Click here to expand the detailed solutions for all exercise questions</summary>

### Exercise 1 Solutions
* **A1.1:** `UP` indicates the administrative state of the interface (the system administrator has toggled it enabled via `ifconfig <interface> up`). `RUNNING` indicates the operational state: the kernel driver has allocated memory buffers (mbufs), configured hardware registers, and established that the interface hardware is active and ready to transmit/receive frames. An interface can be `UP` but not `RUNNING` if the link cable is unplugged or driver initialization failed.
* **A1.2:** High `Ierrs` (Input Errors) typically indicate corrupted frames, framing errors, or bad CRCs caused by faulty cabling, damaged SFP/SFP+ transceivers, or bad switch ports. High `Coll` (Collisions) on modern Ethernet indicates a duplex mismatch (e.g., one end forced to `half-duplex` while the other is `full-duplex` or `autoselect`).

### Exercise 2 Solutions
* **A2.1:** Standard Ethernet MTU is 1500 bytes. An IP header requires 20 bytes and a standard ICMP Echo Request header requires 8 bytes ($20 + 8 = 28$ bytes of protocol overhead). Therefore:
  $$\text{Payload} (1472) + \text{IP Header} (20) + \text{ICMP Header} (8) = 1500 \text{ bytes (Exact MTU limit)}$$
  Using `-D` sets the DF (Don't Fragment) bit. If packet size exceeds MTU along the path, an ICMP "Fragmentation Needed and DF set" error is returned.
* **A2.2:** 
  * `U`: Route is **Up** (active).
  * `G`: Route uses a **Gateway** (requires forwarding to an intermediate L3 router).
  * `S`: Route was **Statically** added (manually defined or set via `/etc/rc.conf` static routes, not dynamically learned via RIP/OSPF/BGP).

### Exercise 3 Solutions
* **A3.1:** `netstat` lists open socket handles across the network stack, but requires cross-referencing socket inode numbers via external tools to identify owner processes. `sockstat` directly interrogates FreeBSD kernel structures (`sysctl` network Control Blocks) to map socket bindings directly to process binary names (`COMMAND`), Process IDs (`PID`), User IDs (`USER`), and File Descriptors (`FD`) in a single atomic call.
* **A3.2:** High TCP retransmissions indicate packet loss on the network, severe link congestion, or buffer overflow on intermediate network switches or remote host NIC rings. This forces TCP to trigger congestion control algorithms (reducing congestion window size `cwnd`), leading to severe application latency spikes and degraded database throughput.

### Exercise 4 Solutions
* **A4.1:** `NOERROR` indicates the DNS server successfully processed the query and found matching records (or an empty answer set for an existing node). `NXDOMAIN` (Non-Existent Domain) indicates the queried domain name does not exist in the DNS root tree structure.
* **A4.2:** Without `-nn`, `tcpdump` performs synchronous reverse DNS lookups for every captured IP address and service port name lookups (`/etc/services`). Under high packet rates, this causes massive CPU overhead, blocks the packet processing loop, fills BPF kernel buffer queues, and causes severe packet dropping (`packets dropped by kernel`).
* **A4.3:** Consecutive outgoing `[S]` (SYN) packets without receiving an incoming `[S.]` (SYN-ACK) packet indicate that TCP handshake requests are either being silently dropped by an upstream firewall/stateful filter (PF/IPFW), or the target daemon is unreachable / not listening and network rules drop outbound ICMP Port Unreachable responses.

</details>

---

## Official References & Direct Documentation Links
* [FreeBSD ifconfig(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?ifconfig(8))
* [FreeBSD netstat(1) Manual Page](https://man.freebsd.org/cgi/man.cgi?netstat(1))
* [FreeBSD sockstat(1) Manual Page](https://man.freebsd.org/cgi/man.cgi?sockstat(1))
* [FreeBSD route(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?route(8))
* [FreeBSD tcpdump(1) Manual Page](https://man.freebsd.org/cgi/man.cgi?tcpdump(1))
* [LPI BSD Specialist 702 Objectives Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)