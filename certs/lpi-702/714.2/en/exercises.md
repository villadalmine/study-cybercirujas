# Advanced SRE & Platform Architecture Study Guide: LPI 702-100
## Topic 714.2: Basic Network Configuration (Exam Weight: 3)

---

## 1. Architectural & Kernel-Level Overview

In BSD operating systems (FreeBSD, OpenBSD, NetBSD), the networking architecture is centered around the kernel socket layer and the **`ifnet`** data structure. Understanding how the kernel processes packets and manages interface states is critical for senior SREs operating production infrastructure.

```
                      +-----------------------------------+
                      |      Userland Applications        |
                      |   (dhclient, ifconfig, route)     |
                      +-----------------+-----------------+
                                        |  ioctl(2) / Routing Sockets (PF_ROUTE)
                                        v
+-----------------------------------------------------------------------------------+
| FreeBSD / OpenBSD / NetBSD Kernel                                                 |
|                                                                                   |
|  +--------------------+     +---------------------+     +----------------------+  |
|  |   Socket Layer     | <-> |   TCP/IP Stack      | <-> |  Kernel Routing Table|  |
|  |   (AF_INET / v6)   |     | (inet4 / inet6)     |     |    (radix tree)      |  |
|  +--------------------+     +----------+----------+     +----------------------+  |
|                                        |                                          |
|                                        v                                          |
|                             +--------------------+                                |
|                             |  struct ifnet      | (Interface Control Block)      |
|                             |  - if_flags        |                                |
|                             |  - if_addrhead     |                                |
|                             |  - if_ioctl        |                                |
|                             +----------+---------+                                |
+----------------------------------------|------------------------------------------+
                                         |
                                         v
                              +--------------------+
                              | Hardware Device    |
                              | Driver (em0, wm0)  |
                              +--------------------+
```

### Key Technical Concepts:
*   **Kernel `struct ifnet`**: Every physical and virtual network device is represented in the BSD kernel by a `struct ifnet` instance. It holds the interface state, queue length, MTU, operational flags (`IFF_UP`, `IFF_BROADCAST`, `IFF_RUNNING`, `IFF_MULTICAST`), and function pointers for link-layer operations.
*   **Interface Configuration Control (`ioctl(2)`)**: Userland utilities such as `ifconfig` communicate directly with the kernel network stack using system calls like `ioctl(2)` with request parameters like `SIOCSIFADDR` (set interface address), `SIOCSIFNETMASK` (set netmask), or `SIOCSIFFLAGS` (set flags like UP/DOWN).
*   **Persistent Configuration Hooks**: BSD systems decouple runtime kernel configuration from storage persistence:
    *   **FreeBSD**: Utilizes `/etc/rc.conf` parsed by `/etc/rc.d/netif` and `subr` scripts.
    *   **OpenBSD**: Uses declarative interface definition files named `/etc/hostname.<if>` parsed by `netstart(8)`.
    *   **NetBSD**: Uses `/etc/ifconfig.<if>` parsed by `/etc/rc.d/network`.
*   **IP Alias Subnetting Rules**: In BSD kernels, assigning multiple IPv4 addresses (aliases) on the same broadcast domain requires setting the alias netmask to **`255.255.255.255`** (`/32`). Using a full prefix size (e.g., `/24`) on an alias duplicates the subnet route entry in the kernel radix routing table, leading to route collisions and unpredictable packet egress paths.
*   **DHCP Architecture (`dhclient`)**: The ISC DHCP client (`dhclient`) operates via BPF (Berkeley Packet Filter) sockets to craft raw Ethernet/UDP frames before an IP address is officially bound. The execution state lifecycle follows `SELECTING` -> `REQUESTING` -> `BOUND` -> `RENEWING` -> `REBINDING`.

---

## 2. Official Reference Sources
*   **LPI BSD Specialist Certification Overview**: [https.www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
*   **FreeBSD Handbook - Network Basics**: [https://docs.freebsd.org/en/books/handbook/network/](https://docs.freebsd.org/en/books/handbook/network/)
*   **FreeBSD `ifconfig(8)` Manual Page**: [https://man.freebsd.org/cgi/man.cgi?query=ifconfig](https://man.freebsd.org/cgi/man.cgi?query=ifconfig)
*   **OpenBSD `hostname.if(5)` Manual Page**: [https://man.openbsd.org/hostname.if.5](https://man.openbsd.org/hostname.if.5)
*   **NetBSD Network Configuration Guide**: [https://www.netbsd.org/docs/network/](https://www.netbsd.org/docs/network/)

---

## 3. Hands-on Guided Production Exercises

### Exercise 1: Runtime Interface Control, CIDR Subnetting, and Alias Management

In this exercise, you will manipulate runtime network interfaces using `ifconfig`, bind primary IP addresses, compute broadcast boundaries, and safely add IPv4/IPv6 interface aliases without corrupting the kernel routing table.

#### Step 1.1: Inspect active interfaces and kernel flags
Run `ifconfig` to audit current interface parameters on a FreeBSD target (`em0` interface):

```bash
# ifconfig em0
```

*Expected Output:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=481009b<RXCSUM,TXCSUM,VLAN_MTU,VLAN_HWTAGGING,VLAN_HWCSUM,WOL_UCAST,WOL_MCAST,WOL_MAGIC,VLAN_HWFILTER>
	ether 52:54:00:12:34:56
	inet 10.0.2.15 netmask 0xffffff00 broadcast 10.0.2.255
	inet6 fe80::5054:ff:fe12:3456%em0 prefixlen 64 scopeid 0x1
	media: Ethernet autoselect (1000baseT <full-duplex>)
	status: active
	nd6 options=23<PERFORMNUD,ACCEPT_RTADV,AUTO_LINKLOCAL>
```

#### Step 1.2: Assign a primary static IPv4 address with explicit netmask
Assign IP `192.168.10.15/24` to interface `em0`. Notice the usage of CIDR notation and hex representation in BSD kernel state.

```bash
# ifconfig em0 inet 192.168.10.15/24 up
# ifconfig em0 inet
```

*Expected Output:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	inet 192.168.10.15 netmask 0xffffff00 broadcast 192.168.10.255
```

#### Step 1.3: Add a secondary IPv4 Alias safely
To bind an secondary IP `192.168.10.20` on the same subnet, apply the BSD-mandatory `/32` (`255.255.255.255`) mask rule to prevent kernel routing table collision.

```bash
# ifconfig em0 inet 192.168.10.20 netmask 255.255.255.255 alias
# ifconfig em0 inet
```

*Expected Output:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	inet 192.168.10.15 netmask 0xffffff00 broadcast 192.168.10.255
	inet 192.168.10.20 netmask 0xffffffff broadcast 192.168.10.20
```

#### Step 1.4: Remove an interface alias
Remove the alias bound in Step 1.3:

```bash
# ifconfig em0 inet 192.168.10.20 -alias
# ifconfig em0 inet
```

*Expected Output:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	inet 192.168.10.15 netmask 0xffffff00 broadcast 192.168.10.255
```

---

#### Verification Questions (Exercise 1)

1. **Question 1.1**: What happens inside the BSD kernel's radix routing table if an administrator configures an IPv4 alias on `em0` using `192.168.10.20 netmask 255.255.255.0` instead of `255.255.255.255` when `192.168.10.15/24` is already active on `em0`?
2. **Question 1.2**: In the output of `ifconfig em0`, what does the `SIMPLEX` flag represent from a network stack architecture perspective?

---

### Exercise 2: Cross-BSD Persistent Network Configuration Syntax

Persistent configuration differs significantly between FreeBSD, OpenBSD, and NetBSD. In this exercise, you will craft syntactically valid configuration manifests for each variant.

#### Step 2.1: Configure persistent networking on FreeBSD (`/etc/rc.conf`)
Open `/etc/rc.conf` and append static network configurations, including interface aliasing and default gateway settings.

```bash
# cat << 'EOF' >> /etc/rc.conf
# Primary interface configuration (FreeBSD syntax)
hostname="bsd-node01.production.internal"
ifconfig_em0="inet 10.100.5.50 netmask 255.255.250.0"
ifconfig_em0_alias0="inet 10.100.5.51 netmask 255.255.255.255"
ifconfig_em0_alias1="inet 10.100.5.52 netmask 255.255.255.255"
defaultrouter="10.100.4.1"
EOF
```

Restart network services on FreeBSD runtime to validate parse syntax:

```bash
# service netif restart && service routing restart
```

*Expected Output:*
```text
Stopping Network: em0.
Starting Network: em0.
add net default: gateway 10.100.4.1
```

#### Step 2.2: Configure persistent networking on OpenBSD (`/etc/hostname.em0`)
On OpenBSD, interface persistence is driven by file naming conventions (`/etc/hostname.<if>`). Create `/etc/hostname.em0` with primary IP, aliases, and DHCP backup options.

```bash
# cat << 'EOF' > /etc/hostname.em0
inet 10.100.5.50 255.255.250.0 10.100.7.255
inet alias 10.100.5.51 255.255.255.255
inet alias 10.100.5.52 255.255.255.255
up
EOF

# cat << 'EOF' > /etc/mygate
10.100.4.1
EOF
```

Trigger OpenBSD network reload script:

```bash
# sh /etc/netstart em0
```

*Expected Output:*
```text
netstart: configuring em0
```

#### Step 2.3: Configure persistent networking on NetBSD (`/etc/ifconfig.wm0`)
On NetBSD, `/etc/ifconfig.<if>` stores parameters passed directly to `ifconfig` at system init.

```bash
# cat << 'EOF' > /etc/ifconfig.wm0
up
10.100.5.50 netmask 255.255.250.0 broadcast 10.100.7.255
alias 10.100.5.51 netmask 255.255.255.255
EOF

# cat << 'EOF' >> /etc/rc.conf
mygate="10.100.4.1"
EOF
```

Restart NetBSD network subsystem:

```bash
# /etc/rc.d/network restart
```

*Expected Output:*
```text
Stopping network elements: wm0.
Starting network elements: wm0.
```

---

#### Verification Questions (Exercise 2)

1. **Question 2.1**: In FreeBSD's `/etc/rc.conf`, what happens if you specify `ifconfig_em0="DHCP"` alongside `defaultrouter="10.100.4.1"`? Which component sets the default route upon booting?
2. **Question 2.2**: Compare OpenBSD's `/etc/mygate` and FreeBSD's `defaultrouter`. How does NetBSD handle static default gateways persistently?

---

### Exercise 3: DHCP Client Mechanics, Lease Diagnostics, and Overrides

In this exercise, you will inspect `dhclient` operational mechanics, analyze lease files in `/var/db/`, and configure `/etc/dhclient.conf` to override server-offered parameters like DNS resolution servers.

#### Step 3.1: Execute runtime DHCP release and request cycles
Release the current lease on `em0` and start `dhclient` in foreground debug mode to observe the DORA (Discover, Offer, Request, Acknowledge) cycle.

```bash
# dhclient -r em0
# dhclient -d em0
```

*Expected Output:*
```text
DHCPRELEASE on em0 to 192.168.1.1 port 67
DHCPDISCOVER on em0 to 255.255.255.255 port 67 interval 3
DHCPOFFER from 192.168.1.1
DHCPREQUEST on em0 to 255.255.255.255 port 67
DHCPACK from 192.168.1.1 via em0
bound to 192.168.1.105 -- renewal in 43200 seconds.
^C
```

#### Step 3.2: Inspect the active lease state database
Examine the active lease state recorded by `dhclient` on disk:

```bash
# cat /var/db/dhclient.leases.em0
```

*Expected Output:*
```text
lease {
  interface "em0";
  fixed-address 192.168.1.105;
  option subnet-mask 255.255.255.0;
  option routers 192.168.1.1;
  option dhcp-lease-time 86400;
  option dhcp-message-type 5;
  option domain-name-servers 192.168.1.1;
  option dhcp-server-identifier 192.168.1.1;
  renew 4 2026/08/06 12:00:00;
  rebind 4 2026/08/06 21:00:00;
  expire 5 2026/08/07 00:00:00;
}
```

#### Step 3.3: Configure `/etc/dhclient.conf` parameter overrides
In enterprise SRE environments, local DNS policies often require overriding or prepending custom recursive resolvers (e.g., internal Anycast DNS `10.0.0.2` and Cloudflare `1.1.1.1`) regardless of what the untrusted DHCP server supplies.

Create `/etc/dhclient.conf`:

```bash
# cat << 'EOF' > /etc/dhclient.conf
interface "em0" {
    # Force client to ignore DHCP server provided DNS and use production resolvers
    supersede domain-name-servers 10.0.0.2, 1.1.1.1;
    # Prepend internal domain search path
    prepend domain-name "corp.internal enterprise.local";
    # Set maximum request timeout
    timeout 15;
}
EOF
```

Restart `dhclient` to apply changes:

```bash
# dhclient -r em0 && dhclient em0
# cat /etc/resolv.conf
```

*Expected Output:*
```text
# Generated by dhclient
search corp.internal enterprise.local
nameserver 10.0.0.2
nameserver 1.1.1.1
```

---

#### Verification Questions (Exercise 3)

1. **Question 3.1**: What is the structural difference between `supersede domain-name-servers` and `prepend domain-name-servers` inside `/etc/dhclient.conf`?
2. **Question 3.2**: If `dhclient` fails to contact any DHCP server during boot and no active lease file exists in `/var/db/dhclient.leases`, how does `dhclient` behave when a `fallback` statement is defined in `/etc/dhclient.conf`?

---

### Exercise 4: IPv6 Configuration, Link-Local Addressing, SLAAC, and Privacy Extensions

This exercise covers IPv6 state configuration on BSD, differentiating between Link-Local addresses, SLAAC (Stateless Address Autoconfiguration), DHCPv6, and EUI-64 vs. RFC 4941 Privacy Extensions.

#### Step 4.1: Manual IPv6 address binding and scope analysis
Assign a static IPv6 Global Unicast Address (GUA) to `em0`:

```bash
# ifconfig em0 inet6 2001:db8:abc:100::50/64
# ifconfig em0 inet6
```

*Expected Output:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	inet6 fe80::5054:ff:fe12:3456%em0 prefixlen 64 scopeid 0x1
	inet6 2001:db8:abc:100::50 prefixlen 64
```

#### Step 4.2: Enable IPv6 Stateless Address Autoconfiguration (SLAAC)
Configure FreeBSD runtime to listen for IPv6 ICMPv6 Router Advertisements (RA) via `rtsold` / kernel `accept_rtadv`.

On FreeBSD (`/etc/rc.conf`):
```bash
# sysctl net.inet6.ip6.accept_rtadv=1
# ifconfig em0 inet6 accept_rtadv
```

On OpenBSD (`/etc/hostname.em0`):
```text
inet6 autoconf
```

Execute `rtsol` manually to force a Router Solicitation:

```bash
# rtsol em0
# ifconfig em0 inet6
```

*Expected Output:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	inet6 fe80::5054:ff:fe12:3456%em0 prefixlen 64 scopeid 0x1
	inet6 2001:db8:abc:100:5054:ff:fe12:3456 prefixlen 64 autoconf status autoconf
	inet6 2001:db8:abc:100::50 prefixlen 64
```

#### Step 4.3: Configure IPv6 Privacy Extensions (RFC 4941)
Prevent MAC address tracking via EUI-64 by enabling privacy addresses in sysctl:

```bash
# sysctl net.inet6.ip6.use_tempaddr=2
```

*Expected Output:*
```text
net.inet6.ip6.use_tempaddr: 0 -> 2
```

---

#### Verification Questions (Exercise 4)

1. **Question 4.1**: What does the `%em0` suffix appended to IPv6 link-local addresses (`fe80::5054:ff:fe12:3456%em0`) represent, and why is it mandatory for link-local sockets/ping commands?
2. **Question 4.2**: In IPv6 SLAAC, what mechanism prevents two nodes on the same Ethernet segment from autoconfiguring identical IPv6 addresses via EUI-64 or privacy addresses?

---

### Exercise 5: Advanced Network Diagnostics, Kernel Routing, and Interface Flags

In this exercise, you will use kernel network inspection tools (`netstat`, `route`, `arp`) to analyze routing decisions and troubleshoot interface state mismatches.

#### Step 5.1: Query the Kernel Routing Table (Radix Tree)
Inspect the active IPv4 and IPv6 routing tables:

```bash
# netstat -rn -f inet
```

*Expected Output:*
```text
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
default            10.100.4.1         UGS         em0
10.100.4.0/21      link#1             UC          em0      -
10.100.4.1         52:54:00:12:00:01  UHLW        em0   1198
127.0.0.1          link#2             UH          lo0
```

#### Step 5.2: Trace route selection for a specific destination IP
Use `route get` to query how the kernel routes packets to a target IP (`8.8.8.8`):

```bash
# route -n get 8.8.8.8
```

*Expected Output:*
```text
   route to: 8.8.8.8
destination: 0.0.0.0
    mask: 0.0.0.0
  gateway: 10.100.4.1
  fib: 0
  interface: em0
    flags: <UP,GATEWAY,DONE,STATIC>
 recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire
       0         0         0         0      1500         0         0
```

#### Step 5.3: Inspect ARP table state
Display and manipulate neighbor resolution cache entries:

```bash
# arp -an
```

*Expected Output:*
```text
? (10.100.4.1) at 52:54:00:12:00:01 on em0 expires in 1195 seconds [ethernet]
? (10.100.5.50) at 52:54:00:12:34:56 on em0 permanent [ethernet]
```

---

#### Verification Questions (Exercise 5)

1. **Question 5.1**: In `netstat -rn` output, what do the routing flags `UGS` and `UHLW` stand for individually?
2. **Question 5.2**: An administrator sets `ifconfig em0 down`. Does `netstat -rn` immediately purge the routes associated with `em0` from the BSD kernel memory? Explain the operational impact.

---

## 4. Solutions and Architectural Explanations

<details>
<summary>Click to expand official solutions for Exercises 1 to 5</summary>

### Exercise 1 Solutions

*   **Answer 1.1**: If an alias is configured with a full netmask (`255.255.250.0` or `255.255.255.0`) identical to the primary IP on the same physical interface, the BSD kernel attempts to insert a second, identical subnet route entry into its radix routing tree. This causes a route table conflict or non-deterministic behavior where outbound traffic intended for local broadcast or subnet targets might select the alias IP address as the source IP instead of the primary interface IP, breaking stateful firewall rules (PF/IPFW) and source-IP-sensitive services. Assigning `255.255.255.255` (`/32`) explicitly tells the kernel that the alias is a single host entry and does not redefine a subnet boundary.
*   **Answer 1.2**: The `SIMPLEX` flag indicates that the hardware interface cannot hear its own transmitted packets. In ethernet controllers, this means the interface hardware driver handles transmit and receive channels separately in full-duplex, and packet loopback for locally bound traffic must be handled explicitly by the loopback interface (`lo0`) or kernel software loopback rather than physical wire reflections.

---

### Exercise 2 Solutions

*   **Answer 2.1**: When `ifconfig_em0="DHCP"` is configured in FreeBSD's `/etc/rc.conf`, the system starts `dhclient` via `/etc/rc.d/dhclient`. If a DHCP server provides a router option, `dhclient` invokes `/sbin/route add default <gateway>` upon obtaining a lease. If `defaultrouter` is ALSO specified statically in `/etc/rc.conf`, the startup script `/etc/rc.d/routing` attempts to set the static default gateway. However, `dhclient` running later will overwrite or fail to set the route depending on route table flags. Best practice in BSD production is to leave `defaultrouter` unset when using DHCP.
*   **Answer 2.2**:
    *   **OpenBSD**: Uses the simple file `/etc/mygate` containing a single IPv4/IPv6 address per line. The `/etc/netstart` script reads `/etc/mygate` and executes `route add default <address>`.
    *   **FreeBSD**: Uses `defaultrouter="x.x.x.x"` inside `/etc/rc.conf`.
    *   **NetBSD**: Uses `mygate="x.x.x.x"` inside `/etc/rc.conf` (parsed by `/etc/rc.d/network`). NetBSD can also use `/etc/mygate` if enabled.

---

### Exercise 3 Solutions

*   **Answer 3.1**:
    *   `supersede domain-name-servers`: Completely replaces and overrides any DNS servers offered by the DHCP server in the DHCPACK packet with the specified IP addresses. The DNS IPs supplied by the DHCP server are ignored.
    *   `prepend domain-name-servers`: Takes the specified IP addresses and inserts them at the *beginning* of the DNS server list returned by the DHCP server. Any DNS servers received via DHCP will still be included in `/etc/resolv.conf`, but listed after the prepended IPs.
*   **Answer 3.2**: When `dhclient` cannot locate a DHCP server and has no valid cached lease in `/var/db/dhclient.leases`, it checks `/etc/dhclient.conf` for a `alias { ... }` or `fallback` declaration. If defined, `dhclient` executes the `dhclient-script` to configure the interface with the predefined static fallback IP address and default gateway parameters, allowing headless production systems to maintain minimal out-of-band management access during total DHCP infrastructure outages.

---

### Exercise 4 Solutions

*   **Answer 4.1**: The `%em0` string is the **Zone Index** (or Scope Zone Identifier). Because link-local IPv6 addresses (`fe80::/10`) are non-routable and identical address spaces can exist concurrently on multiple physical interfaces (e.g., `em0`, `em1`, `igb0`), the kernel routing table cannot determine which physical link to egress packets onto based solely on the IPv6 address `fe80::1`. The zone index explicitly binds the socket operation to the specific physical interface index.
*   **Answer 4.2**: **Duplicate Address Detection (DAD)**. When an IPv6 address is configured via SLAAC (or statically), the BSD kernel places the address into a `tentative` state (visible in `ifconfig` as `inet6 ... flags=TENTATIVE`). Before claiming the address, the node sends an ICMPv6 **Neighbor Solicitation (NS)** message to the Solicited-Node Multicast address (`ff02::1:ffXX:XXXX`). If another node responds with a Neighbor Advertisement (NA), address collision is detected, the kernel marks the address as `DUPLICATE`, disables the interface IPv6 binding, and logs a kernel alert.

---

### Exercise 5 Solutions

*   **Answer 5.1**:
    *   `U`: Route is **Up** (active in routing table).
    *   `G`: **Gateway** (the destination requires forwarding through an intermediate router/gateway address).
    *   `S`: **Static** route manually added via configuration files or CLI, not dynamically learned via routing protocols (RIP/OSPF/BGP).
    *   `H`: **Host** route (matches a single specific host `/32` or `/128`, rather than an entire network subnet).
    *   `L`: **Link-layer** (contains MAC address mapping hardware information).
    *   `W`: **Cloned** route generated dynamically by ARP or Neighbor Discovery (Wand/Wormhole route in BSD kernel terminology).
*   **Answer 5.2**: Bringing an interface down via `ifconfig em0 down` modifies the `struct ifnet` interface flags in the kernel, removing the `IFF_UP` flag. The kernel immediately marks connected interface subnet routes as inactive (removing the `U` flag). However, static routing entries referencing `em0` as a gateway remain in the routing table unless explicitly deleted, but packet forwarding through `em0` fails immediately at the socket layer with `EHOSTUNREACH` (No route to host) or `ENETDOWN` (Network is down).

</details>