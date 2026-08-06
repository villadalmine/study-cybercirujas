# LPIC-2 Certification Study Guide: Topic 205 (Exam 201-450) — Network Configuration

## 1. Architectural Motivation & Production Problem Statement

In mission-critical enterprise environments and cloud-native infrastructure, host network architecture underpins system reliability, high availability (HA), throughput scalability, and security segmentation. A single network interface card (NIC) failure, switch port drop, or improper packet routing policy can cause split-brain scenarios in clustered applications (e.g., Kubernetes control planes, Etcd, Corosync/Pacemaker, PostgreSQL Patroni) or result in asymmetric routing dropping stateful firewall traffic.

### 1.1 The Enterprise Networking Requirements
Modern bare-metal and virtualized enterprise nodes must fulfill four key architectural imperatives:
1. **Link Redundancy & Aggregation (L2/L3)**: Protection against physical medium or TOR (Top-of-Rack) switch failure while multiplexing bandwidth across multiple physical interfaces (IEEE 802.3ad / LACP).
2. **Traffic Segmentation (IEEE 802.1Q VLANs)**: Isolation of sensitive control plane, storage (iSCSI/NFS), management, and data-plane traffic streams over unified physical trunks.
3. **Policy-Based Routing (PBR)**: Multi-homed networking where traffic selection is governed by criteria beyond the packet destination IP—such as source IP, interface ingress, or TOS (Type of Service) bits—preventing asymmetrical routing asymmetric drops caused by Reverse Path Filtering (`rp_filter`).
4. **Resilient Host Resolution Stack**: Ensuring deterministic Name Service Switch (`nsswitch.conf`) ordering, system-wide local DNS caching (`systemd-resolved`), and IPv4/IPv6 dual-stack fallback behaviors.

```
                   +------------------------------------+
                   |     Linux Kernel Network Stack     |
                   |                                    |
                   | +--------------------------------+ |
                   | |    Policy Routing Engine       | |
                   | |   (rt_tables & ip rule DB)     | |
                   | +--------------------------------+ |
                   |                 |                  |
                   | +--------------------------------+ |
                   | | 802.1Q VLAN Interface Processor| |
                   | |   (bond0.100  /  bond0.200)    | |
                   | +--------------------------------+ |
                   |                 |                  |
                   | +--------------------------------+ |
                   | | Linux Ethernet Bonding Subsystem| |
                   | |      (bond0 / Mode 4 LACP)     | |
                   | +--------------------------------+ |
                   +--------/------------------\--------+
                           /                    \
            +--------------------+        +--------------------+
            | Slave Interface 1  |        | Slave Interface 2  |
            |      (eth0)        |        |      (eth1)        |
            +---------+----------+        +---------+----------+
                      |                             |
                      |   LACP IEEE 802.3ad Trunk   |
                      v                             v
            +--------------------+        +--------------------+
            | Top-of-Rack Switch |<----->| Top-of-Rack Switch |
            |      (TOR-A)       |  mLAG  |      (TOR-B)       |
            +--------------------+        +--------------------+
```

### 1.2 Linux Kernel Subsystem Mechanics
At the Linux kernel level, packet processing traverses several distinct subsystems:
- **Netfilter / Socket Layer**: Filters incoming/outgoing datagrams via hooks before they hit application socket buffers.
- **FIB (Forwarding Information Base)**: The kernel lookup mechanism for destination IP routing. Traditional setups query `table main` (ID 254) or `table local` (ID 255). Multi-homed systems utilize additional user-defined tables (`table 100`, `table 200`) managed via `ip rule`.
- **IP Neighbor / ARP Subsystem**: Maintains L3-to-L2 mapping tables (`ip neigh`). Outgoing frames are queued in `dev_queue` before hardware transmission rings (`tx_ring`).
- **Driver Abstraction Layer**: Exposes physical (`ethX`, `enpXsY`) and virtual (`bondX`, `teamX`, `vlanX`, `vethX`) network devices to user space through `rtnetlink` sockets.

---

## 2. Technical Comparisons & Trade-Off Matrix

### 2.1 Network Configuration Subsystems: Legacy vs. Modern
Linux network management has evolved from simple shell-scripted configuration (`ifupdown`) to dynamic event-driven daemons (`NetworkManager`, `systemd-networkd`, `Netplan`).

| Dimension | Legacy `ifupdown` (`/etc/network/interfaces`) | RHEL/CentOS Scripts (`/etc/sysconfig/network-scripts`) | `NetworkManager` (`nmcli`, `keyfile`) | `systemd-networkd` | `Netplan` (Ubuntu Abstraction) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Primary Architecture** | Static shell script invocation | Static shell script invocation | Dynamic, DBus-driven daemon | Lightweight systemd init daemon | Declarative YAML abstraction layer |
| **Daemon Memory Footprint** | None (ephemeral runtime) | None (ephemeral runtime) | ~25MB - 60MB RAM | ~2MB - 5MB RAM | Ephemeral (generates backend configs) |
| **Target Environment** | Embedded, legacy Debian | Legacy RHEL 6/7 enterprise | Desktop, Workstations, Multi-NIC Laptops | Cloud Instances, Container Hosts, Minimal Servers | Ubuntu 18.04+ Cloud & Edge Nodes |
| **Convergence / Boot Time** | Slow (blocking synchronous execution) | Slow (blocking shell execution) | Medium (event-driven initialization) | Ultra-Fast (asynchronous kernel notification) | Depends on backend (`networkd` vs `NM`) |
| **Hotplug Support** | Poor (requires manual `allow-hotplug`) | Poor | Native (auto-detects hardware events via udev) | Native (udev integrated link tracking) | Backend-dependent |
| **Configuration Model** | Imperative syntax per interface | Imperative key-value pairs | Imperative CLI / Declarative keyfiles | Declarative `.netdev` and `.network` INI files | Declarative YAML schema v2 |

---

### 2.2 Link Aggregation: Kernel Bonding vs. Network Teaming (`teamd`)

Linux provides two distinct mechanisms for unifying multiple physical interfaces into a logical fault-tolerant interface.

```
       +-------------------------------------------------------------+
       |                  User Space Control Plane                   |
       |  (sysfs / procfs for Bonding)      (teamd daemon for Team)  |
       +------------------------------+------------------------------+
                                      |
       +------------------------------v------------------------------+
       |                  Kernel Space Execution Layer                |
       |  +------------------------+      +-----------------------+  |
       |  |  drivers/net/bonding   |      |  drivers/net/team     |  |
       |  | (Monolithic C Logic)   |      | (Modular Netlink App) |  |
       |  +------------------------+      +-----------------------+  |
       +-------------------------------------------------------------+
```

| Feature / Metric | Linux Ethernet Bonding (`bonding.ko`) | Linux Network Teaming (`drivers/net/team` & `teamd`) |
| :--- | :--- | :--- |
| **Architecture Location** | Monolithic kernel module implementation | Minimal kernel infrastructure + Userspace daemon (`teamd`) |
| **Extensibility** | Low (kernel recompilation required for new algorithms) | High (userspace plugins / custom code dynamically loaded) |
| **Performance (Throughput)**| Extremely high (zero context switching between userspace and kernel) | High (fast path in kernel, control path in userspace) |
| **LACP Implementation** | Hardcoded in `drivers/net/bonding/bond_3ad.c` | Userspace `teamd` runner module (`lacp`) |
| **Monitoring Mechanisms** | MII (Media Independent Interface) & ARP polling | MII, ARP polling, NS/NA (IPv6), Custom D-Bus health hooks |
| **Deprecated Status** | Fully supported, universal industry standard | Feature-frozen / Deprecated in newer enterprise distros (RHEL 9+) in favor of bonding |

#### Linux Bonding Modes Breakdown
1. **Mode 0 (`balance-rr`)**: Round-robin packet transmission across slaves. Provides load balancing and fault tolerance. *Requires switch support (static etherchannel).*
2. **Mode 1 (`active-backup`)**: Only one slave is active. A second interface takes over if the primary fails. *No switch configuration required.*
3. **Mode 2 (`balance-xor`)**: Transmit based on hash policy `(source-MAC XOR destination-MAC) % slave_count`. *Requires static link aggregation on switch.*
4. **Mode 3 (`broadcast`)**: Transmits everything on all slave interfaces. Used for high-reliability networks (e.g., financial ticker feeds).
5. **Mode 4 (`802.3ad`)**: Dynamic Link Aggregation (LACP). Creates aggregation groups sharing speed/duplex settings. *Requires IEEE 802.3ad support on switch.*
6. **Mode 5 (`balance-tlb`)**: Adaptive Transmit Load Balancing. Outgoing traffic distributed according to current load on each slave. Incoming received by current slave.
7. **Mode 6 (`balance-alb`)**: Adaptive Load Balancing. Includes `balance-tlb` plus receive load balancing (RLB) via ARP negotiation manipulation.

---

### 2.3 Management Tooling: Legacy Net-tools vs. Modern `iproute2`

| Functionality | Legacy Utility (`net-tools`) | Modern Utility (`iproute2`) | Kernel System Call Interface |
| :--- | :--- | :--- | :--- |
| **Interface Management** | `ifconfig eth0 up` | `ip link set dev eth0 up` | Netlink socket (`RTM_NEWLINK`) |
| **Address Assignment** | `ifconfig eth0 192.168.1.2 netmask 255.255.255.0` | `ip addr add 192.168.1.2/24 dev eth0` | Netlink socket (`RTM_NEWADDR`) |
| **Routing Table Query** | `route -n` | `ip route show` / `ip route show table all` | Netlink socket (`RTM_GETROUTE`) |
| **ARP Table Inspection** | `arp -an` | `ip neigh show` | Netlink socket (`RTM_GETNEIGH`) |
| **Multicast Group List** | `netstat -g` | `ip maddr show` | Netlink socket (`RTM_GETMULTICAST`)|
| **Policy Routing Rules** | *Unsupported* | `ip rule show` | Netlink socket (`RTM_GETRULE`) |

---

## 3. Production Infrastructure Manifests & Configurations

All configurations below are complete, syntactically valid, production-grade files.

### 3.1 Debian/Ubuntu Legacy: `/etc/network/interfaces`
*Features: Dual-interface LACP Bonding (`bond0`) with VLAN 100 and VLAN 200 sub-interfaces, custom static routes, and inline policy routing rules.*

```ini
# /etc/network/interfaces
# Production High-Availability Network Configuration

source /etc/network/interfaces.d/*

# Loopback Interface
auto lo
iface lo inet loopback

# Primary Physical Slave 1
auto eth0
iface eth0 inet manual
    bond-master bond0
    bond-primary eth0

# Primary Physical Slave 2
auto eth1
iface eth1 inet manual
    bond-master bond0

# LACP Aggregated Bond Interface
auto bond0
iface bond0 inet manual
    bond-slaves eth0 eth1
    bond-mode 4
    bond-miimon 100
    bond-downdelay 200
    bond-updelay 200
    bond-lacp-rate fast
    bond-xmit-hash-policy layer3+4

# VLAN 100 - Production Data Plane
auto bond0.100
iface bond0.100 inet static
    address 10.100.0.50
    netmask 255.255.255.0
    gateway 10.100.0.1
    dns-nameservers 1.1.1.1 8.8.8.8
    dns-search production.internal
    mtu 9000
    up ip rule add from 10.100.0.50/32 table 100
    up ip route add default via 10.100.0.1 dev bond0.100 table 100
    down ip route del default via 10.100.0.1 dev bond0.100 table 100
    down ip rule del from 10.100.0.50/32 table 100

# VLAN 200 - Management & Backup Plane
auto bond0.200
iface bond0.200 inet static
    address 10.200.0.50
    netmask 255.255.255.0
    mtu 1500
    up ip route add 172.16.0.0/12 via 10.200.0.1 dev bond0.200
    down ip route del 172.16.0.0/12 via 10.200.0.1 dev bond0.200
```

---

### 3.2 Enterprise Ubuntu Netplan: `/etc/netplan/01-netplan.yaml`
*Features: Netplan YAML declaration utilizing `networkd` backend, defining LACP bonding, VLAN trunking, dual-stack IPv4/IPv6, and policy routing rules.*

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: false
      dhcp6: false
      match:
        macaddress: "52:54:00:a8:3b:01"
      set-name: eth0
    eth1:
      dhcp4: false
      dhcp6: false
      match:
        macaddress: "52:54:00:a8:3b:02"
      set-name: eth1
  bonds:
    bond0:
      interfaces:
        - eth0
        - eth1
      parameters:
        mode: 802.3ad
        mii-monitor-interval: 100
        lacp-rate: fast
        transmit-hash-policy: layer3+4
        down-delay: 200
        up-delay: 200
  vlans:
    bond0.100:
      id: 100
      link: bond0
      mtu: 9000
      addresses:
        - 10.100.0.50/24
        - "2001:db8:100::50/64"
      routes:
        - to: default
          via: 10.100.0.1
          metric: 100
          table: 100
        - to: default
          via: "2001:db8:100::1"
          metric: 100
          table: 100
      routing-policy:
        - from: 10.100.0.50/32
          table: 100
          priority: 1000
        - from: "2001:db8:100::50/128"
          table: 100
          priority: 1001
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
          - "2606:4700:4700::1111"
        search:
          - production.internal
```

---

### 3.3 Modern Native Systemd-Networkd Configurations
Systemd-networkd splits interface definitions into separate physical, netdev, and network units inside `/etc/systemd/network/`.

#### File 1: Netdev Bond Definition (`/etc/systemd/network/10-bond0.netdev`)
```ini
[NetDev]
Name=bond0
Kind=bond
MACAddress=52:54:00:a8:3b:01

[Bond]
Mode=802.3ad
MIIMonitorSec=100ms
LACPTransmitRate=fast
TransmitHashPolicy=layer3+4
DownDelaySec=200ms
UpDelaySec=200ms
```

#### File 2: Physical Slave Bindings (`/etc/systemd/network/15-eth0.network`)
```ini
[Match]
Name=eth0

[Network]
Bond=bond0
```

#### File 3: Physical Slave Bindings (`/etc/systemd/network/15-eth1.network`)
```ini
[Match]
Name=eth1

[Network]
Bond=bond0
```

#### File 4: Netdev VLAN Definition (`/etc/systemd/network/20-vlan100.netdev`)
```ini
[NetDev]
Name=bond0.100
Kind=vlan

[VLAN]
Id=100
```

#### File 5: Bond Network Configuration with VLAN attachment (`/etc/systemd/network/10-bond0.network`)
```ini
[Match]
Name=bond0

[Network]
VLAN=bond0.100
LinkLocalAddressing=no
IPv6AcceptRA=no
```

#### File 6: VLAN Interface Configuration with PBR (`/etc/systemd/network/20-vlan100.network`)
```ini
[Match]
Name=bond0.100

[Network]
Address=10.100.0.50/24
Address=2001:db8:100::50/64
DNS=1.1.1.1
DNS=8.8.8.8
Domains=production.internal

[RoutingPolicyRule]
From=10.100.0.50/32
Table=100
Priority=1000

[RoutingPolicyRule]
From=2001:db8:100::50/128
Table=100
Priority=1001

[Route]
Destination=0.0.0.0/0
Gateway=10.100.0.1
Table=100

[Route]
Destination=::/0
Gateway=2001:db8:100::1
Table=100
```

---

### 3.4 Custom Routing Tables & Name Resolution Stack

#### File 1: Custom Routing Table Declaration (`/etc/iproute2/rt_tables`)
```text
#
# reserved values
#
255	local
254	main
253	default
0	unspec
#
# local custom tables
#
100	data_plane
200	mgmt_plane
```

#### File 2: Name Service Switch Configuration (`/etc/nsswitch.conf`)
```text
# /etc/nsswitch.conf
# System Name Service Switch Configuration

passwd:         files systemd
group:          files systemd
shadow:         files
gshadow:        files

hosts:          files resolve [NOTFOUND=return] dns myhostname
networks:       files

protocols:      db files
services:       db files
ethers:         db files
rpc:            db files

netgroup:       nis
```

#### File 3: Systemd Resolver Configuration (`/etc/systemd/resolved.conf`)
```ini
[Resolve]
DNS=1.1.1.1 8.8.8.8 2606:4700:4700::1111
FallbackDNS=9.9.9.9 1.0.0.1
Domains=production.internal
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
MulticastDNS=no
LLMNR=no
Cache=yes
CacheFromLocalhost=no
```

#### File 4: System Resolver Stub File (`/etc/resolv.conf`)
```text
# Generated by systemd-resolved
nameserver 127.0.0.53
options edns0 trust-ad
search production.internal
```

---

## 4. Real CLI Execution Workflows & Expected Output Streams

The following workflows represent live operations on an enterprise Linux node.

### 4.1 Interface Query & Hardware Diagnostic Workflow

```bash
$ ip -s link show dev eth0
```
```text
2: eth0: <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP> mtu 9000 qdisc mq master bond0 state UP mode DEFAULT group default qlen 1000
    link/ether 52:54:00:a8:3b:01 brd ff:ff:ff:ff:ff:ff
    RX:  bytes packets errors dropped missed mcast   
     984210492 7482910      0       0      0   1402 
    TX:  bytes packets errors dropped carrier collsns
     549102941 4920194      0       0      0      0 
```

```bash
$ ethtool eth0
```
```text
Settings for eth0:
	Supported ports: [ TP ]
	Supported link modes:   1000baseT/Full
	                        10000baseT/Full
	Supported pause frame use: Symmetric
	Supports auto-negotiation: Yes
	Supported FEC modes: Not reported
	Advertised link modes:  10000baseT/Full
	Advertised pause frame use: Symmetric
	Advertised auto-negotiation: Yes
	Speed: 10000Mb/s
	Duplex: Full
	Auto-negotiation: on
	Port: Twisted Pair
	PHYAD: 0
	Transceiver: internal
	MDI-X: Unknown
	Supports Wake-on: d
	Wake-on: d
	Current message level: 0x00000007 (7)
			       drv probe link
	Link detected: yes
```

```bash
$ ethtool -k eth0 | grep -E "offload|segmentation"
```
```text
rx-checksumming: on
tx-checksumming: on
	tx-checksum-ipv4: on
	tx-checksum-ip-generic: off [fixed]
	tx-checksum-ipv6: on
scatter-gather: on
	tx-scatter-gather: on
	tx-scatter-gather-fraglist: off [fixed]
tcp-segmentation-offload: on
	tx-tcp-segmentation: on
	tx-tcp-ecn-segmentation: on
	tx-tcp-mangleid-segmentation: off
	tx-tcp6-segmentation: on
generic-segmentation-offload: on
generic-receive-offload: on
large-receive-offload: off [fixed]
```

---

### 4.2 On-the-Fly Dynamic Creation of LACP Bonding & 802.1Q VLANs via `iproute2`

```bash
$ sudo ip link add name bond0 type bond mode 802.3ad miimon 100 lacp_rate fast xmit_hash_policy layer3+4
$ sudo ip link set dev eth0 down
$ sudo ip link set dev eth1 down
$ sudo ip link set dev eth0 master bond0
$ sudo ip link set dev eth1 master bond0
$ sudo ip link set dev bond0 up
$ sudo ip link set dev eth0 up
$ sudo ip link set dev eth1 up
$ sudo ip link add link bond0 name bond0.100 type vlan id 100
$ sudo ip addr add 10.100.0.50/24 dev bond0.100
$ sudo ip link set dev bond0.100 mtu 9000 up
$ ip addr show dev bond0.100
```
```text
5: bond0.100@bond0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 qdisc noqueue state UP group default qlen 1000
    link/ether 52:54:00:a8:3b:01 brd ff:ff:ff:ff:ff:ff
    inet 10.100.0.50/24 brd 10.100.0.255 scope global bond0.100
       valid_lft forever preferred_lft forever
    inet6 2001:db8:100::50/64 scope global 
       valid_lft forever preferred_lft forever
    inet6 fe80::5054:ff:fea8:3b01/64 scope link 
       valid_lft forever preferred_lft forever
```

---

### 4.3 Policy-Based Routing (PBR) Execution & Verification

```bash
$ sudo ip rule add from 10.100.0.50/32 table data_plane priority 1000
$ sudo ip route add default via 10.100.0.1 dev bond0.100 table data_plane
$ ip rule show
```
```text
0:	from all lookup local
1000:	from 10.100.0.50 lookup data_plane
32766:	from all lookup main
32767:	from all lookup default
```

```bash
$ ip route show table data_plane
```
```text
default via 10.100.0.1 dev bond0.100
```

```bash
$ ip route get 8.8.8.8 from 10.100.0.50
```
```text
8.8.8.8 from 10.100.0.50 via 10.100.0.1 dev bond0.100 table data_plane uid 1000
    cache 
```

---

### 4.4 Kernel Bonding State Verification via ProcFS

```bash
$ cat /proc/net/bonding/bond0
```
```text
Ethernet Channel Bonding Driver: v5.15.0-88-generic

Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
MII Polling Interval (ms): 100
Up Delay (ms): 200
Down Delay (ms): 200
Peer Notification Delay (ms): 0

802.3ad info
LACP rate: fast
Min links: 0
Aggregator selection policy (ad_select): stable
System priority: 65535
System MAC address: 52:54:00:a8:3b:01
Active Aggregator Info:
	Aggregator ID: 1
	Number of ports: 2
	Actor Key: 15
	Partner Key: 32768
	Partner Mac Address: 00:2a:6a:12:99:00

Slave Interface: eth0
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:a8:3b:01
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Partner State: reg_state
LACP Actor port state: 61 (EXP_TIM,DEF,DIST,COLL,AGG,SYNC)

Slave Interface: eth1
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:a8:3b:02
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Partner State: reg_state
LACP Actor port state: 61 (EXP_TIM,DEF,DIST,COLL,AGG,SYNC)
```

---

### 4.5 Managing Network Teaming via `teamdctl` and `nmcli`

```bash
$ sudo teamdctl team0 state
```
```json
{
    "setup": {
        "runner_name": "lacp"
    },
    "ports": {
        "eth0": {
            "link": {
                "up": true
            },
            "runner": {
                "aggregator": {
                    "id": 1,
                    "selected": true
                },
                "state": "current"
            }
        },
        "eth1": {
            "link": {
                "up": true
            },
            "runner": {
                "aggregator": {
                    "id": 1,
                    "selected": true
                },
                "state": "current"
            }
        }
    }
}
```

```bash
$ nmcli connection show
```
```text
NAME         UUID                                 TYPE      DEVICE    
bond0        c83a1290-7f21-432d-98e1-9018ab3c9901  bond      bond0     
bond0.100    91a82f34-1189-4d22-bdf9-0a9e71181283  vlan      bond0.100 
bond-slave-1 30b42f21-8290-482a-a912-182937192801  ethernet  eth0      
bond-slave-2 81a02931-192a-4c91-b912-192039182390  ethernet  eth1      
```

---

### 4.6 IP Neighbor Table and Socket Inspection

```bash
$ ip neigh show
```
```text
10.100.0.1 dev bond0.100 lladdr 00:2a:6a:12:99:01 REACHABLE
10.100.0.254 dev bond0.100 lladdr 00:2a:6a:12:99:fe STALE
2001:db8:100::1 dev bond0.100 lladdr 00:2a:6a:12:99:01 router REACHABLE
```

```bash
$ ss -tulpn
```
```text
Netid State  Recv-Q Send-Q   Local Address:Port   Peer Address:Port Process                                                            
udp   UNCONN 0      0        127.0.0.53%lo:53          0.0.0.0:*     users:(("systemd-resolve",pid=842,fd=13))                          
tcp   LISTEN 0      4096     127.0.0.53%lo:53          0.0.0.0:*     users:(("systemd-resolve",pid=842,fd=14))                          
tcp   LISTEN 0      128            0.0.0.0:22           0.0.0.0:*     users:(("sshd",pid=1024,fd=3))                                     
tcp   LISTEN 0      512            0.0.0.0:80           0.0.0.0:*     users:(("nginx",pid=2048,fd=6),("nginx",pid=2049,fd=6))            
tcp   LISTEN 0      128               [::]:22              [::]:*     users:(("sshd",pid=1024,fd=4))                                     
```

```bash
$ lsof -i :80
```
```text
COMMAND  PID     USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
nginx   2048     root    6u  IPv4  29481      0t0  TCP *:http (LISTEN)
nginx   2049 www-data    6u  IPv4  29481      0t0  TCP *:http (LISTEN)
```

---

## 5. Advanced Verification, Failure Recovery & Diagnostic Guide

### 5.1 System SRE Troubleshooting Playbook

```
                         [ Network Issue Reported ]
                                     |
                                     v
                        [ Can host ping Gateway? ]
                               /           \
                             NO             YES
                             /               \
            [ Check Link State & L1/L2 ]     [ Check L3 Routing & Policy Rules ]
                         |                                  |
            +------------+------------+            +--------+--------+
            |                         |            |                 |
     (Link Down / Drops)     (LACP Mismatch) (Path Dropped)   (RPF Filter Drop)
            |                         |            |                 |
    Check `ethtool ethX`    Check ProcFS Bonding   Check `ip route`  Check sysctl
    & Ring Buffers          / `teamdctl` state     & `ip rule`       `rp_filter`
```

---

### 5.2 Common Production Failure Scenarios & Root Causes

#### Scenario A: Asymmetric Routing & Reverse Path Filtering Drops
- **Symptom**: Packets arrive on `bond0.200` interface, but the host fails to return SYN-ACK packets or silently drops incoming traffic despite proper route table entries.
- **Root Cause**: Kernel `rp_filter` (Strict Reverse Path Filtering) enabled. When a packet arrives on `bond0.200`, the kernel checks if the path back to the source IP would route out through `bond0.200`. If `table main` points the default gateway out of `bond0.100`, the kernel deems the packet spoofed and silently drops it.
- **Remediation**: Set `rp_filter` to loose mode (`2`) or disable (`0`) for target interfaces via `sysctl`:
  ```bash
  sudo sysctl -w net.ipv4.conf.all.rp_filter=2
  sudo sysctl -w net.ipv4.conf.bond0/100.rp_filter=2
  sudo sysctl -w net.ipv4.conf.bond0/200.rp_filter=2
  ```

#### Scenario B: LACP Aggregator Mismatch / Split-Brain Link
- **Symptom**: Bond interface is up, but experiencing ~50% packet loss.
- **Root Cause**: Switch ports are misconfigured (e.g., one port in LACP mode, partner port in standalone/unbundled mode), or `xmit_hash_policy` mismatch causes frame reordering across out-of-order links.
- **Remediation**: Inspect `/proc/net/bonding/bond0` for `Partner MAC Address` consistency across all slave interfaces. Ensure `xmit_hash_policy` is explicitly configured to `layer3+4` for transport-layer distribution.

#### Scenario C: Path MTU Blackhole over VLAN Trunks
- **Symptom**: ICMP ping works (small payload), SSH connects, but large HTTP payload/TLS handshake hangs indefinitely.
- **Root Cause**: The physical switch interface has a standard MTU of 1500, but the Linux host VLAN configuration defines `mtu 9000` (Jumbo Frames), or an intermediate router drops ICMP "Fragmentation Needed" packets.
- **Remediation**: Verify MTU end-to-end using payload-sized pings with Don't Fragment (DF) bit set:
  ```bash
  ping -M do -s 8972 10.100.0.1
  ```

---

### 5.3 Deep Diagnostics Tooling Commands

#### 1. Low-Level Packet Capture & VLAN Frame Inspection
Capture incoming 802.1Q tagged traffic on physical interfaces:
```bash
sudo tcpdump -nn -e -i eth0 vlan 100 and port 80 -vvv
```
*`-e` prints the link-level header, exposing source/destination MAC addresses and VLAN tags (`vlan 100, p 0`).*

#### 2. Querying Kernel Route Lookup Path
Simulate how the kernel FIB processes a specific packet tuple:
```bash
ip route get 172.16.10.50 from 10.100.0.50 iif bond0.100
```

#### 3. Analyzing Hardware Rx/Tx Ring Buffer Counter Errors
Check if NIC hardware rings are dropping frames due to buffer exhaustion:
```bash
ethtool -S eth0 | grep -E "drop|error|miss|fifo|buf"
```
```text
     rx_dropped: 0
     tx_dropped: 0
     rx_errors: 0
     tx_errors: 0
     rx_missed_errors: 0
     rx_fifo_errors: 0
     rx_buf_length_errors: 0
```

#### 4. Diagnostic Tracing & Path MTU Discovery
Trace path MTU constraints dynamically across network hops:
```bash
tracepath -n 10.100.0.1
```

---

### 5.4 Kernel Sysctl Optimization Matrix for High-Throughput Networking

Save the following production tuneables inside `/etc/sysctl.d/99-production-network.conf`:

```ini
# /etc/sysctl.d/99-production-network.conf
# SRE Production Networking Tuneables

# Enable IP Forwarding (Required for Routers, VPN gateways, K8s CNI)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Loose Reverse Path Filtering (Mitigates PBR Asymmetric Routing Drops)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Increase Maximum Network Socket Receive/Send Buffers (16MB)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# Increase Maximum Connection Backlog Queue for High Concurrency
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536

# TCP Buffer Auto-Tuning Parameters (min, default, max in bytes)
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Enable TCP BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP TIME_WAIT Reuse for High-Frequency Load Balancers
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
```

Apply sysctl configuration immediately:
```bash
sudo sysctl --system
```

---

## 6. References

- **Linux Professional Institute (LPI) Official LPIC-2 Objectives**:  
  [https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5](https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5)  
  [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)

- **Linux Kernel Documentation — Ethernet Bonding Driver**:  
  [https://www.kernel.org/doc/Documentation/networking/bonding.txt](https://www.kernel.org/doc/Documentation/networking/bonding.txt)

- **iproute2 Official Man Pages & Documentation**:  
  [https://wiki.linuxfoundation.org/networking/iproute2](https://wiki.linuxfoundation.org/networking/iproute2)  
  [https://man7.org/linux/man-pages/man8/ip.8.html](https://man7.org/linux/man-pages/man8/ip.8.html)

- **Systemd-networkd Official Documentation**:  
  [https://www.freedesktop.org/software/systemd/man/systemd.network.html](https://www.freedesktop.org/software/systemd/man/systemd.network.html)  
  [https://www.freedesktop.org/software/systemd/man/systemd.netdev.html](https://www.freedesktop.org/software/systemd/man/systemd.netdev.html)

- **Netplan Core Reference Specification**:  
  [https://netplan.io/reference/](https://netplan.io/reference/)

- **Red Hat Enterprise Linux Network Administration Guide**:  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/)