# LPIC-2 Certification (Exams 201-450 & 202-450, v4.5)
## Topic 205: Network Configuration (Exam 201-450) — Production-Grade Lab Manual & Guided Exercises

**Weight:** 7  
**Official Reference:** [LPI LPIC-2 Exam Objectives](https://www.lpi.org/our-certifications/lpic-2-overview/) | [Linux Foundation iproute2 Documentation](https://wiki.linuxfoundation.org/networking/iproute2) | [Linux Kernel Networking Subsystem Documentation](https://www.kernel.org/doc/Documentation/networking/)

---

### Architectural Overview & Kernel Mechanics

In modern Linux kernel architectures (Kernel 4.x/5.x/6.x), network configuration has evolved from the legacy `net-tools` suite (`ifconfig`, `route`, `arp`) which relied on legacy `ioctl()` system calls, to the modern `iproute2` suite (`ip`, `ss`, `tc`), which communicates directly with the kernel via the **Netlink Sockets Protocol** (`AF_NETLINK`). 

Netlink provides an asynchronous, full-duplex socket-based IPC interface between user-space utilities and kernel subsystems (specifically `NETLINK_ROUTE`). This architecture eliminates the performance overhead of traditional `ioctl()` calls, enables real-time kernel event monitoring (e.g., `ip monitor`), and exposes advanced subsystem features such as Policy-Based Routing (PBR), multiple routing tables, 802.1Q VLAN tagging, software bridging, and network namespaces.

```
+-----------------------------------------------------------------------+
|                              USER SPACE                               |
|   +-------------------+    +--------------------+    +------------+   |
|   |  iproute2 (ip)    |    |  Systemd-networkd  |    |  Netplan   |   |
|   +---------+---------+    +---------+----------+    +-----+------+   |
+-------------|------------------------|---------------------|----------+
              | AF_NETLINK             | AF_NETLINK          | YAML Config
              v                        v                     v
+-----------------------------------------------------------------------+
|                             KERNEL SPACE                              |
|   +---------------------------------------------------------------+   |
|   |                   Netlink Interface Subsystem                 |   |
|   +---------------------------------------------------------------+   |
|   | Core Networking Stack (sk_buff management, socket buffers)    |   |
|   +-------------------+--------------------+----------------------+   |
|   | Policy Routing    | 802.1Q VLAN        | Link Aggregation     |   |
|   | (FIB / rt_tables) | Engine             | (Bonding/Bridging)   |   |
|   +-------------------+--------------------+----------------------+   |
|   |                    Network Device Drivers (NIC)               |   |
+-----------------------------------------------------------------------+
```

---

### Lab Setup Requirements & Environment Assumptions

All exercises are designed for modern enterprise Linux distributions (RHEL 8/9, AlmaLinux, Rocky Linux, Debian 11/12, Ubuntu 22.04/24.04 LTS).

**Prerequisite Network Topologies:**
- Primary Interface: `eth0` (or `ens192` / `enp0s3`) — IP: `192.168.1.50/24`, Gateway: `192.168.1.1`
- Secondary Interface: `eth1` (or `ens224` / `enp0s8`) — IP: `10.0.0.50/24`, Gateway: `10.0.0.1`
- Root or `sudo` privileges required.

---

### Exercise 1: Low-Level Interface Manipulation, Name Resolution, and Dual-Stack Configuration

#### Theoretical Background & Mechanics
The domain name resolution subsystem on Linux relies on the Name Service Switch (NSS) daemon configured in `/etc/nsswitch.conf`. When a process issues a socket lookup (e.g., `getaddrinfo()`), the C library (`glibc`) parses the `hosts:` database line in `/etc/nsswitch.conf`. If set to `hosts: files dns`, local resolution via `/etc/hosts` takes strict priority over recursive DNS queries sent to resolver addresses listed in `/etc/resolv.conf`.

#### Guided Execution Steps

1. Inspect current network link states and socket statistics using `iproute2` tools.
   ```bash
   ip -stats link show dev eth0
   ```
   *Expected Output:*
   ```text
   2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000
       link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
       RX:  bytes packets errors dropped overrun mcast
         10485760   12450      0       0       0     0
       TX:  bytes packets errors dropped carrier collsns
          2097152    8500      0       0       0     0
   ```

2. Assign a secondary static IPv4 address (IP alias) and an IPv6 global unicast address to `eth0`.
   ```bash
   sudo ip addr add 192.168.1.75/24 dev eth0 label eth0:1
   sudo ip -6 addr add 2001:db8:1::50/64 dev eth0
   ```

3. Verify interface IP addressing and flags.
   ```bash
   ip addr show dev eth0
   ```
   *Expected Output:*
   ```text
   2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
       link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
       inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0
          valid_lft forever preferred_lft forever
       inet 192.168.1.75/24 scope global secondary eth0:1
          valid_lft forever preferred_lft forever
       inet6 2001:db8:1::50/64 scope global 
          valid_lft forever preferred_lft forever
       inet6 fe80::5054:ff:fe12:3456/64 scope link 
          valid_lft forever preferred_lft forever
   ```

4. Modify physical layer parameters using `ethtool` to disable Hardware Offloading (TCP Segmentation Offload - TSO, Receive Side Coalescing - GRO) for low-latency network troubleshooting.
   ```bash
   sudo ethtool -K eth0 tso off gro off
   ethtool -k eth0 | grep -E "(tcp-segmentation|generic-receive)-offload"
   ```
   *Expected Output:*
   ```text
   tcp-segmentation-offload: off
   generic-receive-offload: off
   ```

5. Configure persistence via canonical system configuration manifests:

   *Debian/Ubuntu (`/etc/network/interfaces`):*
   ```ini
   # /etc/network/interfaces
   auto eth0
   iface eth0 inet static
       address 192.168.1.50/24
       gateway 192.168.1.1
       dns-nameservers 1.1.1.1 8.8.8.8

   iface eth0 inet6 static
       address 2001:db8:1::50/64
       gateway 2001:db8:1::1

   auto eth0:1
   iface eth0:1 inet static
       address 192.168.1.75/24
   ```

   *RHEL/CentOS/AlmaLinux Legacy (`/etc/sysconfig/network-scripts/ifcfg-eth0`):*
   ```ini
   DEVICE=eth0
   BOOTPROTO=none
   ONBOOT=yes
   TYPE=Ethernet
   IPADDR=192.168.1.50
   PREFIX=24
   GATEWAY=192.168.1.1
   DNS1=1.1.1.1
   DNS2=8.8.8.8
   IPV6INIT=yes
   IPV6ADDR=2001:db8:1::50/64
   IPV6_DEFAULTGW=2001:db8:1::1
   ```

   *Netplan (`/etc/netplan/01-netcfg.yaml`):*
   ```yaml
   network:
     version: 2
     renderer: networkd
     ethernets:
       eth0:
         dhcp4: no
         dhcp6: no
         addresses:
           - 192.168.1.50/24
           - 192.168.1.75/24
           - "2001:db8:1::50/64"
         routes:
           - to: default
             via: 192.168.1.1
           - to: default
             via: "2001:db8:1::1"
         nameservers:
           addresses: [1.1.1.1, 8.8.8.8]
   ```

6. Audit `/etc/nsswitch.conf` and `/etc/resolv.conf` to verify system name resolution ordering.
   ```bash
   grep -E "^hosts:" /etc/nsswitch.conf
   cat /etc/resolv.conf
   ```
   *Expected Output:*
   ```text
   hosts:          files dns myhostname
   # Generated by NetworkManager or systemd-resolved
   nameserver 1.1.1.1
   nameserver 8.8.8.8
   options timeout:2 attempts:3 rotate
   ```

---

#### Comprehension Questions — Exercise 1

- **Q1.1:** What is the fundamental architectural difference between legacy `ifconfig` (from `net-tools`) and `ip addr` (from `iproute2`) regarding how they query and manipulate kernel interface states?
- **Q1.2:** If an administrator adds a secondary IP address via `ip addr add 192.168.1.75/24 dev eth0` without providing a label (`label eth0:1`), how will legacy tools like `ifconfig` display this secondary address, and why?
- **Q1.3:** Explain the operational impact of the `options rotate` directive in `/etc/resolv.conf` under heavy web microservice traffic.

---

### Exercise 2: Advanced Policy-Based Routing (PBR) and Multi-Homed Architecture

#### Theoretical Background & Mechanics
Standard IP routing operates purely on destination addresses via a single Forwarding Information Base (FIB). In multi-homed servers (connected to multiple ISPs or distinct subnets), default routing fails when traffic arriving on a secondary interface attempts to reply via the primary interface's default gateway. This causes asymmetric routing and trigger Reverse Path Filtering (`rp_filter`) packet drops in security-hardened kernels.

Policy-Based Routing (PBR) overcomes this by decoupling route selection from destination-only lookups. Linux implements PBR using multiple routing tables defined in `/etc/iproute2/rt_tables` combined with Routing Policy Database (RPDB) rules managed via `ip rule`.

```
                        +----------------------------+
                        |   Incoming Packet on eth1  |
                        +--------------+-------------+
                                       |
                                       v
                        +----------------------------+
                        |  RPDB Evaluation (ip rule) |
                        +--------------+-------------+
                                       |
                  +--------------------+--------------------+
                  | Match Rule:                             | Match Rule:
                  | "from 10.0.0.50 lookup T2"              | Default fallback
                  v                                         v
    +---------------------------+             +---------------------------+
    | Routing Table 102 (T2)    |             | Main Routing Table        |
    | Gateway: 10.0.0.1 (eth1)  |             | Gateway: 192.168.1.1(eth0)|
    +-------------+-------------+             +-------------+-------------+
                  |                                         |
                  v                                         v
    +---------------------------+             +---------------------------+
    | Symmetric Outbound (eth1) |             | Standard Outbound (eth0)  |
    +---------------------------+             +---------------------------+
```

#### Guided Execution Steps

1. View the default RPDB rules.
   ```bash
   ip rule show
   ```
   *Expected Output:*
   ```text
   0:	from all lookup local
   32766:	from all lookup main
   32767:	from all lookup default
   ```

2. Register custom routing tables in `/etc/iproute2/rt_tables`.
   ```bash
   sudo sh -c 'echo "101 T1" >> /etc/iproute2/rt_tables'
   sudo sh -c 'echo "102 T2" >> /etc/iproute2/rt_tables'
   tail -n 2 /etc/iproute2/rt_tables
   ```
   *Expected Output:*
   ```text
   101 T1
   102 T2
   ```

3. Populate table `T1` (for `eth0` / `192.168.1.0/24`) and table `T2` (for `eth1` / `10.0.0.0/24`) with network paths and gateway rules.
   ```bash
   sudo ip route add 192.168.1.0/24 dev eth0 src 192.168.1.50 table T1
   sudo ip route add default via 192.168.1.1 dev eth0 table T1

   sudo ip route add 10.0.0.0/24 dev eth1 src 10.0.0.50 table T2
   sudo ip route add default via 10.0.0.1 dev eth1 table T2
   ```

4. Create RPDB policies to bind source IP addresses to their respective routing tables.
   ```bash
   sudo ip rule add from 192.168.1.50 table T1 pref 100
   sudo ip rule add from 10.0.0.50 table T2 pref 200
   ```

5. Verify table contents and active RPDB rule priority logic.
   ```bash
   ip rule show
   ip route show table T2
   ```
   *Expected Output:*
   ```text
   0:	from all lookup local
   100:	from 192.168.1.50 lookup T1
   200:	from 10.0.0.50 lookup T2
   32766:	from all lookup main
   32767:	from all lookup default

   default via 10.0.0.1 dev eth1 
   10.0.0.0/24 dev eth1 scope link src 10.0.0.50
   ```

6. Simulate route lookups from kernel space to test PBR behavior.
   ```bash
   ip route get 8.8.8.8 from 10.0.0.50
   ```
   *Expected Output:*
   ```text
   8.8.8.8 via 10.0.0.1 dev eth1 table T2 src 10.0.0.50 uid 0
       cache
   ```

7. Audit kernel Reverse Path Filtering settings to prevent asymmetric packet drops.
   ```bash
   sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.eth1.rp_filter
   ```
   *Expected Output:*
   ```text
   net.ipv4.conf.all.rp_filter = 2
   net.ipv4.conf.eth1.rp_filter = 2
   ```
   *(Note: Value `2` enables Loose Reverse Path Filtering, which accepts packets if the source address is reachable via ANY interface, required for asymmetric or PBR routing).*

---

#### Comprehension Questions — Exercise 2

- **Q2.1:** What is the technical function of the `pref` (preference/priority) parameter in `ip rule add`, and what happens if two rules have identical priorities?
- **Q2.2:** What is the critical difference between strict (`rp_filter = 1`) and loose (`rp_filter = 2`) reverse path filtering in a multi-homed Linux server environment?
- **Q2.3:** In `/etc/iproute2/rt_tables`, what are the reserved table names/IDs, and what role does table `local` play in the kernel processing loop?

---

### Exercise 3: Advanced Link Layer Aggregation (Bonding/LACP), Bridging, and 802.1Q VLAN Tagging

#### Theoretical Background & Mechanics
Enterprise virtualization hosts (KVM/QEMU) require high availability at Layer 2 and network segmentation. 
- **Bonding (LACP Mode 4 / IEEE 802.3ad):** Combines multiple physical links into a single logical link, multiplexing frames based on transmit hash policies (Layer 2, Layer 2+3, or Layer 3+4). Requires switch-side LACP configuration.
- **802.1Q VLAN Tagging:** Inserts a 4-byte VLAN header (TPID `0x8100` + 12-bit VLAN ID) into Ethernet frames.
- **Linux Software Bridge:** Acts as a virtual Layer 2 IEEE 802.1D ethernet switch inside the kernel, forwarding frames using an internal MAC address learning table (FDB - Forwarding Database).

```
                      +-----------------------------------+
                      |      Virtual Bridge (br0)         |
                      |      IP: 10.200.0.10/24           |
                      +-----------------+-----------------+
                                        |
                                        v
                      +-----------------+-----------------+
                      |     VLAN Sub-interface            |
                      |     bond0.200 (VLAN ID 200)     |
                      +-----------------+-----------------+
                                        |
                                        v
                      +-----------------+-----------------+
                      |     Bonded Master Interface       |
                      |     bond0 (Mode 4 - 802.3ad)     |
                      +--------+----------------+---------+
                               |                |
             +-----------------+                +-----------------+
             v                                                    v
+------------------------+                              +------------------------+
| Slave: eth1            |                              | Slave: eth2            |
+------------------------+                              +------------------------+
```

#### Guided Execution Steps

1. Load kernel bonding module with explicit parameters.
   ```bash
   sudo modprobe bonding
   ```

2. Create a LACP Bond (`bond0`), set hash policy to `layer3+4` for optimal multi-flow distribution, add slave interfaces, and bring the link up.
   ```bash
   sudo ip link add dev bond0 type bond mode 802.3ad miimon 100 xmit_hash_policy layer3+4
   sudo ip link set dev eth1 master bond0
   sudo ip link set dev eth2 master bond0
   sudo ip link set dev eth1 up
   sudo ip link set dev eth2 up
   sudo ip link set dev bond0 up
   ```

3. Query the bond operational state via `/proc` filesystem interfaces.
   ```bash
   cat /proc/net/bonding/bond0
   ```
   *Expected Output:*
   ```text
   Ethernet Channel Bonding Driver: v5.15.0-89-generic

   Bonding Mode: IEEE 802.3ad Dynamic link aggregation
   Transmit Hash Policy: layer3+4 (1)
   MII Status: up
   MII Polling Interval (ms): 100
   Up Delay (ms): 0
   Down Delay (ms): 0
   Peer Encryption Key: 

   802.3ad info
   LACP rate: slow
   Min links: 0
   Aggregator selection policy (ad_select): bandwidth
   System priority: 65535
   System MAC address: 52:54:00:ab:cd:ef
   Active Aggregator Info:
   	Aggregator ID: 1
   	Number of ports: 2
   	Actor Key: 17
   	Partner Key: 1

   Slave Interface: eth1
   MII Status: up
   Speed: 10000 Mbps
   Duplex: full
   Link Failure Count: 0
   Permanent HW addr: 52:54:00:11:22:33
   Aggregator ID: 1

   Slave Interface: eth2
   MII Status: up
   Speed: 10000 Mbps
   Duplex: full
   Link Failure Count: 0
   Permanent HW addr: 52:54:00:44:55:66
   Aggregator ID: 1
   ```

4. Create an IEEE 802.1Q tagged VLAN interface (`bond0.200`) over the trunked bond link.
   ```bash
   sudo ip link add link bond0 name bond0.200 type vlan id 200
   sudo ip link set dev bond0.200 up
   ```

5. Create a virtual software bridge (`br0`), attach the VLAN interface `bond0.200` to it, and assign an IP address to the bridge interface.
   ```bash
   sudo ip link add name br0 type bridge
   sudo ip link set dev bond0.200 master br0
   sudo ip addr add 10.200.0.10/24 dev br0
   sudo ip link set dev br0 up
   ```

6. Inspect Bridge Forwarding Database (FDB) and bridge link status.
   ```bash
   ip link show dev br0
   bridge fdb show dev bond0.200
   ```
   *Expected Output:*
   ```text
   7: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
       link/ether 52:54:00:ab:cd:ef brd ff:ff:ff:ff:ff:ff
   52:54:00:ab:cd:ef master br0 permanent
   3c:ec:ef:99:88:77 vlan 200 master br0
   ```

---

#### Comprehension Questions — Exercise 3

- **Q3.1:** What is the technical mechanism of `miimon` in the Linux bonding driver, and what happens if `miimon` is set to `0`?
- **Q3.2:** Why is `xmit_hash_policy layer3+4` superior to `layer2` in a high-density LACP environment connected to a core switch?
- **Q3.3:** In a software bridge scenario for virtual machine networking, why must the IP address be assigned to the bridge interface (`br0`) rather than member interfaces (`eth0` or `bond0.200`)?

---

### Exercise 4: Production Network Diagnostics, Socket State Analysis, and Packet Capture

#### Theoretical Background & Mechanics
Modern Linux network diagnostics requires understanding socket states (`TCP_ESTABLISHED`, `TIME_WAIT`, `CLOSE_WAIT`), kernel socket buffer allocation (`rmem`, `wmem`), and ICMP type processing (`Time Exceeded`, `Destination Unreachable`). 

Tools like `ss` extract socket diagnostic information directly from kernel memory using `sock_diag` netlink family modules, making `ss` orders of magnitude faster than legacy `netstat` (which iteratively parsed `/proc/net/tcp`).

#### Guided Execution Steps

1. Analyze active TCP listening sockets, process bindings, and numeric port mappings using `ss`.
   ```bash
   sudo ss -tlpn
   ```
   *Expected Output:*
   ```text
   State      Recv-Q Send-Q Local Address:Port  Peer Address:Port Process                                 
   LISTEN     0      128    0.0.0.0:22          0.0.0.0:*         users:(("sshd",pid=912,fd=3))           
   LISTEN     0      511    0.0.0.0:80          0.0.0.0:*         users:(("nginx",pid=1450,fd=6))         
   LISTEN     0      4096   127.0.0.1:6379      0.0.0.0:*         users:(("redis-server",pid=1120,fd=6))  
   ```

2. Inspect internal TCP socket buffer memory allocation and TCP congestion control algorithms for established connections.
   ```bash
   ss -t-i -e 'sport = :http or dport = :http'
   ```
   *Expected Output:*
   ```text
   ESTAB 0 0 192.168.1.50:80 192.168.1.105:54322
        cubic wscale:7,7 rto:200 rtt:0.12/0.04 ato:40 mss:1460 rcvspace:14600 ssthresh:10 cwnd:10
   ```

3. Perform MTU Path Discovery troubleshooting using `tracepath` to detect PMTU (Path MTU) black holes caused by blocked ICMP Type 3 Code 4 (`Fragmentation Needed`).
   ```bash
   tracepath 8.8.8.8
   ```
   *Expected Output:*
   ```text
   1?: [LOCALHOST]                      pmtu 1500
   1:  192.168.1.1                                            0.852ms 
   1:  192.168.1.1                                            0.741ms pmtu 1492
   2:  10.254.0.1                                             4.120ms 
   3:  dns.google                                               9.450ms reached
       Resume: pmtu 1492 hops 3 back 56
   ```

4. Execute low-level packet capture filtering using `tcpdump` with raw BPF (Berkeley Packet Filter) syntax to isolate ARP resolution failures and TCP SYN floods.
   ```bash
   sudo tcpdump -i eth0 -nn -e -c 5 'arp or (tcp[tcpflags] & (tcp-syn) != 0)'
   ```
   *Expected Output:*
   ```text
   10:15:30.123456 52:54:00:12:34:56 > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 42: Request who-has 192.168.1.1 tell 192.168.1.50, length 28
   10:15:30.124111 52:54:00:aa:bb:cc > 52:54:00:12:34:56, ethertype ARP (0x0806), length 42: Reply 192.168.1.1 is-at 52:54:00:aa:bb:cc, length 28
   10:15:32.456789 52:54:00:12:34:56 > 52:54:00:aa:bb:cc, ethertype IPv4 (0x0800), length 74: 192.168.1.50.48912 > 1.1.1.1.53: Flags [S], seq 312458901, win 64240, options [mss 1460,sackOK,TS val 1294021 ecr 0,nop,wscale 7], length 0
   ```

5. Query ARP/NDP neighbor cache tables and purge stale ARP entries.
   ```bash
   ip neighbor show
   sudo ip neighbor flush dev eth0 state stale
   ```
   *Expected Output:*
   ```text
   192.168.1.1 dev eth0 lladdr 52:54:00:aa:bb:cc REACHABLE
   192.168.1.105 dev eth0 lladdr 3c:ec:ef:11:22:33 STALE
   ```

6. Inspect kernel network interface error counters and socket drop metrics.
   ```bash
   netstat -s | grep -i "buffer errors"
   sudo nstat -az TcpExtListenDrop TcpExtListenOverflow
   ```
   *Expected Output:*
   ```text
   # nstat -az TcpExtListenDrop TcpExtListenOverflow
   TcpExtListenDrop                0                  0.0
   TcpExtListenOverflow            0                  0.0
   ```

---

#### Comprehension Questions — Exercise 4

- **Q4.1:** In `ss -tlpn` output, what do the `Recv-Q` and `Send-Q` columns signify specifically for TCP sockets in the **LISTEN** state versus sockets in the **ESTABLISHED** state?
- **Q4.2:** Explain how a TCP SYN Flood attack causes `TcpExtListenOverflow` to increment, and what kernel parameters can be tuned to mitigate this issue.
- **Q4.3:** How does `tracepath` determine Path MTU without requiring root privileges, unlike traditional `traceroute -I`?

---

<details>
<summary><strong>Answers & Detailed Explanations</strong></summary>

### Exercise 1 Solutions

- **A1.1:** `ifconfig` relies on legacy `ioctl(SIOCGIFFLAGS, SIOCGIFADDR)` system calls, which are synchronous, slow, and cannot handle modern kernel constructs like multiple IP addresses per interface without creating pseudo-aliased interfaces (`eth0:1`). `ip` uses high-performance netlink sockets (`AF_NETLINK`, `NETLINK_ROUTE`), which communicate asynchronously with kernel structures, natively supporting multiple primary/secondary addresses, namespaces, and advanced routing tables without legacy aliasing hacks.
- **A1.2:** Legacy `ifconfig` will not display the secondary address at all unless it is explicitly tagged with a legacy label (`label eth0:X`) during creation. `ifconfig` parses `/proc/net/dev` and legacy `ioctl` structures which only recognize label-tagged aliases. `ip addr`, however, queries netlink directly and displays all primary and secondary IPv4/IPv6 addresses attached to the device regardless of labels.
- **A1.3:** `options rotate` instructs the C library resolver (`getaddrinfo` / `res_init`) to round-robin queries across all listed `nameserver` IPs in `/etc/resolv.conf`. In microservice architectures, this distributes DNS query load evenly across multiple upstream recursive resolvers, preventing a single DNS server from becoming a CPU bottleneck.

---

### Exercise 2 Solutions

- **A2.1:** `pref` (or `priority`) defines the processing order in the Routing Policy Database (RPDB), evaluated from lowest numerical preference value to highest (0 to 32767). If two rules have identical `pref` values, rule evaluation behavior is non-deterministic (depends on insertion order in netlink lists), which can cause random routing path selection.
- **A2.2:** 
  - **Strict Mode (`rp_filter = 1`):** The kernel checks if the incoming packet's source IP address is reachable via the *exact same interface* the packet arrived on, according to the main FIB. If not, the packet is silently dropped. This breaks multi-homing/PBR.
  - **Loose Mode (`rp_filter = 2`):** The kernel only checks if the source IP is reachable via *any* active network interface on the host. If reachable via any interface, the packet is accepted. Loose mode is mandatory when asymmetry or policy routing is used.
- **A2.3:** 
  - **Reserved IDs:** `255 (local)`, `254 (main)`, `253 (default)`, `0 (unspec)`.
  - **Table `local` (255):** Highest priority table evaluated first by the kernel. It contains routes for local host loopback addresses (`127.0.0.1`), local interface IPs, and broadcast addresses. It handles locally destined packets before any custom policy routing or default routing rules are processed.

---

### Exercise 3 Solutions

- **A3.1:** `miimon` (Media Independent Interface Monitor) specifies the frequency in milliseconds at which the bonding driver inspects the physical link state (via MII/ethtool queries). If `miimon = 0`, link monitoring is disabled completely; the driver will never detect physical cable disconnections or link failures, preventing failover.
- **A3.2:** `layer2` hashing only uses Source and Destination MAC addresses. In a routed network environment where all outbound traffic passes through a single gateway router MAC address, all traffic hashes to the exact same slave interface, rendering LACP ineffective. `layer3+4` hashes Source/Destination IP addresses combined with Source/Destination TCP/UDP Ports, ensuring granular flow distribution across all physical slaves even when communicating with a single upstream router.
- **A3.3:** A software bridge (`br0`) aggregates slave interfaces into a single Layer 2 broadcast domain. Slave interfaces attached to a bridge operate in promiscuous mode with their individual Layer 3 capabilities deactivated. Assigning an IP address directly to a slave interface attached to a bridge prevents the kernel from attaching proper socket handlers to the bridge master, resulting in unroutable packets and broken ARP processing.

---

### Exercise 4 Solutions

- **A4.1:** 
  - **LISTEN State:** `Recv-Q` indicates the number of connection requests currently in the TCP Accept Queue waiting for `accept()` to be called by the application. `Send-Q` indicates the maximum capacity (backlog limit) of the Accept Queue.
  - **ESTABLISHED State:** `Recv-Q` indicates the bytes received in the socket receive buffer waiting to be read by `read()`. `Send-Q` indicates the bytes sent but not yet acknowledged by the remote TCP peer.
- **A4.2:** A TCP SYN Flood fills the SYN Backlog Queue with incomplete 3-way handshakes (`SYN_RECV`). When the queue fills up, incoming connection requests cannot be queued and are dropped, incrementing `TcpExtListenOverflow` and `TcpExtListenDrop`. Mitigation requires setting `net.ipv4.tcp_syncookies = 1` (enabling SYN Cookies to avoid state allocation) and increasing `net.core.somaxconn` and `net.ipv4.tcp_max_syn_backlog`.
- **A4.3:** `tracepath` sends UDP packets with the `DF` (Don't Fragment) IP flag enabled, starting with an assumed MTU (usually 1500). When a router along the path cannot forward the packet due to a smaller MTU, it drops the packet and sends back an ICMP `Destination Unreachable` (Type 3) with code `Fragmentation Needed and DF set` (Code 4), containing the Next-Hop MTU value. `tracepath` parses this ICMP response from standard unprivileged UDP sockets without needing raw socket (`CAP_NET_RAW`) permissions required by `traceroute -I`.

</details>