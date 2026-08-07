# LPI 702-100: BSD Specialist Certification Exam Study Material
## Topic 714.2: Basic Network Configuration (Weight: 5)

---

### 1. Production Architecture Motivation & Architectural Problem

#### The Enterprise Edge & Core BSD Networking Paradigm
In high-availability enterprise environments, edge routers, security appliances (e.g., pfSense, OPNSense, custom OpenBSD firewalls), and high-throughput storage storage arrays (e.g., TrueNAS on FreeBSD) rely on the BSD network stack due to its kernel lock fine-granularity, predictable socket buffering, zero-copy network architecture (`zero-copy sockets` / `netmap`), and deterministic boot sequence.

Unlike modern Linux distributions that abstract interface management behind dynamically reacting daemons (`systemd-networkd`, `NetworkManager`) with DBus IPC layers, BSD operating systems enforce a declarative, file-based network configuration paradigm executed deterministically during system initialization via `rc.d` scripts.

```
                   +---------------------------------------+
                   |           Applications /              |
                   |      Daemon Layer (bind, unbound)     |
                   +-------------------+-------------------+
                                       | Socket API (AF_INET / AF_INET6)
                   +-------------------+-------------------+
                   |         BSD Kernel Socket Layer       |
                   |        (mbuf chains, zero-copy)       |
                   +---------+-------------------+---------+
                             |                   |
            +----------------+--+             +--+----------------+
            |  IPv4 / IPv6      |             |  pf / ipfw / npf  |
            |  Routing Table    |             |  Packet Filtering |
            +--------+----------+             +--+----------------+
                     |                           |
            +--------+---------------------------+---------+
            | Link Aggregation (lagg / trunk / agr)        |
            | IEEE 802.3ad LACP / Failover                 |
            +--------------------+-------------------------+
                                 |
            +--------------------+-------------------------+
            |  VLAN Tagging (802.1Q)                       |
            +--------------------+-------------------------+
                                 |
            +--------------------+-------------------------+
            | Hardware Drivers (ixgbe, em, vioif, alc, re) |
            +----------------------------------------------+
```

#### Key Architectural Challenges in Production BSD Deployments
1. **Multi-Flavored Heterogeneity**: Production BSD fleets often combine FreeBSD (high-performance I/O and storage), OpenBSD (hardened perimeter gateways and VPN endpoints), and NetBSD (embedded architectures and specialized appliances). Each variant implements distinct configuration syntax and network abstractions:
   - **FreeBSD**: Centralized single-file network declaration in `/etc/rc.conf` evaluated by `/etc/rc.d/netif` and `/etc/rc.d/routing`.
   - **OpenBSD**: Per-interface configuration files (`/etc/hostname.<if>`) executed by `/etc/netstart`.
   - **NetBSD**: Dual model using `/etc/rc.conf` alongside per-interface files (`/etc/ifconfig.<if>`).
2. **Link Aggregation & Redundancy**: Multi-homed servers require LACP (IEEE 802.3ad) or active/passive failover paired with 802.1Q VLAN trunking. Designing interfaces requires understanding interface layering (`physical` $\rightarrow$ `lagg`/`trunk`/`agr` $\rightarrow$ `vlan` $\rightarrow$ `L3 IP`).
3. **Dual-Stack IPv4/IPv6 Coexistence**: Ensuring atomic bind operations, handling IPv6 Stateless Address Autoconfiguration (SLAAC) alongside static IPv6 addressing, and preventing Duplicate Address Detection (DAD) lockups during boot.
4. **Persistence vs. Ephemeral Execution**: In-flight changes using `ifconfig` or `route` do not survive reboots. System Administrators must ensure exact alignment between runtime memory state and persistent `/etc` configuration manifests.

---

### 2. Technical Comparisons & Trade-off Tables

#### 2.1 BSD Network Configuration Framework Matrix

| Feature / Aspect | FreeBSD | OpenBSD | NetBSD |
| :--- | :--- | :--- | :--- |
| **Primary Network Manifest** | `/etc/rc.conf` (and `/etc/rc.conf.d/`) | `/etc/hostname.<if>` | `/etc/rc.conf` & `/etc/ifconfig.<if>` |
| **Interface Management Command** | `ifconfig` | `ifconfig` | `ifconfig` |
| **Network Restart Command** | `service netif restart && service routing restart` | `sh /etc/netstart` | `/etc/rc.d/network restart` |
| **Default Gateway Manifest** | `defaultrouter` in `/etc/rc.conf` | `/etc/mygate` | `defaultroute` in `/etc/rc.conf` or `/etc/mygate` |
| **Static Route Manifest** | `static_routes` in `/etc/rc.conf` | `/etc/hostname.<if>` or custom script | `/etc/rc.conf` (`static_routes`) |
| **Link Aggregation Module** | `lagg(4)` | `trunk(4)` | `agr(4)` |
| **VLAN Interface Creation** | `vlans_<if>` or `cloned_interfaces` in `/etc/rc.conf` | Created via `/etc/hostname.vlanX` | Created via `/etc/ifconfig.vlanX` |
| **Hostname Manifest** | `hostname` in `/etc/rc.conf` | `/etc/myname` | `hostname` in `/etc/rc.conf` or `/etc/myname` |

#### 2.2 Link Aggregation Protocol Modes Across BSD Flavors

| Aggregation Mode | FreeBSD (`lagg`) Syntax | OpenBSD (`trunk`) Syntax | NetBSD (`agr`) Syntax | Operational Behavior & Production Trade-offs |
| :--- | :--- | :--- | :--- | :--- |
| **LACP (IEEE 802.3ad)** | `laggproto lacp` | `trunkproto lacp` | `lacp` (default in `agr`) | **Active-Active**. Requires switch-side LACP configuration. Dynamic link negotiation, automatic failure detection, flow hashing. |
| **Failover (Active/Backup)**| `laggproto failover` | `trunkproto failover` | *N/A (Use `carp(4)` or static failover)* | **Active-Passive**. Uses primary interface; switches to backup upon link-down. Does not require switch configuration. |
| **Load Balance** | `laggproto loadbalance` | `trunkproto loadbalance` | *N/A* | **Static Multi-Link**. Balances traffic based on IP/MAC headers. No LACP signaling; sensitive to asymmetric link failures. |

---

### 3. Complete Syntax-Valid Configuration Manifests

The following configurations illustrate a enterprise edge scenario:
- Two physical 10GbE interfaces (`em0`, `em1` on OpenBSD/NetBSD; `ix0`, `ix1` on FreeBSD).
- Aggregated into a high-availability LACP bond (`lagg0` / `trunk0` / `agr0`).
- Trunking 802.1Q VLAN 10 (Management: `192.168.10.50/24`, Gateway: `192.168.10.1`, IPv6: `2001:db8:10::50/64`) and VLAN 20 (Data: `10.20.0.50/24`).

#### 3.1 FreeBSD Complete Configuration

##### File: `/etc/rc.conf`
```sh
# System Identity
hostname="freebsd-node01.prod.enterprise.internal"

# Base Network Interfaces Initialization
ifconfig_ix0="up"
ifconfig_ix1="up"

# Link Aggregation (LACP) Configuration
cloned_interfaces="lagg0 vlan10 vlan20"
ifconfig_lagg0="laggproto lacp laggport ix0 laggport ix1 up"

# 802.1Q VLAN Sub-Interfaces
ifconfig_vlan10="vlan 10 vlandev lagg0 inet 192.168.10.50 netmask 255.255.255.0 up"
ifconfig_vlan10_ipv6="inet6 2001:db8:10::50 prefixlen 64"
ifconfig_vlan20="vlan 20 vlandev lagg0 inet 10.20.0.50 netmask 255.255.255.0 up"

# Routing Configuration
defaultrouter="192.168.10.1"
ipv6_defaultrouter="2001:db8:10::1"

# Static Route Configuration (Routing 172.16.0.0/12 traffic via Data VLAN Gateway)
static_routes="internal_app"
route_internal_app="-net 172.16.0.0/12 10.20.0.1"
```

##### File: `/etc/resolv.conf`
```conf
search prod.enterprise.internal enterprise.internal
nameserver 192.168.10.2
nameserver 192.168.10.3
options timeout:2 attempts:3 rotate
```

##### File: `/etc/hosts`
```etc
127.0.0.1       localhost localhost.prod.enterprise.internal
::1             localhost localhost.prod.enterprise.internal
192.168.10.50   freebsd-node01.prod.enterprise.internal freebsd-node01
2001:db8:10::50 freebsd-node01.prod.enterprise.internal freebsd-node01
```

---

#### 3.2 OpenBSD Complete Configuration

##### File: `/etc/myname`
```text
openbsd-gw01.prod.enterprise.internal
```

##### File: `/etc/hostname.em0`
```text
up
```

##### File: `/etc/hostname.em1`
```text
up
```

##### File: `/etc/hostname.trunk0`
```text
trunkproto lacp trunkport em0 trunkport em1 up
```

##### File: `/etc/hostname.vlan10`
```text
vlan 10 vlandev trunk0
inet 192.168.10.50 255.255.255.0
inet6 2001:db8:10::50 64
up
```

##### File: `/etc/hostname.vlan20`
```text
vlan 20 vlandev trunk0
inet 10.20.0.50 255.255.255.0
!route add -net 172.16.0.0/12 10.20.0.1
up
```

##### File: `/etc/mygate`
```text
192.168.10.1
2001:db8:10::1
```

##### File: `/etc/resolv.conf`
```conf
search prod.enterprise.internal
nameserver 192.168.10.2
nameserver 192.168.10.3
lookup bind file
```

---

#### 3.3 NetBSD Complete Configuration

##### File: `/etc/rc.conf`
```sh
# System Identity
hostname=netbsd-node01.prod.enterprise.internal

# Enable Network Functionality
auto_ifconfig=YES
net_interfaces="wm0 wm1 agr0 vlan10 vlan20"

# Default IPv4 and IPv6 Routing
defaultroute="192.168.10.1"
defaultroute6="2001:db8:10::1"

# Static Routing
static_routes="corp"
route_corp="-net 172.16.0.0/12 10.20.0.1"
```

##### File: `/etc/ifconfig.wm0`
```text
up
```

##### File: `/etc/ifconfig.wm1`
```text
up
```

##### File: `/etc/ifconfig.agr0`
```text
create
agrport wm0
agrport wm1
up
```

##### File: `/etc/ifconfig.vlan10`
```text
create
vlan 10 vlandev agr0
inet 192.168.10.50 netmask 255.255.255.0
inet6 2001:db8:10::50 prefixlen 64
up
```

##### File: `/etc/ifconfig.vlan20`
```text
create
vlan 20 vlandev agr0
inet 10.20.0.50 netmask 255.255.255.0
up
```

---

### 4. Real CLI Commands & Expected Terminal Outputs

#### 4.1 Interface Inspection & Manipulations (`ifconfig`)

##### Command: Display Detailed State of Interface and Aggregation
```console
$ ifconfig lagg0
```
##### Expected Output (FreeBSD):
```text
lagg0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=80000<LINKSTATE>
	ether 52:54:00:fa:9b:11
	laggproto lacp lagghash l2,l3,l4
	laggport: ix0 flags=1c<ACTIVE,COLLECTING,DISTRIBUTING>
	laggport: ix1 flags=1c<ACTIVE,COLLECTING,DISTRIBUTING>
	groups: lagg
	media: Ethernet autoselect
	status: active
```

##### Command: Assign IPv4 Address and Alias Ephemerally
```console
# ifconfig vlan10 inet 192.168.10.75 netmask 255.255.255.0 alias
$ ifconfig vlan10
```
##### Expected Output:
```text
vlan10: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=3<RXCSUM,TXCSUM>
	ether 52:54:00:fa:9b:11
	inet 192.168.10.50 netmask 0ffffff00 broadcast 192.168.10.255
	inet 192.168.10.75 netmask 0ffffff00 broadcast 192.168.10.255
	inet6 fe80::5054:ff:fefa:9b11%vlan10 prefixlen 64 scopeid 0x5
	inet6 2001:db8:10::50 prefixlen 64
	vlan: 10 vlandev: lagg0
	groups: vlan
	media: Ethernet autoselect
	status: active
```

##### Command: Remove Alias Ephemerally
```console
# ifconfig vlan10 inet 192.168.10.75 -alias
```

---

#### 4.2 Routing Table Operations (`route` & `netstat`)

##### Command: Query Active IPv4 Routing Table
```console
$ netstat -rn -f inet
```
##### Expected Output:
```text
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
default            192.168.10.1       UGS      vlan10
10.20.0.0/24       link#6             UC       vlan20      -
10.20.0.1          52:54:00:12:34:56  UHLW     vlan20   1198
127.0.0.1          link#1             UH          lo0
172.16.0.0/12      10.20.0.1          UGS      vlan20
192.168.10.0/24    link#5             UC       vlan10      -
192.168.10.50      link#5             UHS         lo0
```

##### Command: Query Active IPv6 Routing Table
```console
$ netstat -rn -f inet6
```
##### Expected Output:
```text
Routing tables (IPv6):
Destination                       Gateway                         Flags     Netif Expire
::/0                              2001:db8:10::1                  UGS      vlan10
::1                               link#1                          UHS         lo0
2001:db8:10::/64                  link#5                          U        vlan10
2001:db8:10::50                   link#5                          UHS         lo0
fe80::%lo0/64                     link#1                          U           lo0
```

##### Command: Add Static Ephemeral Route and Verify Path
```console
# route add -net 10.50.0.0/16 10.20.0.1
```
##### Expected Output:
```text
add net 10.50.0.0: gateway 10.20.0.1
```

##### Command: Perform Route Lookup for Specific IP Target
```console
$ route -n get 10.50.4.12
```
##### Expected Output:
```text
   route to: 10.50.4.12
destination: 10.50.0.0
    mask: 255.255.0.0
    gateway: 10.20.0.1
    fib: 0
  interface: vlan20
  flags: <UP,GATEWAY,DONE,STATIC>
 recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire
       0         0         0         0      1500         0         0
```

##### Command: Delete Ephemeral Route
```console
# route delete -net 10.50.0.0/16
```
##### Expected Output:
```text
delete net 10.50.0.0
```

---

#### 4.3 Socket & Open Connection Inspection (`sockstat` / `netstat`)

##### Command: Display Listening Sockets with Process Association (FreeBSD)
```console
$ sockstat -4 -6 -l
```
##### Expected Output:
```text
USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS      
root     sshd       1420  4  tcp4   *:22                  *:*
root     sshd       1420  5  tcp6   *:22                  *:*
bind     named      1105  20 tcp4   192.168.10.50:53      *:*
bind     named      1105  21 udp4   192.168.10.50:53      *:*
root     ntpd       890   16 udp4   *:123                 *:*
```

##### Command: OpenBSD Active Sockets Inspection (`netstat`)
```console
$ netstat -na -f inet | grep LISTEN
```
##### Expected Output:
```text
tcp          0      0  *.22                   *.*                    LISTEN
tcp          0      0  192.168.10.50.53       *.*                    LISTEN
```

---

#### 4.4 DNS Resolution & Diagnostics (`drill` / `dig`)

##### Command: Perform Forward DNS Lookup using System Resolver Tool (`drill` - FreeBSD standard)
```console
$ drill -TD freebsd.org
```
##### Expected Output:
```text
;; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 48291
;; flags: qr rd ra ; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 0
;; QUESTION SECTION:
;; freebsd.org.	IN	A

;; ANSWER SECTION:
freebsd.org.	300	IN	A	96.47.72.84
freebsd.org.	300	IN	A	147.28.184.45

;; Query time: 24 msec
;; SERVER: 192.168.10.2
;; WHEN: Thu Aug  6 20:51:54 2026
;; MSG SIZE rcvd: 61
```

---

### 5. Troubleshooting & Verification Guide

```
                         [ Network Incident Reported ]
                                       |
                                       v
                    +------------------------------------+
                    | Layer 1 / Layer 2 Physical Check   |
                    | command: ifconfig -a               |
                    +------------------+-----------------+
                                       |
                   Is Link Status "active" & Up?
                   /                               \
               [NO]                                 [YES]
                /                                     \
    +-----------------------+              +--------------------------+
    | Check Physical Cable, |              | Check 802.1Q VLAN / LACP |
    | Transceiver, Switch   |              | status: ifconfig lagg0   |
    | Port, SFP Status      |              +------------+-------------+
    +-----------------------+                           |
                                            Are LACP ports COLLECTING?
                                            /                        \
                                        [NO]                          [YES]
                                         /                              \
                           +------------------------+      +-------------------------+
                           | Fix Switch LACP Mode   |      | Layer 3 IP Check        |
                           | (Active vs Passive)    |      | command: ping -c 3 IP   |
                           +------------------------+      +------------+------------+
                                                                        |
                                                           Can ping Local Gateway?
                                                           /                     \
                                                       [NO]                       [YES]
                                                        /                           \
                                          +--------------------------+    +-----------------------+
                                          | Verify IP, Subnet Mask,  |    | Check Routing Table   |
                                          | and VLAN Tag ID match    |    | command: netstat -rn  |
                                          +--------------------------+    +-----------+-----------+
                                                                                      |
                                                                          Is Default Route Present?
                                                                          /                       \
                                                                      [NO]                         [YES]
                                                                       /                             \
                                                         +--------------------------+   +---------------------------+
                                                         | Fix defaultrouter in     |   | Check Firewall / Pf /     |
                                                         | /etc/rc.conf or mygate   |   | DNS Resolution            |
                                                         +--------------------------+   | command: drill @DNS host  |
                                                                                        +---------------------------+
```

#### 5.1 Common Production Failure Scenarios & Solutions

##### Scenario A: LACP Aggregate Stuck in `DOWN` or Partial Link State
- **Symptom**: `ifconfig lagg0` shows status `no carrier` or `laggport` status lacking `COLLECTING`/`DISTRIBUTING` flags.
- **Root Cause**: Mismatch in LACP frame transmission timer (fast vs. slow) or switch side configured in static trunk mode instead of dynamic LACP (`lacpmode active`).
- **Diagnosis Command**:
  ```console
  $ ifconfig -v lagg0
  ```
- **Remediation**:
  Ensure switch-side ports are set to LACP active. On FreeBSD, verify `lagghash` matches system architecture requirements:
  ```console
  # ifconfig lagg0 laggproto lacp lagghash l2,l3,l4
  ```

##### Scenario B: IPv6 Duplicate Address Detection (DAD) Failure
- **Symptom**: `ifconfig vlan10` shows IPv6 address marked as `DUPLICATED` or `TENTATIVE`.
- **Root Cause**: Ethernet MAC address conflict on underlying interfaces, or switch looping multicast ICMPv6 Neighbor Solicitation (NS) packets back to the host interface.
- **Diagnosis Command**:
  ```console
  $ dmesg | grep DAD
  ```
  *Output*: `vlan10: DAD complete, duplicate address 2001:db8:10::50 found!`
- **Remediation**:
  Instantiate explicit unique MAC addresses on virtual interface or adjust node static allocation:
  ```console
  # ifconfig vlan10 link 52:54:00:ab:cd:99
  ```

##### Scenario C: Ephemeral Changes Lost After Reboot
- **Symptom**: Static routes or interface IP additions disappear following host maintenance reboot.
- **Root Cause**: Changes executed via `ifconfig` or `route add` directly in terminal without adding directives to `/etc/rc.conf` (FreeBSD/NetBSD) or `/etc/hostname.<if>` (OpenBSD).
- **Verification Rule**:
  Always validate persistent file syntax.
  - **FreeBSD**: Run dry-run rc inspection:
    ```console
    $ service netif restart --dryrun
    ```
  - **OpenBSD**: Check syntax by invoking `/etc/netstart` in debug mode:
    ```console
    # sh -x /etc/netstart vlan10
    ```

---

#### 5.2 Diagnostic Tool Reference Cheat Sheet

1. **Packet Capture on Specific Interface**:
   ```console
   # tcpdump -nni vlan10 -c 10 'icmp or icmp6'
   ```
2. **Trace Route Path to Remote Destination**:
   ```console
   $ traceroute -n 8.8.8.8
   $ traceroute6 -n 2001:4860:4860::8888
   ```
3. **Verify ARP Table (IPv4 MAC Resolution)**:
   ```console
   $ arp -an
   ```
4. **Verify NDP Table (IPv6 Neighbor Discovery Protocol)**:
   ```console
   $ ndp -an
   ```

---

### 6. References

- **Linux Professional Institute (LPI) BSD Specialist Official Overview**:
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
- **FreeBSD Handbook - Chapter 33: Network Configuration**:
  https://docs.freebsd.org/en/books/handbook/network/
- **FreeBSD Manual Pages - `ifconfig(8)`**:
  https://man.freebsd.org/cgi/man.cgi?query=ifconfig&sektion=8
- **FreeBSD Manual Pages - `lagg(4)`**:
  https://man.freebsd.org/cgi/man.cgi?query=lagg&sektion=4
- **OpenBSD FAQ - Network Configuration**:
  https://www.openbsd.org/faq/faq6.html
- **OpenBSD Manual Pages - `hostname.if(5)`**:
  https://man.openbsd.org/hostname.if.5
- **NetBSD Documentation - Network Configuration**:
  https://www.netbsd.org/docs/guide/en/chap-netconn.html