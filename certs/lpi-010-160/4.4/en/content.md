# 4.4 Your Computer on the Network

**Exam:** LPI Linux Essentials 010-160 (version 1.6) — **Weight: 2**

---

## Overview

Almost every Linux system today is connected to a network. This topic covers the basic concepts you need to understand and inspect that connection:

- What a computer needs to participate in a network: **IP address**, **subnet mask**, **default gateway (router)**, and **DNS servers**
- **IPv4** and **IPv6** addressing
- Querying the network configuration (`ip addr show`, `ip route show`, and the legacy `ifconfig`/`route`)
- Querying the DNS client configuration (`/etc/resolv.conf`, `/etc/hosts`, `host`, `dig`)
- Testing connectivity (`ping`) and inspecting connections (`ss`, `netstat`)

---

## 1. Fundamental Network Concepts

### 1.1 What a computer needs to be on the network

For a computer to communicate on an IP network — including the Internet — it needs four pieces of configuration:

| Setting | Purpose |
|---|---|
| **IP address** | Uniquely identifies the machine on its network |
| **Subnet mask / prefix** | Defines which addresses belong to the *local* network (reachable directly) |
| **Default gateway** | The **router** that forwards traffic destined for *other* networks, including the Internet |
| **DNS server** | Translates human-readable names (`www.lpi.org`) into IP addresses |

These values can be set **manually (static configuration)** or obtained **automatically via DHCP** (Dynamic Host Configuration Protocol), which is the norm on home and office networks: when the machine joins the network, a DHCP server leases it an address and supplies the gateway and DNS servers.

A **router** connects networks together. When your machine wants to reach an address outside its local subnet, it sends the packets to the default gateway, which forwards them hop by hop toward the destination. The Internet is exactly that: a worldwide mesh of interconnected networks and routers.

### 1.2 IPv4

An **IPv4** address is a 32-bit number written as four decimal octets, e.g. `192.168.1.20`. The **subnet mask** (e.g. `255.255.255.0`, also written as the prefix `/24`) splits the address into a *network* part and a *host* part: with `192.168.1.20/24`, every address starting with `192.168.1.` is on the same local network.

Three IPv4 ranges are reserved for **private networks** (defined in RFC 1918). They are used inside homes and companies and are *not* routable on the public Internet:

| Range | Prefix |
|---|---|
| `10.0.0.0` – `10.255.255.255` | `10.0.0.0/8` |
| `172.16.0.0` – `172.31.255.255` | `172.16.0.0/12` |
| `192.168.0.0` – `192.168.255.255` | `192.168.0.0/16` |

Machines with private addresses reach the Internet through **NAT** (Network Address Translation): the router rewrites their traffic so it appears to come from the router's single public address.

Two special addresses to recognize:

- `127.0.0.1` — the **loopback** address (`localhost`), which always refers to the machine itself
- `169.254.x.x` — a **link-local** address that a host auto-assigns itself when DHCP fails; seeing one usually means "DHCP didn't work"

### 1.3 IPv6

IPv4 offers only about 4.3 billion addresses, which is no longer enough — that's why **IPv6** exists. An IPv6 address is **128 bits**, written as eight groups of four hexadecimal digits:

```
2001:0db8:0000:0000:0000:0000:0000:0001
```

Two abbreviation rules make addresses shorter: leading zeros in a group may be dropped, and *one* run of consecutive all-zero groups may be replaced with `::`. The address above becomes `2001:db8::1`.

Useful IPv6 facts for the exam:

- `::1` is the IPv6 **loopback** address (equivalent to `127.0.0.1`)
- Addresses starting with `fe80::` are **link-local**, automatically assigned to every interface and valid only on the local network segment
- `2001:db8::/32` is reserved for documentation and examples
- IPv4 and IPv6 commonly run in parallel on the same machine (**dual stack**)

### 1.4 DNS

The **Domain Name System (DNS)** is the Internet's distributed directory: it maps names like `learning.lpi.org` to IP addresses. On Linux, the classic client-side configuration lives in two files:

**`/etc/resolv.conf`** lists the DNS servers (resolvers) to query:

```
$ cat /etc/resolv.conf
search example.com
nameserver 192.168.1.1
nameserver 9.9.9.9
```

On many modern distributions this file is managed automatically (by NetworkManager or `systemd-resolved`, in which case `nameserver 127.0.0.53` points to a local stub resolver) — but it remains the file to know for the exam.

**`/etc/hosts`** provides static, local name-to-address mappings that are checked *before* DNS is queried:

```
$ cat /etc/hosts
127.0.0.1   localhost
::1         localhost
192.168.1.10  fileserver.lan fileserver
```

The lookup order (files first, then DNS) is defined by the `hosts:` line in `/etc/nsswitch.conf`.

---

## 2. Querying the Network Configuration

### 2.1 The `ip` command (current standard)

The `ip` utility (from the `iproute2` package) is the modern tool for inspecting and configuring networking. The two subcommands to master:

**Show addresses and interfaces — `ip addr show`** (abbreviable to `ip a`):

```
$ ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN ...
    inet 127.0.0.1/8 scope host lo
    inet6 ::1/128 scope host
2: enp3s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP ...
    link/ether 08:00:27:9b:2a:f1 brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.20/24 brd 192.168.1.255 scope global dynamic enp3s0
    inet6 fe80::a00:27ff:fe9b:2af1/64 scope link
```

Reading this output: interface `enp3s0` is **UP**, its MAC address is `08:00:27:9b:2a:f1`, its IPv4 address is `192.168.1.20` with a `/24` mask (`dynamic` = obtained via DHCP), and it has an IPv6 link-local address. `lo` is the loopback interface.

**Show the routing table — `ip route show`** (abbreviable to `ip r`):

```
$ ip route show
default via 192.168.1.1 dev enp3s0 proto dhcp metric 100
192.168.1.0/24 dev enp3s0 proto kernel scope link src 192.168.1.20
```

The `default via 192.168.1.1` line identifies the **default gateway**: anything not on `192.168.1.0/24` is sent to the router at `192.168.1.1`. For IPv6, use `ip -6 route show`.

### 2.2 Legacy tools: `ifconfig` and `route`

Older systems (and the exam objectives) also mention the classic `net-tools` commands, now deprecated but still widely seen:

```
$ ifconfig enp3s0
enp3s0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 192.168.1.20  netmask 255.255.255.0  broadcast 192.168.1.255
        ether 08:00:27:9b:2a:f1  txqueuelen 1000  (Ethernet)

$ route -n
Kernel IP routing table
Destination     Gateway        Genmask         Flags Metric Ref Use Iface
0.0.0.0         192.168.1.1    0.0.0.0         UG    100    0   0   enp3s0
192.168.1.0     0.0.0.0        255.255.255.0   U     100    0   0   enp3s0
```

Mapping old to new: `ifconfig` → `ip addr show`, `route` → `ip route show`. In `route -n` output, destination `0.0.0.0` is the default route and the `G` flag marks the gateway.

---

## 3. Testing Connectivity and DNS

### 3.1 `ping` — is the host reachable?

`ping` sends ICMP echo requests and reports replies and round-trip times. It is the first diagnostic tool for "is the network working?":

```
$ ping -c 3 www.lpi.org
PING www.lpi.org (65.39.134.165) 56(84) bytes of data.
64 bytes from 65.39.134.165: icmp_seq=1 ttl=54 time=18.3 ms
64 bytes from 65.39.134.165: icmp_seq=2 ttl=54 time=18.1 ms
64 bytes from 65.39.134.165: icmp_seq=3 ttl=54 time=18.4 ms

--- www.lpi.org ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
```

`-c 3` limits it to three packets (otherwise it runs until interrupted with `Ctrl+C`). Use `ping6` (or `ping -6`) for IPv6. A classic troubleshooting sequence: ping the gateway, then a public IP like `9.9.9.9`, then a hostname — if the IP works but the name doesn't, the problem is DNS.

### 3.2 `host` and `dig` — querying DNS

`host` performs simple name lookups:

```
$ host learning.lpi.org
learning.lpi.org has address 208.94.166.201

$ host 208.94.166.201
201.166.94.208.in-addr.arpa domain name pointer lpi.org.
```

`dig` gives a detailed view of the DNS answer, useful for debugging:

```
$ dig +short www.lpi.org
65.39.134.165
```

### 3.3 `ss` and `netstat` — sockets and connections

`ss` (socket statistics) shows open ports and active connections; it replaces the legacy `netstat`:

```
$ ss -tuln
Netid State  Local Address:Port
tcp   LISTEN 0.0.0.0:22
tcp   LISTEN 127.0.0.53%lo:53
udp   UNCONN 0.0.0.0:68
```

Common option letters (same for both tools): `-t` TCP, `-u` UDP, `-l` listening sockets, `-n` numeric (don't resolve names). The output above shows an SSH server listening on port 22 and a DHCP client on UDP 68. The equivalent legacy command is `netstat -tuln`.

---

## 4. Quick Reference

| Task | Modern command | Legacy command |
|---|---|---|
| Show IP addresses / interfaces | `ip addr show` | `ifconfig` |
| Show routing table / gateway | `ip route show` | `route -n` |
| Test reachability | `ping` / `ping6` | — |
| Resolve a hostname | `host`, `dig` | `nslookup` |
| Show sockets / open ports | `ss -tuln` | `netstat -tuln` |
| DNS resolvers | `/etc/resolv.conf` | — |
| Static name mappings | `/etc/hosts` | — |

Key facts to memorize: the three RFC 1918 private ranges, `127.0.0.1` / `::1` as loopback, `fe80::` as IPv6 link-local, that the **default gateway is a router**, and that DHCP hands out the IP address, gateway, and DNS servers automatically.

---

## Referencias

- LPI Learning Materials, Topic 4.4 "Your Computer on the Network": https://learning.lpi.org/en/learning-materials/010-160/4/4.4/
- LPI Linux Essentials Objectives (version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- `ip` command manual (iproute2): https://man7.org/linux/man-pages/man8/ip.8.html
- `ip-address` and `ip-route` subcommands: https://man7.org/linux/man-pages/man8/ip-address.8.html , https://man7.org/linux/man-pages/man8/ip-route.8.html
- `ping`: https://man7.org/linux/man-pages/man8/ping.8.html
- `ss`: https://man7.org/linux/man-pages/man8/ss.8.html
- `host`: https://man7.org/linux/man-pages/man1/host.1.html
- `resolv.conf`: https://man7.org/linux/man-pages/man5/resolv.conf.5.html
- `hosts`: https://man7.org/linux/man-pages/man5/hosts.5.html
- RFC 1918, "Address Allocation for Private Internets": https://datatracker.ietf.org/doc/html/rfc1918